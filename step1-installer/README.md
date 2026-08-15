# MiniMax H3 Windows Installer

Double-click `Start-Installer.bat`. The installer detects the NVIDIA GPU, VRAM, system RAM, driver, and free disk space, then asks which MiniMax H3 configuration to install before any downloads begin.

## Supported range

- Windows 10/11 x64 with a desktop session
- NVIDIA RTX 3060-class through RTX 5090-class GPUs
- At least 8 GB VRAM and 16 GB system RAM for the compatibility profile
- PyTorch 2.12 / CUDA 13.0 is the default runtime for all supported RTX 30/40/50-series GPUs
- NVIDIA driver 580 or newer is recommended for the CUDA 13.0 runtime
- PyTorch 2.8 / CUDA 12.6 remains available as a manual compatibility fallback
- Internet access during installation

The installer chooses the highest-VRAM NVIDIA GPU when more than one GPU is present and writes that physical GPU index into the launcher through `CUDA_VISIBLE_DEVICES`.

## Installation profiles

| Profile | Intended hardware | Diffusion / text encoder | Default output | Minimum free disk |
|---|---|---|---|---:|
| Compatibility | RTX 3060/4060 and other 8–16 GB cards; 16–32 GB RAM | Pruned INT8 ConvRot / INT8 ConvRot | 608x352, 5 seconds, 24 fps | 60 GiB |
| Balanced 4090/5090 | RTX 4090 or RTX 5090 with at least 32 GB RAM | Pruned FP8 Scaled / INT8 ConvRot | 864x480, 5 seconds, 24 fps | 60 GiB |
| Quality 64 GB | 24 GB+ VRAM and at least 64 GB RAM | Pruned BF16 / INT8 ConvRot | 960x544, 5 seconds, 24 fps | 90 GiB |

All profiles now use `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` as the default text encoder. Re-running the installer on an older installation downloads and verifies the INT8 encoder when needed, regenerates the profile workflow, and refreshes the browser autoload key so an older NVFP4-based canvas is not silently reused.

`Auto` recommends Compatibility for normal 8–16 GB cards and for RTX 30-series cards with 32 GB RAM. It recommends Balanced for FP8-capable RTX 40/50-series cards with 24 GB+ VRAM and 32–63 GB RAM, and Quality for any supported 24 GB+ card with at least 64 GB RAM. A manually selected profile is checked against its own VRAM, RAM, and disk requirements before installation can start.

## CUDA runtime selection

The default runtime for RTX 30, RTX 40, and RTX 50 series is:

- PyTorch `2.12.0+cu130`
- Torchvision `0.27.0+cu130`
- TorchAudio `2.11.0+cu130`
- CUDA runtime `13.0`

PyTorch `2.8.0+cu126` / CUDA `12.6` remains selectable from **Change configuration** as a compatibility fallback.

The installer verifies the exact package versions, CUDA availability, CUDA runtime version, and detected GPU before downloading the H3 models.

## Upgrade an existing installation

Select the same installation directory and click **Install / Repair**. The installer preserves models, user workflows, logs, launchers, PyTorch wheel cache, and partial model downloads. If the private Python runtime is older than 3.13, its virtual environment is removed and rebuilt against Python 3.13.9. If the installed PyTorch runtime does not match the selected runtime, the old Torch/Torchvision/TorchAudio packages are removed and the matching set is installed. ComfyUI requirements are then refreshed with `--upgrade --upgrade-strategy only-if-needed`, followed by `pip check` and a CUDA verification run.

Existing RTX 30/40/50-series installations that are still on the older runtime are upgraded to PyTorch 2.12 CUDA 13.0 by default unless the CUDA 12.6 compatibility runtime is selected manually.

The ComfyUI source archive is overlaid with `Expand-Archive -Force`. This updates bundled files while preserving `models/`, `user/`, logs, downloads, and other installation data. It is intentionally a repair/update operation rather than a destructive directory mirror, so obsolete files that disappeared upstream are not automatically deleted.

## Local and cached PyTorch wheels

The installer searches its root and `assets` recursively for exact Python 3.13 Windows wheels matching the selected runtime. For the default CUDA 13.0 runtime the optional local files are:

- `torch-2.12.0+cu130-cp313-cp313-win_amd64.whl`
- `torchvision-0.27.0+cu130-cp313-cp313-win_amd64.whl`
- `torchaudio-2.11.0+cu130-cp313-cp313-win_amd64.whl`

Local wheels are used first. If a matching wheel is not bundled beside the installer, it is downloaded as a standalone file into `downloads/torch-wheels/`, kept for future repairs, and installed locally with `--no-deps`. Interrupted wheel downloads are kept as `.partial` files and resumed on the next run when the server supports HTTP range requests.

The smaller PyTorch Python dependencies such as NumPy, Pillow, NetworkX, Jinja2, FSSpec, SymPy, and typing-extensions are installed separately through the normal PyPI mirror route. This prevents a fast 1.8+ GB PyTorch wheel download from becoming blocked by a slow unrelated package source.

## Installed stack

- Fixed ComfyUI source `v0.32.0` bundled as `assets/ComfyUI-source.zip`
- Private Python 3.13 runtime and virtual environment
- Selected PyTorch CUDA runtime
- Triton 3.7.1 and SageAttention 2.2 installed from bundled wheels when present
- One selected FL2VA diffusion model
- Qwen3-VL 32B MiniMax H3 INT8 ConvRot text encoder
- MiniMax H3 video and audio VAEs
- A generated workflow whose model names and resolution match the selected profile
- `Start MiniMax H3.bat`, `Stop MiniMax H3.bat`, logs, manifest, and optional desktop shortcut

The current installer deploys the standard FL2VA workflow for text generation and optional first/last frame conditioning. Ref2VA reference-image/video/audio weights are not installed by this version.

The launcher does not use `--lowvram`; ComfyUI uses DynamicVRAM. The SageAttention 2.2 acceleration node is bundled and activated by the second installation step.

## Download routes and safety

The main installer window includes **China mainland mirror priority**. When enabled:

- Python runtime uses npmmirror before python.org
- normal Python packages use Tsinghua PyPI first, Aliyun PyPI second, and official PyPI as fallback for installer-managed toolchain/PyTorch dependencies
- CUDA 12.6 and CUDA 13.0 PyTorch wheels use the Aliyun PyTorch mirror before the official PyTorch source
- MiniMax H3 models use `hf-mirror` before Hugging Face

When the option is disabled, official sources are attempted first and configured mirrors remain fallbacks. The selected route is locked while an installation is running and is written to the installation manifest.

PyTorch wheel downloads are stored in the installation's `downloads/torch-wheels/` cache and preserve partial data for resume/fallback. Model downloads also retain partial files, resume by HTTP range, and verify completed model files against the official size and SHA-256 inventory in `assets/hf_model_inventory.json`.

## Use

1. Double-click `Start-Installer.bat`.
2. Review the detected GPU/RAM and accept `Auto`, or choose one of the three profiles.
3. Leave the default CUDA 13.0 runtime selected unless a compatibility fallback is needed.
4. Select an installation folder and run **Check computer**.
5. Click **Install / Repair**.
6. After completion, run the second step (plugin pack) to add the workflows, plugins, and the SageAttention node.
7. Use `Start MiniMax H3.bat` or the desktop shortcut.
8. Use `Stop MiniMax H3.bat` before shutting down or moving the installation.

The full 50–68 GiB model downloads and generation performance still require end-to-end validation on representative RTX 3060, RTX 4090, and RTX 5090 systems before this branch is treated as a final release.