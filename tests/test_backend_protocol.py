import base64
import io
import hashlib
import http.client
import http.server
import json
import socket
import sys
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

import numpy as np

from voice_flow import backend
from voice_flow.openai_transcriber import OpenAITranscriber, _is_prompt_echo, _transcription_prompt


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
    stdin = io.StringIO(json.dumps(command) + "\n")
    stdout = _Output()
    with (
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

    def test_retired_local_provider_fails_visibly(self):
        events = _run({"cmd": "transcribe", "request_id": "old-local", "provider": "local", "audio_b64": _audio()})
        error = next(e for e in events if e["event"] == "error")
        self.assertEqual(error["request_id"], "old-local")
        self.assertIn("retired", error["message"])

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
                self.wfile.write(b'data: {"type":"transcript.text.done","text":"Recovered long dictation"}\n\n')

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
        self.assertEqual(next(e for e in events if e["event"] == "partial_result"), {"event": "partial_result", "run_id": "run", "request_id": 1, "text": ""})


if __name__ == "__main__":
    unittest.main()
