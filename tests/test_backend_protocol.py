import base64
import io
import json
import sys
import unittest
from unittest import mock

import numpy as np

from voice_flow import backend


class _Local:
    is_loaded = True

    def load(self):
        pass

    def transcribe(self, audio, sample_rate=16000):
        return "local"


class _Cleaner:
    is_loaded = True

    def load(self):
        pass

    def clean(self, raw, vocabulary=None):
        return raw


class _OpenAI:
    def transcribe(self, audio, **kwargs):
        return "hello"


class _Output(io.StringIO):
    def reconfigure(self, **kwargs):
        pass


def _run(command):
    stdin = io.StringIO(json.dumps(command) + "\n")
    stdout = _Output()
    with (
        mock.patch.object(backend, "Transcriber", _Local),
        mock.patch.object(backend, "Cleaner", _Cleaner),
        mock.patch.object(backend, "OpenAITranscriber", _OpenAI),
        mock.patch.object(sys, "stdin", stdin),
        mock.patch.object(sys, "stdout", stdout),
    ):
        backend.main()
    return [json.loads(line) for line in stdout.getvalue().splitlines()]


def _audio():
    pcm = np.ones(2000, dtype=np.int16)
    return base64.b64encode(pcm.tobytes()).decode()


class BackendProtocolTests(unittest.TestCase):
    def test_final_result_echoes_capture_run_id(self):
        events = _run({
            "cmd": "transcribe",
            "request_id": "run-123",
            "audio_b64": _audio(),
            "provider": "openai",
            "openai_api_key": "test",
            "sample_rate": 16000,
        })
        result = next(event for event in events if event["event"] == "result")
        self.assertEqual(result, {
            "event": "result",
            "request_id": "run-123",
            "raw": "hello",
            "cleaned": "hello",
        })

    def test_partial_result_echoes_run_and_sequence_ids(self):
        events = _run({
            "cmd": "partial_transcribe",
            "run_id": "run-456",
            "request_id": 7,
            "audio_b64": _audio(),
            "provider": "openai",
            "openai_api_key": "test",
            "sample_rate": 16000,
        })
        result = next(event for event in events if event["event"] == "partial_result")
        self.assertEqual(result["run_id"], "run-456")
        self.assertEqual(result["request_id"], 7)


if __name__ == "__main__":
    unittest.main()
