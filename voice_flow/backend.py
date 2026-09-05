"""Voice Flow backend worker — JSON-lines over stdin/stdout."""

import base64
import json
import os
import sys
import threading
import wave

import numpy as np

from voice_flow.config import SAMPLE_RATE
from voice_flow.openai_transcriber import OpenAITranscriber
from voice_flow.speech_worker import SpeechWorker


def _read_wav(path: str) -> np.ndarray:
    with wave.open(path, "r") as wf:
        frames = wf.readframes(wf.getnframes())
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32767.0


def _decode_b64_pcm(b64: str) -> np.ndarray:
    """Decode base64-encoded int16 PCM to float32 [-1.0, 1.0]."""
    raw = base64.b64decode(b64)
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32767.0


_output_lock = threading.Lock()


def _send(msg: dict):
    with _output_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


class RequestHandler:
    def __init__(self):
        self.openai_transcriber = OpenAITranscriber()

    def __call__(self, cmd, emit):
        action = cmd.get("cmd")
        if action not in ("transcribe", "partial_transcribe"):
            emit({"event": "error", "request_id": cmd.get("request_id"),
                  "message": "Only API transcription is supported."})
            return
        partial = action == "partial_transcribe"
        request_id = cmd.get("request_id")
        audio_path = cmd.get("audio_path", "")

        def result(text):
            if partial:
                emit({"event": "partial_result", "run_id": cmd.get("run_id"),
                      "request_id": request_id, "text": text})
            else:
                emit({"event": "result", "request_id": request_id, "raw": text, "cleaned": text})

        try:
            if cmd.get("provider", "openai") != "openai":
                raise ValueError("Local transcription was retired. Select OpenAI API in Settings.")
            sample_rate = int(cmd.get("sample_rate", SAMPLE_RATE) or SAMPLE_RATE)
            if sample_rate <= 0:
                raise ValueError("Invalid audio sample rate")
            if cmd.get("audio_b64"):
                audio = _decode_b64_pcm(cmd["audio_b64"])
            elif audio_path:
                audio = _read_wav(audio_path)
            else:
                result("")
                return
            if len(audio) < sample_rate * (0.05 if partial else 0.1):
                result("")
                return
            options = dict(
                api_key=cmd.get("openai_api_key", ""), sample_rate=sample_rate,
                vocabulary=cmd.get("vocabulary") or None,
                wake_word=str(cmd.get("wake_word") or "").strip() or None,
            )
            if partial:
                options.update(max_attempts=1, timeout_seconds=10)
            else:
                emit({"event": "status", "request_id": request_id, "message": "Transcribing with OpenAI..."})
                options.update(
                    on_delta=lambda text: emit({"event": "transcription_delta", "request_id": request_id, "text": text}),
                    on_retry=lambda attempt, total: emit({
                        "event": "status", "request_id": request_id,
                        "message": f"Transcription interrupted — retrying ({attempt}/{total})...",
                    }),
                )
            result(self.openai_transcriber.transcribe(audio, **options) or "")
        except Exception as exc:
            if partial:
                result("")
            else:
                emit({"event": "error", "request_id": request_id, "message": str(exc)})
        finally:
            if audio_path:
                try:
                    os.unlink(audio_path)
                except OSError:
                    pass


def main():
    sys.stdout.reconfigure(line_buffering=True)
    worker = SpeechWorker(RequestHandler, _send)
    _send({"event": "ready"})
    try:
        for line in sys.stdin:
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(cmd, dict):
                continue
            if cmd.get("cmd") == "ping":
                _send({"event": "pong"})
            else:
                worker.submit(cmd)
    finally:
        worker.close()


if __name__ == "__main__":
    main()
