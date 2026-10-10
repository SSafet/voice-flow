"""Small Laya, Jev, and Clef decision-model experiment; no production app changes."""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from cases import cases, TRIAGE, CONTINUITY, INTENT

REPO = "convaiinnovations/laya"
REVISION = "1c5edc17a7acd8701df6fc341c0d179f1c62c982"
LOCAL = {"laya-en": "", "laya-multi": "multilingual", "laya-typed": "typed-decisions"}
REMOTE = {"jev": "typesafe/jev-1.13", "clef": "cloudflare/clef", "clef-flash": "cloudflare/clef-flash"}
ENDPOINTS = {"openrouter": "https://openrouter.ai/api/alpha/decisions", "typesafe": "https://api.typesafe.ai/v1/systemone"}


def local_path(name, offline=False):
    from huggingface_hub import snapshot_download
    sub = LOCAL[name]
    files = ["model.safetensors", "encoder/config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "rl_agent_config.json"]
    root = snapshot_download(REPO, revision=REVISION, allow_patterns=[f"{sub}/{f}" if sub else f for f in files], local_files_only=offline)
    return Path(root) / sub


def api_key(provider, keychain):
    name = "OPENROUTER_API_KEY" if provider == "openrouter" else "TYPESAFE_API_KEY"
    key = os.getenv(name)
    if not key and provider == "openrouter" and keychain:
        key = subprocess.run(["security", "find-generic-password", "-s", "com.voiceflow.app", "-a", "agent_api_key", "-w"], capture_output=True, text=True).stdout.strip()
    if not key:
        raise RuntimeError(f"Set {name}, or use --voiceflow-keychain for your saved OpenRouter key. Never paste keys into reports.")
    return key


def make_predictor(name, args):
    started = time.perf_counter()
    if name in REMOTE:
        import requests
        key = api_key(args.provider, args.voiceflow_keychain)
        session = requests.Session()
        session.headers.update({"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        if name != "jev" and args.provider != "openrouter":
            raise ValueError("Clef models use --provider openrouter")
        model = (args.jev_model or (REMOTE[name] if args.provider == "openrouter" else "jev-1.13.0")) if name == "jev" else REMOTE[name]

        def predict(state, questions):
            response = session.post(ENDPOINTS[args.provider], json={"model": model, "state": state, "questions": questions}, timeout=45)
            if not response.ok:
                raise RuntimeError(f"{args.provider} HTTP {response.status_code}: " + response.text[:500].replace(key, "[REDACTED]"))
            result = response.json()
            if "answers" not in result:
                raise RuntimeError("Provider returned no answers")
            return result

        return predict, {"provider": args.provider, "requested_model": model, "endpoint": ENDPOINTS[args.provider]}, session.close

    import laya
    import torch
    torch.set_num_threads(args.threads)
    agent = laya.load(str(local_path(name, args.offline)), device=args.device)
    meta = {"repo": REPO, "revision": REVISION, "subfolder": LOCAL[name], "device": str(agent.device),
            "dtype": str(next(agent.model.parameters()).dtype), "parameters": sum(p.numel() for p in agent.model.parameters()),
            "config": agent.cfg, "load_seconds": time.perf_counter() - started}

    def predict(state, questions):
        from laya.common import build_sequence, serialize_state
        truncation = {}
        for qid, question in questions.items():
            internal = agent._to_internal(question)
            empty, _ = build_sequence(agent.tok, "", internal, agent.cfg.get("max_len", 512), agent.cfg.get("head_max_len", 192))
            available = max(0, agent.cfg.get("max_len", 512) - len(empty))
            count = len(agent.tok(serialize_state(state), add_special_tokens=False)["input_ids"])
            truncation[qid] = {"state_tokens": count, "available_state_tokens": available, "truncated": count > available}
        if agent.device.type == "mps":
            torch.mps.synchronize()
        result = agent.predict(state, questions)
        if agent.device.type == "mps":
            torch.mps.synchronize()
        result["input_diagnostics"] = truncation
        result["actual_device"] = str(agent.device)
        return result

    return predict, meta, lambda: None


def evaluate(question, answer, expected):
    kind = question["type"]
    if answer.get("type") != kind:
        raise ValueError("Response type does not match question")
    if kind == "noul":
        p = float(answer["noul"])
        if not math.isfinite(p) or not 0 <= p <= 1:
            raise ValueError("Invalid noul probability")
        predicted = p >= 0.5
        return {"predicted": predicted, "expected": expected, "correct": predicted == expected,
                "top_probability": max(p, 1-p), "brier": (p-float(expected))**2}
    keys = list(question["criteria"]) if kind == "choice" else [str(i) for i in range(len(question["criteria"]))]
    probs = {k: float(v) for k, v in answer["probabilities"].items()}
    if set(probs) != set(keys) or any(not math.isfinite(p) or not 0 <= p <= 1 for p in probs.values()) or abs(sum(probs.values())-1) > .01:
        raise ValueError("Invalid probability distribution")
    top = max(probs, key=probs.get)
    if kind == "choice":
        predicted = answer["choice"]
        if predicted not in keys or probs[predicted] < max(probs.values()) - .001:
            raise ValueError("Choice does not match maximum probability")
        return {"predicted": predicted, "expected": expected, "correct": predicted == expected, "top_probability": probs[predicted]}
    score = float(answer["score"])
    if not math.isfinite(score) or not 0 <= score <= len(keys)-1:
        raise ValueError("Invalid ordinal score")
    return {"predicted": score, "expected": expected, "correct": int(top) == expected,
            "top_probability": probs[top], "absolute_error": abs(score-expected)}


def summary(rows):
    # A latency sample is one successful request, not each individual question.
    decisions = [d for row in rows if row["task"] != "stress" for d in row.get("decisions", {}).values()]
    latency = [r["latency_ms"] for r in rows if "response" in r and r["task"] != "stress"]
    groups = {}
    for row in rows:
        if row["task"] == "stress":
            continue
        for group in (row["language"], row["task"]):
            groups.setdefault(group, []).extend(row.get("decisions", {}).values())
    return {"decisions": len(decisions), "correct": sum(d["correct"] for d in decisions),
            "errors": sum("error" in r for r in rows), "median_request_ms": statistics.median(latency) if latency else None,
            "groups": {k: {"correct": sum(d["correct"] for d in ds), "total": len(ds)} for k, ds in groups.items()},
            "wrong_at_90pct": sum(not d["correct"] and d["top_probability"] >= .9 for d in decisions),
            "score_mae": statistics.mean([d["absolute_error"] for d in decisions if "absolute_error" in d]) if any("absolute_error" in d for d in decisions) else None,
            "noul_brier": statistics.mean([d["brier"] for d in decisions if "brier" in d]) if any("brier" in d for d in decisions) else None,
            "reported_cost_usd": sum(r.get("response", {}).get("usage", {}).get("cost", 0) or 0 for r in rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", nargs="*", default=["laya-multi"], help="laya-multi, laya-en, laya-typed, jev, clef, clef-flash, local, hosted, or all (Laya + Jev)")
    parser.add_argument("--provider", choices=ENDPOINTS, default="openrouter")
    parser.add_argument("--jev-model")
    parser.add_argument("--voiceflow-keychain", action="store_true", help="Read the existing Voice Flow OpenRouter key into memory")
    parser.add_argument("--device", choices=["cpu", "mps", "cuda"], default="mps" if platform.system() == "Darwin" else "cpu")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--offline", action="store_true", help="Use cached local model files")
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--list", action="store_true", help="Print test inputs and expected answers without inference")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--text", help="Try your own text; shown separately without an accuracy label")
    parser.add_argument("--task", choices=["triage", "continuity", "intent"], default="triage")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "results")
    args = parser.parse_args()
    selected = cases()
    if args.list:
        print(json.dumps(selected, indent=2, ensure_ascii=False)); return
    names = []
    for name in args.models:
        names.extend(list(REMOTE) if name == "hosted" else list(LOCAL) + (["jev"] if name == "all" else []) if name in ("local", "all") else [name])
    names = list(dict.fromkeys(names))
    if any(name not in [*LOCAL, *REMOTE] for name in names):
        parser.error("Unknown model. Use laya-en, laya-multi, laya-typed, jev, clef, clef-flash, local, hosted, or all.")
    if args.provider != "openrouter" and any(name in ("clef", "clef-flash") for name in names):
        parser.error("Clef and Clef Flash require --provider openrouter.")
    if args.limit is not None:
        if args.limit < 1: parser.error("--limit must be positive")
        selected = selected[:args.limit]
    if args.text:
        selected = [{"id": "custom", "language": "custom", "task": args.task, "state": args.text,
                     "questions": {"triage": TRIAGE, "continuity": CONTINUITY, "intent": INTENT}[args.task], "expected": {}}]
    if args.download_only:
        for name in names:
            if name in LOCAL: print(name, local_path(name, args.offline))
        return
    args.output.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    pack_hash = hashlib.sha256(json.dumps(selected, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    any_errors = False
    for name in names:
        print(f"\n=== {name} ===", flush=True)
        report = {"model": name, "created_utc": timestamp, "cases_sha256": pack_hash,
                  "platform": platform.platform(), "python": platform.python_version(),
                  "packages": {p: importlib.metadata.version(p) for p in ["laya", "torch", "transformers", "huggingface-hub"]}, "rows": []}
        path = args.output / f"{timestamp}-{name}.json"
        cleanup = lambda: None
        try:
            predict, meta, cleanup = make_predictor(name, args)
            report["runtime"] = meta
            # Warm-up shares the first input; keep its response/cost out of accuracy.
            t0 = time.perf_counter()
            warmup = predict(selected[0]["state"], selected[0]["questions"])
            report["warmup"] = {"latency_ms": (time.perf_counter()-t0)*1000, "response": warmup}
            for case in selected:
                row = dict(case)
                started = time.perf_counter()
                try:
                    response = predict(case["state"], case["questions"])
                    row["latency_ms"] = (time.perf_counter()-started)*1000
                    row["response"] = response
                    row["decisions"] = {qid: evaluate(case["questions"][qid], response["answers"][qid], truth) for qid, truth in case["expected"].items()}
                    hits = sum(d["correct"] for d in row["decisions"].values())
                    print(f"{case['id']:24} {hits}/{len(row['decisions'])} {row['latency_ms']:7.0f} ms", flush=True)
                    if args.text: print(json.dumps(response["answers"], indent=2, ensure_ascii=False))
                except Exception as exc:
                    row["error"] = str(exc); any_errors = True
                    print(f"{case['id']}: ERROR {exc}", flush=True)
                report["rows"].append(row)
                path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            report["summary"] = summary(report["rows"])
            report["summary"]["reported_cost_usd"] += warmup.get("usage", {}).get("cost", 0) or 0
            print(json.dumps(report["summary"], indent=2), flush=True)
        except Exception as exc:
            report["error"] = str(exc); any_errors = True
            print(f"ERROR: {exc}", flush=True)
        finally:
            cleanup()
            # Drop the closure holding model weights before loading the next model.
            if "predict" in locals(): del predict
            import gc
            gc.collect()
            if "torch" in __import__("sys").modules:
                import torch
                if torch.backends.mps.is_available(): torch.mps.empty_cache()
            path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(f"Saved: {path}", flush=True)
    raise SystemExit(1 if any_errors else 0)


if __name__ == "__main__":
    main()
