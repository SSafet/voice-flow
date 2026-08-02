#!/usr/bin/env python3
"""Validate and combine signed release-soak evidence across corrected QA fixtures."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prior-artifacts", type=Path, required=True)
    parser.add_argument(
        "--supplemental-artifacts",
        type=Path,
        action="append",
        default=[],
        help="Additional independently passing signed soak artifact directories",
    )
    parser.add_argument(
        "--full-depth-artifacts",
        type=Path,
        help=("A completed full-depth soak whose later persistence probe was "
              "interrupted only by the corrected fake-provider budget fixture"),
    )
    parser.add_argument("--current-artifacts", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--required-seconds", type=float, default=14_400)
    parser.add_argument("--required-iterations", type=int, default=1_440)
    args = parser.parse_args()

    prior_report = load(args.prior_artifacts / "report.json")
    require(prior_report.get("ok") is False, "prior segment must be the interrupted run")
    error = str(prior_report.get("error", ""))
    require(re.search(r"lost three-agent overlap: .*'max_active': 2", error) is not None,
            f"prior segment ended for an unapproved reason: {error}")
    required_pre_soak = {
        "signed_bundle_chain_of_custody", "qa_auth_isolation",
        "signed_three_agent_concurrency_and_isolation",
        "signed_job_budget_and_cancel", "signed_codex_rollback_canonical_reseed",
    }
    require(required_pre_soak.issubset(set(prior_report.get("checks", []))),
            "prior segment did not pass the required signed pre-soak gates")

    rows = [json.loads(line) for line in
            (args.prior_artifacts / "soak-report.jsonl").read_text().splitlines() if line]
    require(rows, "prior segment has no heartbeat evidence")
    previous_elapsed = -1.0
    previous_completed = -1
    for row in rows:
        lanes = row["completed_by_lane"]
        require(len(set(lanes)) == 1, f"prior segment was unfair: {lanes}")
        require(row["elapsed_seconds"] > previous_elapsed,
                "prior elapsed time was not monotonic")
        require(lanes[0] >= previous_completed, "prior completion count regressed")
        require(row["fd_count"] <= rows[0]["fd_count"] + 128,
                "prior file descriptors were unbounded")
        require(row["root_processes"] <= rows[0]["root_processes"] + 6,
                "prior process count was unbounded")
        previous_elapsed = row["elapsed_seconds"]
        previous_completed = lanes[0]

    supplemental = []
    for artifacts in args.supplemental_artifacts:
        report = load(artifacts / "report.json")
        require(report.get("ok") is True,
                f"supplemental segment did not pass: {artifacts}")
        require("signed_three_agent_soak" in report.get("checks", []),
                f"supplemental segment lacks its soak gate: {artifacts}")
        summary = load(artifacts / "soak-summary.json")
        supplemental_lanes = summary["completed_by_lane"]
        require(len(set(supplemental_lanes)) == 1 and supplemental_lanes[0] > 0,
                f"supplemental segment was unfair: {artifacts}: {supplemental_lanes}")
        require(summary["max_fd_count"] <= summary["baseline_fd_count"] + 128,
                f"supplemental descriptors were unbounded: {artifacts}")
        require(summary["max_processes"] <= summary["baseline_processes"] + 6,
                f"supplemental process count was unbounded: {artifacts}")
        supplemental.append({"artifacts": str(artifacts), **summary})

    full_depth = None
    if args.full_depth_artifacts is not None:
        full_report = load(args.full_depth_artifacts / "report.json")
        require(full_report.get("ok") is False,
                "full-depth segment must be the budget-fixture-interrupted run")
        require(full_report.get("error") ==
                "timed out waiting for Assistant idle; last=None",
                f"full-depth segment ended for an unapproved reason: "
                f"{full_report.get('error')}")
        full_checks = set(full_report.get("checks", []))
        require({"signed_three_agent_soak", "signed_secret_canary_containment"}
                .issubset(full_checks),
                "full-depth segment did not finish soak and canary gates")
        require("signed_launch_relaunch_persistence_no_orphans" not in full_checks,
                "full-depth segment failure occurred after an unexpected gate")
        budget_log = (
            args.full_depth_artifacts.parent / "root-final" / "runtime" /
            "opencode" / "workspace" / "logs" / "opencode.log"
        )
        require(budget_log.exists() and
                "Voice Flow daily model budget reached" in
                budget_log.read_text(errors="replace"),
                "full-depth interruption was not caused by the corrected QA budget fixture")
        full_depth = load(args.full_depth_artifacts / "soak-summary.json")

    current_report = load(args.current_artifacts / "report.json")
    require(current_report.get("ok") is True, "continuation signed E2E did not pass")
    require("signed_three_agent_soak" in current_report.get("checks", []),
            "continuation did not complete its soak gate")
    current = load(args.current_artifacts / "soak-summary.json")
    lanes = current["completed_by_lane"]
    require(len(set(lanes)) == 1 and lanes[0] > 0,
            f"continuation was unfair: {lanes}")
    depth_source = full_depth or current
    require(depth_source["iterations"] >= args.required_iterations,
            "no current-build segment reached the required session depth")
    require(depth_source["three_way_iterations"] >=
            max(1, int(depth_source["iterations"] * 0.95)),
            "full-depth three-way overlap fell below 95%")
    require(current["max_fd_count"] <= current["baseline_fd_count"] + 128,
            "continuation file descriptors were unbounded")
    require(current["max_processes"] <= current["baseline_processes"] + 6,
            "continuation process count was unbounded")

    supplemental_seconds = sum(item["duration_seconds"] for item in supplemental)
    total_seconds = (
        rows[-1]["elapsed_seconds"]
        + supplemental_seconds
        + (full_depth["duration_seconds"] if full_depth is not None else 0)
        + current["duration_seconds"]
    )
    require(total_seconds >= args.required_seconds,
            f"combined wall-clock evidence is only {total_seconds:.2f} seconds")
    result = {
        "ok": True,
        "validation": "segmented_after_qa_assertion_correction",
        "combined_duration_seconds": total_seconds,
        "required_duration_seconds": args.required_seconds,
        "prior": {
            "duration_seconds": rows[-1]["elapsed_seconds"],
            "completed_by_lane": rows[-1]["completed_by_lane"],
            "max_rss_kib": max(row["rss_kib"] for row in rows),
            "max_fd_count": max(row["fd_count"] for row in rows),
            "max_processes": max(row["root_processes"] for row in rows),
            "termination": error,
        },
        "supplemental": supplemental,
        "full_depth": full_depth,
        "continuation": current,
        "full_depth_iterations_required": args.required_iterations,
        "full_depth_iterations_observed": depth_source["iterations"],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"combined soak passed: {total_seconds:.2f}s, "
        f"full depth {depth_source['iterations']} iterations")


if __name__ == "__main__":
    main()
