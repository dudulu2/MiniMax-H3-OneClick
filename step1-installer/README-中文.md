# MiniMax H3 一键安装器（硬件自动配置版）

双击 `Start-Installer.bat` 后，安装器会先检测 NVIDIA 显卡、显存、系统内存、驱动和目标磁盘空间，并在开始下载前询问要安装哪一种 MiniMax H3 配置。

## 支持范围

- Windows 10/11 64 位，需有桌面环境
- NVIDIA RTX 3060 级别到 RTX 5090 级别显卡
- 兼容配置最低要求：8 GB 显存、16 GB 系统内存
- 默认运行环境为 PyTorch 2.12 / CUDA 13.0
- CUDA 13.0 运行环境建议 NVIDIA 驱动 580 或更新
- PyTorch 2.8 / CUDA 12.6 保留为手动兼容通道
- 安装期间需要联网（也可用随包离线 wheel 与内置镜像减少下载）

存在多张 NVIDIA 显卡时，安装器会默认选择显存最大的一张，并通过 `CUDA_VISIBLE_DEVICES` 把对应物理 GPU 编号写入启动器。

## 三种安装配置

| 配置 | 适用硬件 | 扩散模型 / 文本编码器 | 默认输出 | 最低可用空间 |
|---|---|---|---|---:|
| 兼容配置 | RTX 3060/4060 及其他 8–16 GB 显卡；16–32 GB 内存 | Pruned INT8 ConvRot / INT8 ConvRot | 608×352、5 秒、24fps | 60 GiB |
| 4090/5090 平衡配置 | RTX 4090 或 RTX 5090，至少 32 GB 内存 | Pruned FP8 Scaled / INT8 ConvRot | 864×480、5 秒、24fps | 60 GiB |
| 64 GB 高质量配置 | 24 GB 以上显存、至少 64 GB 内存 | Pruned BF16 / INT8 ConvRot | 960×544、5 秒、24fps | 90 GiB |

三个配置现在统一默认使用 `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` 文本编码器。旧安装原来使用 NVFP4 时，重新运行安装器会在需要时下载并校验 INT8 文本模型、重新生成对应工作流，同时刷新浏览器自动加载标记，避免磁盘文件已更新但浏览器仍停留在旧 NVFP4 工作流。

选择 `Auto` 时：

- 普通 8–16 GB 显卡，以及只有 32 GB 内存的 RTX 30 系高显存显卡，推荐“兼容配置”；
- 支持 FP8 的 RTX 40/50 系显卡，显存 24 GB 以上且内存为 32–63 GB 时，推荐“4090/5090 平衡配置”；
- 任意受支持的 24 GB 以上显存显卡，系统内存达到 64 GB 时，推荐“64 GB 高质量配置”。

也可以手动选择，但安装器会按所选配置重新检查显存、内存和磁盘空间，不符合最低条件时会阻止安装。Windows 可能显示略低于内存条标称容量，因此检测为正常的 16/32/64 GB 机器时会保留少量容差。

## CUDA 运行环境自动选择

默认运行环境：

- PyTorch `2.12.0+cu130`
- Torchvision `0.27.0+cu130`
- TorchAudio `2.11.0+cu130`
- CUDA `13.0`
- Triton `3.7.1.post27`
- SageAttention `2.2.0+cu130torch2.10.0andhigher.post6`

手动兼容通道为 PyTorch `2.8.0+cu126` / CUDA `12.6`，可从 **Change configuration** 中选择。

需要特别说明：仓库随包的 SageAttention wheel 明确针对 **CUDA 13 / Torch 2.10+**。因此选择 CUDA 12.6 / PyTorch 2.8 兼容通道时，第一步不会安装这组 SageAttention/Triton 加速包；如果旧环境里残留了这组 CUDA13 加速包，修复过程会将其移除，继续使用标准 PyTorch attention。这样可以避免把已知不匹配的 CUDA13 wheel 强行塞进兼容环境。

开始下载 H3 模型前，安装器会验证精确版本、CUDA 是否可用、CUDA 运行时版本以及实际识别到的显卡。

## 升级已有安装目录

选择原来的安装目录并点击 **Install / Repair** 即可就地升级。升级前请先运行 `Stop MiniMax H3.bat`。修复入口会检查该安装目录的 PID 文件以及目录下正在运行的 Python 进程；如果本目录的 ComfyUI/Python 仍在运行，会直接阻止替换核心文件和运行时，避免边运行边覆盖造成损坏。若 PID 文件已经陈旧、指向的是安装目录之外的其他进程，则会忽略该 PID，不会误阻止修复。

安装器会保留模型、`user\` 工作流、日志、启动器、PyTorch wheel 缓存以及 `downloads\` 中的断点文件。私有 Python 现在会精确校验到 `3.13.9`：只要不是目标补丁版本，就会删除旧虚拟环境和旧私有 Python，再安装 Python 3.13.9 并重建 venv。若 PyTorch 版本与所选运行时不一致，则先卸载旧 Torch/Torchvision/TorchAudio，再安装目标版本；ComfyUI requirements 更新后还会再次执行一次 SageAttention/Triton 精确修复与校验，随后再次执行 `pip check`，最后再做 CUDA 校验，避免依赖安装在后半程偷偷改掉加速栈。

ComfyUI 本体升级也改成了更彻底但仍保护用户数据的方式：先把经过 SHA-256 校验的 `ComfyUI-source.zip` 解压到临时目录，再把当前非用户核心文件备份到 `comfyui-backups\<时间戳>\`，清掉旧核心残留，然后从临时目录干净重铺新版核心。以下位置会**完全原地保留，不把临时新版内容合并进去，也不覆盖同名文件**：`models\`、`user\`、`custom_nodes\`、`input\`、`output\`、`temp\`，以及根目录现有的 `extra_model_paths.yaml`。如果核心复制失败，安装器会尝试从备份恢复旧核心。

旧但已经不再使用的模型文件不会自动删除。例如从旧 NVFP4 文本编码器升级到现在的 INT8 默认后，原来的 NVFP4 权重可能仍保留在模型目录中，方便确认新版运行正常后再手动清理，避免自动删错模型。

## 安装内容

- 固定版本 ComfyUI：`assets/ComfyUI-source.zip`（ComfyUI v0.32.0，SHA-256 校验）
- 独立 Python 3.13.9 和虚拟环境，不污染系统 Python
- 根据显卡/手动选择的 PyTorch CUDA 运行环境
- 默认 CUDA13 环境使用随包 Triton 3.7.1 与 SageAttention 2.2
- 所选配置对应的一份 FL2VA 扩散模型
- Qwen3-VL 32B MiniMax H3 INT8 ConvRot 文本编码器
- MiniMax H3 视频 VAE 和音频 VAE
- 自动生成与配置匹配的工作流，包括模型名和默认分辨率
- `Start MiniMax H3.bat`、`Stop MiniMax H3.bat`、日志、安装清单和可选桌面快捷方式

当前版本安装的是标准 FL2VA 工作流，支持文生视频以及可选首帧/尾帧条件。Ref2VA 的参考图片、参考视频和参考音频权重暂未包含在这一版安装器中。

启动时不使用 `--lowvram`，由 PyTorch DynamicVRAM 管理显存。第二步插件包会为默认 CUDA13 运行环境安装/更新 12 个插件与 SageAttention 节点。

## 第二步插件包的运行时限制

`step2-plugin-pack\Install-Plugins-Safe.bat` 现在会执行前后两次运行时检查：

1. 安装插件前，要求 Python `3.13.9`、PyTorch `2.12.0+cu130`、CUDA `13.0`；如果是旧 Python 或 CUDA12.6/PyTorch2.8 兼容通道，会在修改插件前停止并提示先运行第一步 **Install / Repair** 或切回默认运行时。
2. 12 个插件及 requirements 安装完成后，再次检查 Triton `3.7.1.post27`、SageAttention `2.2.0+cu130torch2.10.0andhigher.post6`，并实际导入 `triton` 与 `sageattention`，防止某个插件依赖把加速栈偷偷换掉。

已有的受管插件目录仍会先移动到 `plugin-backups\<时间戳>\`，再复制新版，因此第二步可以重复执行用于插件更新。

## 下载与校验

官方模型文件大小和 SHA-256 全部记录在 `assets/hf_model_inventory.json`。下载会优先使用 Hugging Face（勾选“中国大陆镜像优先”后先走 `hf-mirror`）；保留未完成文件，支持 HTTP Range 断点续传，并在继续安装前校验完整文件。PyTorch wheel 与 Python 包同样支持官方源/阿里云/清华镜像多路回退。

## 使用方法

1. 双击 `Start-Installer.bat`。
2. 查看检测到的显卡和内存，接受 `Auto` 推荐，或手动选择三种配置之一。
3. 保持默认 CUDA 13.0 运行环境（除非确实需要兼容通道）。
4. 选择安装目录并点击 **Check computer**。
5. 如果是升级旧目录，先运行 `Stop MiniMax H3.bat`。
6. 点击 **Install / Repair**。
7. 使用默认 CUDA13 运行环境时，再运行第二步插件包，安装/更新 12 个插件并校验 SageAttention/Triton。
8. 运行 `Start MiniMax H3.bat` 或桌面快捷方式。
9. 关机或移动安装目录前运行 `Stop MiniMax H3.bat`。

目前代码和静态/合成升级校验已经覆盖三种模型配置与已有目录刷新逻辑，但约 50–68 GiB 模型的完整下载和实际生成性能，仍需分别在 RTX 3060、RTX 4090 和 RTX 5090 代表机器上做端到端实测后，才能作为正式发布版本。