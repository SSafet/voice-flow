"""Render latest complete standard runs as a Markdown comparison."""
import json
import argparse
import statistics
from pathlib import Path

ROOT = Path(__file__).parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "results")
    parser.add_argument("--output", type=Path, default=ROOT / "RESULTS.md")
    args = parser.parse_args()
    reports = {}
    paths = {}
    for path in sorted(args.input.glob("*.json")):
        report = json.loads(path.read_text())
        if report.get("summary", {}).get("decisions") != 46 or len(report["rows"]) != 28 or report["summary"]["errors"]:
            continue
        reports[report["model"]] = report
        paths[report["model"]] = path
    if not reports:
        raise SystemExit("No complete standard run found. Run ./run.sh all --voiceflow-keychain first.")
    if len({r["cases_sha256"] for r in reports.values()}) != 1:
        raise SystemExit("Input hashes differ: rerun the same test pack for every model before comparing.")
    lines = ["# Measured decision-model comparison", "", "Synthetic smoke test run from Safet's Mac. Hosted models use OpenRouter; any local Laya results use MPS/float32. See [README](README.md) for methods, caveats, and commands.", "",
             "26 bilingual short cases / 46 decisions, plus two separate long-input stress cases. No examples or expected labels were changed after seeing model outputs.", "",
             "| Model | Correct | English | Bulgarian | Median request | Wrong at ≥90% probability |",
             "|---|---:|---:|---:|---:|---:|"]
    for name in ["jev", "clef", "clef-flash", "laya-multi", "laya-typed", "laya-en"]:
        if name not in reports: continue
        r = reports[name]; s = r["summary"]
        groups = [s["groups"][lang] for lang in ["en", "bg"]]
        parts = [f"{g['correct']}/{g['total']}" for g in groups]
        lines.append(f"| {name} | {s['correct']}/46 ({s['correct']/46:.1%}) | {parts[0]} | {parts[1]} | {s['median_request_ms']:.0f} ms | {s['wrong_at_90pct']} |")
    lines += ["", "## By use case", "", "| Model | Triage | Continuity | Intent | Score MAE ↓ | Boolean Brier ↓ |", "|---|---:|---:|---:|---:|---:|"]
    for name, r in reports.items():
        s = r["summary"]
        parts = [f"{s['groups'][task]['correct']}/{s['groups'][task]['total']}" for task in ["triage", "continuity", "intent"]]
        lines.append(f"| {name} | {' | '.join(parts)} | {s['score_mae']:.3f} | {s['noul_brier']:.3f} |")
    lines += ["", "## Speed and startup", "", "Timing is one pass after one warm-up, with models run sequentially. Hosted timings include network and provider processing; local timings include input processing/diagnostics and possible first-shape MPS setup. No claim about tail latency or equal serving hardware. These short, correlated examples cannot establish general accuracy or a stable speed ranking.", "",
              "| Model | Load (excludes warm-up) | Warm-up | One-question median | Three-question median |", "|---|---:|---:|---:|---:|"]
    for name, r in reports.items():
        medians = [statistics.median([row["latency_ms"] for row in r["rows"] if row["task"] != "stress" and len(row["questions"]) == n]) for n in [1, 3]]
        load = r["runtime"].get("load_seconds")
        load_s = f"{load:.1f} s" if load is not None else "hosted"
        lines.append(f"| {name} | {load_s} | {r['warmup']['latency_ms']:.0f} ms | {medians[0]:.0f} ms | {medians[1]:.0f} ms |")
    lines += ["", "## Long-input stress", "", "The same request is moved from the start to the end of a long log. These cases are excluded from the accuracy and speed tables above. Laya logs its configured truncation budget; hosted providers may also truncate input.", ""]
    if any(name in reports for name in ("clef", "clef-flash")):
        lines += ["OpenRouter's [Clef](https://openrouter.ai/cloudflare/clef) and [Flash](https://openrouter.ai/cloudflare/clef-flash) descriptions warn that the current Workers AI route reads roughly the first 2K text-state tokens, despite the advertised 65,536-token model context. Both models passed our start/end cases (~2.7K billed input tokens per request); this run therefore does not reproduce or establish an exact truncation boundary.", ""]
    for name, r in reports.items():
        for row in r["rows"]:
            if row["task"] != "stress": continue
            a = row["response"]["answers"]["refund"]
            diag = row["response"].get("input_diagnostics", {}).get("refund")
            suffix = f"; {diag['state_tokens']} state tokens / {diag['available_state_tokens']} available" if diag else ""
            lines.append(f"- {name}, {row['id']}: P(refund) = {a['noul']:.4f}{suffix}.")
    lines += ["", "## Every short-input mistake", ""]
    for name, r in reports.items():
        lines += [f"### {name}", ""]
        mistakes = 0
        for row in r["rows"]:
            if row["task"] == "stress": continue
            for qid, d in row["decisions"].items():
                if d["correct"]: continue
                mistakes += 1
                lines.append(f"- `{row['id']}/{qid}`: expected `{d['expected']}`, got `{d['predicted']}`; top-label probability {d['top_probability']:.1%}.")
        if not mistakes:
            lines.append("None in this run.")
        lines.append("")
    image_probe = args.input / "image-route-probe.json"
    if image_probe.exists():
        lines += ["## Separate image-route probe", "", "A Clef Flash probe sent a synthetic red PNG, a blue PNG, and a no-image control using a top-level `images` extension. All three responses returned identical probabilities for ‘no image available’ and identical input-token counts. The extension appears to have been ignored on this route. This does not test Clef's underlying vision quality; image input remains unverified in our OpenRouter integration. The current [SDK request schema](https://github.com/OpenRouterTeam/typescript-sdk/blob/main/src/models/decisionsrequest.ts) does not expose an images field.", "", f"[Raw probe responses]({image_probe.resolve()}). Excluded from the text accuracy and cost tables.", ""]
    lines += ["## Provenance", "", f"Input pack SHA-256: `{next(iter(reports.values()))['cases_sha256']}`", ""]
    for name, r in reports.items():
        versions = sorted({row["response"]["model"] for row in r["rows"]})
        lines.append(f"- {name}: {r['created_utc']}; returned {', '.join(versions)}; raw [JSON]({paths[name].resolve()}).")
        if "provider" in r["runtime"]:
            lines.append(f"  Reported run cost, including warm-up: ${r['summary']['reported_cost_usd']:.6f}.")
        else:
            meta = r["runtime"]
            lines.append(f"  {meta['parameters']:,} parameters; {meta['repo']} @ `{meta['revision']}`, subfolder `{meta['subfolder'] or '(root)'}`; max_len={meta['config']['max_len']}, head_max_len={meta['config']['head_max_len']}.")
    path = args.output
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    print(path)


if __name__ == "__main__":
    main()
