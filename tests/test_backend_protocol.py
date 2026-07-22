import base64
import io
import json
import sys
import unittest
from unittest import mock

import numpy as np

from voice_flow import backend
from voice_flow.openai_transcriber import _is_prompt_echo, _transcription_prompt


class _Local:
    is_loaded = True

    def load(self):
        pass

    def transcribe(self, audio, sample_rate=16000):
        return "local"


class _Cleaner:
    is_loaded = True
    last_kwargs = None

    def load(self):
        pass

    def clean(self, raw, **kwargs):
        type(self).last_kwargs = kwargs
        return raw


class _OpenAI:
    last_kwargs = None

    def transcribe(self, audio, **kwargs):
        type(self).last_kwargs = kwargs
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
    def setUp(self):
        _Cleaner.last_kwargs = None
        _OpenAI.last_kwargs = None

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

    def test_wake_word_reaches_cloud_transcription(self):
        _run({
            "cmd": "transcribe",
            "request_id": "run-wake",
            "audio_b64": _audio(),
            "provider": "openai",
            "openai_api_key": "test",
            "wake_word": "FLORA",
        })
        self.assertEqual(_OpenAI.last_kwargs["wake_word"], "FLORA")

    def test_wake_word_reaches_local_cleanup(self):
        _run({
            "cmd": "transcribe",
            "request_id": "run-local-wake",
            "audio_b64": _audio(),
            "provider": "local",
            "wake_word": "FLORA",
        })
        self.assertEqual(_Cleaner.last_kwargs["wake_word"], "FLORA")

    def test_cloud_prompt_preserves_exact_wake_script(self):
        prompt = _transcription_prompt(["Anthropic"], "FLORA")
        self.assertIn('written exactly as "FLORA"', prompt)
        self.assertIn("even when the surrounding speech uses another language", prompt)
        self.assertIn("Correct spellings: Anthropic", prompt)
        self.assertTrue(_is_prompt_echo(prompt, ["Anthropic"], "FLORA"))

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
