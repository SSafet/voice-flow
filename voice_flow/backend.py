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


def _read_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "r") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            raise ValueError("Audio WAV must contain mono 16-bit PCM")
        frames = wf.readframes(wf.getnframes())
        audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32767.0
        return audio, wf.getframerate()


def _decode_b64_pcm(b64: str) -> np.ndarray:
    """Decode base64-encoded int16 PCM to float32 [-1.0, 1.0]."""
    raw = base64.b64decode(b64, validate=True)
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32767.0


def _sample_rate(cmd: dict) -> int:
    rate = cmd.get("sample_rate", SAMPLE_RATE)
    if type(rate) is not int or rate <= 0:
        raise ValueError("sample_rate must be a positive integer")
    return rate


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
        if not isinstance(cmd, dict):
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
            request_id = cmd.get("request_id")
            audio_path = cmd.get("audio_path", "")
            audio_b64 = cmd.get("audio_b64", "")
            skip_cleanup = cmd.get("skip_cleanup", False)
            provider = cmd.get("provider", "openai")
            openai_api_key = cmd.get("openai_api_key", "")
            vocabulary = cmd.get("vocabulary") or []
            wake_word = str(cmd.get("wake_word") or "").strip() or None
            consumed_path = None
            try:
                sample_rate = _sample_rate(cmd)
                # Prefer base64 PCM (no file I/O), fall back to WAV path
                if audio_b64:
                    audio = _decode_b64_pcm(audio_b64)
                elif audio_path:
                    if not isinstance(audio_path, str):
                        raise ValueError("audio_path must be a string")
                    consumed_path = audio_path
                    audio, sample_rate = _read_wav(audio_path)
                else:
                    _send({"event": "result", "request_id": request_id, "raw": "", "cleaned": ""})
                    continue

                if len(audio) * 10 < sample_rate:  # < 100ms
                    _send({"event": "result", "request_id": request_id, "raw": "", "cleaned": ""})
                    continue

                if provider == "openai":
                    _send({"event": "status", "message": "Transcribing with OpenAI..."})
                    raw = openai_transcriber.transcribe(
                        audio,
                        api_key=openai_api_key,
                        sample_rate=sample_rate,
                        vocabulary=vocabulary or None,
                        wake_word=wake_word,
                        on_retry=lambda attempt, total: _send({
                            "event": "status", "request_id": request_id,
                            "message": f"Transcription interrupted — retrying ({attempt}/{total})...",
                        }),
                    )
                else:
                    if not transcriber.is_loaded:
                        _send({"event": "status", "message": "Loading STT model..."})
                    raw = transcriber.transcribe(audio, sample_rate=sample_rate)

                if not raw:
                    _send({"event": "result", "request_id": request_id, "raw": "", "cleaned": ""})
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
                    cleaned = cleaner.clean(
                        raw, vocabulary=vocabulary or None, wake_word=wake_word)

                _send({"event": "result", "request_id": request_id, "raw": raw, "cleaned": cleaned})
            except Exception as e:
                _send({"event": "error", "request_id": request_id, "message": str(e)})
            finally:
                # Clean up temp file if WAV path was used
                if consumed_path is not None:
                    try:
                        os.unlink(consumed_path)
                    except (OSError, ValueError):
                        pass

        elif action == "partial_transcribe":
            run_id = cmd.get("run_id")
            audio_b64 = cmd.get("audio_b64", "")
            provider = cmd.get("provider", "openai")
            openai_api_key = cmd.get("openai_api_key", "")
            request_id = cmd.get("request_id", 0)
            vocabulary = cmd.get("vocabulary") or []
            wake_word = str(cmd.get("wake_word") or "").strip() or None
            try:
                sample_rate = _sample_rate(cmd)
                if not audio_b64:
                    _send({"event": "partial_result", "run_id": run_id, "text": "", "request_id": request_id})
                    continue

                audio = _decode_b64_pcm(audio_b64)
                if len(audio) * 20 < sample_rate:  # < 50ms
                    _send({"event": "partial_result", "run_id": run_id, "text": "", "request_id": request_id})
                    continue

                if provider == "openai":
                    raw = openai_transcriber.transcribe(
                        audio,
                        api_key=openai_api_key,
                        sample_rate=sample_rate,
                        vocabulary=vocabulary or None,
                        wake_word=wake_word,
                        # A newer preview supersedes this one; do not hold up
                        # the final dictation by retrying stale partial audio.
                        max_attempts=1,
                    )
                else:
                    if not transcriber.is_loaded:
                        _send({"event": "status", "message": "Loading STT model..."})
                    raw = transcriber.transcribe(audio, sample_rate=sample_rate)

                _send({"event": "partial_result", "run_id": run_id, "text": raw or "", "request_id": request_id})
            except Exception:
                _send({"event": "partial_result", "run_id": run_id, "text": "", "request_id": request_id})

        elif action == "ping":
            _send({"event": "pong"})


if __name__ == "__main__":
    main()
