"""Workflow-scoped SageAttention selection for MiniMax H3."""

from comfy.ldm.modules.attention import get_attention_function


class SageAttentionMiniMaxH3Safe:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "model": ("MODEL",),
                "backend": (["sage", "pytorch", "original"], {
                    "default": "sage",
                    "tooltip": "Attention backend for the MiniMax H3 diffusion model only.",
                }),
            }
        }

    RETURN_TYPES = ("MODEL",)
    FUNCTION = "patch"
    CATEGORY = "sampling/custom_sampling/minimax_h3"

    def patch(self, model, backend):
        if backend == "original":
            return (model,)

        if self._find_minimax_dit(model) is None:
            raise ValueError("Sage Attention MiniMax H3 only supports MiniMax H3 models")

        attention = get_attention_function(backend, None)
        if attention is None:
            if backend == "sage":
                raise RuntimeError(
                    "SageAttention is unavailable. Run the Sage safe installer and restart ComfyUI."
                )
            raise RuntimeError(f"Attention backend is unavailable: {backend}")

        patched = model.clone()
        transformer_options = patched.model_options.get("transformer_options", {}).copy()
        if "optimized_attention_override" in transformer_options:
            raise ValueError(
                "Another workflow node already overrides optimized attention; "
                "remove or bypass one of the attention override nodes."
            )

        def attention_override(_original, *args, **kwargs):
            return attention(*args, **kwargs)

        transformer_options["optimized_attention_override"] = attention_override
        patched.model_options["transformer_options"] = transformer_options
        return (patched,)

    @staticmethod
    def _find_minimax_dit(model):
        current = getattr(model, "model", None)
        seen = 0
        while current is not None and seen < 12:
            if type(current).__name__ == "MiniMaxH3Model":
                return current
            next_model = None
            for attr in ("model", "inner_model", "diffusion_model", "unet_model"):
                next_model = getattr(current, attr, None)
                if next_model is not None:
                    break
            current = next_model
            seen += 1
        return None
