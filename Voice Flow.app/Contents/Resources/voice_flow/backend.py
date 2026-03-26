"""Voice Flow backend worker — JSON-lines over stdin/stdout."""

import base64
import json
import os
import sys
import wave

import numpy as np

from voice_flow.transcriber import Transcriber
from voice_flow.cleaner import Cleaner
from voice_flow.config import SAMPLE_RATE
from voice_flow.openai_transcriber import OpenAITranscriber


def _read_wav(path: str) -> np.ndarray:
    with wave.open(path, "r") as wf:
        frames = wf.readframes(wf.getnframes())
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32767.0


def _decode_b64_pcm(b64: str) -> np.ndarray:
    """Decode base64-encoded int16 PCM to float32 [-1.0, 1.0]."""
    raw = base64.b64decode(b64)
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32767.0


def _send(msg: dict):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    # Line-buffered stdout for real-time communication
    sys.stdout.reconfigure(line_buffering=True)

    transcriber = Transcriber()
    cleaner = Cleaner()
    openai_transcriber = OpenAITranscriber()

    _send({"event": "ready"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue

        action = cmd.get("cmd")

        if action == "load":
            try:
                _send({"event": "status", "message": "Loading STT model..."})
                transcriber.load()
                _send({"event": "status", "message": "Loading cleanup LLM..."})
                cleaner.load()
                _send({"event": "loaded"})
            except Exception as e:
                _send({"event": "error", "message": str(e)})

        elif action == "transcribe":
            audio_path = cmd.get("audio_path", "")
            audio_b64 = cmd.get("audio_b64", "")
            sample_rate = int(cmd.get("sample_rate", SAMPLE_RATE) or SAMPLE_RATE)
            skip_cleanup = cmd.get("skip_cleanup", False)
            provider = cmd.get("provider", "local")
            openai_api_key = cmd.get("openai_api_key", "")
            try:
                # Prefer base64 PCM (no file I/O), fall back to WAV path
                if audio_b64:
                    audio = _decode_b64_pcm(audio_b64)
                elif audio_path:
                    audio = _read_wav(audio_path)
                else:
                    _send({"event": "result", "raw": "", "cleaned": ""})
                    continue

                if len(audio) < 1600:  # < 100ms at 16kHz
                    _send({"event": "result", "raw": "", "cleaned": ""})
                    continue

                if provider == "openai":
                    _send({"event": "status", "message": "Transcribing with OpenAI..."})
                    raw = openai_transcriber.transcribe(
                        audio,
                        api_key=openai_api_key,
                        sample_rate=sample_rate,
                    )
                else:
                    if not transcriber.is_loaded:
                        _send({"event": "status", "message": "Loading STT model..."})
                    raw = transcriber.transcribe(audio, sample_rate=sample_rate)

                if not raw:
                    _send({"event": "result", "raw": "", "cleaned": ""})
                    continue

                if provider == "openai":
                    cleaned = raw
                elif skip_cleanup:
                    # Basic capitalization only — no LLM round-trip
                    cleaned = raw.strip()
                    if cleaned:
                        cleaned = cleaned[0].upper() + cleaned[1:]
                else:
                    if not cleaner.is_loaded:
                        _send({"event": "status", "message": "Loading cleanup LLM..."})
                    cleaned = cleaner.clean(raw)

                _send({"event": "result", "raw": raw, "cleaned": cleaned})
            except Exception as e:
                _send({"event": "error", "message": str(e)})
            finally:
                # Clean up temp file if WAV path was used
                if audio_path:
                    try:
                        os.unlink(audio_path)
                    except OSError:
                        pass

        elif action == "ping":
            _send({"event": "pong"})


if __name__ == "__main__":
    main()
