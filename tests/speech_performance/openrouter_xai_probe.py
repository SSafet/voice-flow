"""Real file-STT probe, synthetic audio only; does not test live input streaming.

Run from repo root with python3. Uses the existing Voice Flow OpenRouter Keychain
credential in memory. Existing results are resumed; archive them for a fresh run.
"""
import base64
import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import statistics
import subprocess
import time
import urllib.error
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "design/speech-performance/evidence"
OUTPUT = EVIDENCE / "openrouter-xai-probe.json"
URL = "https://openrouter.ai/api/v1/audio/transcriptions"
MODELS = ["x-ai/grok-stt-1.0", "openai/gpt-4o-mini-transcribe"]


def tokens(text):
    text = re.sub(r"voice\s+flow", "voiceflow", text.lower())
    text = re.sub(r"seven[\s-]+four[\s-]+two[\s-]+nine", "7429", text)
    return re.findall(r"\w+", text)


def wer(reference, text):
    ref, hyp = tokens(reference), tokens(text)
    row = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        nxt = [i]
        for j, other in enumerate(hyp, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (word != other)))
        row = nxt
    return row[-1] / len(ref)


def main():
    credential = subprocess.run(
        ["security", "find-generic-password", "-s", "com.voiceflow.app",
         "-a", "agent_api_key", "-w"], capture_output=True, check=True,
    ).stdout.decode().strip()
    if not credential.startswith("sk-or-"):
        raise RuntimeError("Configured agent credential is not an OpenRouter key")

    previous = json.loads((EVIDENCE / "model-comparison.json").read_text())
    reference = previous["reference"]
    with wave.open(str(EVIDENCE / "model-probe-synthetic.wav"), "rb") as source:
        params = source.getparams()
        pcm = source.readframes(source.getnframes())
    results = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "endpoint": URL,
        "kind": "completed-file STT, not live input streaming",
        "fixture_pcm_sha256": hashlib.sha256(pcm).hexdigest(),
        "reference": reference,
        "scoring": "case/punctuation insensitive, Voice Flow and fixture number normalized",
        "trials": [],
    }
    if OUTPUT.exists():
        results = json.loads(OUTPUT.read_text())

    for repeat in [1, 6]:
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as target:
            target.setparams(params)
            target.writeframes(pcm * repeat)
        encoded = base64.b64encode(buffer.getvalue()).decode()
        duration = len(pcm) * repeat / (params.framerate * params.sampwidth * params.nchannels)
        for trial in range(3):
            for model in (MODELS if trial % 2 == 0 else MODELS[::-1]):
                if any(r["model"] == model and r["trial"] == trial and r["repeat"] == repeat
                       for r in results["trials"]):
                    continue
                row = dict(model=model, trial=trial, repeat=repeat, audio_seconds=duration)
                request = urllib.request.Request(
                    URL,
                    data=json.dumps({"model": model, "input_audio": {
                        "data": encoded, "format": "wav"}}).encode(),
                    headers={"Authorization": "Bearer " + credential,
                             "Content-Type": "application/json"},
                )
                started = time.monotonic()
                try:
                    with urllib.request.urlopen(request, timeout=70) as response:
                        payload = json.load(response)
                        row["generation_id"] = response.headers.get("X-Generation-Id")
                    row["final_ms"] = (time.monotonic() - started) * 1000
                    if not isinstance(payload.get("text"), str):
                        raise RuntimeError("Response missing transcript text")
                    row.update(transcript=payload["text"], usage=payload.get("usage"),
                               normalized_wer=wer(" ".join([reference]*repeat), payload["text"]))
                except urllib.error.HTTPError as exc:
                    row["error"] = f"HTTP {exc.code}"
                except Exception as exc:
                    row["error"] = type(exc).__name__
                row["elapsed_ms"] = (time.monotonic() - started) * 1000
                results["trials"].append(row)
                OUTPUT.write_text(json.dumps(results, indent=2) + "\n")
                print({k: v for k, v in row.items() if k != "transcript"}, flush=True)
                if row.get("error") in ("HTTP 401", "HTTP 402", "HTTP 403"):
                    return  # Do not repeat an account/authentication failure.

    for repeat in [1, 6]:
        for model in MODELS:
            rows = [r for r in results["trials"] if r["model"] == model and r["repeat"] == repeat]
            ok = [r for r in rows if not r.get("error")]
            print(model, repeat, "successes", len(ok), "/", len(rows),
                  "median_ms", statistics.median(r["final_ms"] for r in ok) if ok else None)


if __name__ == "__main__":
    main()
