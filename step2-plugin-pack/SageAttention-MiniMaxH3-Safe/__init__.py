from .nodes import SageAttentionMiniMaxH3Safe


NODE_CLASS_MAPPINGS = {
    "SageAttentionMiniMaxH3Safe": SageAttentionMiniMaxH3Safe,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "SageAttentionMiniMaxH3Safe": "Sage Attention MiniMax H3 (Safe)",
}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
