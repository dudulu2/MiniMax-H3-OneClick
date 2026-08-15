MiniMax H3 Step 2 local dependency wheelhouse
============================================

Place the Step 2 plugin dependency .whl files in this directory.

Default install order:
  1. This local wheels\dependencies directory (offline attempt)
  2. Configured China PyPI mirror
  3. Official PyPI fallback

The tested 2026-08-15 wheelhouse contains 52 wheels and is about 208.6 MiB.
It was generated against Windows x64 / CPython 3.13.9 and the default
PyTorch 2.12.0+cu130 runtime.

Optional integrity manifest:
  Put step2-wheel-sha256.txt one directory level above wheels, at:
    step2-plugin-pack\step2-wheel-sha256.txt

If that manifest is present, Install-Step2-Dependencies-LocalFirst.ps1 verifies
all listed wheel SHA-256 hashes before using the local wheelhouse. If the local
wheelhouse is missing, incomplete, incompatible, or fails verification, the
installer does not treat that as a fatal error; it falls back to the configured
mirror and then official PyPI through the normal Step 2 installer.

Triton and SageAttention remain in step2-plugin-pack\wheels\ itself, not in this
subdirectory, because the installer handles those exact acceleration wheels
separately.
