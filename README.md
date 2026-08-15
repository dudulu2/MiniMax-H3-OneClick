# MiniMax H3 One-Click Windows Installers

Two-step, fully offline-capable installer package for running a MiniMax H3 (FL2VA video generation) ComfyUI environment on Windows 10/11 with NVIDIA RTX 30/40/50-series GPUs.

This repository ships the same packages that are distributed as the two installer folders. Everything needed for an offline installation is bundled: Python 3.13.9, the CUDA 13.0 PyTorch wheel set, the fixed ComfyUI v0.32.0 source, the H3 model catalog, plugin packs, and the SageAttention/Triton wheels.

## Layout

| Directory | Content |
|---|---|
| [`step1-installer`](step1-installer/) | Core installer: Python 3.13.9 runtime, PyTorch 2.12 / CUDA 13.0 (with CUDA 12.6 compatibility fallback), ComfyUI v0.32.0, H3 model downloads, hardware profiles, SageAttention 2.2 + Triton 3.7.1 wheels for the default CUDA 13 runtime, cancellation UI, existing-install repair safeguards, and GitHub Actions validation |
| [`step2-plugin-pack`](step2-plugin-pack/) | Plugin pack: installs or updates 12 ComfyUI custom nodes (Manager, VideoHelperSuite, rgthree, crystools, Essentials, H3 audio/block-cache/AVCache/TE-Speed, SageAttention-MiniMaxH3-Safe), keeps timestamped plugin backups, and repairs the required SageAttention/Triton versions in an existing default-runtime step-1 install |
| `.github/workflows` | CI validation for the installer and plugin upgrade contracts (PowerShell 5.1 parse, profile/workflow generation, download routes, output contracts, release version, existing-install refresh, step-2 runtime checks) |

## Install order

1. Download this repository (GitHub zip export works — no git required).
2. Run step 1: double-click `step1-installer/Start-Installer.bat`.
3. Run step 2: double-click `step2-plugin-pack/Install-Plugins-Safe.bat`.
4. Launch with `Start MiniMax H3.bat` next to your installation.

Step 2 requires the exact current default runtime: Python `3.13.9`, PyTorch `2.12.0+cu130`, and CUDA `13.0`. It runs a preflight before touching plugins and a postflight after dependency installation. The postflight verifies Triton `3.7.1.post27` and SageAttention `2.2.0+cu130torch2.10.0andhigher.post6` again so plugin requirements cannot silently replace the acceleration stack.

The manual CUDA 12.6 / PyTorch 2.8 compatibility channel remains available in step 1. The bundled SageAttention wheel is a CUDA 13 / Torch 2.10+ build, so step 1 intentionally disables that Sage/Triton acceleration pair on the compatibility runtime and step 2 stops before making changes. This avoids installing a known-incompatible acceleration wheel into the fallback environment.

## Runtime stack

- Python 3.13.9 (private runtime, no system Python required)
- PyTorch 2.12.0+cu130 / Torchvision 0.27.0+cu130 / TorchAudio 2.11.0+cu130 (default), or PyTorch 2.8.0+cu126 (manual compatibility channel)
- ComfyUI source archive `ComfyUI-source.zip` (top-level `ComfyUI/`, SHA-256 verified, fixed build pinned to ComfyUI v0.32.0)
- MiniMax H3 Qwen3-VL 32B INT8 ConvRot text encoder as the default text encoder for all installer profiles
- NVIDIA driver 580+ recommended for CUDA 13.0

## Existing-install repair behavior

Step 1 can be re-run over the same installation directory. It refuses to replace runtime/core files while a MiniMax H3 Python/ComfyUI process from that directory is still running. Existing private Python is repaired to the exact `3.13.9` patch level, and the selected PyTorch runtime is repaired if versions differ.

For an existing ComfyUI tree, step 1 now stages the verified source zip, backs up the active non-user application files to `comfyui-backups/<timestamp>/`, removes stale core files, and deploys a clean copy. `models/`, `user/`, `custom_nodes/`, `input/`, `output/`, `temp/`, and an existing root `extra_model_paths.yaml` are preserved. If the core copy fails, the installer attempts to restore the previous core from the backup.

Step 2 remains repeatable: each managed plugin folder is moved to `plugin-backups/<timestamp>/` before its bundled replacement is copied in.

## Notes

- RTX 3060-class through RTX 5090-class, 8 GB+ VRAM, 16 GB+ RAM.
- Old model files that are no longer selected (for example the previous NVFP4 text encoder) are not automatically deleted; this avoids destructive model cleanup and lets users remove unused weights manually after verification.
- All model/package downloads support mirrors (Chinese mainland mirror priority available) and resume from partial files.
- The third-party `Sage加速一键安装包加速版` variant with pre-patched workflows is intentionally **not** uploaded here — it targets the older Python 3.10 / Torch 2.10 stack.
