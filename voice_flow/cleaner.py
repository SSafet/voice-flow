import re

from voice_flow.config import LLM_MODEL, CLEANUP_SYSTEM_PROMPT


class Cleaner:
    """LLM-powered dictation cleanup via mlx-lm (in-process, no server)."""

    def __init__(self, model_name: str = LLM_MODEL):
        self.model_name = model_name
        self.model = None
        self.tokenizer = None
        self._loaded = False

    def load(self) -> None:
        from mlx_lm import load
        self.model, self.tokenizer = load(self.model_name)
        self._loaded = True

    def clean(self, raw_text: str) -> str:
        if not self._loaded:
            self.load()
        if not raw_text.strip():
            return ""

        # Very short inputs (1–2 words) — just capitalize, skip LLM
        words = raw_text.strip().split()
        if len(words) <= 2:
            cleaned = raw_text.strip()
            # Capitalize first letter, add period if missing punctuation
            cleaned = cleaned[0].upper() + cleaned[1:] if cleaned else cleaned
            if cleaned and cleaned[-1] not in ".!?,:;":
                cleaned += "."
            return cleaned

        from mlx_lm import generate

        messages = [
            {"role": "system", "content": CLEANUP_SYSTEM_PROMPT},
            {"role": "user", "content": raw_text},
        ]

        # Build prompt — disable Qwen3 thinking mode if supported
        try:
            prompt = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            prompt = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )

        from mlx_lm.generate import make_sampler

        response = generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            max_tokens=max(len(words) * 4, 100),
            sampler=make_sampler(temp=0.1),
        )

        # Strip any residual thinking tags or wrapping
        cleaned = re.sub(r"<think>.*?</think>", "", response, flags=re.DOTALL)
        cleaned = cleaned.strip().strip('"').strip("'")

        # Safety: if LLM returned nothing useful, fall back to raw
        if not cleaned or len(cleaned) < len(raw_text) * 0.3:
            return raw_text.strip()

        return cleaned

    @property
    def is_loaded(self) -> bool:
        return self._loaded
