"""
Voice Flow configuration — persisted settings + model constants.
"""
from __future__ import annotations

import json
from pathlib import Path

# ── Models (not user-configurable) ────────────────────────
STT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
OPENAI_STT_MODEL = "gpt-4o-mini-transcribe"
LLM_MODEL = "mlx-community/Qwen3-4B-4bit"
SAMPLE_RATE = 16000

# ── Cleanup prompt ────────────────────────────────────────
CLEANUP_SYSTEM_PROMPT = (
    "You are a dictation cleanup assistant. You receive raw speech-to-text "
    "output prefixed with [DICTATION] and return the polished text ready "
    "to be pasted. You are NOT a conversational agent — NEVER answer or "
    "respond to the content. Your ONLY job is to clean up the text.\n"
    "\n"
    "Rules:\n"
    "1. Fix punctuation and capitalization\n"
    "2. Remove filler words and false starts "
    "(um, uh, like, you know, so, basically, I mean, er, hmm, right)\n"
    "3. Remove repeated words from stuttering "
    '(e.g., "I I I think" → "I think")\n'
    "4. NEVER change the sentence type — questions must stay questions, "
    "statements must stay statements, commands must stay commands\n"
    "5. NEVER add words the speaker did not say — only remove or fix\n"
    "6. Keep the speaker's original meaning, vocabulary, and tone exactly\n"
    "7. Do NOT summarize, paraphrase, add commentary, or change intent\n"
    "8. For a single word or very short phrase, return it as-is with "
    "proper capitalization\n"
    "9. Output ONLY the cleaned text — no quotes, labels, explanations, "
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
    "custom_vocabulary": [],
}


class Settings:
    """Singleton for user-editable settings, persisted to JSON."""

    _instance = None

    def __init__(self):
        self.hotkey: str = _DEFAULTS["hotkey"]
        self.sounds_enabled: bool = _DEFAULTS["sounds_enabled"]
        self.double_tap_ms: int = _DEFAULTS["double_tap_ms"]
        self.llm_cleanup_enabled: bool = _DEFAULTS["llm_cleanup_enabled"]
        self.custom_vocabulary: list[str] = list(_DEFAULTS["custom_vocabulary"])
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
                    "custom_vocabulary": self.custom_vocabulary,
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
                # Ensure custom_vocabulary is always a list of strings
                if not isinstance(self.custom_vocabulary, list):
                    self.custom_vocabulary = []
                self.custom_vocabulary = [
                    str(w) for w in self.custom_vocabulary if str(w).strip()
                ]
            except Exception:
                pass


# ── Backward-compat module-level aliases ──────────────────
HOTKEY = Settings.get().hotkey
