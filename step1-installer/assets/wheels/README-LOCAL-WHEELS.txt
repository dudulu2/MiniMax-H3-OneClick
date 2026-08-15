MiniMax H3 Step 1 local wheels
==============================

Step 1 checks compatible local wheels before using network package sources.

Runtime wheels
--------------
For the default Windows x64 / Python 3.13.9 / CUDA 13.0 runtime, place these
files anywhere under step1-installer (this assets\wheels directory is the
recommended location):

  torch-2.12.0+cu130-cp313-cp313-win_amd64.whl
  torchvision-0.27.0+cu130-cp313-cp313-win_amd64.whl
  torchaudio-2.11.0+cu130-cp313-cp313-win_amd64.whl

Step 1 PyTorch runtime order is:
  1. Matching wheel bundled under the Step 1 installer directory/assets
  2. Existing target cache under downloads\torch-wheels\...
  3. Configured PyTorch mirror/official download sources

The exact Triton and SageAttention wheels stored directly in assets\wheels are
also used locally first for the default CUDA 13 runtime.

Ordinary Python dependency wheels
---------------------------------
Optional small dependency wheels can be placed in:

  step1-installer\assets\wheels\dependencies\

When this folder contains .whl files, Step 1 first tries pip completely offline
with --no-index --find-links for toolchain packages, ordinary PyTorch Python
dependencies, and ComfyUI requirements. If the local wheelhouse cannot satisfy a
request completely, the installer continues with its normal configured package
sources instead of failing solely because the local wheelhouse is incomplete.

Do not put CUDA 13 Torch/Sage/Triton wheels into a CUDA 12.6 compatibility
installation. Step 1 selects runtime wheel names from the chosen channel and
keeps the compatibility channel isolated from the CUDA 13 acceleration pair.
