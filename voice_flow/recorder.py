import threading

import numpy as np
import sounddevice as sd

from voice_flow.config import SAMPLE_RATE


class Recorder:
    """Push-to-talk audio recorder using sounddevice."""

    def __init__(self, sample_rate: int = SAMPLE_RATE):
        self.sample_rate = sample_rate
        self._recording = False
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream: sd.InputStream | None = None

    # ── public api ──────────────────────────────────────

    def start(self) -> None:
        with self._lock:
            self._chunks = []
            self._recording = True

        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        self._recording = False
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

        with self._lock:
            if self._chunks:
                audio = np.concatenate(self._chunks, axis=0).flatten()
                self._chunks = []
                return audio
        return np.array([], dtype="float32")

    @property
    def is_recording(self) -> bool:
        return self._recording

    # ── internals ───────────────────────────────────────

    def _callback(self, indata, frames, time, status):
        if self._recording:
            with self._lock:
                self._chunks.append(indata.copy())
