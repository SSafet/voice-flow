import os
import tempfile
import wave

import numpy as np

from voice_flow.config import STT_MODEL, SAMPLE_RATE, FILLER_ONLY


class Transcriber:
    """Parakeet TDT speech-to-text via mlx-audio."""

    def __init__(self, model_name: str = STT_MODEL):
        self.model_name = model_name
        self._model = None
        self._loaded = False

    def load(self) -> None:
        from mlx_audio.stt import load_model

        self._model = load_model(self.model_name)
        self._loaded = True

    def transcribe(self, audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> str:
        if not self._loaded:
            self.load()
        if len(audio) == 0:
            return ""

        # Try passing audio directly as mlx array (avoids WAV I/O)
        try:
            import mlx.core as mx

            audio_mx = mx.array(audio)
            result = self._model.generate(audio_mx)
        except Exception:
            # Fallback: write to temp WAV
            tmp = tempfile.mktemp(suffix=".wav")
            try:
                _write_wav(tmp, audio, sample_rate)
                result = self._model.generate(tmp)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)

        text = ""
        if hasattr(result, "text"):
            text = result.text.strip()
        elif isinstance(result, dict):
            text = result.get("text", "").strip()
        else:
            text = str(result).strip()

        # Discard filler-only outputs (saves an LLM round-trip)
        if text.lower().strip(".,!?") in FILLER_ONLY:
            return ""

        return text

    @property
    def is_loaded(self) -> bool:
        return self._loaded


def _write_wav(path: str, audio: np.ndarray, sample_rate: int) -> None:
    audio_int16 = (audio * 32767).astype(np.int16)
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())
