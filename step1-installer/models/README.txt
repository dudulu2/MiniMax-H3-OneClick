MiniMax H3 local model bundle
==============================

Put optional pre-downloaded model files in this folder to make Step 1 use them
before Hugging Face downloads.

Recommended layout:

step1-installer\models\
  diffusion_models\
    minimax_h3_fl2va_pruned_int8_convrot.safetensors
    minimax_h3_fl2va_pruned_fp8_scaled.safetensors
    minimax_h3_fl2va_pruned_bf16.safetensors
  text_encoders\
    qwen3vl_32b_minimax_h3_int8_convrot.safetensors
  vae\
    minimax_h3_video_vae_fp16.safetensors
    minimax_h3_audio_vae_fp32.safetensors

Only the files required by the selected hardware profile are used.

Safety rules:
- The installer checks the exact catalog size and SHA-256 before replacing a
  missing or partial installed model with a bundled model.
- A corrupt or wrong same-name bundled file is ignored and is never deleted.
- Existing complete-size installed models are left in place for the normal
  authoritative SHA-256 verification.
- If a required local model is absent or fails verification, the normal
  resumable Hugging Face / mirror download remains available.
- The installer searches only inside the extracted one-click package folder;
  it does not scan entire disks.

The helper also supports exact-name fallback discovery elsewhere inside the
extracted one-click package, but this models\ layout is preferred because it is
fast and unambiguous.
