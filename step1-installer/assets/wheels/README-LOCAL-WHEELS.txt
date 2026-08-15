MiniMax H3 Step 1 local runtime wheels
======================================

Step 1 already checks the installer package for matching local Python wheels
before downloading the selected PyTorch runtime.

For the default Windows x64 / Python 3.13.9 / CUDA 13.0 runtime, place these
files anywhere under step1-installer (this assets\wheels directory is the
recommended location):

  torch-2.12.0+cu130-cp313-cp313-win_amd64.whl
  torchvision-0.27.0+cu130-cp313-cp313-win_amd64.whl
  torchaudio-2.11.0+cu130-cp313-cp313-win_amd64.whl

Step 1 runtime order is:
  1. Matching wheel bundled under the Step 1 installer directory/assets
  2. Existing target cache under downloads\torch-wheels\...
  3. Configured PyTorch mirror/official download sources

The exact Triton and SageAttention wheels already stored in this directory are
also used locally first for the default CUDA 13 runtime.

Do not put CUDA 13 Torch/Sage/Triton wheels into a CUDA 12.6 compatibility
installation. Step 1 selects wheel names from the chosen runtime and keeps the
compatibility channel isolated from the CUDA 13 acceleration pair.
