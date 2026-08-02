#!/usr/bin/env python3
"""Compare the same bounded canary task across the retained runtimes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--opencode", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(args.codex.read_text()), json.loads(args.opencode.read_text())]
    assert {row["runtime"] for row in rows} == {"codex", "opencode"}
    assert all(row["task"] == "CANARY_SHARED_TEXT" for row in rows)
    assert all(row["completed"] and row["errors"] == 0 for row in rows)
    assert {row["output"] for row in rows} == {"CANARY_SHARED_OK"}
    report = {
        "ok": True,
        "task": "CANARY_SHARED_TEXT",
        "runtimes": rows,
        "rollback_ready": True,
    }
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print("Codex/OpenCode shared canary comparison passed")


if __name__ == "__main__":
    main()
