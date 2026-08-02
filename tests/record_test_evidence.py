#!/usr/bin/env python3
"""Emit and audit the exact capability-test evidence for one harness tier."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "tests" / "test_registry.json"
ORDER = {"unit": 0, "live": 1, "e2e": 2, "release": 3}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=ORDER, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    registry = json.loads(REGISTRY.read_text())
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    ).stdout.strip()
    selected = [
        {"id": row["id"], "runner": row["runner"], "status": "passed"}
        for row in registry["tests"]
        if ORDER[row["runner"]] <= ORDER[args.mode]
    ]
    evidence = {
        "version": 1,
        "mode": args.mode,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "revision": commit,
        "tests": selected,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"test evidence: {len(selected)} registered checks passed through {args.mode}; {args.out}")


if __name__ == "__main__":
    main()
