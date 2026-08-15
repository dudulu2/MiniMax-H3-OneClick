# MiniMax H3 One-Click Windows Installers

Two-step, offline-capable installer package for running a MiniMax H3 (FL2VA video generation) ComfyUI environment on Windows 10/11 with NVIDIA RTX 30/40/50-series GPUs.

The installer prefers compatible local wheels when they are bundled with the package and falls back to cached files, China mirrors, and official package sources only when required. This lets a release package be assembled as either a smaller online installer or a larger full/offline installer without changing the install flow.

## Layout

| Directory | Content |
|---|---|
| [`step1-installer`](step1-installer/) | Core installer: Python 3.13.9 runtime, PyTorch 2.12 / CUDA 13.0 (with CUDA 12.6 compatibility fallback), ComfyUI v0.32.0, H3 model downloads, hardware profiles, SageAttention 2.2 + Triton 3.7.1 wheels for the default CUDA 13 runtime, cancellation UI, existing-install repair safeguards, and GitHub Actions validation |
| [`step2-plugin-pack`](step2-plugin-pack/) | Plugin pack: installs or updates 12 ComfyUI custom nodes (Manager, VideoHelperSuite, rgthree, crystools, Essentials, H3 audio/block-cache/AVCache/TE-Speed, SageAttention-MiniMaxH3-Safe), keeps timestamped plugin backups, supports an offline plugin-dependency wheelhouse, and repairs the required SageAttention/Triton versions in an existing default-runtime step-1 install |
| `.github/workflows` | CI validation for installer/runtime/plugin contracts, including local-wheel-first ordering in both steps |

## Install order

1. Download this repository (GitHub zip export works — no git required).
2. Run step 1: double-click `step1-installer/Start-Installer.bat`.
3. Run step 2: double-click `step2-plugin-pack/Install-Plugins-Safe.bat`.
4. Launch with `Start MiniMax H3.bat` next to your installation.

Step 2 requires the exact current default runtime: Python `3.13.9`, PyTorch `2.12.0+cu130`, and CUDA `13.0`. It runs a preflight before touching plugins and a postflight after dependency installation. The postflight verifies Triton `3.7.1.post27` and SageAttention `2.2.0+cu130torch2.10.0andhigher.post6` again so plugin requirements cannot silently replace the acceleration stack.

The manual CUDA 12.6 / PyTorch 2.8 compatibility channel remains available in step 1. The bundled SageAttention wheel is a CUDA 13 / Torch 2.10+ build, so step 1 intentionally disables that Sage/Triton acceleration pair on the compatibility runtime and step 2 stops before making changes. This avoids installing a known-incompatible acceleration wheel into the fallback environment.

## Local wheel priority

### Step 1 runtime and dependency wheels

Step 1 checks for a matching runtime wheel under the Step 1 installer package before downloading PyTorch. The recommended runtime-wheel folder is `step1-installer/assets/wheels/`.

For the default Windows x64 / Python 3.13.9 / CUDA 13 runtime, a full package can include:

- `torch-2.12.0+cu130-cp313-cp313-win_amd64.whl`
- `torchvision-0.27.0+cu130-cp313-cp313-win_amd64.whl`
- `torchaudio-2.11.0+cu130-cp313-cp313-win_amd64.whl`

The Step 1 PyTorch order is: **bundled matching wheel -> existing target cache under `downloads/torch-wheels/` -> configured mirror/official download source**. The exact bundled Triton and SageAttention wheels are also used locally first on the default CUDA 13 runtime.

For ordinary small Python dependencies, an optional wheelhouse can be placed at:

`step1-installer/assets/wheels/dependencies/`

When that directory contains wheels, Step 1 first attempts the Python toolchain packages, ordinary PyTorch Python dependencies, and ComfyUI requirements completely offline with `--no-index --find-links`. If the local wheelhouse cannot satisfy a request completely, Step 1 falls back to its normal configured package sources.

### Step 2 plugin dependency wheels

Put ordinary plugin dependency wheels in:

`step2-plugin-pack/wheels/dependencies/`

`Install-Plugins-Safe.bat` now runs `Install-Step2-Dependencies-LocalFirst.ps1` after runtime preflight and before the main plugin installer. It first tries every managed plugin requirement completely offline with `--no-index --find-links`. The validated versions are recorded in `step2-plugin-pack/step2-wheel-lock.txt`.

The real-machine wheelhouse captured on 2026-08-15 contains **52 wheels / about 208.6 MiB** for Windows x64 / Python 3.13.9. If `step2-plugin-pack/step2-wheel-sha256.txt` is present, the helper verifies the listed hashes before using the wheelhouse. If local wheels are missing, incomplete, incompatible, or fail verification, Step 2 continues with the configured China mirror and then official PyPI.

Triton and SageAttention stay directly under `step2-plugin-pack/wheels/`; they are handled separately from the ordinary plugin dependency wheelhouse.

## Runtime stack

- Python 3.13.9 (private runtime, no system Python required)
- PyTorch 2.12.0+cu130 / Torchvision 0.27.0+cu130 / TorchAudio 2.11.0+cu130 (default), or PyTorch 2.8.0+cu126 (manual compatibility channel)
- ComfyUI source archive `ComfyUI-source.zip` (top-level `ComfyUI/`, SHA-256 verified, fixed build pinned to ComfyUI v0.32.0)
- MiniMax H3 Qwen3-VL 32B INT8 ConvRot text encoder as the default text encoder for all installer profiles
- NVIDIA driver 580+ recommended for CUDA 13.0

## Existing-install repair behavior

Step 1 can be re-run over the same installation directory. It refuses to replace runtime/core files while a MiniMax H3 Python/ComfyUI process from that directory is still running. Existing private Python is repaired to the exact `3.13.9` patch level, and the selected PyTorch runtime is repaired if versions differ.

For an existing ComfyUI tree, step 1 stages the verified source zip, backs up the active non-user application files to `comfyui-backups/<timestamp>/`, removes stale core files, and deploys a clean copy. `models/`, `user/`, `custom_nodes/`, `input/`, `output/`, `temp/`, and an existing root `extra_model_paths.yaml` are preserved. If the core copy fails, the installer attempts to restore the previous core from the backup.

Step 2 remains repeatable: each managed plugin folder is moved to `plugin-backups/<timestamp>/` before its bundled replacement is copied in.

## Notes

- RTX 3060-class through RTX 5090-class, 8 GB+ VRAM, 16 GB+ RAM.
- Old model files that are no longer selected (for example the previous NVFP4 text encoder) are not automatically deleted; this avoids destructive model cleanup and lets users remove unused weights manually after verification.
- Model/package downloads retain network fallbacks and resumable behavior where applicable.
- The third-party `Sage加速一键安装包加速版` variant with pre-patched workflows is intentionally **not** uploaded here — it targets the older Python 3.10 / Torch 2.10 stack.
