#!/usr/bin/env python3
"""Signed-app end-to-end gate for Voice Flow's dual-runtime harness.

The control plane is setup/observation only. Runtime work still crosses the
signed app, canonical history, real pinned OpenCode server, private tool and
model gateways, durable scheduler, and AppKit presentation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
import struct
import zlib
from pathlib import Path
from typing import Any, Callable


class GateFailure(RuntimeError):
    pass


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise GateFailure(message)


def wait_for(description: str, function: Callable[[], Any], timeout: float = 30) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        try:
            last = function()
            if last:
                return last
        except (ConnectionError, OSError, urllib.error.URLError):
            pass
        time.sleep(0.05)
    raise GateFailure(f"timed out waiting for {description}; last={last!r}")


def http_json(method: str, url: str, payload: dict[str, Any] | None = None,
              token: str | None = None, timeout: float = 10,
              headers: dict[str, str] | None = None) -> tuple[int, Any]:
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Accept", "application/json")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if token is not None:
        request.add_header("Authorization", f"Bearer {token}")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            decoded = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            decoded = {"raw": raw.decode(errors="replace")}
        return error.code, decoded


def mcp_json(base: str, payload: dict[str, Any] | None,
             session_id: str | None = None,
             method: str = "POST") -> tuple[int, Any, dict[str, str]]:
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(base + "/mcp", data=body, method=method)
    request.add_header("Accept", "application/json")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if session_id:
        request.add_header("Mcp-Session-Id", session_id)
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            raw = response.read()
            decoded = json.loads(raw) if raw else {}
            return response.status, decoded, dict(response.headers.items())
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            decoded = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            decoded = {"raw": raw.decode(errors="replace")}
        return error.code, decoded, dict(error.headers.items())


def scaffold_assistant(root: Path) -> None:
    assistant = root / "assistants" / "flora"
    (assistant / "memory").mkdir(parents=True)
    (assistant / "workspace").mkdir()
    (assistant / "skills" / "test-skill").mkdir(parents=True)
    (assistant / "assistant.md").write_text(
        "---\nname: FLORA\ndescription: signed QA assistant\n"
        "skills: test-skill\n---\nUse only deterministic QA evidence.\n"
    )
    (assistant / "memory" / "core.md").write_text(
        "2026-08-02: MEMORY_NONCE_7291\n"
    )
    (assistant / "memory" / "ledger.md").write_text("QA ledger\n")
    (assistant / "skills" / "test-skill" / "SKILL.md").write_text(
        "---\nname: test-skill\ndescription: Signed app QA skill\n---\n"
        "Return SKILL_NONCE_8421.\n"
    )
    # Headless macOS test sessions may run with Secure Input, which suppresses
    # synthetic keyDown/keyUp events, and synthetic F-keys may become media
    # events. flagsChanged events still traverse the real global tap, so QA
    # uses distinct modifiers while retaining the production hotkey managers,
    # timing, longest-match logic, and callbacks.
    (root / "settings.json").write_text(json.dumps({
        "hands_free_hotkey": {"key_code": 59, "modifiers": 0, "label": "Left Ctrl"},
        "continuous_capture_hotkey": {"key_code": 62, "modifiers": 0, "label": "Right Ctrl"},
        "snapshot_hotkey": {"key_code": 56, "modifiers": 0, "label": "Left Shift"},
        "annotate_hotkey": {"key_code": 60, "modifiers": 0, "label": "Right Shift"},
    }))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def png_channel_range(path: Path) -> int:
    """Decode an 8-bit non-interlaced RGB/RGBA PNG and return color range."""
    data = path.read_bytes()
    expect(data.startswith(b"\x89PNG\r\n\x1a\n"), "UI snapshot is not a PNG")
    position = 8
    width = height = color_type = bit_depth = interlace = 0
    compressed = bytearray()
    while position + 12 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    channels = {2: 3, 6: 4}.get(color_type)
    expect(bit_depth == 8 and channels is not None and interlace == 0,
           f"unsupported QA PNG format depth={bit_depth} color={color_type} interlace={interlace}")
    raw = zlib.decompress(bytes(compressed))
    stride = width * channels
    previous = bytearray(stride)
    values: list[int] = []
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset:offset + stride])
        offset += stride
        for index in range(stride):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 0xFF
            elif filter_type == 2:
                row[index] = (row[index] + up) & 0xFF
            elif filter_type == 3:
                row[index] = (row[index] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                estimate = left + up - upper_left
                distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
                predictor = (left, up, upper_left)[distances.index(min(distances))]
                row[index] = (row[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise GateFailure(f"unsupported PNG row filter {filter_type}")
        for index, value in enumerate(row):
            if channels == 3 or index % channels != 3:
                values.append(value)
        previous = row
    return max(values) - min(values) if values else 0


class SignedAppGate:
    PROVIDER_CANARY = "VF_PROVIDER_CANARY_8eb638c97b0d"
    OPENAI_CANARY = "VF_OPENAI_CANARY_27369dc94f81"

    def __init__(self, app: Path, root: Path, repo: Path, artifacts: Path,
                 soak_seconds: int = 0, soak_interval_seconds: float = 10) -> None:
        self.app = app
        self.root = root
        self.repo = repo
        self.artifacts = artifacts
        self.app_process: subprocess.Popen[bytes] | None = None
        self.provider_process: subprocess.Popen[bytes] | None = None
        self.provider_port = 0
        self.qa_port = 18794
        self.sync_port = 18795
        self.token = ""
        self.checks: list[str] = []
        self.app_log_handle: Any = None
        self.provider_log_handle: Any = None
        self.expected_ghost_session: str | None = None
        self.pinned_job_models: dict[str, str] = {}
        self.soak_seconds = soak_seconds
        self.soak_interval_seconds = max(1, soak_interval_seconds)
        self.last_descendant_pids: set[int] = set()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.qa_port}"

    def record(self, check: str) -> None:
        self.checks.append(check)

    def start_provider(self) -> None:
        port_file = self.artifacts / "provider-port"
        request_log = self.artifacts / "provider-requests.jsonl"
        self.provider_log_handle = (self.artifacts / "provider.log").open("wb")
        self.provider_process = subprocess.Popen(
            [sys.executable, str(self.repo / "tests" / "fake_openai_server.py"),
             "--port-file", str(port_file), "--log-file", str(request_log),
             "--response-cost", "0.01"],
            cwd=self.repo, stdout=self.provider_log_handle,
            stderr=subprocess.STDOUT, start_new_session=True,
            env={**os.environ,
                 "VOICE_FLOW_FAKE_PROVIDER_KEY": self.PROVIDER_CANARY,
                 "VOICE_FLOW_FAKE_OPENAI_KEY": self.OPENAI_CANARY},
        )
        wait_for("fake provider port", lambda: port_file.read_text() if port_file.exists() else "")
        self.provider_port = int(port_file.read_text())

    def start_app(self) -> None:
        executable = self.app / "Contents" / "MacOS" / "voice-flow"
        environment = os.environ.copy()
        environment.update({
            "VOICE_FLOW_CONFIG_ROOT": str(self.root),
            "VOICE_FLOW_QA_AGENT_API_KEY": self.PROVIDER_CANARY,
            "VOICE_FLOW_QA_OPENAI_API_KEY": self.OPENAI_CANARY,
            "VOICE_FLOW_QA_HEADLESS_APPROVAL": "1",
            "VOICE_FLOW_QA_SYNTHETIC_INPUT_ONLY": "1",
            "VOICE_FLOW_QA_AUDIO_FIXTURE": "1",
            "VOICE_FLOW_QA_TRANSCRIPT_FIXTURE": "qa synthetic hotkey transcript",
            "VOICE_FLOW_QA_PORT": str(self.qa_port),
            "VOICE_FLOW_QA_SYNC_PORT": str(self.sync_port),
            "VOICE_FLOW_QA_SCREENSHOT_FIXTURE": str(
                self.repo / "assets" / "icon.iconset" / "icon_16x16.png"),
            "VOICE_FLOW_QA_TTS_URL": (
                f"http://127.0.0.1:{self.provider_port}/v1/audio/speech"),
        })
        if self.app_log_handle:
            self.app_log_handle.close()
        self.app_log_handle = (self.artifacts / "signed-app.log").open("ab")
        previous_token = self.token
        self.app_process = subprocess.Popen(
            [str(executable)], cwd=self.repo, env=environment,
            stdout=self.app_log_handle, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.last_descendant_pids = set()
        token_file = self.root / "qa-control-token"
        wait_for(
            "rotated QA token",
            lambda: token_file.exists() and token_file.stat().st_size == 64
            and token_file.read_text() != previous_token,
        )
        self.token = token_file.read_text()
        wait_for("signed app API", lambda: self.qa("GET", "/__qa/state", expect_status=200))

    def qa(self, method: str, path: str, payload: dict[str, Any] | None = None,
           expect_status: int = 200, token: str | None = None) -> Any:
        status_code, result = http_json(
            method, self.base + path, payload,
            self.token if token is None else token,
        )
        if status_code != expect_status:
            raise GateFailure(
                f"{method} {path} returned {status_code}, wanted {expect_status}: {result}"
            )
        return result

    def state(self) -> dict[str, Any]:
        return self.qa("GET", "/__qa/state")

    def wait_idle(self, minimum_messages: int | None = None, timeout: float = 45) -> dict[str, Any]:
        def settled() -> dict[str, Any] | None:
            state = self.state()
            assistant = state["assistant"]
            if assistant["running"]:
                return None
            if minimum_messages is not None and len(assistant["messages"]) < minimum_messages:
                return None
            return state
        return wait_for("Assistant idle", settled, timeout)

    def submit(self, text: str, screenshots: list[str] | None = None,
               expected: str | None = None, timeout: float = 45) -> dict[str, Any]:
        before = self.state()["assistant"]["messages"]
        self.qa("POST", "/__qa/submit", {
            "text": text, "screenshots": screenshots or [],
        }, expect_status=202)
        state = self.wait_idle(len(before) + (2 if expected is not None else 1), timeout)
        if expected is not None:
            messages = state["assistant"]["messages"]
            expect(messages[-1]["role"] == "assistant", f"{text}: final role was not assistant")
            expect(messages[-1]["text"] == expected,
                   f"{text}: final was {messages[-1]['text']!r}, expected {expected!r}")
        return state

    def events(self) -> list[dict[str, Any]]:
        return self.qa("GET", "/__qa/events")["events"]

    def wait_event(self, event_type: str,
                   predicate: Callable[[dict[str, Any]], bool] | None = None,
                   after: int = 0, timeout: float = 30) -> dict[str, Any]:
        def find() -> dict[str, Any] | None:
            for event in self.events():
                if event["sequence"] <= after or event["type"] != event_type:
                    continue
                if predicate is None or predicate(event):
                    return event
            return None
        return wait_for(event_type, find, timeout)

    def create_job(self, prompt: str, trigger: str = "manual",
                   conversation_id: str | None = None, **extra: Any) -> str:
        payload: dict[str, Any] = {
            "prompt": prompt, "runtime": "opencode", "trigger": trigger,
            "trust_profile": "workspace", "daily_budget_usd": 100,
            "max_duration_seconds": 30, "max_attempts": 2,
        }
        if conversation_id:
            payload["conversation_id"] = conversation_id
        payload.update(extra)
        return self.qa("POST", "/__qa/jobs/create", payload)["job_id"]

    def job(self, job_id: str) -> dict[str, Any]:
        rows = self.qa("GET", "/__qa/jobs")["jobs"]
        return next(row for row in rows if row["id"] == job_id)

    def run_job(self, job_id: str) -> None:
        self.qa("POST", "/__qa/jobs/run", {"job_id": job_id}, expect_status=202)

    def wait_job_event(self, job_id: str, state: str, after: int,
                       timeout: float = 45) -> dict[str, Any]:
        return self.wait_event(
            "job_status",
            lambda event: event["payload"].get("job_id") == job_id
            and event["payload"].get("state") == state,
            after=after, timeout=timeout,
        )

    def reset_metrics(self) -> None:
        status, _ = http_json("DELETE", f"http://127.0.0.1:{self.provider_port}/metrics")
        expect(status == 204, f"provider metrics reset returned {status}")

    def metrics(self) -> dict[str, Any]:
        status, value = http_json("GET", f"http://127.0.0.1:{self.provider_port}/metrics")
        expect(status == 200, f"provider metrics returned {status}")
        return value

    def verify_bundle(self) -> None:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], check=True)
        runtime_dir = self.app / "Contents" / "Resources" / "Runtime" / "OpenCode"
        installed = json.loads((runtime_dir / "installed.json").read_text())
        versions = json.loads((runtime_dir / "versions.json").read_text())
        arch = "arm64" if os.uname().machine != "x86_64" else "x86_64"
        expect(installed["version"] == versions["version"], "installed runtime version drifted")
        expect(installed["architecture"] == arch, "installed runtime architecture drifted")
        expect(installed["sourceBinarySHA256"] == versions["assets"][arch]["binarySHA256"],
               "signed runtime lost official source chain of custody")
        expect(installed["installedBinarySHA256"] == sha256(runtime_dir / "opencode"),
               "signed runtime digest does not match its sealed manifest")
        self.record("signed_bundle_chain_of_custody")

    def verify_auth_and_isolation(self) -> None:
        status_code, _ = http_json("GET", self.base + "/__qa/state")
        expect(status_code == 401, "QA endpoint accepted a missing token")
        status_code, _ = http_json("GET", self.base + "/__qa/state", token="wrong")
        expect(status_code == 401, "QA endpoint accepted a wrong token")
        mode = stat.S_IMODE((self.root / "qa-control-token").stat().st_mode)
        expect(mode == 0o600, f"QA token mode is {oct(mode)}, expected 0600")
        state = self.state()
        reported_root = Path(state["config_root"]).resolve()
        expect(state["isolated"] and reported_root == self.root.resolve(),
               f"signed app root {reported_root} != isolated root {self.root.resolve()}")
        expect(state["synthetic_input_only"] is True,
               "desktop QA did not isolate the user's physical keyboard")
        expect(not state["assistant"]["messages"] and not state["jobs"],
               "fresh QA root imported host history or jobs")
        self.record("qa_auth_isolation")
        self.record("signed_qa_physical_input_isolation")

    def configure_runtime(self) -> None:
        self.qa("POST", "/__qa/provider", {
            "base_url": f"http://127.0.0.1:{self.provider_port}/v1",
            # Long release soaks deliberately issue thousands of requests.
            # The fake provider uses a one-cent synthetic cost, leaving ample
            # room under the product's supported $500 maximum; focused gateway
            # and zero-budget job tests still prove enforcement.
            "model": "test/model", "daily_budget_usd": 500,
        })
        result = self.qa("POST", "/__qa/runtime", {
            "runtime": "opencode", "trust_profile": "workspace",
        })
        expect(result["runtime"] == "opencode", "runtime selection did not persist")

    def verify_foreground_runtime(self) -> None:
        self.qa("POST", "/__qa/events/reset", {})
        self.submit("PLAIN_TEXT_TURN", expected="gateway ok")
        events = self.events()
        deltas = [event["payload"].get("text", "") for event in events
                  if event["type"] == "assistant_delta"]
        joined = "".join(deltas)
        expect(sum(event["type"] == "assistant_started" for event in events) == 1
               and sum(event["type"] == "assistant_completed" for event in events) == 1
               and joined == "gateway ok",
               f"Assistant callbacks did not reduce exactly once: {events}")
        expect("You are the Assistant inside Voice Flow" not in joined,
               "OpenCode leaked the user/system prompt into assistant UI deltas")
        expect("PLAIN_TEXT_TURN" not in joined,
               "OpenCode leaked the current user task into assistant UI deltas")
        self.submit("CALL_MEMORY_TOOL", expected="TOOL_OK")
        self.submit("CALL_SKILL_TOOL", expected="SKILL_NONCE_8421")
        image = self.root / "captures" / "qa-input.png"
        image.parent.mkdir(exist_ok=True)
        shutil.copyfile(self.repo / "assets" / "icon.iconset" / "icon_16x16.png", image)
        self.submit("IMAGE_TURN", [str(image)], expected="IMAGE_OK")
        self.record("signed_foreground_text_memory_skill_image")

    def post_hotkey(self, key_code: int, action: str) -> None:
        self.qa("POST", "/__qa/hotkey/post", {
            "key_code": key_code, "action": action,
        }, expect_status=202)

    def verify_physical_hotkeys(self) -> None:
        fixture_text = "qa synthetic hotkey transcript"
        before = len(self.dictations())

        self.post_hotkey(63, "press")
        wait_for("hold Dictate recording", lambda: self.state()["capture"]["recording"])
        self.post_hotkey(63, "release")
        wait_for("hold Dictate delivery", lambda: len(self.dictations()) >= before + 1)
        expect(self.dictations()[0]["text"] == fixture_text,
               "hold Dictate did not use the synthetic audio/backend fixture")

        before = len(self.dictations())
        self.post_hotkey(59, "double_tap")
        wait_for("double-tap Inbox recording",
                 lambda: self.state()["capture"]["state"] == "handsFree")
        self.post_hotkey(59, "tap")
        wait_for("double-tap Inbox delivery", lambda: len(self.dictations()) >= before + 1)
        expect(self.dictations()[0].get("destination") == "kept",
               f"double-tap Inbox was routed externally: {self.dictations()[0]}")

        before = len(self.dictations())
        self.post_hotkey(56, "press")
        wait_for("snapshot Dictate recording",
                 lambda: self.state()["capture"]["capability"] == "snapshot")
        self.post_hotkey(56, "release")
        wait_for("snapshot Dictate delivery", lambda: len(self.dictations()) >= before + 1)
        expect(self.dictations()[0].get("capability") == "snapshot",
               f"snapshot hotkey lost capability metadata: {self.dictations()[0]}")

        before = len(self.dictations())
        self.post_hotkey(62, "press")
        wait_for("continuous capture start",
                 lambda: self.state()["capture"]["session_active"] is True)
        self.post_hotkey(62, "release")
        self.post_hotkey(62, "press")
        wait_for("continuous capture stop",
                 lambda: self.state()["capture"]["session_active"] is False)
        self.post_hotkey(62, "release")
        wait_for("continuous capture delivery", lambda: len(self.dictations()) >= before + 1,
                 timeout=15)
        expect(self.dictations()[0].get("capability") == "continuous",
               f"continuous hotkey lost bundle metadata: {self.dictations()[0]}")

        self.post_hotkey(60, "tap")
        wait_for("annotation hotkey", lambda: self.state()["annotation_editing"] is True)
        self.post_hotkey(53, "tap")
        wait_for("physical Escape annotation exit",
                 lambda: self.state()["annotation_editing"] is False)
        self.record("signed_physical_hotkeys_with_audio_fixture")

    def dictations(self) -> list[dict[str, Any]]:
        path = self.root / "dictations.json"
        return json.loads(path.read_text()) if path.exists() else []

    def verify_capture_delivery(self) -> None:
        fixture = self.root / "captures" / "qa-input.png"

        self.qa("POST", "/__qa/capture/deliver", {
            "capability": "dictate", "route": "history",
            "transcript": "qa kept dictation",
        }, expect_status=202)
        kept = wait_for(
            "kept dictation",
            lambda: next((row for row in self.dictations()
                          if row.get("text") == "qa kept dictation"), None),
        )
        expect(kept.get("destination") == "kept" and kept.get("seen") is False,
               f"history-only dictation contract changed: {kept}")

        before = len(self.state()["assistant"]["messages"])
        self.qa("POST", "/__qa/capture/deliver", {
            "capability": "dictate", "route": "assistant",
            "transcript": "PLAIN_TEXT_TURN dictated assistant",
        }, expect_status=202)
        state = self.wait_idle(before + 2)
        expect(state["assistant"]["messages"][-1]["text"] == "gateway ok",
               "contextual dictation did not complete through the Assistant")

        before = len(state["assistant"]["messages"])
        self.qa("POST", "/__qa/capture/deliver", {
            "capability": "snapshot", "route": "assistant",
            "transcript": "IMAGE_TURN snapshot", "fixture_path": str(fixture),
        }, expect_status=202)
        state = self.wait_idle(before + 2)
        expect(state["assistant"]["messages"][-1]["text"] == "IMAGE_OK",
               "snapshot dictation dropped its image")
        snapshot = wait_for(
            "snapshot history",
            lambda: next((row for row in self.dictations()
                          if row.get("text") == "IMAGE_TURN snapshot"), None),
        )
        expect(snapshot.get("capability") == "snapshot"
               and len(snapshot.get("attachments", [])) == 1
               and Path(snapshot["attachments"][0]).is_file(),
               f"snapshot evidence was not persisted: {snapshot}")

        before = len(state["assistant"]["messages"])
        self.qa("POST", "/__qa/capture/deliver", {
            "capability": "continuous", "route": "assistant",
            "transcript": "PLAIN_TEXT_TURN continuous narration",
            "fixture_path": str(fixture),
        }, expect_status=202)
        state = self.wait_idle(before + 2)
        expect(state["assistant"]["messages"][-1]["text"] == "IMAGE_OK",
               "continuous capture did not complete through the Assistant")
        continuous = wait_for(
            "continuous history",
            lambda: next((row for row in self.dictations()
                          if row.get("capability") == "continuous"), None),
        )
        expect(continuous.get("captureId")
               and len(continuous.get("attachments", [])) == 1,
               f"continuous capture bundle was not linked: {continuous}")

        self.qa("POST", "/__qa/capture/deliver", {
            "capability": "dictate", "route": "closed_paste",
            "transcript": "qa frozen paste fallback",
        }, expect_status=202)
        fallback = wait_for(
            "closed paste fallback",
            lambda: next((row for row in self.dictations()
                          if row.get("text") == "qa frozen paste fallback"), None),
        )
        expect(fallback.get("destination") == "kept"
               and self.state()["clipboard_text"] == "qa frozen paste fallback",
               f"closed original target did not copy-and-keep: {fallback}")

        self.qa("POST", "/__qa/pill/action", {"action": "annotate_begin"},
                expect_status=202)
        expect(self.state()["annotation_editing"] is True,
               "annotation did not enter editing mode")
        self.qa("POST", "/__qa/pill/action", {"action": "escape"},
                expect_status=202)
        expect(self.state()["annotation_editing"] is False,
               "Escape did not commit and exit annotation mode")
        self.record("signed_capture_routes_snapshot_continuous_annotation_fallback")

    def resolve_permission(self, response: str) -> dict[str, Any]:
        after = max((event["sequence"] for event in self.events()), default=0)
        event = self.wait_event("permission_requested", after=after, timeout=15)
        self.qa("POST", "/__qa/permission", {
            "id": event["payload"]["id"], "response": response,
        }, expect_status=202)
        return event

    def verify_permissions_and_interrupt(self) -> None:
        assistant_dir = self.root / "assistants" / "flora"
        denied = assistant_dir / "permission-deny.txt"
        before = len(self.state()["assistant"]["messages"])
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/submit", {
            "text": "CALL_PERMISSION_TOOL PERMISSION_DENY",
        }, expect_status=202)
        event = self.wait_event("permission_requested", after=after)
        self.qa("POST", "/__qa/permission", {
            "id": event["payload"]["id"], "response": "reject",
        }, expect_status=202)
        self.wait_idle(before + 1)
        expect(not denied.exists(), "rejected permission created its marker")

        allowed = assistant_dir / "permission-allow.txt"
        before = len(self.state()["assistant"]["messages"])
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/submit", {
            "text": "CALL_PERMISSION_TOOL PERMISSION_ALLOW",
        }, expect_status=202)
        event = self.wait_event("permission_requested", after=after)
        self.qa("POST", "/__qa/permission", {
            "id": event["payload"]["id"], "response": "once",
        }, expect_status=202)
        state = self.wait_idle(before + 2)
        expect(state["assistant"]["messages"][-1]["text"] == "TOOL_OK",
               "allow-once did not complete the turn")
        expect(allowed.read_text() == "PERMISSION_OK", "allow-once marker was wrong")

        long_pid_file = assistant_dir / "long-child.pid"
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/submit", {"text": "CALL_LONG_CHILD"}, expect_status=202)
        event = self.wait_event("permission_requested", after=after)
        self.qa("POST", "/__qa/permission", {
            "id": event["payload"]["id"], "response": "once",
        }, expect_status=202)
        wait_for("long OpenCode child", lambda: long_pid_file.exists())
        child_pid = int(long_pid_file.read_text())
        wait_for("Assistant acting state",
                 lambda: self.state()["assistant"]["activity"] == "acting")
        self.qa("POST", "/__qa/pill/action", {"action": "escape"},
                expect_status=202)
        self.wait_idle(timeout=15)
        wait_for("long child termination", lambda: not self.pid_exists(child_pid), timeout=10)
        self.record("signed_permission_reject_allow_interrupt_cleanup")

    @staticmethod
    def pid_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def verify_runtime_restart(self) -> None:
        health = self.qa("GET", "/__qa/runtime/health")
        open_code = next(row for row in health["runtimes"]
                         if row["runtime"] == "opencode")
        expect(open_code["health"] == "healthy" and open_code["version"] == "1.17.11",
               f"running OpenCode health was not visible: {open_code}")
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/opencode/restart", {
            "trust_profile": "workspace",
        }, expect_status=202)
        self.wait_event("opencode_restarted", after=after, timeout=20)
        health = self.qa("GET", "/__qa/runtime/health")
        open_code = next(row for row in health["runtimes"]
                         if row["runtime"] == "opencode")
        expect(open_code["health"] == "healthy",
               f"restarted OpenCode health was not visible: {open_code}")
        self.submit("PLAIN_TEXT_TURN RESTARTED", expected="gateway ok")
        self.record("signed_opencode_restart")

    def verify_runtime_failure_recovery(self) -> None:
        before = self.state()["assistant"]["messages"]
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/submit", {
            "text": "DELAY_MS_5000 PLAIN_TEXT_TURN KILL_RUNTIME",
        }, expect_status=202)
        wait_for("provider request before runtime kill",
                 lambda: self.metrics().get("active", 0) == 1)
        self.qa("POST", "/__qa/opencode/stop", {
            "trust_profile": "workspace",
        }, expect_status=202)
        self.wait_event("opencode_stopped", after=after, timeout=15)
        state = self.wait_idle(len(before) + 2, timeout=20)
        new_messages = state["assistant"]["messages"][len(before):]
        expect(len(new_messages) == 2 and new_messages[0]["role"] == "user"
               and new_messages[1]["role"] == "note"
               and new_messages[1]["text"].strip(),
               f"runtime death did not persist one typed failure note: {new_messages}")
        expect(not any(message["role"] == "assistant" and not message["text"].strip()
                       for message in new_messages),
               f"runtime death persisted a blank assistant final: {new_messages}")
        expect(state["ui"]["controls"]["runtime_enabled"] is True,
               "runtime selector stayed disabled after runtime death")
        self.submit("PLAIN_TEXT_TURN AFTER_RUNTIME_DEATH", expected="gateway ok")
        self.record("signed_runtime_death_note_and_recovery")

    def verify_secret_containment(self) -> None:
        request_log = self.artifacts / "provider-requests.jsonl"
        if request_log.exists():
            for line_number, line in enumerate(request_log.read_text().splitlines(), 1):
                record = json.loads(line)
                expect(not record.get("contains_provider_secret")
                       and not record.get("contains_openai_secret"),
                       f"provider request {line_number} contained a long-lived credential")
        leaked: list[str] = []
        canaries = [self.PROVIDER_CANARY.encode(), self.OPENAI_CANARY.encode()]
        for base in [self.root, self.artifacts]:
            for path in base.rglob("*"):
                if not path.is_file():
                    continue
                try:
                    data = path.read_bytes()
                except OSError:
                    continue
                if any(canary in data for canary in canaries):
                    leaked.append(str(path))
        expect(not leaked, f"provider canary escaped the Keychain/gateway boundary: {leaked}")
        self.record("signed_secret_canary_containment")

    def verify_trigger_adapters(self) -> None:
        conversation = self.state()["assistant"]["conversation_id"]
        cases = [
            ("inbox", "/__qa/inbox/add", {"text": "qa inbox event"}),
            ("capture", "/__qa/capture/finalize", {"transcript": "qa capture event"}),
            ("watcher", "/__qa/watcher/action", {"event_id": "qa-watcher-1"}),
        ]
        for trigger, path, payload in cases:
            job_id = self.create_job(
                f"PLAIN_TEXT_TURN {trigger}", trigger=trigger,
                conversation_id=conversation,
            )
            after = max((event["sequence"] for event in self.events()), default=0)
            self.qa("POST", path, payload, expect_status=202)
            self.wait_job_event(job_id, "completed", after)
            expect(self.job(job_id)["state"] == "completed",
                   f"{trigger} adapter did not settle its job")
        self.record("signed_inbox_capture_watcher_triggers")

    def verify_sync(self) -> None:
        sync_base = f"http://127.0.0.1:{self.sync_port}"
        status, _ = http_json("POST", sync_base + "/pair", {"device": "QA phone"})
        expect(status == 403, "phone paired without Mac-side consent")
        status, _ = http_json("POST", self.base + "/api/pair-mode", {})
        expect(status in (200, 202), f"Mac-side pairing consent returned {status}")
        status, pair = http_json("POST", sync_base + "/pair", {"device": "QA phone"})
        expect(status == 200 and pair.get("ok") is True and pair.get("token"),
               "consented phone pairing did not issue a token")
        sync_token = pair["token"]
        status, _ = http_json("POST", sync_base + "/pair", {"device": "second phone"})
        expect(status == 403, "one-shot pairing window remained open")

        payload = {
            "dictations": [{
                "id": "phone-entry-1", "text": "phone nonce one",
                "date": "2026-08-02", "time": "12:00:00", "kind": "kept",
            }],
            "chat": [],
        }
        status, _ = http_json("POST", sync_base + "/sync", payload)
        expect(status == 401, "sync accepted a missing bearer token")
        auth = {"Authorization": f"Bearer {sync_token}"}
        status, response = http_json(
            "POST", sync_base + "/sync", payload, headers=auth)
        expect(status == 200 and response.get("ok") is True,
               "authorized phone dictation ingest failed")

        def recent_texts() -> list[str] | None:
            status_code, value = http_json(
                "POST", sync_base + "/sync", payload, headers=auth)
            if status_code != 200:
                return None
            texts = [item.get("text", "") for item in value.get("dictations", [])]
            return texts if "phone nonce one" in texts else None
        texts = wait_for("phone dictation persistence", recent_texts)
        expect(texts.count("phone nonce one") == 1,
               "repeated phone dictation was not deduplicated")

        updated = {
            "dictations": [{
                "id": "phone-entry-1", "text": "phone nonce updated",
                "date": "2026-08-02", "time": "12:00:00", "kind": "kept",
            }],
            "chat": [],
        }
        status, _ = http_json("POST", sync_base + "/sync", updated, headers=auth)
        expect(status == 200, "phone dictation upsert request failed")

        def updated_texts() -> list[str] | None:
            status_code, value = http_json(
                "POST", sync_base + "/sync", {"dictations": [], "chat": []},
                headers=auth)
            if status_code != 200:
                return None
            values = [item.get("text", "") for item in value.get("dictations", [])]
            return values if "phone nonce updated" in values else None
        texts = wait_for("phone dictation upsert", updated_texts)
        expect("phone nonce one" not in texts,
               "phone dictation upsert left the stale text in history")

        status, _ = http_json(
            "POST", sync_base + "/sync", {"dictations": [], "chat": []},
            headers={"Authorization": "Bearer disconnected-client"})
        expect(status == 401, "unauthorized reconnect was accepted")
        status, response = http_json(
            "POST", sync_base + "/sync", {"dictations": [], "chat": []},
            headers=auth)
        expect(status == 200 and response.get("ok") is True,
               "authorized client did not recover after a rejected reconnect")
        self.record("signed_sync_pairing_ingest_dedupe_recovery")

    def verify_tts(self) -> None:
        speech = (
            "The first deterministic sentence is long enough to be queued. "
            "The second deterministic sentence verifies transport controls. "
            "The third deterministic sentence verifies barge in behavior."
        )
        configuration = {
            "text": speech, "voice": "cedar", "speed": 1.25,
            "instructions": "  Crisp deterministic QA.  ", "reveal": False,
        }
        status, result = http_json("POST", self.base + "/api/tts/set", configuration)
        expect(status == 200 and result.get("voice") == "cedar"
               and result.get("speed") == 1.25,
               f"TTS configuration was not applied: {status} {result}")
        status, configured = http_json("GET", self.base + "/api/tts/status")
        expect(status == 200 and configured.get("text") == speech
               and configured.get("voice") == "cedar"
               and configured.get("instructions") == "Crisp deterministic QA.",
               "TTS status did not preserve normalized text/voice/instructions")
        status, _ = http_json("POST", self.base + "/api/tts/speak", {"text": ""})
        expect(status == 400, "TTS accepted empty speech")

        status, result = http_json("POST", self.base + "/api/tts/speak", configuration)
        expect(status == 202 and result.get("status") == "speaking",
               f"TTS speak did not start: {status} {result}")
        wait_for("TTS generation/playback", lambda: (lambda value:
            value if value["phase"] in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=12)
        self.qa("POST", "/__qa/tts/action", {"action": "pause"},
                expect_status=202)
        wait_for("TTS pause", lambda: (lambda value:
            value if value["message"] == "Paused" else None
        )(self.state()["tts"]), timeout=8)
        status, _ = http_json("POST", self.base + "/api/tts/seek", {"position": 1.0})
        expect(status == 200, "TTS seek endpoint failed while paused")
        after_seek = self.state()["tts"]
        expect(after_seek["phase"] != "error", "TTS seek entered an error state")
        # A seek can restart generation immediately when chunk boundaries are
        # already known, or remain paused while the first boundary is still
        # arriving. Normalize both correct timing outcomes before resuming.
        if after_seek["phase"] in ("generating", "playing"):
            self.qa("POST", "/__qa/tts/action", {"action": "pause"},
                    expect_status=202)
            normalized = wait_for("TTS re-pause", lambda: (lambda value:
                value if value["message"] == "Paused"
                or value["phase"] not in ("generating", "playing") else None
            )(self.state()["tts"]), timeout=8)
            if normalized["message"] == "Paused":
                self.qa("POST", "/__qa/tts/action", {"action": "resume"},
                        expect_status=202)
                wait_for("TTS resume", lambda: (lambda value:
                    value if value["phase"] in ("generating", "playing") else None
                )(self.state()["tts"]), timeout=8)
        status, _ = http_json("POST", self.base + "/api/tts/stop", {})
        expect(status == 200, "TTS stop endpoint failed")
        wait_for("TTS stop", lambda: (lambda value:
            value if value["phase"] not in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=8)

        status, _ = http_json("POST", self.base + "/api/tts/speak", configuration)
        expect(status == 202, "TTS barge-in setup did not start")
        wait_for("TTS before barge in", lambda: (lambda value:
            value if value["phase"] in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=8)
        self.qa("POST", "/__qa/pill/action", {"action": "barge_in"},
                expect_status=202)
        wait_for("TTS barge in", lambda: (lambda value:
            value if value["phase"] not in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=8)

        self.qa("POST", "/__qa/tts/action", {"action": "live_begin"},
                expect_status=202)
        expect(self.state()["tts"]["reply_speaker_active"] is True,
               "live reply speaker did not begin")
        self.qa("POST", "/__qa/tts/action", {
            "action": "live_feed",
            "text": "The first deterministic sentence is long enough to begin playback. ",
        }, expect_status=202)
        wait_for("live reply speech before final", lambda: (lambda value:
            value if value["tts"]["reply_speaker_active"]
            and value["tts"]["phase"] in ("generating", "playing") else None
        )(self.state()), timeout=15)
        self.qa("POST", "/__qa/tts/action", {
            "action": "live_feed", "text": "The second sentence completes the reply.",
        }, expect_status=202)
        self.qa("POST", "/__qa/tts/action", {"action": "live_finish"},
                expect_status=202)
        expect(self.state()["tts"]["reply_speaker_active"] is False,
               "live reply speaker did not finalize")
        self.qa("POST", "/__qa/pill/action", {"action": "barge_in"},
                expect_status=202)
        self.record("signed_tts_configuration_transport_barge_in")

    def verify_public_mcp(self) -> None:
        expect(self.state()["mcp"]["sessions"] == [],
               "embedded OpenCode tools polluted the public MCP session registry")
        next_id = 1

        def pill_snapshot(name: str) -> dict[str, Any]:
            result = self.qa("POST", "/__qa/ui/pill_snapshot", {"name": name})
            source = Path(result["path"])
            destination = self.artifacts / f"indicator-{name}.png"
            shutil.copyfile(source, destination)
            expect(destination.stat().st_size > 200,
                   f"indicator {name} snapshot is empty")
            expect(png_channel_range(destination) >= 16,
                   f"indicator {name} snapshot is visually degenerate")
            return result

        self.qa("POST", "/__qa/pill/action", {"action": "collapse"},
                expect_status=202)
        expect(self.state()["pill"]["mode"] == "pill",
               "indicator did not begin in collapsed pill mode")
        pill_snapshot("pill")

        def request(method: str, params: dict[str, Any] | None = None,
                    session: str | None = None) -> tuple[Any, dict[str, str]]:
            nonlocal next_id
            envelope: dict[str, Any] = {
                "jsonrpc": "2.0", "id": next_id, "method": method,
            }
            next_id += 1
            if params is not None:
                envelope["params"] = params
            status, decoded, headers = mcp_json(self.base, envelope, session)
            expect(status == 200 and "error" not in decoded,
                   f"MCP {method} failed with {status}: {decoded}")
            return decoded["result"], headers

        result, headers = request("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "voice-flow-qa", "version": "1"},
            "capabilities": {},
        })
        session_a = headers.get("Mcp-Session-Id") or headers.get("Mcp-Session-ID")
        expect(session_a and result["serverInfo"]["name"] == "voice-flow",
               "MCP initialize did not issue a session")
        listed, _ = request("tools/list", session=session_a)
        tool_names = [tool["name"] for tool in listed["tools"]]
        expect(len(tool_names) == 15 and len(set(tool_names)) == 15,
               f"MCP tool catalog changed: {tool_names}")

        def call(name: str, arguments: dict[str, Any] | None = None,
                 session: str | None = session_a,
                 should_error: bool = False) -> str:
            result_value, _ = request("tools/call", {
                "name": name, "arguments": arguments or {},
            }, session=session)
            expect(result_value.get("isError") is should_error,
                   f"MCP {name} error contract changed: {result_value}")
            content = result_value.get("content", [])
            expect(len(content) == 1 and content[0].get("type") == "text",
                   f"MCP {name} returned an invalid content envelope")
            return content[0].get("text", "")

        call("set_session_name", {"name": "MCP contract A"})
        sessions = self.state()["mcp"]["sessions"]
        expect(len(sessions) == 1 and sessions[0]["name"] == "MCP contract A"
               and sessions[0]["engaged"] is False,
               "silent MCP naming engaged or misnamed the session")

        expect("qa capture event" in call("get_latest_capture"),
               "MCP latest capture omitted the finalized capture")
        expect("captures" in call("list_captures", {"limit": 2}),
               "MCP capture listing returned no structured list")
        screenshot_text = call("take_screenshot")
        expect("\"path\"" in screenshot_text and "\"cursor\"" in screenshot_text,
               "MCP screenshot omitted bounded path or cursor geometry")
        expect("phone nonce updated" in call("get_recent_dictations", {"limit": 2}),
               "MCP recent dictations omitted synchronized history")
        expect(self.state()["mcp"]["sessions"][0]["engaged"] is False,
               "read-only MCP tools unexpectedly engaged the session")

        self.qa("POST", "/__qa/inbox/add", {"text": "queued MCP check"},
                expect_status=202)
        expect("queued MCP check" in call("check_messages"),
               "MCP check_messages did not drain a queued message")
        self.qa("POST", "/__qa/inbox/add", {"text": "queued MCP wait"},
                expect_status=202)
        expect("queued MCP wait" in call("wait_for_message", {"timeout_seconds": 5}),
               "MCP wait_for_message did not receive a queued message")

        tts_before = self.state()["tts"]
        call("report_to_user", {
            "summary": "MCP contract report", "details": "isolated signed-app evidence",
        })
        full_state = self.state()
        first_state = full_state["mcp"]
        first_row = next(item for item in first_state["sessions"] if item["id"] == session_a)
        expect(first_row["engaged"] is True and first_row["push_count"] == 1,
               "MCP report did not engage and persist one push")
        expect(first_state["target_session_id"] == session_a,
               "first engaged MCP session did not claim the empty voice target")
        expect(full_state["tts"] == tts_before,
               "agent message arrival auto-started or mutated speech")
        expect(full_state["pill"]["mode"] == "flash"
               and full_state["pill"]["unread_visible"] is True,
               "message arrival did not render a receipt plus unread ring")
        pill_snapshot("flash")
        self.qa("POST", "/__qa/mcp/select", {"session_id": session_a})
        grown = self.state()["pill"]
        expect(grown["mode"] == "grown" and grown["current_push_session_id"] == session_a,
               "session selection did not grow its exact push stack")
        viewed_push = next(item for item in grown["pushes"]
                           if item["session_id"] == session_a)
        expect(viewed_push["unread"] == 0,
               "viewed session left its own push stack unread")
        slot_a = next(item for item in grown["slots"] if item["id"] == session_a)
        expect(slot_a["label"] == "MCP contract A" and slot_a["number"] >= 1,
               f"first MCP session did not get a numbered slot: {grown['slots']}")
        pill_snapshot("grown")

        self.qa("POST", "/__qa/pill/action", {
            "action": "user_select", "session_id": session_a,
        }, expect_status=202)
        wait_for("double-select read aloud", lambda: (lambda value:
            value if value["phase"] in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=12)
        self.qa("POST", "/__qa/pill/action", {"action": "barge_in"},
                expect_status=202)
        wait_for("double-select speech stop", lambda: (lambda value:
            value if value["phase"] not in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=8)
        # Barge-in may collapse the grown surface as part of recording focus.
        # Re-open the same session before testing its explicit speaker button.
        if self.state()["pill"]["mode"] != "grown":
            self.qa("POST", "/__qa/mcp/select", {"session_id": session_a})
            wait_for("regrown MCP push stack", lambda: (lambda value:
                value if value["mode"] == "grown" else None
            )(self.state()["pill"]), timeout=5)
        # The grown preview has an intentional timeout. It can collapse in
        # the narrow gap between the state poll above and this click on a
        # busy CI machine, so bind the precondition to the action and retry
        # once instead of misclassifying a correct 400 as a product failure.
        speaker_tapped = False
        for _ in range(2):
            if self.state()["pill"]["mode"] != "grown":
                self.qa("POST", "/__qa/mcp/select", {"session_id": session_a})
                wait_for("regrown MCP speaker target", lambda: (lambda value:
                    value if value["mode"] == "grown" else None
                )(self.state()["pill"]), timeout=5)
            try:
                self.qa("POST", "/__qa/pill/action", {"action": "speaker"},
                        expect_status=202)
                speaker_tapped = True
                break
            except GateFailure:
                continue
        expect(speaker_tapped, "grown speaker target collapsed twice before click")
        wait_for("grown speaker read aloud", lambda: (lambda value:
            value if value["phase"] in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=12)
        self.qa("POST", "/__qa/pill/action", {"action": "barge_in"},
                expect_status=202)
        wait_for("grown speaker stop", lambda: (lambda value:
            value if value["phase"] not in ("generating", "playing") else None
        )(self.state()["tts"]), timeout=8)
        # The two read-aloud checks may legitimately consume the first push.
        # Add one fresh message so the following close/keep assertion proves
        # an active stack survives close instead of only inspecting history.
        active_before_close_push = next(
            item for item in self.state()["pill"]["pushes"]
            if item["session_id"] == session_a
        )["active"]
        call("report_to_user", {
            "summary": "MCP close-keep report", "details": "must remain active after close",
        })
        active_after_fresh_push = wait_for(
            "fresh close-keep push", lambda: (lambda value: (lambda active:
                active if active > active_before_close_push else None
            )(next(item for item in value["pushes"]
                   if item["session_id"] == session_a)["active"])
            )(self.state()["pill"]))

        overlay_dir = self.root / "overlays"
        direct_a = overlay_dir / "direct-a.json"
        direct_b = overlay_dir / "direct-b.json"
        direct_a.write_text(json.dumps({
            "type": "panel", "session": session_a, "title": "Direct A",
            "blocks": [{"kind": "text", "text": "first version"}],
        }))
        wait_for("direct overlay poll", lambda:
                 "direct-a" in self.state()["overlays"]["rendered_ids"])
        before_overlay_edit = self.state()["overlays"]["signature"]
        direct_a.write_text(json.dumps({
            "type": "panel", "session": session_a, "title": "Direct A updated",
            "blocks": [{"kind": "text", "text": "second longer version"}],
        }))
        wait_for("direct overlay edit poll", lambda: (lambda overlay:
                 overlay if overlay["signature"] != before_overlay_edit
                 and "direct-a" in overlay["rendered_ids"] else None
        )(self.state()["overlays"]))
        direct_b.write_text(json.dumps({
            "type": "panel", "session": "background-placeholder",
            "title": "Direct B", "blocks": [{"kind": "text", "text": "B"}],
        }))
        time.sleep(0.7)
        expect("direct-b" not in self.state()["overlays"]["rendered_ids"],
               "background-owned direct overlay rendered over active session")
        self.qa("POST", "/__qa/pill/action", {"action": "close"},
                expect_status=202)
        closed = self.state()["pill"]
        push_a = next(item for item in closed["pushes"] if item["session_id"] == session_a)
        expect(closed["mode"] in ("pill", "flash")
               and push_a["active"] == active_after_fresh_push,
               "close did not collapse while keeping the push stack: "
               f"mode={closed['mode']} active={push_a['active']} "
               f"expected_active={active_after_fresh_push}")
        self.qa("POST", "/__qa/pill/action", {"action": "picker"},
                expect_status=202)
        expect(self.state()["pill"]["mode"] == "picker",
               "session picker mode did not render")
        pill_snapshot("picker")

        call("show_guide", {
            "id": "mcp-guide", "title": "Guide",
            "steps": [{"text": "one"}, {"text": "two"}],
        })
        call("update_guide", {"id": "mcp-guide", "active_step": 2})
        call("show_panel", {
            "id": "mcp-panel", "title": "Panel",
            "blocks": [{"kind": "text", "text": "panel body"}],
        })
        call("annotate_screen", {
            "id": "mcp-marks", "clear_first": True,
            "actions": [
                {"type": "circle", "center": [40, 50], "radius": 12},
                {"type": "label", "position": [60, 70], "text": "nonce"},
            ],
        })
        call("show_guide", {"title": "bad", "steps": []}, should_error=True)
        overlays = call("list_overlays")
        expect(all(name in overlays for name in ["mcp-guide", "mcp-panel", "mcp-marks"]),
               "MCP overlay listing omitted live documents")
        call("clear_annotations")
        expect("mcp-marks" not in call("list_overlays"),
               "MCP clear_annotations did not remove annotation files")
        call("remove_overlay", {"id": "mcp-guide"})
        call("remove_overlay", {"id": "mcp-panel"})
        direct_a.unlink()
        direct_b.unlink()
        wait_for("direct overlay delete poll", lambda:
                 all(item not in self.state()["overlays"]["file_ids"]
                     for item in ["direct-a", "direct-b"]))
        expect("No overlays" in call("list_overlays"),
               "MCP overlay removal did not reach an empty state")

        _, headers_b = request("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "voice-flow-qa-b", "version": "1"},
            "capabilities": {},
        })
        session_b = headers_b.get("Mcp-Session-Id") or headers_b.get("Mcp-Session-ID")
        expect(session_b and session_b != session_a, "second MCP session was not isolated")
        call("set_session_name", {"name": "MCP contract B"}, session=session_b)
        direct_b.write_text(json.dumps({
            "type": "panel", "session": session_b, "title": "Direct B",
            "blocks": [{"kind": "text", "text": "B"}],
        }))
        call("show_panel", {
            "id": "mcp-background", "blocks": [{"kind": "text", "text": "B"}],
        }, session=session_b)
        second_state = self.state()["mcp"]
        expect(second_state["target_session_id"] == session_a,
               "background MCP engagement stole the active voice target")
        expect(len(second_state["sessions"]) == 2,
               "second MCP session was not retained independently")
        call("remove_overlay", {"id": "mcp-background"}, session=session_b)
        call("report_to_user", {
            "summary": "MCP B report", "details": "trash isolation evidence",
        }, session=session_b)
        slots = self.state()["pill"]["slots"]
        slot_a_after = next(item for item in slots if item["id"] == session_a)
        slot_b = next(item for item in slots if item["id"] == session_b)
        expect(slot_a_after["number"] == slot_a["number"]
               and slot_b["number"] != slot_a["number"],
               f"MCP sessions did not retain distinct sticky slots: {slots}")

        # Threads uses a typed route and recoverable lifecycle over the same
        # canonical push stack. A third session keeps this contract isolated
        # from the pill trash/ghost scenarios below.
        _, headers_c = request("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "voice-flow-qa-c", "version": "1"},
            "capabilities": {},
        })
        session_c = headers_c.get("Mcp-Session-Id") or headers_c.get("Mcp-Session-ID")
        expect(session_c and session_c not in (session_a, session_b),
               "third MCP session was not isolated")
        call("set_session_name", {"name": "Threads lifecycle C"}, session=session_c)
        call("report_to_user", {
            "summary": "Threads lifecycle report",
            "details": "retained content for Complete, Reopen, and Delete",
        }, session=session_c)
        retained_before = next(
            row for row in self.state()["threads"]
            if row["source"] == "mcp" and row["id"] == session_c
        )["retained_messages"]
        expect(retained_before >= 1, "Threads fixture has no retained message")
        target_before_thread_open = self.state()["mcp"]["target_session_id"]
        self.qa("POST", "/__qa/panel", {
            "tab": "agents", "agents_destination": "threads",
            "thread_source": "mcp", "thread_id": session_c,
        })
        opened_thread = wait_for(
            "typed Threads detail", lambda: (lambda value: value
                if value["ui"]["agents_navigation"]["mode"] == "thread"
                and value["ui"]["agents_navigation"]["thread_source"] == "mcp"
                and value["ui"]["agents_navigation"]["thread_id"] == session_c
                and value["ui"]["conversation_focus"] == f"session(\"{session_c}\")"
                else None)(self.state()),
        )
        expect(opened_thread["mcp"]["target_session_id"] == target_before_thread_open,
               "opening historical Threads detail stole the pill voice target")
        thread_snapshot = self.qa("POST", "/__qa/ui/snapshot", {})
        thread_source = Path(thread_snapshot["path"])
        thread_image = self.artifacts / "threads-external-detail.png"
        shutil.copyfile(thread_source, thread_image)
        expect(thread_snapshot["width"] >= 390
               and thread_image.stat().st_size > 10_000
               and png_channel_range(thread_image) >= 24,
               "Threads detail snapshot was blank or malformed")

        self.qa("POST", "/__qa/thread/action", {
            "source": "mcp", "id": session_c, "action": "complete",
        }, expect_status=202)
        completed_c = wait_for(
            "retained completed Thread", lambda: (lambda rows: next((row for row in rows
                if row["source"] == "mcp" and row["id"] == session_c
                and row["archived"] is True
                and row["retained_messages"] == retained_before), None)
            )(self.state()["threads"]),
        )
        expect(completed_c["group"] == "done",
               f"Complete did not move retained Thread to Done: {completed_c}")
        completed_state = self.state()
        expect(all(item["id"] != session_c for item in completed_state["mcp"]["sessions"])
               and completed_state["ui"]["conversation_focus"] == "none",
               "Complete left the external session live or capture-focused")

        self.qa("POST", "/__qa/thread/action", {
            "source": "mcp", "id": session_c, "action": "reopen",
        }, expect_status=202)
        reopened_c = wait_for(
            "reopened Thread", lambda: next((row for row in self.state()["threads"]
                if row["source"] == "mcp" and row["id"] == session_c
                and row["archived"] is False), None),
        )
        expect(reopened_c["group"] == "recent"
               and reopened_c["retained_messages"] == retained_before,
               f"Reopen lost content or fabricated liveness: {reopened_c}")

        self.qa("POST", "/__qa/thread/action", {
            "source": "mcp", "id": session_c, "action": "delete",
        }, expect_status=202)
        deleted_c = self.state()
        expect(all(not (row["source"] == "mcp" and row["id"] == session_c)
                   for row in deleted_c["threads"])
               and all(item["session_id"] != session_c
                       for item in deleted_c["pill"]["pushes"]),
               "Delete retained the exact external Thread or its stack")
        expect(any(row["id"] == session_a for row in deleted_c["threads"])
               and any(row["id"] == session_b for row in deleted_c["threads"]),
               "exact Thread delete damaged another session")

        self.qa("POST", "/__qa/mcp/select", {"session_id": session_b})
        wait_for("session overlay swap", lambda: (lambda ids:
            ids if "direct-b" in ids and "direct-a" not in ids else None
        )(self.state()["overlays"]["rendered_ids"]))
        self.qa("POST", "/__qa/overlay/user_close", {"id": "direct-b"},
                expect_status=202)
        wait_for("overlay user close", lambda:
                 not direct_b.exists()
                 and "direct-b" not in self.state()["overlays"]["file_ids"])
        self.qa("POST", "/__qa/pill/action", {"action": "trash"},
                expect_status=202)
        trashed = self.state()
        expect(all(item["id"] != session_b for item in trashed["mcp"]["sessions"]),
               "trash did not remove its live MCP session")
        push_b = next(item for item in trashed["pill"]["pushes"]
                      if item["session_id"] == session_b)
        expect(push_b["active"] == 0,
               "trash did not retire its push stack into done history")

        # A final unread push must outlive the clean MCP DELETE as a ghost;
        # the earlier viewed push is correctly eligible for retirement.
        unread_before_ghost = next(
            item for item in self.state()["pill"]["pushes"]
            if item["session_id"] == session_a
        )["unread"]
        call("report_to_user", {
            "summary": "MCP A unread ghost", "details": "persist this unread stack",
        }, session=session_a)
        pending_a = next(item for item in self.state()["pill"]["pushes"]
                         if item["session_id"] == session_a)
        expect(pending_a["unread"] == unread_before_ghost + 1,
               "final MCP A push was not retained unread before disconnect")

        for session in [session_c, session_b, session_a]:
            status, _, _ = mcp_json(self.base, None, session, method="DELETE")
            expect(status == 200, f"MCP session DELETE failed for {session}")
        wait_for("MCP sessions to close", lambda: self.state()["mcp"]["sessions"] == [])
        ghost = self.state()["pill"]
        expect(any(item["id"] == session_a for item in ghost["slots"]),
               "unread/readable push stack did not survive as a ghost after session death")
        self.expected_ghost_session = session_a
        self.record("signed_public_mcp_all_tools_engagement_isolation")

    def verify_concurrency(self) -> None:
        conversation = self.state()["assistant"]["conversation_id"]
        same_jobs = [self.create_job(
            f"DELAY_MS_700 PLAIN_TEXT_TURN SAME_{index}",
            conversation_id=conversation,
        ) for index in range(3)]
        self.reset_metrics()
        after = max((event["sequence"] for event in self.events()), default=0)
        for job_id in same_jobs:
            self.run_job(job_id)
        for job_id in same_jobs:
            self.wait_job_event(job_id, "completed", after, timeout=30)
        expect(self.metrics()["max_active"] == 1,
               "same-conversation jobs overlapped at the provider")

        distinct: list[tuple[str, str, str]] = []
        for index in range(3):
            conversation_id = self.qa(
                "POST", "/__qa/conversation/create", {"force": True}
            )["conversation_id"]
            marker = f"DISTINCT_{index}"
            job_id = self.create_job(
                f"DELAY_MS_1200 PLAIN_TEXT_TURN {marker}",
                conversation_id=conversation_id,
            )
            distinct.append((conversation_id, job_id, marker))
        self.reset_metrics()
        after = max((event["sequence"] for event in self.events()), default=0)
        for _, job_id, _ in distinct:
            self.run_job(job_id)
        for _, job_id, _ in distinct:
            self.wait_job_event(job_id, "completed", after, timeout=30)
        expect(self.metrics()["max_active"] == 3,
               f"three independent agents did not overlap: {self.metrics()}")
        for conversation_id, _, marker in distinct:
            self.qa("POST", "/__qa/conversation/select", {
                "conversation_id": conversation_id,
            })
            texts = [message["text"] for message in self.state()["assistant"]["messages"]]
            expect(any(marker in text for text in texts), f"{marker} missing from its conversation")
            for _, _, other in distinct:
                if other != marker:
                    expect(not any(other in text for text in texts),
                           f"{other} leaked into {marker}'s conversation")
        self.record("signed_three_agent_concurrency_and_isolation")

    def verify_job_model_pinning(self) -> None:
        original = self.state()["assistant"]["conversation_id"]
        conversations = [
            self.qa("POST", "/__qa/conversation/create", {"force": True})["conversation_id"]
            for _ in range(2)
        ]
        models = ["test/model", "test/model-fast"]
        jobs = [
            self.create_job(
                f"DELAY_MS_500 PLAIN_TEXT_TURN PINNED_MODEL_{index}",
                conversation_id=conversation_id, model_id=model,
            )
            for index, (conversation_id, model) in enumerate(zip(conversations, models))
        ]
        self.pinned_job_models = dict(zip(jobs, models))
        expect([self.job(job_id).get("model_id") for job_id in jobs] == models,
               "per-job model IDs did not persist through the QA API")

        # Changing the global default must not mutate durable automation pins.
        self.qa("POST", "/__qa/provider", {
            "base_url": f"http://127.0.0.1:{self.provider_port}/v1",
            "model": "test/model-fast", "daily_budget_usd": 500,
        })
        expect([self.job(job_id).get("model_id") for job_id in jobs] == models,
               "global model change rewrote an existing automation")
        self.qa("POST", "/__qa/provider", {
            "base_url": f"http://127.0.0.1:{self.provider_port}/v1",
            "model": "test/model", "daily_budget_usd": 500,
        })

        # Restart the shared worker so its private provider catalog is built
        # from both persisted jobs, then prove their outbound request IDs.
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/opencode/stop", {"trust_profile": "workspace"},
                expect_status=202)
        self.wait_event("opencode_stopped", after=after, timeout=15)
        request_log = self.artifacts / "provider-requests.jsonl"
        before_lines = len(request_log.read_text().splitlines()) if request_log.exists() else 0
        self.reset_metrics()
        after = max((event["sequence"] for event in self.events()), default=0)
        for job_id in jobs:
            self.run_job(job_id)
        for job_id in jobs:
            self.wait_job_event(job_id, "completed", after, timeout=30)
        records = [json.loads(line) for line in request_log.read_text().splitlines()[before_lines:]]
        sent_models = {record.get("model") for record in records}
        expect(set(models).issubset(sent_models),
               f"pinned models did not reach the provider independently: {sent_models}")
        expect(self.metrics()["max_active"] == 2,
               "two differently pinned agents did not run concurrently")
        self.qa("POST", "/__qa/conversation/select", {"conversation_id": original})
        self.record("signed_per_job_model_persistence_and_routing")

    def verify_job_limits(self) -> None:
        conversation = self.state()["assistant"]["conversation_id"]
        blocked = self.create_job(
            "PLAIN_TEXT_TURN BLOCKED", conversation_id=conversation,
            daily_budget_usd=0,
        )
        after = max((event["sequence"] for event in self.events()), default=0)
        self.run_job(blocked)
        self.wait_job_event(blocked, "blocked", after, timeout=10)
        expect(self.job(blocked)["state"] == "blocked", "zero-budget job was not blocked")

        cancellable = self.create_job(
            "DELAY_MS_5000 PLAIN_TEXT_TURN CANCEL_JOB",
            conversation_id=conversation,
        )
        after = max((event["sequence"] for event in self.events()), default=0)
        self.run_job(cancellable)
        self.wait_job_event(cancellable, "running", after, timeout=10)
        cancel_after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/jobs/cancel", {"job_id": cancellable}, expect_status=202)
        self.wait_job_event(cancellable, "cancelled", cancel_after, timeout=15)
        wait_for("cancelled durable job", lambda: self.job(cancellable)["state"] == "cancelled")
        self.record("signed_job_budget_and_cancel")

    def verify_stale_session_reseed(self) -> None:
        # Force-created conversations intentionally inherit the product
        # default (Codex). Select OpenCode explicitly before testing its stale
        # external-session recovery on the currently active conversation.
        self.qa("POST", "/__qa/runtime", {
            "runtime": "opencode", "trust_profile": "workspace",
        })
        before_messages = list(self.state()["assistant"]["messages"])
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/opencode/stop", {}, expect_status=202)
        self.wait_event("opencode_stopped", after=after, timeout=15)
        data_root = self.root / "runtime" / "opencode" / "workspace" / "data"
        if data_root.exists():
            shutil.rmtree(data_root)
        state = self.submit("PLAIN_TEXT_TURN RESEED", expected="gateway ok", timeout=45)
        expect(len(state["assistant"]["messages"]) == len(before_messages) + 2,
               "stale-session reseed duplicated or dropped canonical messages")
        self.record("signed_stale_session_canonical_reseed")

    def verify_ui(self) -> None:
        current_conversation = self.state()["assistant"]["conversation_id"]
        before = len(self.state()["assistant"]["messages"])
        self.qa("POST", "/__qa/submit", {
            "text": "DELAY_MS_1200 PLAIN_TEXT_TURN UI_RUNNING",
        }, expect_status=202)
        wait_for("runtime selector disabled", lambda: (lambda value:
            value if value["assistant"]["running"]
            and value["ui"]["controls"]["runtime_enabled"] is False else None
        )(self.state()), timeout=10)
        self.qa("POST", "/__qa/runtime", {
            "runtime": "codex", "trust_profile": "workspace",
        }, expect_status=409)
        self.wait_idle(before + 2, timeout=15)
        expect(self.state()["ui"]["controls"]["runtime_enabled"] is True,
               "runtime selector stayed disabled after the turn")

        self.qa("POST", "/__qa/runtime/default", {"runtime": "codex"})
        codex_conversation = self.qa(
            "POST", "/__qa/conversation/create", {"force": True}
        )["conversation_id"]
        expect(self.state()["assistant"]["runtime"] == "codex",
               "new conversation ignored the Codex default")
        self.qa("POST", "/__qa/runtime/default", {"runtime": "opencode"})
        opencode_conversation = self.qa(
            "POST", "/__qa/conversation/create", {"force": True}
        )["conversation_id"]
        expect(self.state()["assistant"]["runtime"] == "opencode"
               and self.state()["default_runtime"] == "opencode",
               "new conversation ignored the OpenCode default")
        self.qa("POST", "/__qa/conversation/select", {
            "conversation_id": current_conversation,
        })

        runtime_result = self.qa("POST", "/__qa/ui/snapshot", {})
        runtime_source = Path(runtime_result["path"])
        runtime_screenshot = self.artifacts / "assistant-runtime-selector.png"
        shutil.copyfile(runtime_source, runtime_screenshot)
        expect(runtime_screenshot.stat().st_size > 10_000
               and png_channel_range(runtime_screenshot) >= 32,
               "Assistant runtime-selector snapshot was blank or degenerate")

        self.qa("POST", "/__qa/panel", {"tab": "agents"})
        state = wait_for(
            "Agents panel",
            lambda: (lambda value: value if value["ui"]["panel_visible"]
                    and value["ui"]["job_rows"] >= 1 else None)(self.state()),
        )
        expect(state["ui"]["agent_session_rows"] >= 1, "Agents panel has no session rows")
        labels = set(state["ui"]["controls"]["accessibility_labels"])
        expect("Assistant runtime" in labels,
               f"runtime selector lacks an accessibility label: {sorted(labels)}")
        expect(codex_conversation != opencode_conversation,
               "runtime-default fixture reused one conversation")
        result = self.qa("POST", "/__qa/ui/snapshot", {})
        source = Path(result["path"])
        expect(source.resolve().is_relative_to(self.root.resolve()),
               "UI snapshot escaped the isolated QA root")
        screenshot = self.artifacts / "agents-panel.png"
        shutil.copyfile(source, screenshot)
        expect(result["width"] >= 390 and result["height"] >= 500,
               f"Agents panel rendered at unexpected size {result}")
        expect(screenshot.exists() and screenshot.stat().st_size > 10_000,
               "Agents panel screenshot was not captured")
        expect(png_channel_range(screenshot) >= 32,
               "Agents panel snapshot is blank or visually degenerate")

        self.record("signed_agents_panel_visual")
        self.verify_settings_model_picker()
        self.verify_automation_model_picker()

    def verify_settings_model_picker(self) -> None:
        self.qa("POST", "/__qa/settings/assistant", {"action": "open"}, expect_status=202)

        def loaded_settings() -> dict[str, Any] | None:
            value = self.state()
            editor = value.get("settings_assistant", {})
            return value if (value.get("settings_assistant_visible")
                             and editor.get("model_count", 0) >= 2
                             and editor.get("model_width", 0) >= 350) else None

        state = wait_for("Assistant Settings model picker", loaded_settings, timeout=15)
        editor = state["settings_assistant"]
        expect(editor["model_accessibility_label"] == "Default OpenCode model",
               f"Settings model picker lacks its accessibility label: {editor}")
        self.qa("POST", "/__qa/settings/assistant", {
            "action": "select_model", "model_id": "test/model-fast",
        })
        wait_for(
            "Settings model selection",
            lambda: (lambda value: value if value.get("settings_assistant", {}).get(
                "default_model") == "test/model-fast" else None)(self.state()),
        )
        result = self.qa("POST", "/__qa/settings/snapshot", {})
        source = Path(result["path"])
        screenshot = self.artifacts / "settings-opencode-model-picker.png"
        shutil.copyfile(source, screenshot)
        expect(result["width"] >= 650 and result["height"] >= 450,
               f"Assistant Settings rendered at unexpected size {result}")
        expect(screenshot.stat().st_size > 10_000
               and png_channel_range(screenshot) >= 32,
               "Assistant Settings model-picker snapshot was blank or degenerate")
        self.qa("POST", "/__qa/settings/assistant", {
            "action": "select_model", "model_id": "test/model",
        })
        self.qa("POST", "/__qa/settings/assistant", {"action": "close"}, expect_status=202)
        self.record("signed_settings_model_picker_visual")

    def verify_automation_model_picker(self) -> None:
        self.qa("POST", "/__qa/automation/editor", {"action": "open"}, expect_status=202)
        def visible_model_editor() -> dict[str, Any] | None:
            value = self.state()
            return value if value.get("automation_editor_visible") else None
        wait_for("automation model editor", visible_model_editor, timeout=15)
        editor_state = self.state()["automation_editor"]
        expect(editor_state["model_accessibility_label"] == "OpenCode model",
               f"automation model picker lacks its accessibility label: {editor_state}")
        expect(editor_state["runtime_title"] == "OpenCode"
               and editor_state["trigger_title"] == "Manual",
               f"automation popup selections are not visible: {editor_state}")
        self.qa("POST", "/__qa/automation/editor", {
            "action": "select_runtime", "runtime": "codex",
        })
        codex_state = self.state()["automation_editor"]
        expect(codex_state["selected_runtime"] == "codex"
               and not codex_state["model_enabled"],
               f"Codex automation selection did not disable its model picker: {codex_state}")
        self.qa("POST", "/__qa/automation/editor", {
            "action": "select_runtime", "runtime": "opencode",
        })
        opencode_state = self.state()["automation_editor"]
        expect(opencode_state["selected_runtime"] == "opencode"
               and opencode_state["model_enabled"]
               and "Codex chooses" not in opencode_state["model_status"],
               f"visible OpenCode selection did not enable its model picker: {opencode_state}")
        self.qa("POST", "/__qa/automation/editor", {
            "action": "select_trigger", "trigger": "capture",
        })
        trigger_state = self.state()["automation_editor"]
        expect(trigger_state["selected_trigger"] == "capture",
               f"visible automation trigger did not resolve by stable value: {trigger_state}")
        self.qa("POST", "/__qa/automation/editor", {
            "action": "search", "query": "fast",
        })
        filtered = self.state()["automation_editor"]["matching_model_ids"]
        expect(filtered == ["test/model-fast"],
               f"automation model search did not filter the live catalog: {filtered}")
        self.qa("POST", "/__qa/automation/editor", {
            "action": "select_model", "model_id": "test/model-fast",
        })
        expect(self.state()["automation_editor"]["model_text"].endswith("test/model-fast"),
               "automation picker did not resolve the filtered model row")
        editor_result = self.qa("POST", "/__qa/automation/editor_snapshot", {})
        editor_source = Path(editor_result["path"])
        editor_screenshot = self.artifacts / "automation-model-picker.png"
        shutil.copyfile(editor_source, editor_screenshot)
        expect(editor_result["width"] >= 450 and editor_result["height"] >= 200,
               f"automation model picker rendered at unexpected size {editor_result}")
        expect(editor_screenshot.stat().st_size > 10_000
               and png_channel_range(editor_screenshot) >= 32,
               "automation model picker snapshot was blank or degenerate")
        self.qa("POST", "/__qa/automation/editor", {"action": "close"}, expect_status=202)
        wait_for("closed automation model editor", lambda: (
            True if not self.state().get("automation_editor_visible") else None
        ), timeout=10)
        self.record("signed_automation_model_picker_visual")

    def verify_codex_rollback(self) -> None:
        state = self.state()
        conversation_id = state["assistant"]["conversation_id"]
        canonical_before = list(state["assistant"]["messages"])
        after = max((event["sequence"] for event in self.events()), default=0)
        self.qa("POST", "/__qa/opencode/stop", {}, expect_status=202)
        self.wait_event("opencode_stopped", after=after, timeout=15)
        switched = self.qa("POST", "/__qa/runtime", {
            "runtime": "codex", "trust_profile": "workspace",
        })
        expect(switched["runtime"] == "codex", "one-click rollback did not select Codex")
        state = self.submit(
            "Reply with exactly CODEX_ROLLBACK_NONCE_4621 and no punctuation or explanation.",
            expected="CODEX_ROLLBACK_NONCE_4621", timeout=150)
        expect(state["assistant"]["conversation_id"] == conversation_id
               and state["assistant"]["messages"][:len(canonical_before)] == canonical_before,
               "Codex rollback changed the conversation or lost canonical history")
        stored = json.loads((self.root / "assistant-sessions.json").read_text())
        row = next(item for item in stored["sessions"] if item["id"] == conversation_id)
        binding = row["runtimeBindings"].get("codex")
        expect(binding and binding["state"] == "clean" and binding.get("externalSessionID"),
               f"Codex rollback did not establish a clean binding: {binding}")
        self.qa("POST", "/__qa/runtime", {
            "runtime": "opencode", "trust_profile": "workspace",
        })
        self.record("signed_codex_rollback_canonical_reseed")

    def process_rss_kib(self) -> int:
        expect(self.app_process is not None, "app process is unavailable")
        raw = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(self.app_process.pid)], text=True,
        ).strip()
        return int(raw or "0")

    def process_fd_count(self) -> int:
        expect(self.app_process is not None, "app process is unavailable")
        result = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", str(self.app_process.pid), "-Fn"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        return sum(line.startswith("f") for line in result.stdout.splitlines())

    def stored_conversation_tail(self, conversation_id: str) -> list[str]:
        """Read one canonical lane without rebuilding the visible AppKit thread.

        The soak still selects every lane once per minute to exercise the real
        UI path. Reading the atomic history file between those checkpoints keeps
        the workload representative instead of forcing an increasingly large
        O(n) view rebuild every ten seconds merely to assert isolation.
        """
        path = self.root / "assistant-sessions.json"
        for attempt in range(5):
            try:
                stored = json.loads(path.read_text())
                row = next(item for item in stored["sessions"]
                           if item["id"] == conversation_id)
                return [message["text"] for message in row["messages"][-8:]]
            except (FileNotFoundError, json.JSONDecodeError, StopIteration, KeyError):
                if attempt == 4:
                    raise
                time.sleep(0.05)
        raise GateFailure(f"conversation {conversation_id} is unavailable")

    def wait_soak_job(self, job_id: str, iteration: int,
                      timeout: float = 75) -> dict[str, Any]:
        """Wait on durable state, allowing the configured retry window.

        Job-status events are asserted by the focused scheduler gates. The soak
        uses SQLite state as its source of truth so a transient first-attempt
        timeout gets the product's normal retry/backoff opportunity instead of
        being mistaken for failure after only one 30-second attempt.
        """
        def settled() -> dict[str, Any] | None:
            row = self.job(job_id)
            if row["state"] == "completed":
                return row
            if row["state"] in {"failed", "blocked", "cancelled"}:
                raise GateFailure(
                    f"soak iteration {iteration} job {job_id} reached "
                    f"{row['state']}: {row}")
            return None
        return wait_for(f"soak job {job_id}", settled, timeout)

    def write_soak_failure(self, iteration: int,
                           jobs: list[tuple[int, str, str, str]],
                           error: Exception) -> None:
        snapshot: dict[str, Any] = {
            "iteration": iteration,
            "error": str(error),
            "jobs": [],
            "events": self.events()[-100:],
        }
        for _, _, marker, job_id in jobs:
            try:
                snapshot["jobs"].append({
                    "marker": marker,
                    "job": self.job(job_id),
                })
            except Exception as read_error:
                snapshot["jobs"].append({
                    "marker": marker, "job_id": job_id,
                    "read_error": str(read_error),
                })
        for key, reader in {
            "provider_metrics": self.metrics,
            "rss_kib": self.process_rss_kib,
            "fd_count": self.process_fd_count,
            "root_processes": lambda: len(self.root_processes()),
        }.items():
            try:
                snapshot[key] = reader()
            except Exception as read_error:
                snapshot[key] = {"read_error": str(read_error)}
        (self.artifacts / "soak-failure.json").write_text(
            json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
        diagnostic_files = {
            "opencode-supervisor.log": self.root / "runtime" / "opencode"
                / "workspace" / "logs" / "opencode.log",
            "opencode-runtime.log": self.root / "runtime" / "opencode"
                / "workspace" / "data" / "opencode" / "log" / "opencode.log",
            "model-budget.json": self.root / "agent-model-budget.json",
        }
        for destination, source in diagnostic_files.items():
            if source.exists():
                shutil.copyfile(source, self.artifacts / destination)

    def verify_soak(self) -> None:
        if self.soak_seconds <= 0:
            return
        original = self.state()["assistant"]["conversation_id"]
        lanes: list[tuple[str, str]] = []
        for lane in range(3):
            conversation_id = self.qa(
                "POST", "/__qa/conversation/create", {"force": True}
            )["conversation_id"]
            self.qa("POST", "/__qa/runtime", {
                "runtime": "opencode", "trust_profile": "workspace",
            })
            lanes.append((conversation_id, f"SOAK_LANE_{lane}"))

        # Long-running QA shares the user's login session. Its AppKit surface
        # is tested immediately before the soak, then removed so it cannot sit
        # in the user's click path while background agents continue running.
        self.qa("POST", "/__qa/panel", {"tab": "hide"})
        wait_for("hidden QA panel before soak", lambda: (lambda value:
                 True if not value["ui"]["panel_visible"] else None)(self.state()))

        started = time.monotonic()
        deadline = started + self.soak_seconds
        next_heartbeat = started
        iteration = 0
        completed = [0, 0, 0]
        three_way_iterations = 0
        baseline_rss = self.process_rss_kib()
        baseline_fds = self.process_fd_count()
        baseline_processes = len(self.root_processes())
        max_rss = baseline_rss
        max_fds = baseline_fds
        max_processes = baseline_processes
        heartbeat_path = self.artifacts / "soak-report.jsonl"

        while time.monotonic() < deadline:
            cycle_started = time.monotonic()
            self.reset_metrics()
            jobs: list[tuple[int, str, str, str]] = []
            for lane, (conversation_id, lane_marker) in enumerate(lanes):
                marker = f"{lane_marker}_ITER_{iteration}"
                job_id = self.create_job(
                    f"DELAY_MS_250 PLAIN_TEXT_TURN {marker}",
                    conversation_id=conversation_id,
                )
                jobs.append((lane, conversation_id, marker, job_id))
            for _, _, _, job_id in jobs:
                self.run_job(job_id)
            try:
                for lane, _, _, job_id in jobs:
                    self.wait_soak_job(job_id, iteration)
                    completed[lane] += 1
            except Exception as error:
                self.write_soak_failure(iteration, jobs, error)
                raise
            iteration_metrics = self.metrics()
            overlap = iteration_metrics["max_active"]
            expect(overlap >= 2,
                   f"soak iteration {iteration} lost concurrent execution: "
                   f"{iteration_metrics}")
            if overlap >= 3:
                three_way_iterations += 1

            for _, conversation_id, marker, _ in jobs:
                texts = self.stored_conversation_tail(conversation_id)
                expect(any(marker in text for text in texts),
                       f"soak marker {marker} missing from its lane")
                expect(not any(other in text for _, _, other, _ in jobs if other != marker
                               for text in texts),
                       f"soak iteration {iteration} leaked cross-lane text")

            # Exercise the real selector/history-render path on a sustained
            # cadence without turning the soak itself into an O(n^2) allocator
            # benchmark as each conversation grows.
            if iteration % 6 == 0:
                for _, conversation_id, marker, _ in jobs:
                    self.qa("POST", "/__qa/conversation/select", {
                        "conversation_id": conversation_id,
                    })
                    tail = self.qa("GET", "/__qa/assistant/tail")
                    expect(tail["conversation_id"] == conversation_id
                           and any(marker in row["text"] for row in tail["messages"]),
                           f"visible soak selector failed for {conversation_id}")

            rss = self.process_rss_kib()
            fds = self.process_fd_count()
            processes = len(self.root_processes())
            max_rss = max(max_rss, rss)
            max_fds = max(max_fds, fds)
            max_processes = max(max_processes, processes)
            expect(rss <= max(baseline_rss + 350_000, int(baseline_rss * 2.5)),
                   f"Voice Flow RSS grew without bound: baseline={baseline_rss} current={rss}")
            expect(fds <= baseline_fds + 128,
                   f"Voice Flow file descriptors grew without bound: baseline={baseline_fds} current={fds}")
            expect(processes <= baseline_processes + 6,
                   f"supervised process count grew without bound: baseline={baseline_processes} current={processes}")

            now = time.monotonic()
            if now >= next_heartbeat:
                row = {
                    "elapsed_seconds": round(now - started, 2), "iteration": iteration,
                    "completed_by_lane": completed, "rss_kib": rss, "fd_count": fds,
                    "root_processes": processes,
                    "three_way_iterations": three_way_iterations,
                }
                with heartbeat_path.open("a") as handle:
                    handle.write(json.dumps(row, sort_keys=True) + "\n")
                print(f"soak heartbeat: {row}", flush=True)
                next_heartbeat = now + 60
            iteration += 1
            remaining = min(
                self.soak_interval_seconds - (time.monotonic() - cycle_started),
                deadline - time.monotonic())
            if remaining > 0:
                time.sleep(remaining)

        self.qa("POST", "/__qa/conversation/select", {"conversation_id": original})
        expect(completed[0] == completed[1] == completed[2] and completed[0] > 0,
               f"soak admission was unfair: {completed}")
        expect(three_way_iterations >= max(1, int(iteration * 0.95)),
               "three-way provider overlap fell below 95%: "
               f"{three_way_iterations}/{iteration}")
        expect(self.metrics()["active"] == 0, "provider stayed active after soak")
        summary = {
            "duration_seconds": time.monotonic() - started,
            "iterations": iteration, "completed_by_lane": completed,
            "three_way_iterations": three_way_iterations,
            "baseline_rss_kib": baseline_rss, "max_rss_kib": max_rss,
            "baseline_fd_count": baseline_fds, "max_fd_count": max_fds,
            "baseline_processes": baseline_processes, "max_processes": max_processes,
        }
        (self.artifacts / "soak-summary.json").write_text(
            json.dumps(summary, indent=2) + "\n")
        self.record("signed_three_agent_soak")

    def terminate_app(self) -> None:
        if self.app_process is None or self.app_process.poll() is not None:
            return
        self.last_descendant_pids = {
            pid for pid, _, _ in self.app_process_tree(include_app=False)
        }
        try:
            self.qa("POST", "/__qa/app/terminate", {}, expect_status=202)
        except Exception:
            pass
        try:
            self.app_process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(self.app_process.pid, signal.SIGTERM)
            self.app_process.wait(timeout=5)

    def process_table(self) -> list[tuple[int, int, str]]:
        output = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,command="], text=True,
        )
        rows: list[tuple[int, int, str]] = []
        for line in output.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
                rows.append((int(fields[0]), int(fields[1]), fields[2]))
        return rows

    def app_process_tree(self, include_app: bool = True) -> list[tuple[int, int, str]]:
        if self.app_process is None:
            return []
        rows = self.process_table()
        family = {self.app_process.pid}
        changed = True
        while changed:
            changed = False
            for pid, ppid, _ in rows:
                if ppid in family and pid not in family:
                    family.add(pid)
                    changed = True
        if not include_app:
            family.discard(self.app_process.pid)
        return [row for row in rows if row[0] in family]

    def root_processes(self) -> list[str]:
        if self.app_process is not None and self.app_process.poll() is None:
            return [command for _, _, command in self.app_process_tree(include_app=False)]
        return [command for pid, _, command in self.process_table()
                if pid in self.last_descendant_pids]

    def verify_restart_persistence(self) -> None:
        expected_jobs = len(self.state()["jobs"])
        expected_conversation = self.state()["assistant"]["conversation_id"]
        self.terminate_app()
        wait_for("runtime descendants to exit", lambda: not self.root_processes(), timeout=12)
        old_token = self.token
        self.start_app()
        expect(self.token != old_token, "QA authority token did not rotate on relaunch")
        state = self.state()
        expect(len(state["jobs"]) == expected_jobs, "durable jobs changed across relaunch")
        for job_id, model_id in self.pinned_job_models.items():
            row = next(item for item in state["jobs"] if item["id"] == job_id)
            expect(row.get("model_id") == model_id,
                   f"job {job_id} lost its pinned model across relaunch")
        if self.expected_ghost_session:
            expect(any(item["id"] == self.expected_ghost_session
                       for item in state["pill"]["slots"]),
                   "ghost push slot did not persist across relaunch")
        conversations = self.qa("POST", "/__qa/conversation/select", {
            "conversation_id": expected_conversation,
        })
        expect(conversations["conversation_id"] == expected_conversation,
               "active canonical conversation was not restorable")
        self.submit("PLAIN_TEXT_TURN AFTER_RELAUNCH", expected="gateway ok")

        baseline = json.loads((self.root / "assistant-sessions.json").read_text())
        baseline_session_count = len(baseline["sessions"])
        legacy_session = next(row for row in baseline["sessions"]
                              if row["id"] == expected_conversation)
        baseline_messages = list(legacy_session["messages"])
        legacy_session["codexThreadId"] = "legacy-rollback-thread"
        legacy_session.pop("runtimeBindings", None)
        self.terminate_app()
        wait_for("pre-migration descendants to exit",
                 lambda: not self.root_processes(), timeout=12)
        (self.root / "assistant-sessions.json").write_text(
            json.dumps(baseline, separators=(",", ":")))
        old_token = self.token
        self.start_app()
        expect(self.token != old_token, "QA token did not rotate for migration relaunch")
        self.qa("POST", "/__qa/conversation/select", {
            "conversation_id": expected_conversation,
        })
        migrated = json.loads((self.root / "assistant-sessions.json").read_text())
        migrated_session = next(row for row in migrated["sessions"]
                                if row["id"] == expected_conversation)
        expect(len(migrated["sessions"]) == baseline_session_count,
               "legacy expansion created a duplicate scaffold conversation")
        expect(migrated_session["messages"] == baseline_messages,
               "legacy expansion changed the canonical transcript")
        codex_binding = migrated_session["runtimeBindings"]["codex"]
        expect(codex_binding["externalSessionID"] == "legacy-rollback-thread"
               and codex_binding["state"] == "dirty"
               and migrated_session["codexThreadId"] == "legacy-rollback-thread",
               f"legacy Codex binding was not expanded rollback-readably: {codex_binding}")
        self.record("signed_launch_relaunch_persistence_no_orphans")

    def cleanup(self) -> None:
        self.terminate_app()
        if self.provider_process is not None and self.provider_process.poll() is None:
            os.killpg(self.provider_process.pid, signal.SIGTERM)
            try:
                self.provider_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.provider_process.pid, signal.SIGKILL)
                self.provider_process.wait(timeout=2)
        if self.app_log_handle:
            self.app_log_handle.close()
        if self.provider_log_handle:
            self.provider_log_handle.close()

    def run(self) -> None:
        self.verify_bundle()
        self.start_provider()
        self.start_app()
        self.verify_auth_and_isolation()
        self.configure_runtime()
        self.verify_physical_hotkeys()
        self.verify_foreground_runtime()
        self.verify_capture_delivery()
        self.verify_permissions_and_interrupt()
        self.verify_runtime_restart()
        self.verify_runtime_failure_recovery()
        self.verify_trigger_adapters()
        self.verify_sync()
        self.verify_tts()
        self.verify_public_mcp()
        self.verify_job_model_pinning()
        self.verify_concurrency()
        self.verify_job_limits()
        self.verify_stale_session_reseed()
        self.verify_ui()
        self.verify_codex_rollback()
        self.verify_soak()
        self.verify_secret_containment()
        self.verify_restart_persistence()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--soak-seconds", type=int, default=0)
    parser.add_argument("--soak-interval-seconds", type=float, default=10)
    parser.add_argument("--focus", choices=["model-picker"])
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    expect(not any(args.root.iterdir()), "QA root must be fresh and empty")
    scaffold_assistant(args.root)
    gate = SignedAppGate(
        args.app.resolve(), args.root.resolve(), args.repo.resolve(), args.artifacts.resolve(),
        soak_seconds=max(0, args.soak_seconds),
        soak_interval_seconds=max(1, args.soak_interval_seconds))
    def interrupt_for_cleanup(signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt(f"received signal {signum}")

    previous_handlers = {
        signum: signal.signal(signum, interrupt_for_cleanup)
        for signum in (signal.SIGTERM, signal.SIGHUP)
    }
    try:
        if args.focus == "model-picker":
            gate.verify_bundle()
            gate.start_provider()
            gate.start_app()
            gate.verify_auth_and_isolation()
            gate.configure_runtime()
            gate.verify_automation_model_picker()
            gate.verify_secret_containment()
        else:
            gate.run()
        report = {
            "ok": True,
            "checks": gate.checks,
            "app": str(gate.app),
            "root": str(gate.root),
            "artifacts": str(gate.artifacts),
        }
        (args.artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"signed app e2e passed: {len(gate.checks)} high-level gates")
    except Exception as error:
        report = {
            "ok": False, "checks": gate.checks,
            "error": str(error), "artifacts": str(gate.artifacts),
        }
        (args.artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        raise
    finally:
        gate.cleanup()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    main()
