"""
Voice Flow configuration — persisted settings + model constants.
"""

import json
from pathlib import Path

# ── Models (not user-configurable) ────────────────────────
STT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
LLM_MODEL = "mlx-community/Qwen3-4B-4bit"
SAMPLE_RATE = 16000

# ── Cleanup prompt ────────────────────────────────────────
CLEANUP_SYSTEM_PROMPT = (
    "You are a dictation cleanup assistant. You receive raw speech-to-text "
    "output and return polished text ready to be pasted.\n"
    "\n"
    "Rules:\n"
    "1. Fix punctuation, capitalization, and sentence structure\n"
    "2. Remove filler words and false starts "
    "(um, uh, like, you know, so, basically, I mean, er, hmm, right)\n"
    "3. Remove repeated words from stuttering "
    '(e.g., "I I I think" → "I think")\n'
    "4. Fix obvious homophones and speech recognition errors from context\n"
    "5. Keep the speaker's original meaning, vocabulary, and tone exactly\n"
    "6. Do NOT summarize, paraphrase, add commentary, or change intent\n"
    "7. For a single word or very short phrase, return it as-is with "
    "proper capitalization\n"
    "8. Output ONLY the cleaned text — no quotes, labels, explanations, "
    "or formatting markers"
)

# ── Filler words that should be discarded entirely ────────
FILLER_ONLY = frozenset(
    {"uh", "um", "hmm", "hm", "ah", "er", "oh", "mhm", "uh-huh"}
)

# ── Persistent user settings ──────────────────────────────

_SETTINGS_FILE = Path.home() / ".config" / "voice-flow" / "settings.json"

_DEFAULTS = {
    "hotkey": "alt_r",
    "sounds_enabled": True,
    "double_tap_ms": 400,
    "llm_cleanup_enabled": True,
}


class Settings:
    """Singleton for user-editable settings, persisted to JSON."""

    _instance = None

    def __init__(self):
        self.hotkey: str = _DEFAULTS["hotkey"]
        self.sounds_enabled: bool = _DEFAULTS["sounds_enabled"]
        self.double_tap_ms: int = _DEFAULTS["double_tap_ms"]
        self.llm_cleanup_enabled: bool = _DEFAULTS["llm_cleanup_enabled"]
        self._load()

    @classmethod
    def get(cls) -> "Settings":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def save(self):
        _SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        _SETTINGS_FILE.write_text(
            json.dumps(
                {
                    "hotkey": self.hotkey,
                    "sounds_enabled": self.sounds_enabled,
                    "double_tap_ms": self.double_tap_ms,
                    "llm_cleanup_enabled": self.llm_cleanup_enabled,
                },
                indent=2,
            )
        )

    def _load(self):
        if _SETTINGS_FILE.exists():
            try:
                data = json.loads(_SETTINGS_FILE.read_text())
                for k, v in data.items():
                    if hasattr(self, k):
                        setattr(self, k, v)
            except Exception:
                pass


# ── Backward-compat module-level aliases ──────────────────
HOTKEY = Settings.get().hotkey
