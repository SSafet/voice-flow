"""Compare completed-recording STT models via OpenRouter on identical WAV files.

Private audio, transcripts, timings, hashes, and usage stay in --output, which
must be outside the repository. This does not change Voice Flow settings.

Example:
  python3 tests/speech_model_probe.py --output ~/.config/voice-flow/model-probes/run \
    --models meta/muse-voice-transcribe-1.0 openai/gpt-4o-mini-transcribe \
    --audio /path/to/first.wav /path/to/second.wav --trials 2
"""
import argparse
import base64
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import wave

ENDPOINT = "https://openrouter.ai/api/v1/audio/transcriptions"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--models", nargs="+", required=True)
    parser.add_argument("--audio", nargs="+", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=2, choices=range(1, 6))
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    repository = Path(__file__).resolve().parents[1]
    if output == repository or repository in output.parents:
        parser.error("Choose an output directory outside the repository for private recordings")
    output.mkdir(parents=True, exist_ok=False)
    result = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "endpoint": ENDPOINT,
        "protocol": "Completed WAV file, JSON response; no live microphone streaming",
        "options": "Default model options, no vocabulary/language hints; no retries",
        "timing": "HTTP request start through complete JSON response; excludes serialization and paste",
        "clips": [], "trials": [],
    }
    audio_data = []
    for index, source in enumerate(args.audio, 1):
        data = source.read_bytes()
        saved = output / f"clip-{index}.wav"
        saved.write_bytes(data)
        with wave.open(str(saved), "rb") as wav:
            if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() not in (16000, 24000):
                parser.error(f"Unsupported WAV format: {source}")
            duration = wav.getnframes() / wav.getframerate()
            if duration > 600:
                parser.error(f"Recording exceeds the Muse endpoint's 10-minute limit: {source}")
            result["clips"].append({
                "id": index, "source": str(source.resolve()), "copy": str(saved),
                "sha256": hashlib.sha256(data).hexdigest(), "audio_seconds": duration,
                "sample_rate": wav.getframerate(),
            })
        audio_data.append(base64.b64encode(data).decode())

    def save():
        temporary = output / "results.tmp"
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(output / "results.json")

    save()
    try:
        credential = subprocess.run(
            ["security", "find-generic-password", "-s", "com.voiceflow.app",
             "-a", "agent_api_key", "-w"], capture_output=True, check=True, timeout=30,
        ).stdout.decode().strip()
        if not credential.startswith("sk-or-"):
            raise ValueError("Configured agent credential is not an OpenRouter key")
    except (subprocess.SubprocessError, ValueError) as exc:
        result["setup_error"] = type(exc).__name__ + ": OpenRouter Keychain access failed"
        save()
        print(result["setup_error"], flush=True)
        return

    blocked_models = set()
    for clip, encoded in zip(result["clips"], audio_data):
        for trial in range(1, args.trials + 1):
            models = args.models if trial % 2 else args.models[::-1]
            for model in models:
                if model in blocked_models:
                    continue
                body = json.dumps({"model": model, "input_audio": {
                    "data": encoded, "format": "wav"}}).encode()
                request = urllib.request.Request(ENDPOINT, data=body, headers={
                    "Authorization": "Bearer " + credential, "Content-Type": "application/json"})
                row = {"clip_id": clip["id"], "trial": trial, "model": model}
                started = time.monotonic()
                try:
                    with urllib.request.urlopen(request, timeout=90) as response:
                        payload = json.load(response)
                        row["generation_id"] = response.headers.get("X-Generation-Id")
                    row["final_ms"] = (time.monotonic() - started) * 1000
                    response_path = output / f"response-{clip['id']}-{trial}-{model.replace('/', '_')}.json"
                    response_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
                    row["response_file"] = str(response_path)
                    row["usage"] = payload.get("usage")
                    if not isinstance(payload.get("text"), str) or not payload["text"].strip():
                        raise ValueError("Missing or empty transcript")
                    row.update(transcript=payload["text"], usage=payload.get("usage"))
                except urllib.error.HTTPError as exc:
                    row["error"] = f"HTTP {exc.code}"
                    try:
                        message = json.loads(exc.read(4096)).get("error", {}).get("message", "")
                        row["error_message"] = str(message).replace(credential, "[redacted]")[:500]
                        if "guardrail" in str(message).lower():
                            blocked_models.add(model)
                    except (ValueError, OSError, AttributeError):
                        pass
                except Exception as exc:
                    row["error"] = type(exc).__name__
                    row["error_message"] = str(exc).replace(credential, "[redacted]")[:500]
                row["elapsed_ms"] = (time.monotonic() - started) * 1000
                result["trials"].append(row)
                save()
                print({key: value for key, value in row.items() if key != "transcript"}, flush=True)
                if row.get("error") in ("HTTP 401", "HTTP 402", "HTTP 403"):
                    return
    result["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()


if __name__ == "__main__":
    main()
