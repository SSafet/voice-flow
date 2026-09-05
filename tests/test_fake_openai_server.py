"""Contract checks for streaming and ordinary-completion QA fixtures."""
import http.client
import json
import threading
import unittest
from http.server import ThreadingHTTPServer

from fake_openai_server import Handler


class FakeCompletionContract(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.log_file = None
        self.server.response_cost = 0.12
        self.server.log_lock = threading.Lock()
        self.server.metrics_lock = threading.Lock()
        self.server.active_requests = 0
        self.server.max_active_requests = 0
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def complete(self, stream, prompt="PLAIN_TEXT_TURN"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("POST", "/v1/chat/completions", json.dumps({
                "model": "test/model", "max_tokens": 128, "stream": stream,
                "messages": [{"role": "user", "content": prompt}]}),
                {"Authorization": "Bearer provider-secret", "Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return response.getheader("Content-Type"), response.read()
        finally:
            connection.close()

    def test_streaming_contract_unchanged(self):
        content_type, body = self.complete(True)
        self.assertEqual(content_type, "text/event-stream")
        self.assertTrue(body.endswith(b"data: [DONE]\n\n"))
        events = [json.loads(line[6:]) for line in body.decode().splitlines()
                  if line.startswith("data: {")]
        self.assertEqual("".join(event["choices"][0]["delta"].get("content", "") for event in events), "gateway ok")
        self.assertEqual(events[-1]["choices"][0]["finish_reason"], "stop")

    def test_nonstreaming_completion(self):
        content_type, body = self.complete(False)
        self.assertEqual(content_type, "application/json")
        value = json.loads(body)
        self.assertEqual(value["choices"][0]["message"], {"role": "assistant", "content": "gateway ok"})
        self.assertEqual(value["usage"]["cost"], 0.12)

    def test_nonstreaming_retains_tool_request_for_rejection(self):
        _, body = self.complete(False, "CALL_PERMISSION_TOOL")
        choice = json.loads(body)["choices"][0]
        self.assertEqual(choice["finish_reason"], "tool_calls")
        self.assertEqual(choice["message"]["tool_calls"][0]["function"]["name"], "bash")
        self.assertNotIn("index", choice["message"]["tool_calls"][0])


if __name__ == "__main__":
    unittest.main()
