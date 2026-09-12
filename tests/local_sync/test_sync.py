"""Run real Swift sync transport against isolated stores; no user data or keys."""
import concurrent.futures
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="vf-sync-test-") as tmp:
    binary = str(Path(tmp) / "server")
    subprocess.run(["swiftc", "-D", "VOICE_FLOW_QA", str(repo / "swift/SyncIdentity.swift"),
                    str(repo / "swift/Sync.swift"), str(Path(__file__).with_name("main.swift")),
                    "-o", binary], check=True)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    proc = subprocess.Popen([binary], env=dict(os.environ, SYNC_TEST_ROOT=tmp,
                            VOICE_FLOW_QA_SYNC_PORT=str(port)))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def post(path, body, token=None):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers=headers)
        try:
            with opener.open(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)
    try:
        for _ in range(100):
            if (Path(tmp) / "sync-token").exists():
                break
            time.sleep(0.05)
        token = (Path(tmp) / "sync-token").read_text().strip()
        nonce = secrets.token_hex(32)
        status, value = post("/sync-probe", {"nonce": nonce})
        expected = hmac.new(token.encode(), ("voiceflow-sync-probe:" + nonce).encode(), hashlib.sha256).hexdigest()
        assert status == 200 and hmac.compare_digest(value["proof"], expected)
        assert post("/sync-probe", {"nonce": "bad"})[0] == 400
        assert post("/sync", {}, "wrong")[0] == 401
        assert post("/sync", b"invalid", token)[0] == 400
        payload = {"dictations": [{"id": "one", "text": "first", "time": "12:00:00"}], "chat": []}
        status, value = post("/sync", payload, token)
        assert status == 200 and value["dictations"][0]["text"] == "first", "response preceded upsert"
        payload["dictations"][0]["text"] = "continued"
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: post("/sync", payload, token), range(4)))
        assert all(s == 200 and len(v["dictations"]) == 1 and v["dictations"][0]["text"] == "continued" for s,v in results)
        print("PASS: identity challenge, auth rejection, malformed request, synchronous upsert, concurrent retry dedupe")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
