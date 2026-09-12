"""Real Android scheduling against an isolated Mac-protocol fixture.

Build assembleSyncQa, then pass --serial emulator-N --host 10.0.2.2.
Only the separate com.voiceflow.mobile.syncqa app is installed/cleared. Never
launches MainActivity, calls SyncClient directly, or forces a scheduled job.
"""
import argparse
import hashlib
import hmac
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import secrets
import subprocess
import threading
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("--serial", required=True)
parser.add_argument("--host", default="10.0.2.2")
parser.add_argument("--reverse", action="store_true", help="Reach the isolated fixture over USB on a physical phone")
parser.add_argument("--network-cycle", action="store_true", help="Also exercise Wi-Fi return on a physical phone")
parser.add_argument("--reconnect-only", action="store_true", help="Run only bubble startup and network recovery checks")
parser.add_argument("--adb", default=str(Path.home() / "Library/Android/sdk/platform-tools/adb"))
parser.add_argument("--apk", type=Path, default=Path("android/app/build/outputs/apk/syncQa/app-syncQa.apk"))
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--expect-old-failure", action="store_true")
args = parser.parse_args()
package = "com.voiceflow.mobile.syncqa"
token = secrets.token_hex(24)
state = {"blocked": False, "rejected": 0, "entries": {}, "requests": []}
evidence = {"serial": args.serial, "checks": []}
restore_network = False
network_before = {}
log_start = 0
log_uid = None


def adb(*command, check=True):
    return subprocess.run([args.adb, "-s", args.serial, *command], check=check,
                          text=True, capture_output=True).stdout


def driver(action, **kwargs):
    command = ["shell", "am", "instrument", "-w", "-e", "action", action]
    for key, value in kwargs.items():
        command += ["-e", key, str(value)]
    result = adb(*command, f"{package}/com.voiceflow.mobile.SyncQADriver")
    assert "PASS" in result and "FAIL" not in result, result


def wait_for(predicate, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            print("PASS:", description, flush=True)
            evidence["checks"].append(description)
            return
        time.sleep(0.5)
    raise AssertionError(description)


def phone_entries():
    return json.loads(adb("shell", "run-as", package, "cat", "files/dictations.json"))


def start_bubble():
    result = adb("shell", "am", "start-foreground-service", "-n", f"{package}/com.voiceflow.mobile.BubbleService")
    assert "Error" not in result, result


def preferences():
    return {node.attrib["name"]: node.attrib.get("value", node.text)
            for node in ET.fromstring(adb("shell", "run-as", package, "cat", "shared_prefs/app.xml"))}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        code = 200
        if self.path == "/sync-probe":
            proof = hmac.new(token.encode(), ("voiceflow-sync-probe:" + body["nonce"]).encode(), hashlib.sha256).hexdigest()
            result = {"proof": proof}
        elif self.path == "/sync" and self.headers.get("Authorization") == "Bearer " + token:
            if state["blocked"]:
                state["rejected"] += 1
                code, result = 503, {"error": "temporary connection outage"}
            else:
                for item in body["dictations"]:
                    state["entries"][item["id"]] = item
                state["requests"].append({"time": time.time(), "ids": [item["id"] for item in body["dictations"]]})
                result = {"ok": True, "dictations": list(state["entries"].values())}
        else:
            code, result = 401, {"error": "unauthorized"}
        payload = json.dumps(result).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_port
try:
    log_start = float(adb("shell", "date", "+%s").strip())
    evidence["apk_sha256"] = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    adb("install", "-r", str(args.apk))
    adb("shell", "pm", "clear", package)
    uid_match = re.search(r"uid:(\d+)", adb("shell", "cmd", "package", "list", "packages", "-U", package))
    log_uid = uid_match.group(1) if uid_match else None
    if args.reverse:
        adb("reverse", f"tcp:{port}", f"tcp:{port}")
    driver("configure", token=token, host="127.0.0.1" if args.reverse else args.host, port=port)
    if args.expect_old_failure:
        driver("capture", id="old-auto-capture")
        time.sleep(12)
        assert not state["entries"], "Old build unexpectedly delivered without an Activity"
        assert not phone_entries()[0]["synced"]
        print("REPRODUCED: old build saves capture but schedules no delivery", flush=True)
        evidence["checks"].append("old build: no automatic delivery after 12 seconds; entry remains unsynced")
        start_bubble()
        time.sleep(12)
        assert not state["entries"], "Old bubble unexpectedly recovered a finished transcript"
        print("REPRODUCED: old bubble startup skips pending transcript with empty audio queue", flush=True)
        evidence["checks"].append("old build: bubble startup leaves finished transcript unsynced")
    else:
        if not args.reconnect_only:
            driver("capture", id="auto-capture")
            wait_for(lambda: "auto-capture" in state["entries"], "new capture delivered by Android without opening the app")
            wait_for(lambda: phone_entries()[0]["synced"], "phone acknowledges the delivered capture")
            assert preferences()["sync_last_trigger"] == "delivery-job"
            driver("continue", id="auto-capture")
            wait_for(lambda: state["entries"]["auto-capture"]["text"].endswith("continued"), "continued dictation automatically updates the same entry")
            assert len(state["entries"]) == 1

            state["blocked"] = True
            driver("capture", id="outage-capture")
            wait_for(lambda: state["rejected"] > 0, "automatic upload encounters a temporary connection outage")
            assert not next(e for e in phone_entries() if e["id"] == "outage-capture")["synced"]
            state["blocked"] = False
            wait_for(lambda: "outage-capture" in state["entries"], "Android retry delivers after connection recovery without a manual trigger", timeout=150)
            wait_for(lambda: all(e["synced"] for e in phone_entries()), "recovered uploads are acknowledged without duplicates")

        driver("seed", id="bubble-recovery")
        assert not next(e for e in phone_entries() if e["id"] == "bubble-recovery")["synced"]
        start_bubble()
        wait_for(lambda: "bubble-recovery" in state["entries"], "bubble startup recovers finished transcripts with an empty audio queue")
        wait_for(lambda: all(e["synced"] for e in phone_entries()), "bubble recovery is acknowledged")
        if args.serial.startswith("emulator-") or args.network_cycle:
            # A physical-phone network cycle requires the explicit flag.
            # Restore the original transport settings, including on failure.
            network_before = {name: adb("shell", "settings", "get", "global", setting).strip() == "1"
                              for name, setting in [("wifi", "wifi_on"), ("data", "mobile_data")]}
            restore_network = True
            # The USB route stays available during radio loss; make the
            # fixture unreachable too so only recovery can deliver the seed.
            state["blocked"] = True
            if args.serial.startswith("emulator-"):
                adb("shell", "svc", "data", "disable")
            adb("shell", "svc", "wifi", "disable")
            time.sleep(3)
            result = adb("shell", "am", "broadcast", "-n", f"{package}/com.voiceflow.mobile.SyncQASeedReceiver",
                         "--es", "id", "wifi-recovery")
            assert "result=-1" in result, result
            assert "wifi-recovery" not in state["entries"]
            assert not next(e for e in phone_entries() if e["id"] == "wifi-recovery")["synced"]
            state["blocked"] = False
            adb("shell", "svc", "wifi", "enable")
            wait_for(lambda: "wifi-recovery" in state["entries"], "existing bubble reconnect callback delivers after Wi-Fi returns")
            wait_for(lambda: all(e["synced"] for e in phone_entries()), "Wi-Fi recovery is acknowledged")
        activities = adb("shell", "dumpsys", "activity", "activities")
        assert not any(package in line and "MainActivity" in line for line in activities.splitlines())
    evidence["result"] = "passed"
except Exception as error:
    evidence["result"] = "failed"
    evidence["error"] = str(error)
    raise
finally:
    evidence["requests"] = state["requests"]
    logs = adb("logcat", *([f"--uid={log_uid}"] if log_uid else []),
               "-v", "epoch", "-d", "-s", "VoiceFlowSync:I", "*:S", check=False)
    evidence["logs"] = "\n".join(line for line in logs.splitlines()
                                 if line.split() and line.split()[0].replace(".", "", 1).isdigit()
                                 and float(line.split()[0]) >= log_start)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    server.shutdown()
    adb("shell", "am", "force-stop", package, check=False)
    if args.reverse:
        adb("reverse", "--remove", f"tcp:{port}", check=False)
    if restore_network:
        for name, enabled in network_before.items():
            adb("shell", "svc", name, "enable" if enabled else "disable", check=False)
