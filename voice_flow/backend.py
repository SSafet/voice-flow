"""Voice Flow backend worker — JSON-lines over stdin/stdout."""

import json
import os
import sys
import wave

import numpy as np

from voice_flow.transcriber import Transcriber
from voice_flow.cleaner import Cleaner


def _read_wav(path: str) -> np.ndarray:
    with wave.open(path, "r") as wf:
        frames = wf.readframes(wf.getnframes())
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32767.0


def _send(msg: dict):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    # Line-buffered stdout for real-time communication
    sys.stdout.reconfigure(line_buffering=True)

    transcriber = Transcriber()
    cleaner = Cleaner()

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
            try:
                audio = _read_wav(audio_path)
                if len(audio) < 1600:
                    _send({"event": "result", "raw": "", "cleaned": ""})
                    continue

                raw = transcriber.transcribe(audio)
                if not raw:
                    _send({"event": "result", "raw": "", "cleaned": ""})
                    continue

                cleaned = cleaner.clean(raw)
                _send({"event": "result", "raw": raw, "cleaned": cleaned})
            except Exception as e:
                _send({"event": "error", "message": str(e)})
            finally:
                # Clean up temp file
                try:
                    os.unlink(audio_path)
                except OSError:
                    pass

        elif action == "ping":
            _send({"event": "pong"})


if __name__ == "__main__":
    main()
