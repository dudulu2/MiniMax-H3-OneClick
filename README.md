# MiniMax H3 One-Click Windows Installers

Two-step, fully offline-capable installer package for running a MiniMax H3 (FL2VA video generation) ComfyUI environment on Windows 10/11 with NVIDIA RTX 30/40/50-series GPUs.

This repository ships the same packages that are distributed as the two installer folders. Everything needed for an offline installation is bundled: Python 3.13, the CUDA 13.0 PyTorch wheel set, the fixed ComfyUI v0.32.0 source, the H3 model catalog, plugin packs, and the SageAttention/Triton wheels.

## Layout

| Directory | Content |
|---|---|
| [`step1-installer`](step1-installer/) | Core installer: Python 3.13.9 runtime, PyTorch 2.12 / CUDA 13.0 (with CUDA 12.6 compatibility fallback), ComfyUI v0.32.0, H3 model downloads, hardware profiles, SageAttention 2.2 + Triton 3.7.1 wheels, cancellation UI, validates itself through 16 GitHub Actions workflows |
| [`step2-plugin-pack`](step2-plugin-pack/) | Plugin pack: installs 12 ComfyUI custom nodes (Manager, VideoHelperSuite, rgthree, crystools, Essentials, H3 audio/block-cache/AVCache/TE-Speed, SageAttention-MiniMaxH3-Safe), fixes the network, and installs the same SageAttention/Triton wheels into an existing step-1 install |
| `.github/workflows` | CI validation for the step-1 installer (PowerShell 5.1 parse, profile/workflow generation, download routes, output contracts, release version) |

## Install order

1. Download this repository (GitHub zip export works — no git required).
2. Run step 1: double-click `step1-installer/Start-Installer.bat`.
3. Run step 2: double-click `step2-plugin-pack/Install-Plugins-Safe.bat`.
4. Launch with `Start MiniMax H3.bat` next to your installation.

Both steps select the exact same wheels (Triton `3.7.1.post27`, SageAttention `2.2.0+cu130`) so the second step does not downgrade or replace anything step 1 installed.

## Runtime stack

- Python 3.13.9 (private runtime, no system Python required)
- PyTorch 2.12.0+cu130 / Torchvision 0.27.0+cu130 / TorchAudio 2.11.0+cu130 (default), or PyTorch 2.8.0+cu126 (manual compatibility channel)
- ComfyUI source archive `ComfyUI-source.zip` (top-level `ComfyUI/`, SHA-256 verified, fixed build pinned to ComfyUI v0.32.0)
- NVIDIA driver 580+ recommended for CUDA 13.0

## Notes

- RTX 3060-class through RTX 5090-class, 8 GB+ VRAM, 16 GB+ RAM.
- Step 1 preserves existing models, workflows, logs, and the wheel cache when you re-run it over the same directory; outdated PyTorch runtimes are rebuilt automatically.
- All model/package downloads support mirrors (Chinese mainland mirror priority available) and resume from partial files.
- The third-party `Sage加速一键安装包加速版` variant with pre-patched workflows is intentionally **not** uploaded here — it targets the older Python 3.10 / Torch 2.10 stack.