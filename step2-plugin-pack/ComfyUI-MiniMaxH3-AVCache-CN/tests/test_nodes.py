from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest
from unittest import mock

import torch


def load_nodes():
    comfy = types.ModuleType("comfy")
    comfy.__path__ = []
    model_patcher = types.ModuleType("comfy.model_patcher")
    model_patcher.create_model_options_clone = lambda options: {
        **options,
        "transformer_options": options["transformer_options"].copy(),
    }
    patcher_extension = types.ModuleType("comfy.patcher_extension")

    class WrappersMP:
        OUTER_SAMPLE = "outer_sample"
        CALC_COND_BATCH = "calc_cond_batch"
        DIFFUSION_MODEL = "diffusion_model"

    patcher_extension.WrappersMP = WrappersMP
    comfy.model_patcher = model_patcher
    comfy.patcher_extension = patcher_extension
    sys.modules["comfy"] = comfy
    sys.modules["comfy.model_patcher"] = model_patcher
    sys.modules["comfy.patcher_extension"] = patcher_extension

    path = pathlib.Path(__file__).parents[1] / "nodes.py"
    spec = importlib.util.spec_from_file_location("minimax_h3_av_cache_nodes", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


nodes = load_nodes()


class SmartCacheTests(unittest.TestCase):
    def make_state(self, audio_threshold=1.0, max_consecutive_skips=2):
        state = nodes.H3SmartCacheState(
            video_threshold=1.0,
            audio_threshold=audio_threshold,
            start_percent=0.1,
            end_percent=0.9,
            max_consecutive_skips=max_consecutive_skips,
            spatial_subsample=1,
            audio_subsample=1,
            cache_device="auto",
            safety_margin_gb=1.5,
        )
        state.start_sigma = 1.0
        state.end_sigma = 0.0
        return state

    def run_step(self, state, video_value, audio_value, calls):
        video = torch.full((1, 24, 1, 2, 2), video_value)
        audio = torch.full((1, 32, 1, 2), audio_value)
        options = {
            nodes.SMART_KEY: state,
            "sigmas": torch.tensor([0.5]),
            "uuids": ["cond"],
        }

        def executor(*args, **kwargs):
            calls.append(1)
            current_video, current_audio = args[0]
            return [current_video + 2.0, current_audio + 3.0]

        return nodes.smartcache_forward_wrapper(
            executor, [video, audio], torch.tensor([0.5]), None, options
        )

    def test_small_video_and_audio_change_reuses_residual(self):
        state = self.make_state()
        calls = []
        self.run_step(state, 0.0, 0.0, calls)
        self.run_step(state, 0.1, 0.1, calls)
        output = self.run_step(state, 0.2, 0.2, calls)

        self.assertEqual(len(calls), 2)
        self.assertTrue(torch.allclose(output[0], torch.full_like(output[0], 2.2)))
        self.assertTrue(torch.allclose(output[1], torch.full_like(output[1], 3.2)))
        self.assertEqual(state.total_steps_skipped, 1)

    def test_large_audio_change_prevents_video_only_cache_hit(self):
        state = self.make_state(audio_threshold=0.05)
        calls = []
        self.run_step(state, 0.0, 0.0, calls)
        self.run_step(state, 0.1, 0.1, calls)
        self.run_step(state, 0.2, 10.1, calls)

        self.assertEqual(len(calls), 3)
        self.assertEqual(state.total_steps_skipped, 0)
        self.assertGreater(state.last_audio_score, state.audio_threshold)

    def test_maximum_consecutive_reuse_forces_refresh(self):
        state = self.make_state(max_consecutive_skips=1)
        calls = []
        self.run_step(state, 0.0, 0.0, calls)
        self.run_step(state, 0.1, 0.1, calls)
        self.run_step(state, 0.2, 0.2, calls)
        self.run_step(state, 0.3, 0.3, calls)

        self.assertEqual(len(calls), 3)
        self.assertEqual(state.total_steps_skipped, 1)

    def test_gpu_cache_budget_preserves_requested_margin(self):
        gib = 1024 ** 3

        self.assertTrue(nodes._gpu_cache_fits(2.0 * gib, 0, 0.4 * gib, 1.5))
        self.assertFalse(nodes._gpu_cache_fits(1.8 * gib, 0, 0.4 * gib, 1.5))
        self.assertTrue(nodes._gpu_cache_fits(0.7 * gib, 1.2 * gib, 0.4 * gib, 1.5))

    def test_gpu_free_memory_uses_conservative_physical_value(self):
        gib = 1024 ** 3
        fake_nvml = types.ModuleType("pynvml")
        fake_nvml.nvmlInit = lambda: None
        fake_nvml.nvmlShutdown = lambda: None
        fake_nvml.nvmlDeviceGetHandleByIndex = lambda index: index
        fake_nvml.nvmlDeviceGetMemoryInfo = lambda handle: types.SimpleNamespace(free=int(0.8 * gib))

        with mock.patch.object(nodes.torch.cuda, "mem_get_info", return_value=(int(2.0 * gib), int(12.0 * gib))):
            with mock.patch.dict(sys.modules, {"pynvml": fake_nvml}):
                free_bytes = nodes._gpu_free_bytes(torch.device("cuda:0"))

        self.assertEqual(free_bytes, int(0.8 * gib))


class NodeRegistrationTests(unittest.TestCase):
    class FakeModel:
        def __init__(self):
            diffusion_class = type("MiniMaxH3Model", (), {})
            self.diffusion_model = diffusion_class()
            self.model_options = {"transformer_options": {}}
            self.wrappers = []

        def get_model_object(self, name):
            return self.diffusion_model

        def clone(self):
            return self

        def remove_wrappers_with_key(self, wrapper_type, key):
            pass

        def add_wrapper_with_key(self, wrapper_type, key, wrapper):
            self.wrappers.append((wrapper_type, key, wrapper))

    def apply_node(self, model, start=0.15, end=0.85, cache_location="自动", safety_margin_gb=1.5):
        return nodes.MiniMaxH3SmartCache().应用缓存(
            model, 0.12, 0.06, start, end, 1, cache_location, False, safety_margin_gb
        )

    def test_uses_only_public_wrappers(self):
        model = self.FakeModel()
        patched, = self.apply_node(model)
        self.assertIs(patched, model)
        self.assertEqual(len(model.wrappers), 3)

    def test_chinese_inputs_have_tooltips(self):
        required = nodes.MiniMaxH3SmartCache.INPUT_TYPES()["required"]
        self.assertEqual(
            list(required),
            ["模型", "视频阈值", "音频阈值", "开始位置", "结束位置", "最大连续复用", "缓存位置", "详细日志", "显存安全余量GB"],
        )
        self.assertTrue(all(spec[1].get("tooltip") for spec in required.values()))
        self.assertEqual(required["显存安全余量GB"][1]["default"], 1.5)
        self.assertEqual(nodes.NODE_DISPLAY_NAME_MAPPINGS["MiniMaxH3SmartCache"], "MiniMax H3 音画智能缓存")

    def test_chinese_cache_location_maps_to_internal_device(self):
        model = self.FakeModel()
        self.apply_node(model, cache_location="内存")
        state = model.model_options["transformer_options"][nodes.SMART_KEY]
        self.assertEqual(state.cache_device, "cpu")

    def test_safety_margin_is_user_configurable(self):
        model = self.FakeModel()
        self.apply_node(model, safety_margin_gb=2.25)
        state = model.model_options["transformer_options"][nodes.SMART_KEY]
        self.assertEqual(state.safety_margin_gb, 2.25)

    def test_cache_stacking_is_rejected(self):
        model = self.FakeModel()
        model.model_options["transformer_options"]["easycache"] = object()
        with self.assertRaisesRegex(ValueError, "不能与其他缓存节点叠加"):
            self.apply_node(model)

    def test_invalid_window_is_rejected(self):
        model = self.FakeModel()
        with self.assertRaisesRegex(ValueError, "开始位置必须小于结束位置"):
            self.apply_node(model, start=0.9, end=0.1)


if __name__ == "__main__":
    unittest.main()
