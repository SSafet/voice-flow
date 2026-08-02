#!/usr/bin/env python3
"""Tiny streaming OpenAI-compatible upstream for the model-gateway live test."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/v1/models"):
            expected = os.environ.get("VOICE_FLOW_FAKE_PROVIDER_KEY", "provider-secret")
            if self.headers.get("Authorization") != f"Bearer {expected}":
                self.send_error(401)
                return
            payload = json.dumps({"data": [
                {
                    "id": "test/model", "name": "QA balanced model",
                    "context_length": 131072,
                    "top_provider": {
                        "context_length": 131072,
                        "max_completion_tokens": 16384,
                    },
                    "architecture": {
                        "input_modalities": ["text", "image"],
                        "output_modalities": ["text"],
                    },
                    "pricing": {"prompt": "0.000001", "completion": "0.000002"},
                    "supported_parameters": ["tools", "tool_choice", "max_tokens"],
                },
                {
                    "id": "test/model-fast", "name": "QA fast model",
                    "context_length": 32768,
                    "top_provider": {
                        "context_length": 32768,
                        "max_completion_tokens": 8192,
                    },
                    "architecture": {
                        "input_modalities": ["text"],
                        "output_modalities": ["text"],
                    },
                    "pricing": {"prompt": "0.0000001", "completion": "0.0000002"},
                    "supported_parameters": ["tools", "max_tokens"],
                },
            ]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path != "/metrics":
            self.send_error(404)
            return
        with self.server.metrics_lock:
            payload = json.dumps({
                "active": self.server.active_requests,
                "max_active": self.server.max_active_requests,
            }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_DELETE(self) -> None:  # noqa: N802
        if self.path != "/metrics":
            self.send_error(404)
            return
        with self.server.metrics_lock:
            if self.server.active_requests:
                self.send_error(409)
                return
            self.server.max_active_requests = 0
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length)
        request = json.loads(raw_body)
        log_file = getattr(self.server, "log_file", None)
        if log_file:
            # Long-lived sessions send cumulative history, so logging every
            # complete request makes a soak artifact grow O(n^2). Record a
            # bounded proof instead: shape/digest plus explicit assertions
            # that neither provider credential appeared in the outbound body.
            record = {
                "path": self.path,
                "model": request.get("model"),
                "body_bytes": len(raw_body),
                "body_sha256": hashlib.sha256(raw_body).hexdigest(),
                "message_count": len(request.get("messages", [])),
                "contains_provider_secret": os.environ.get(
                    "VOICE_FLOW_FAKE_PROVIDER_KEY", "provider-secret").encode() in raw_body,
                "contains_openai_secret": os.environ.get(
                    "VOICE_FLOW_FAKE_OPENAI_KEY", "qa-openai-secret").encode() in raw_body,
            }
            with self.server.log_lock:
                with Path(log_file).open("a") as handle:
                    handle.write(json.dumps(record, sort_keys=True) + "\n")
        if self.path == "/v1/audio/speech":
            expected = os.environ.get("VOICE_FLOW_FAKE_OPENAI_KEY", "qa-openai-secret")
            if self.headers.get("Authorization") != f"Bearer {expected}":
                self.send_error(401)
                return
            if request.get("model") != "gpt-4o-mini-tts" or request.get("response_format") != "pcm":
                self.send_error(400)
                return
            # Five seconds of deterministic 24 kHz mono signed-16 silence:
            # long enough for transport, seek, and barge-in assertions.
            body = bytes(24_000 * 2 * 5)
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        expected = os.environ.get("VOICE_FLOW_FAKE_PROVIDER_KEY", "provider-secret")
        if self.headers.get("Authorization") != f"Bearer {expected}":
            self.send_error(401)
            return
        if request.get("model") not in {"test/model", "test/model-fast"}:
            self.send_error(400)
            return
        if not 1 <= int(request.get("max_tokens", 0)) <= 32000:
            self.send_error(400)
            return
        messages = request.get("messages", [])
        serialized = json.dumps(messages)
        last_user_index = max(
            (index for index, message in enumerate(messages) if message.get("role") == "user"),
            default=-1,
        )
        latest_turn = messages[last_user_index:]
        latest_serialized = json.dumps(latest_turn)
        current_content = messages[last_user_index].get("content", "") if last_user_index >= 0 else ""
        if isinstance(current_content, list):
            current_text = "\n".join(
                part.get("text", "") for part in current_content
                if isinstance(part, dict) and part.get("type") in {"text", "input_text"}
            )
        else:
            current_text = str(current_content)
        # A stale-session reseed prepends canonical history containing old
        # markers. Only the final prompt layer is the command for this turn.
        current_task = current_text.rsplit("# Current task\n", 1)[-1]
        delay = re.search(r"DELAY_MS_(\d{1,5})", current_task)
        if delay:
            with self.server.metrics_lock:
                self.server.active_requests += 1
                self.server.max_active_requests = max(
                    self.server.max_active_requests,
                    self.server.active_requests,
                )
            try:
                time.sleep(min(int(delay.group(1)), 10_000) / 1000)
            finally:
                with self.server.metrics_lock:
                    self.server.active_requests -= 1
        stream_delay = re.search(r"STREAM_DELAY_MS_(\d{1,5})", current_task)
        stream_delay_seconds = (
            min(int(stream_delay.group(1)), 3_000) / 1000
            if stream_delay else 0.05
        )
        has_tool_result = any(message.get("role") == "tool" for message in latest_turn)
        wants_memory = "CALL_MEMORY_TOOL" in current_task
        wants_skill = "CALL_SKILL_TOOL" in current_task
        wants_permission = "CALL_PERMISSION_TOOL" in current_task
        wants_long_child = "CALL_LONG_CHILD" in current_task
        # Session history is cumulative; only this turn's content may select
        # the image fixture response.
        has_image = ("image_url" in latest_serialized
                     or '"type": "image"' in latest_serialized)

        def chunk(delta: dict, finish_reason: str | None = None,
                  usage: dict | None = None) -> bytes:
            payload = {
                "id": "chatcmpl-voice-flow-test",
                "object": "chat.completion.chunk",
                "created": 1_800_000_000,
                "model": request.get("model"),
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
            }
            if usage is not None:
                payload["usage"] = usage
            return ("data: " + json.dumps(payload) + "\n\n").encode()

        final = chunk({}, "stop", {
            "prompt_tokens": 11, "completion_tokens": 7,
            "cost": self.server.response_cost,
        })

        if has_tool_result:
            # Session history is intentionally cumulative. Only the active
            # user/tool exchange may select the final response; otherwise a
            # prior skill result can poison every later turn in the session.
            if wants_skill:
                chunks = [chunk({"role": "assistant", "content": "SKILL_NONCE_8421"}),
                          final, b"data: [DONE]\n\n"]
            else:
                chunks = [chunk({"role": "assistant", "content": "TOOL_OK"}),
                          final, b"data: [DONE]\n\n"]
        elif wants_memory:
            call = [{
                "index": 0, "id": "call_memory_1", "type": "function",
                "function": {
                    "name": "voiceflow_memory",
                    "arguments": json.dumps({"operation": "read", "kind": "core"}),
                },
            }]
            chunks = [chunk({"role": "assistant", "tool_calls": call}),
                      chunk({}, "tool_calls"), b"data: [DONE]\n\n"]
        elif wants_skill:
            call = [{
                "index": 0, "id": "call_skill_1", "type": "function",
                "function": {
                    "name": "skill",
                    "arguments": json.dumps({"name": "test-skill"}),
                },
            }]
            chunks = [chunk({"role": "assistant", "tool_calls": call}),
                      chunk({}, "tool_calls"), b"data: [DONE]\n\n"]
        elif wants_long_child:
            call = [{
                "index": 0, "id": "call_long_child_1", "type": "function",
                "function": {
                    "name": "bash",
                    "arguments": json.dumps({
                        "command": (
                            "sh -c 'printf %s $$ > long-child.pid; "
                            "sleep 120' VOICE_FLOW_ORPHAN_PROBE"
                        ),
                        "description": "Start the deterministic descendant cleanup probe",
                    }),
                },
            }]
            chunks = [chunk({"role": "assistant", "tool_calls": call}),
                      chunk({}, "tool_calls"), b"data: [DONE]\n\n"]
        elif wants_permission:
            marker = (
                "permission-allow.txt"
                if "PERMISSION_ALLOW" in latest_serialized
                else "permission-deny.txt"
            )
            call = [{
                "index": 0, "id": "call_permission_1", "type": "function",
                "function": {
                    "name": "bash",
                    "arguments": json.dumps({
                        "command": f"printf PERMISSION_OK > {marker}",
                        "description": "Write a deterministic permission marker",
                    }),
                },
            }]
            chunks = [chunk({"role": "assistant", "tool_calls": call}),
                      chunk({}, "tool_calls"), b"data: [DONE]\n\n"]
        elif "CANARY_SHARED_TEXT" in current_task:
            chunks = [chunk({"role": "assistant", "content": "CANARY_SHARED_OK"}),
                      final, b"data: [DONE]\n\n"]
        elif "LIVE_SPEECH_TURN" in current_task:
            chunks = [chunk({"role": "assistant", "content":
                             "The first deterministic sentence begins playback. "}),
                      chunk({"content": "The second sentence completes the reply."}), final,
                      b"data: [DONE]\n\n"]
        elif has_image:
            chunks = [chunk({"role": "assistant", "content": "IMAGE_OK"}),
                      final, b"data: [DONE]\n\n"]
        else:
            chunks = [chunk({"role": "assistant", "content": "gateway "}),
                      chunk({"content": "ok"}), final,
                      b"data: [DONE]\n\n"]
        body = b"".join(chunks)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(chunk)
            self.wfile.flush()
            time.sleep(stream_delay_seconds)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log-file")
    parser.add_argument("--response-cost", type=float, default=0.2)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.log_file = args.log_file
    server.response_cost = max(0, args.response_cost)
    server.log_lock = threading.Lock()
    server.metrics_lock = threading.Lock()
    server.active_requests = 0
    server.max_active_requests = 0
    Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
