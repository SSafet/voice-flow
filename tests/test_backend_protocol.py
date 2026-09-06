import base64
import io
import hashlib
import http.client
import http.server
import json
import socket
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import wave
from pathlib import Path
from unittest import mock

import numpy as np

from voice_flow import backend
from voice_flow.cleaner import Cleaner
from voice_flow.openai_transcriber import OpenAITranscriber, _is_prompt_echo, _transcription_prompt
from voice_flow.transcriber import Transcriber


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


def _run(command, cloud=_OpenAI):
    return _run_commands([command], cloud)


def _run_commands(commands, cloud=_OpenAI):
    stdin = io.StringIO("".join(json.dumps(command) + "\n" for command in commands))
    stdout = _Output()
    with (
        mock.patch.object(backend, "Transcriber", _Local),
        mock.patch.object(backend, "Cleaner", _Cleaner),
        mock.patch.object(backend, "OpenAITranscriber", cloud),
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

    def test_non_object_commands_do_not_kill_worker(self):
        for command in (None, [], "ping", 1, True):
            with self.subTest(command=command):
                events = _run_commands([command, {"cmd": "ping"}])
                self.assertEqual(events[-1], {"event": "pong"})

    def test_invalid_sample_rate_is_contained_and_correlated(self):
        for action in ("transcribe", "partial_transcribe"):
            for rate in ("bad", {}, [], -1, 0, True, 16000.5):
                with self.subTest(action=action, rate=rate):
                    events = _run_commands([{
                        "cmd": action, "request_id": "invalid-rate", "run_id": "run",
                        "sample_rate": rate, "audio_b64": _audio(),
                    }, {"cmd": "ping"}])
                    terminal = events[-2]
                    self.assertEqual(terminal["event"],
                                     "error" if action == "transcribe" else "partial_result")
                    self.assertEqual(terminal["request_id"], "invalid-rate")
                    if action == "partial_transcribe":
                        self.assertEqual(terminal["run_id"], "run")
                        self.assertEqual(terminal["text"], "")
                    self.assertEqual(events[-1], {"event": "pong"})

    def test_base64_precedence_preserves_unused_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "unused.wav"
            path.write_bytes(b"untouched")
            events = _run({"cmd": "transcribe", "audio_b64": _audio(), "audio_path": str(path)})
            self.assertEqual(events[-1]["event"], "result")
            self.assertEqual(path.read_bytes(), b"untouched")

    def test_invalid_path_does_not_kill_worker_during_cleanup(self):
        for path in (["invalid"], {"path": "invalid"}, 1):
            with self.subTest(path=path):
                events = _run_commands([{"cmd": "transcribe", "audio_path": path}, {"cmd": "ping"}])
                self.assertEqual(events[-2]["event"], "error")
                self.assertEqual(events[-1], {"event": "pong"})

    def test_invalid_base64_is_not_silently_transcribed(self):
        events = _run({"cmd": "transcribe", "audio_b64": "!!!!" + _audio()})
        self.assertEqual(events[-1]["event"], "error")

    def test_wav_uses_file_rate_and_removes_consumed_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audio.wav"
            with wave.open(str(path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(48000)
                wav.writeframes(np.ones(6000, dtype=np.int16).tobytes())
            events = _run({"cmd": "transcribe", "audio_path": str(path)})
            self.assertEqual(events[-1]["event"], "result")
            self.assertEqual(_OpenAI.last_kwargs["sample_rate"], 48000)
            self.assertFalse(path.exists())

    def test_unsupported_wav_format_fails_instead_of_corrupting_audio(self):
        for channels, width in ((2, 2), (1, 1), (1, 3)):
            with self.subTest(channels=channels, width=width), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "audio.wav"
                with wave.open(str(path), "wb") as wav:
                    wav.setnchannels(channels)
                    wav.setsampwidth(width)
                    wav.setframerate(16000)
                    wav.writeframes(b"\x01" * (2000 * channels * width))
                events = _run({"cmd": "transcribe", "audio_path": str(path)})
                self.assertEqual(events[-1]["event"], "error")
                self.assertFalse(path.exists())

    def test_short_audio_threshold_uses_duration(self):
        for action in ("transcribe", "partial_transcribe"):
            with self.subTest(action=action):
                # 2000 samples is only 42ms at 48kHz, shorter than either minimum.
                _OpenAI.last_kwargs = None
                events = _run({"cmd": action, "audio_b64": _audio(), "sample_rate": 48000})
                self.assertEqual(events[-1].get("text", events[-1].get("raw")), "")
                self.assertIsNone(_OpenAI.last_kwargs)

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
        self.assertEqual(_OpenAI.last_kwargs["max_attempts"], 1)

    def test_four_minute_upload_recovers_from_real_dropped_http_connection(self):
        uploads = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                uploads.append(hashlib.sha256(body).hexdigest())
                if len(uploads) == 1:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"text":"Recovered long dictation"}')

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        urlopen = urllib.request.urlopen

        def local_request(request, **kwargs):
            request.full_url = f"http://127.0.0.1:{server.server_port}/transcribe"
            return urlopen(request, **kwargs)

        try:
            with (mock.patch("urllib.request.urlopen", side_effect=local_request),
                  mock.patch("voice_flow.openai_transcriber.time.sleep")):
                events = _run({
                    "cmd": "transcribe", "request_id": "long-recording",
                    "audio_b64": base64.b64encode(np.ones(240 * 16000, dtype=np.int16).tobytes()).decode(),
                    "provider": "openai", "openai_api_key": "test",
                }, cloud=OpenAITranscriber)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
        self.assertEqual(len(uploads), 2)
        self.assertEqual(uploads[0], uploads[1])
        terminal = [e for e in events if e["event"] in ("result", "error")]
        self.assertEqual(terminal, [{"event": "result", "request_id": "long-recording",
                                    "raw": "Recovered long dictation", "cleaned": "Recovered long dictation"}])
        retry = next(e for e in events if "retrying" in e.get("message", ""))
        self.assertEqual(retry["request_id"], "long-recording")


class CleanupFastPathTests(unittest.TestCase):
    def test_empty_and_short_text_do_not_load_model(self):
        for raw, expected in (("  ", ""), ("hello", "Hello."), ("hello there!", "Hello there!")):
            with self.subTest(raw=raw):
                cleaner = Cleaner()
                with mock.patch.object(cleaner, "load", side_effect=AssertionError("unnecessary model load")):
                    self.assertEqual(cleaner.clean(raw), expected)


class LocalTranscriptionTests(unittest.TestCase):
    def test_empty_audio_does_not_load_model(self):
        transcriber = Transcriber()
        with mock.patch.object(transcriber, "load", side_effect=AssertionError("unnecessary model load")):
            self.assertEqual(transcriber.transcribe(np.array([], dtype=np.float32)), "")

    def test_fallback_temp_file_is_created_atomically_and_removed_on_failure(self):
        transcriber = Transcriber()
        transcriber._loaded = True
        transcriber._model = mock.Mock()
        paths = []

        def fail_generate(path):
            paths.append(Path(path))
            self.assertTrue(paths[-1].is_file())
            raise RuntimeError("model failed")

        transcriber._model.generate.side_effect = fail_generate
        with mock.patch.dict(sys.modules, {"mlx.core": None}), \
                mock.patch("voice_flow.transcriber.tempfile.mktemp", side_effect=AssertionError("non-atomic temp path")):
            with self.assertRaisesRegex(RuntimeError, "model failed"):
                transcriber.transcribe(np.ones(2000, dtype=np.float32))
        self.assertEqual(len(paths), 1)
        self.assertFalse(paths[0].exists())


class TranscriptionRetryTests(unittest.TestCase):
    def transcribe(self, **kwargs):
        return OpenAITranscriber().transcribe(np.ones(2000, dtype=np.float32), "test", **kwargs)

    def test_transport_failures_are_bounded(self):
        for error in (http.client.RemoteDisconnected("closed"), TimeoutError("timeout"),
                      urllib.error.URLError("offline"), http.client.IncompleteRead(b"partial", 20)):
            with self.subTest(error=error), mock.patch("urllib.request.urlopen", side_effect=error) as request, \
                    mock.patch("voice_flow.openai_transcriber.time.sleep") as sleep:
                with self.assertRaisesRegex(RuntimeError, "after 3 attempt"):
                    self.transcribe()
                self.assertEqual(request.call_count, 3)
                self.assertEqual(sleep.call_args_list, [mock.call(1), mock.call(2)])

    def test_retryable_http_errors_recover_but_permanent_errors_fail_once(self):
        for code in (408, 429, 500, 502, 503, 504, 400, 401, 403, 413):
            error = urllib.error.HTTPError("test", code, "error", {}, io.BytesIO(b'{"error":{"message":"problem"}}'))
            with self.subTest(code=code), mock.patch("urllib.request.urlopen", side_effect=[error, io.BytesIO(b'{"text":"ok"}')]) as request, \
                    mock.patch("voice_flow.openai_transcriber.time.sleep"):
                if code in (400, 401, 403, 413):
                    with self.assertRaisesRegex(RuntimeError, str(code)):
                        self.transcribe()
                    self.assertEqual(request.call_count, 1)
                else:
                    self.assertEqual(self.transcribe(), "ok")
                    self.assertEqual(request.call_count, 2)

    def test_partial_does_not_retry(self):
        with mock.patch("urllib.request.urlopen", side_effect=http.client.RemoteDisconnected("closed")) as request:
            events = _run({"cmd": "partial_transcribe", "run_id": "run", "request_id": 1,
                           "provider": "openai", "openai_api_key": "test", "audio_b64": _audio()},
                          cloud=OpenAITranscriber)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(events[-1], {"event": "partial_result", "run_id": "run", "request_id": 1, "text": ""})

    def test_failed_http_error_body_is_closed_and_status_still_controls_retry(self):
        for code in (503, 401):
            body = mock.Mock()
            body.read.side_effect = http.client.IncompleteRead(b"partial", 20)
            error = urllib.error.HTTPError("test", code, "error", {}, body)
            with self.subTest(code=code), \
                    mock.patch("urllib.request.urlopen", side_effect=[error, io.BytesIO(b'{"text":"ok"}')]) as request, \
                    mock.patch("voice_flow.openai_transcriber.time.sleep"):
                if code == 503:
                    self.assertEqual(self.transcribe(), "ok")
                    self.assertEqual(request.call_count, 2)
                else:
                    with self.assertRaisesRegex(RuntimeError, "401"):
                        self.transcribe()
                    self.assertEqual(request.call_count, 1)
                body.close.assert_called_once()

    def test_invalid_response_never_becomes_dictated_text(self):
        for payload in ({"text": None}, {"text": ["bad"]}, {"text": {"bad": "text"}}, [], {}):
            with self.subTest(payload=payload), \
                    mock.patch("urllib.request.urlopen", return_value=io.BytesIO(json.dumps(payload).encode())) as request:
                with self.assertRaisesRegex(RuntimeError, "invalid transcription response"):
                    self.transcribe()
                self.assertEqual(request.call_count, 1)


if __name__ == "__main__":
    unittest.main()
