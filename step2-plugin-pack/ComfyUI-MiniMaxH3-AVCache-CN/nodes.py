# SPDX-License-Identifier: GPL-3.0-or-later

from __future__ import annotations

import logging
import warnings

import torch

import comfy.model_patcher
import comfy.patcher_extension


SMART_KEY = "minimax_h3_av_cache"
EPSILON = 1e-6
GIB = 1024 ** 3


def _require_h3(model):
    diffusion_model = model.get_model_object("diffusion_model")
    if diffusion_model.__class__.__name__ != "MiniMaxH3Model":
        raise ValueError("MiniMax H3 音画智能缓存只能用于 MiniMax H3 模型")
    return diffusion_model


def _validate_window(start_percent, end_percent):
    if start_percent >= end_percent:
        raise ValueError("开始位置必须小于结束位置")


def _reject_cache_stacking(model):
    transformer_options = model.model_options.get("transformer_options", {})
    active = [key for key in ("easycache", SMART_KEY) if key in transformer_options]
    if active:
        raise ValueError(f"不能与其他缓存节点叠加使用：{', '.join(active)}")


def _mean_abs(tensor):
    return tensor.float().flatten().abs().mean()


def _tensor_bytes(tensor):
    return tensor.numel() * tensor.element_size()


def _gpu_cache_fits(free_bytes, current_cache_bytes, desired_cache_bytes, safety_margin_gb):
    projected_free = free_bytes + current_cache_bytes - desired_cache_bytes
    return projected_free >= safety_margin_gb * GIB


def _gpu_free_bytes(device):
    torch_free_bytes, _ = torch.cuda.mem_get_info(device)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", FutureWarning)
            import pynvml
        pynvml.nvmlInit()
        try:
            device_index = device.index if device.index is not None else torch.cuda.current_device()
            handle = pynvml.nvmlDeviceGetHandleByIndex(device_index)
            physical_free_bytes = pynvml.nvmlDeviceGetMemoryInfo(handle).free
        finally:
            pynvml.nvmlShutdown()
        return min(torch_free_bytes, physical_free_bytes)
    except Exception:
        return torch_free_bytes


def _find_transformer_options(args, kwargs):
    options = kwargs.get("transformer_options")
    if isinstance(options, dict):
        return options
    for value in reversed(args):
        if isinstance(value, dict) and ("sigmas" in value or SMART_KEY in value):
            return value
    raise RuntimeError("MiniMax H3 音画智能缓存无法找到模型运行参数")


def _stream_pair(value):
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise ValueError("MiniMax H3 音画智能缓存需要同时收到视频和音频张量")
    return value[0], value[1]


def _first_uuid_slice(tensor, uuids, first_uuid):
    if not uuids:
        return tensor
    batch_offset = tensor.shape[0] // len(uuids)
    index = uuids.index(first_uuid)
    return tensor[index * batch_offset:(index + 1) * batch_offset]


def _video_signature(tensor, factor, uuids, first_uuid):
    tensor = _first_uuid_slice(tensor, uuids, first_uuid)
    if factor > 1:
        tensor = tensor[..., ::factor, ::factor]
    return tensor.detach().float().clone()


def _audio_signature(tensor, factor, uuids, first_uuid):
    tensor = _first_uuid_slice(tensor, uuids, first_uuid)
    if factor > 1:
        tensor = tensor[..., ::factor]
    return tensor.detach().float().clone()


class H3SmartCacheState:
    def __init__(self, video_threshold, audio_threshold, start_percent, end_percent, max_consecutive_skips,
                 spatial_subsample, audio_subsample, cache_device, safety_margin_gb, verbose=False):
        self.video_threshold = video_threshold
        self.audio_threshold = audio_threshold
        self.start_percent = start_percent
        self.end_percent = end_percent
        self.max_consecutive_skips = max_consecutive_skips
        self.spatial_subsample = spatial_subsample
        self.audio_subsample = audio_subsample
        self.cache_device = cache_device
        self.safety_margin_gb = safety_margin_gb
        self.verbose = verbose
        self.start_sigma = None
        self.end_sigma = None
        self.reset()

    def clone(self):
        return H3SmartCacheState(
            self.video_threshold,
            self.audio_threshold,
            self.start_percent,
            self.end_percent,
            self.max_consecutive_skips,
            self.spatial_subsample,
            self.audio_subsample,
            self.cache_device,
            self.safety_margin_gb,
            self.verbose,
        )

    def prepare(self, model_sampling):
        self.start_sigma = model_sampling.percent_to_sigma(self.start_percent)
        self.end_sigma = model_sampling.percent_to_sigma(self.end_percent)
        return self

    def reset(self):
        self.first_uuid = None
        self.skip_current_step = False
        self.consecutive_skips = 0
        self.cumulative_video = 0.0
        self.cumulative_audio = 0.0
        self.video_rate = None
        self.audio_rate = None
        self.prev_step_video_input = None
        self.prev_step_audio_input = None
        self.last_full_video_input = None
        self.last_full_audio_input = None
        self.last_full_video_output = None
        self.last_full_audio_output = None
        self.video_output_norm = None
        self.audio_output_norm = None
        self.video_cache_diffs = {}
        self.audio_cache_diffs = {}
        self.metadata = None
        self.total_steps_skipped = 0
        self.total_full_steps = 0
        self.last_video_score = None
        self.last_audio_score = None
        self.safety_rejections = 0
        self.last_cache_bytes = 0
        self.low_memory_warned = False

    def in_window(self, sigmas):
        if sigmas is None or self.start_sigma is None or self.end_sigma is None:
            return False
        sigma = float(sigmas.flatten()[0])
        return sigma <= float(self.start_sigma) and sigma > float(self.end_sigma)

    def check_metadata(self, video, audio):
        metadata = (
            tuple(video.shape[1:]), video.dtype, video.device.type, video.device.index,
            tuple(audio.shape[1:]), audio.dtype, audio.device.type, audio.device.index,
        )
        if self.metadata is None:
            self.metadata = metadata
            return
        if metadata != self.metadata:
            logging.warning("MiniMax H3 音画智能缓存：张量形状、精度或设备发生变化，缓存已重置")
            self.reset()
            self.metadata = metadata

    def can_apply(self, uuids):
        return bool(uuids) and all(uuid in self.video_cache_diffs and uuid in self.audio_cache_diffs for uuid in uuids)

    def _apply_stream(self, tensor, uuids, cache):
        batch_offset = tensor.shape[0] // len(uuids)
        output = torch.empty_like(tensor)
        with torch.no_grad():
            for index, uuid in enumerate(uuids):
                item = slice(index * batch_offset, (index + 1) * batch_offset)
                current = tensor[item]
                residual = cache[uuid].to(device=current.device, dtype=current.dtype, non_blocking=True)
                torch.add(current, residual, out=output[item])
        return output

    def apply(self, video, audio, uuids):
        return [
            self._apply_stream(video, uuids, self.video_cache_diffs),
            self._apply_stream(audio, uuids, self.audio_cache_diffs),
        ]

    def _clear_cache(self):
        self.video_cache_diffs.clear()
        self.audio_cache_diffs.clear()
        self.last_cache_bytes = 0

    def _gpu_cache_bytes(self, device):
        caches = (*self.video_cache_diffs.values(), *self.audio_cache_diffs.values())
        return sum(_tensor_bytes(tensor) for tensor in caches if tensor.device == device)

    def _can_store_gpu_cache(self, video_output, audio_output):
        desired_by_device = {}
        for tensor in (video_output, audio_output):
            if tensor.device.type == "cuda":
                desired_by_device[tensor.device] = desired_by_device.get(tensor.device, 0) + _tensor_bytes(tensor)

        for device, desired_bytes in desired_by_device.items():
            free_bytes = _gpu_free_bytes(device)
            current_bytes = self._gpu_cache_bytes(device)
            if not _gpu_cache_fits(
                free_bytes, current_bytes, desired_bytes, self.safety_margin_gb
            ):
                projected_gb = (free_bytes + current_bytes - desired_bytes) / GIB
                if not self.low_memory_warned:
                    logging.warning(
                        "MiniMax H3 音画智能缓存：预计缓存后仅剩 %.2fGB，低于 %.2fGB 安全余量；显存恢复前不保存缓存",
                        max(projected_gb, 0.0), self.safety_margin_gb,
                    )
                    self.low_memory_warned = True
                self.safety_rejections += 1
                self._clear_cache()
                return False
        return True

    def _update_cache(self, output, current, uuids, target):
        stale = set(target) - set(uuids)
        for uuid in stale:
            del target[uuid]
        batch_offset = output.shape[0] // len(uuids)
        for index, uuid in enumerate(uuids):
            item = slice(index * batch_offset, (index + 1) * batch_offset)
            output_item = output[item].detach()
            current_item = current[item].detach()
            target_device = torch.device("cpu") if self.cache_device == "cpu" else output_item.device
            existing = target.get(uuid)
            reusable = (
                existing is not None
                and existing.shape == output_item.shape
                and existing.dtype == output_item.dtype
                and existing.device == target_device
            )
            with torch.no_grad():
                if reusable:
                    existing.copy_(output_item, non_blocking=target_device.type == "cpu")
                    existing.sub_(current_item.to(target_device, non_blocking=target_device.type == "cpu"))
                elif target_device == output_item.device:
                    target[uuid] = output_item.sub(current_item)
                else:
                    cached = output_item.to(target_device, copy=True, non_blocking=True)
                    cached.sub_(current_item.to(target_device, non_blocking=True))
                    target[uuid] = cached

    def update_cache(self, video_output, audio_output, video_input, audio_input, uuids):
        if self.cache_device != "cpu" and not self._can_store_gpu_cache(video_output, audio_output):
            return False
        try:
            self._update_cache(video_output, video_input, uuids, self.video_cache_diffs)
            self._update_cache(audio_output, audio_input, uuids, self.audio_cache_diffs)
        except torch.cuda.OutOfMemoryError:
            self._clear_cache()
            self.safety_rejections += 1
            torch.cuda.empty_cache()
            logging.warning("MiniMax H3 音画智能缓存：缓存分配触发显存不足，缓存已安全清理")
            return False
        self.last_cache_bytes = sum(
            _tensor_bytes(tensor)
            for tensor in (*self.video_cache_diffs.values(), *self.audio_cache_diffs.values())
        )
        return True


def smartcache_calc_cond_batch_wrapper(executor, *args, **kwargs):
    model_options = args[-1]
    state = model_options["transformer_options"][SMART_KEY]
    state.skip_current_step = False
    return executor(*args, **kwargs)


def smartcache_forward_wrapper(executor, *args, **kwargs):
    transformer_options = _find_transformer_options(args, kwargs)
    state = transformer_options[SMART_KEY]
    video, audio = _stream_pair(args[0])
    uuids = transformer_options.get("uuids") or ["minimax-h3"]
    state.check_metadata(video, audio)

    if state.first_uuid is None:
        state.first_uuid = uuids[0]

    is_first_cond = state.first_uuid in uuids
    can_apply = state.can_apply(uuids)
    in_window = state.in_window(transformer_options.get("sigmas"))

    if in_window and not is_first_cond and state.skip_current_step and can_apply:
        return state.apply(video, audio, uuids)

    video_input_signature = None
    audio_input_signature = None
    video_input_change = None
    audio_input_change = None
    should_skip = False

    if is_first_cond:
        video_input_signature = _video_signature(video, state.spatial_subsample, uuids, state.first_uuid)
        audio_input_signature = _audio_signature(audio, state.audio_subsample, uuids, state.first_uuid)
        if in_window and state.prev_step_video_input is not None and state.prev_step_audio_input is not None:
            video_input_change = (video_input_signature - state.prev_step_video_input).flatten().abs().mean()
            audio_input_change = (audio_input_signature - state.prev_step_audio_input).flatten().abs().mean()
            if state.video_rate is not None and state.audio_rate is not None:
                video_score = state.video_rate * video_input_change / state.video_output_norm.clamp_min(EPSILON)
                audio_score = state.audio_rate * audio_input_change / state.audio_output_norm.clamp_min(EPSILON)
                state.last_video_score = float(video_score)
                state.last_audio_score = float(audio_score)
                state.cumulative_video += float(video_score)
                state.cumulative_audio += float(audio_score)
                should_skip = (
                    state.cumulative_video < state.video_threshold
                    and state.cumulative_audio < state.audio_threshold
                    and state.consecutive_skips < state.max_consecutive_skips
                    and can_apply
                )

        state.prev_step_video_input = video_input_signature
        state.prev_step_audio_input = audio_input_signature

        if should_skip:
            state.skip_current_step = True
            state.consecutive_skips += 1
            state.total_steps_skipped += 1
            if state.verbose:
                logging.info(
                    "MiniMax H3 音画智能缓存命中：视频=%.6f/%.6f，音频=%.6f/%.6f，连续复用=%d",
                    state.cumulative_video, state.video_threshold,
                    state.cumulative_audio, state.audio_threshold,
                    state.consecutive_skips,
                )
            return state.apply(video, audio, uuids)

        state.skip_current_step = False
        state.consecutive_skips = 0
        state.cumulative_video = 0.0
        state.cumulative_audio = 0.0

    full_output = executor(*args, **kwargs)
    video_output, audio_output = _stream_pair(full_output)
    state.update_cache(video_output, audio_output, video, audio, uuids)

    if is_first_cond:
        video_output_signature = _video_signature(video_output, state.spatial_subsample, uuids, state.first_uuid)
        audio_output_signature = _audio_signature(audio_output, state.audio_subsample, uuids, state.first_uuid)
        if state.last_full_video_input is not None and state.last_full_video_output is not None:
            video_denominator = (video_input_signature - state.last_full_video_input).flatten().abs().mean().clamp_min(EPSILON)
            audio_denominator = (audio_input_signature - state.last_full_audio_input).flatten().abs().mean().clamp_min(EPSILON)
            state.video_rate = (video_output_signature - state.last_full_video_output).flatten().abs().mean() / video_denominator
            state.audio_rate = (audio_output_signature - state.last_full_audio_output).flatten().abs().mean() / audio_denominator
        state.last_full_video_input = video_input_signature
        state.last_full_audio_input = audio_input_signature
        state.last_full_video_output = video_output_signature
        state.last_full_audio_output = audio_output_signature
        state.video_output_norm = _mean_abs(video_output_signature)
        state.audio_output_norm = _mean_abs(audio_output_signature)
        state.total_full_steps += 1
    return full_output


def _sampling_wrapper(state_key, name):
    def wrapper(executor, *args, **kwargs):
        guider = executor.class_obj
        original_model_options = guider.model_options
        guider.model_options = comfy.model_patcher.create_model_options_clone(original_model_options)
        state = guider.model_options["transformer_options"][state_key].clone()
        state.prepare(guider.model_patcher.model.model_sampling)
        guider.model_options["transformer_options"][state_key] = state
        try:
            logging.info("%s enabled", name)
            return executor(*args, **kwargs)
        finally:
            total = state.total_full_steps + state.total_steps_skipped
            speedup = total / max(state.total_full_steps, 1)
            logging.info(
                "%s：复用 %d/%d 次模型调用，缓存 %.2fGB，安全拦截 %d 次（仅按模型计算量估算 %.2f 倍）",
                name, state.total_steps_skipped, total, state.last_cache_bytes / GIB,
                state.safety_rejections, speedup,
            )
            state.reset()
            guider.model_options = original_model_options
    return wrapper


class MiniMaxH3SmartCache:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "模型": ("MODEL", {"tooltip": "连接 MiniMax H3 模型加载器输出的模型。"}),
            "视频阈值": ("FLOAT", {
                "default": 0.12, "min": 0.0, "max": 3.0, "step": 0.01,
                "tooltip": "视频分支允许的累计变化量。数值越大越容易复用缓存、速度越快，但动作和画面细节风险也越高。",
            }),
            "音频阈值": ("FLOAT", {
                "default": 0.06, "min": 0.0, "max": 3.0, "step": 0.01,
                "tooltip": "音频分支允许的累计变化量。数值越大越容易复用缓存，但声音瞬态、口型和音画同步风险也越高。",
            }),
            "开始位置": ("FLOAT", {
                "default": 0.15, "min": 0.0, "max": 1.0, "step": 0.01,
                "tooltip": "从采样进度的这个位置开始允许使用缓存。0.15 表示前 15% 始终完整计算。",
            }),
            "结束位置": ("FLOAT", {
                "default": 0.85, "min": 0.0, "max": 1.0, "step": 0.01,
                "tooltip": "到达这个采样进度后停止使用缓存。0.85 表示后 15% 始终完整计算，以恢复细节和最终收敛。",
            }),
            "最大连续复用": ("INT", {
                "default": 1, "min": 1, "max": 10, "step": 1,
                "tooltip": "缓存最多连续复用多少次，达到次数后强制完整计算并刷新。1 最保守，2 更快；不建议一开始设得很高。",
            }),
            "缓存位置": (["自动", "显卡", "内存"], {
                "default": "自动",
                "tooltip": "缓存张量保存的位置。“自动”仅在满足显存安全余量时使用显卡，否则停用本轮缓存；“内存”必须由用户明确选择，会增加内存与显卡之间的数据传输。",
            }),
            "详细日志": ("BOOLEAN", {
                "default": True, "label_on": "开启", "label_off": "关闭",
                "tooltip": "开启后在 ComfyUI 控制台显示视频/音频判定值、缓存命中次数和估算计算量。正式稳定使用后可以关闭。",
            }),
            "显存安全余量GB": ("FLOAT", {
                "default": 1.5, "min": 0.5, "max": 16.0, "step": 0.1,
                "tooltip": "保存显卡缓存后必须保留的预计可用显存。默认 1.5GB；系统仍然卡顿或同时运行其他显卡程序时可提高到 2～3GB。此限制也适用于手动选择“显卡”。",
            }),
        }}

    RETURN_TYPES = ("MODEL",)
    RETURN_NAMES = ("模型",)
    FUNCTION = "应用缓存"
    CATEGORY = "MiniMax H3/优化"
    DESCRIPTION = "分别监测视频和音频变化，在两者都稳定时复用模型结果。无需修改 ComfyUI 核心文件。"
    EXPERIMENTAL = True

    def 应用缓存(self, 模型, 视频阈值, 音频阈值, 开始位置, 结束位置, 最大连续复用,
                 缓存位置, 详细日志, 显存安全余量GB=1.5):
        _require_h3(模型)
        _validate_window(开始位置, 结束位置)
        _reject_cache_stacking(模型)
        模型 = 模型.clone()
        cache_device = {"自动": "auto", "显卡": "gpu", "内存": "cpu"}[缓存位置]
        state = H3SmartCacheState(
            视频阈值, 音频阈值, 开始位置, 结束位置, 最大连续复用,
            spatial_subsample=8, audio_subsample=8, cache_device=cache_device,
            safety_margin_gb=显存安全余量GB, verbose=详细日志,
        )
        模型.model_options["transformer_options"][SMART_KEY] = state
        模型.remove_wrappers_with_key(comfy.patcher_extension.WrappersMP.OUTER_SAMPLE, SMART_KEY)
        模型.remove_wrappers_with_key(comfy.patcher_extension.WrappersMP.CALC_COND_BATCH, SMART_KEY)
        模型.remove_wrappers_with_key(comfy.patcher_extension.WrappersMP.DIFFUSION_MODEL, SMART_KEY)
        模型.add_wrapper_with_key(comfy.patcher_extension.WrappersMP.OUTER_SAMPLE, SMART_KEY, _sampling_wrapper(SMART_KEY, "MiniMax H3 音画智能缓存"))
        模型.add_wrapper_with_key(comfy.patcher_extension.WrappersMP.CALC_COND_BATCH, SMART_KEY, smartcache_calc_cond_batch_wrapper)
        模型.add_wrapper_with_key(comfy.patcher_extension.WrappersMP.DIFFUSION_MODEL, SMART_KEY, smartcache_forward_wrapper)
        return (模型,)


NODE_CLASS_MAPPINGS = {
    "MiniMaxH3SmartCache": MiniMaxH3SmartCache,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MiniMaxH3SmartCache": "MiniMax H3 音画智能缓存",
}
