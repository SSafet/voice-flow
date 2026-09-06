#!/usr/bin/env python3
"""Build capability evidence from successful execution receipts, never from mode alone."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "tests" / "test_registry.json"
ORDER = {"unit": 0, "live": 1, "e2e": 2, "release": 3}
SOURCE_DIRECTORIES = {"swift", "voice_flow", "tests", "scripts", "runtime", "watcher", "assets", ".github"}


def is_source(path: bytes) -> bool:
    """Production/test/build inputs; design/docs/research reports are not inputs."""
    name = os.fsdecode(path)
    if "/" in name:
        return name.split("/", 1)[0] in SOURCE_DIRECTORIES
    return name == ".gitignore" or Path(name).suffix in {".py", ".sh", ".toml", ".lock", ".json", ".yaml", ".yml"}


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def git(root: Path, *args: str) -> bytes:
    return subprocess.run(["git", *args], cwd=root, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def source_snapshot(root: Path = ROOT, excluded_paths: list[str] | None = None) -> dict:
    """Hash implementation/test/config inputs, tracked and nonignored untracked.

    Harness journals/evidence may be placed in the checkout, but may never
    exclude a tracked source file. Git-ignored build artifacts stay excluded.
    """
    tracked = set(git(root, "ls-files", "-z").split(b"\0")) - {b""}
    files = {p for p in tracked | (set(git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")) - {b""}) if is_source(p)}
    excluded = {os.fsencode(path) for path in (excluded_paths or [])}
    if tracked & excluded:
        raise ValueError("evidence artifacts cannot exclude tracked source files")
    digest = hashlib.sha256()

    def frame(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    for raw in sorted(files - excluded):
        path = root / os.fsdecode(raw)
        frame(raw)
        if not path.exists() and not path.is_symlink():
            frame(b"deleted")
        elif path.is_symlink():
            frame(b"symlink")
            frame(os.fsencode(os.readlink(path)))
        elif path.is_file():
            frame(str(stat.S_IMODE(path.stat().st_mode) & 0o111).encode())
            frame(path.read_bytes())
        else:
            raise ValueError(f"unsupported source entry: {path}")
    # Artifact exclusions must not make a clean checkout appear dirty either.
    changed = {p for p in git(root, "diff", "--name-only", "-z", "HEAD").split(b"\0") if p and is_source(p)}
    untracked = files - tracked - excluded
    return {"revision": git(root, "rev-parse", "HEAD").decode().strip(),
            "dirty": bool(changed or untracked), "fingerprint": digest.hexdigest()}


def artifact_exclusions(paths: list[Path], root: Path = ROOT) -> list[str]:
    result = []
    for path in paths:
        try:
            result.append(path.resolve().relative_to(root.resolve()).as_posix())
        except ValueError:
            pass
    return sorted(set(result))


def validate_registry(registry: dict) -> None:
    if registry.get("version") != 1 or set(registry.get("runners", {})) != set(ORDER):
        raise ValueError("registry must declare all four runners")
    suite_tiers = {}
    for tier, runner in registry["runners"].items():
        suites = runner.get("required_suites")
        if not isinstance(suites, list) or not suites:
            raise ValueError(f"{tier} must declare required_suites")
        for suite in suites:
            if not isinstance(suite, str) or not suite or suite in suite_tiers:
                raise ValueError(f"invalid or duplicate required suite: {suite!r}")
            suite_tiers[suite] = tier
    ids = set()
    for row in registry.get("tests", []):
        test_id, runner, suites = row.get("id"), row.get("runner"), row.get("suites")
        if not isinstance(test_id, str) or not test_id or test_id in ids or runner not in ORDER:
            raise ValueError(f"invalid registry test: {row}")
        ids.add(test_id)
        if not isinstance(suites, list) or not suites or len(set(suites)) != len(suites):
            raise ValueError(f"{test_id} needs explicit executable suites")
        for suite in suites:
            if suite not in suite_tiers or ORDER[suite_tiers[suite]] > ORDER[runner]:
                raise ValueError(f"{test_id} claims suite {suite!r} before it executes")


def required_suites(registry: dict, mode: str) -> set[str]:
    validate_registry(registry)
    return {suite for tier, row in registry["runners"].items() if ORDER[tier] <= ORDER[mode]
            for suite in row["required_suites"]}


def validate_journal(journal: list[dict], registry: dict, mode: str,
                     root: Path = ROOT) -> dict:
    required = required_suites(registry, mode)
    if not journal or not isinstance(journal[0], dict):
        raise ValueError("execution journal is empty")
    header = journal[0]
    if header.get("type") != "start" or header.get("version") != 1 or header.get("mode") != mode:
        raise ValueError("execution journal has an invalid start or mode")
    exclusions = header.get("excluded_paths", [])
    if not isinstance(exclusions, list) or not all(isinstance(p, str) for p in exclusions):
        raise ValueError("invalid artifact exclusions")
    if header.get("source") != source_snapshot(root, exclusions):
        raise ValueError("source checkout changed since execution started")
    passed = set()
    for row in journal[1:]:
        if not isinstance(row, dict) or row.get("type") != "suite":
            raise ValueError("invalid execution receipt")
        suite = row.get("suite")
        if not isinstance(suite, str) or not suite or suite in passed:
            raise ValueError(f"duplicate or invalid suite receipt: {suite!r}")
        if type(row.get("exit_code")) is not int or row["exit_code"] != 0:
            raise ValueError(f"suite did not pass: {suite}")
        passed.add(suite)
    missing = required - passed
    if missing:
        raise ValueError(f"missing successful execution receipts: {', '.join(sorted(missing))}")
    return header


def build_evidence(journal: list[dict], registry: dict, mode: str, root: Path = ROOT) -> dict:
    header = validate_journal(journal, registry, mode, root)
    return {"version": 2, "mode": mode, "generated_at": timestamp(),
            "source": header["source"], "revision": header["source"]["revision"],
            "journal": journal,
            "tests": [{"id": row["id"], "runner": row["runner"],
                       "suites": row["suites"], "status": "passed"}
                      for row in registry["tests"] if ORDER[row["runner"]] <= ORDER[mode]]}


def validate_evidence(evidence: dict, registry: dict, mode: str, root: Path = ROOT) -> None:
    if evidence.get("version") != 2 or evidence.get("mode") != mode:
        raise ValueError("evidence requires version 2 and the requested mode")
    expected = build_evidence(evidence.get("journal", []), registry, mode, root)
    for field in ("source", "revision", "tests"):
        if evidence.get(field) != expected[field]:
            raise ValueError(f"evidence {field} does not match the execution journal")


def read_journal(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=ORDER)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--journal", type=Path, required=True)
    parser.add_argument("--start", action="store_true")
    parser.add_argument("--suite")
    parser.add_argument("--exit-code", type=int)
    args = parser.parse_args()
    try:
        if args.start:
            if not args.mode or args.suite is not None or args.exit_code is not None:
                parser.error("--start requires --mode and cannot record a suite")
            exclusions = artifact_exclusions([args.journal] + ([args.out] if args.out else []))
            header = {"type": "start", "version": 1, "mode": args.mode,
                      "started_at": timestamp(), "excluded_paths": exclusions,
                      "source": source_snapshot(excluded_paths=exclusions)}
            args.journal.parent.mkdir(parents=True, exist_ok=True)
            # Exclusive creation prevents receipts from previous runs being reused.
            with args.journal.open("x") as stream:
                stream.write(json.dumps(header) + "\n")
        elif args.suite is not None:
            if args.exit_code is None or args.mode or args.out:
                parser.error("--suite requires --exit-code, without --mode/--out")
            if not args.journal.is_file():
                raise ValueError("start the execution journal before recording suites")
            with args.journal.open("a") as stream:
                stream.write(json.dumps({"type": "suite", "suite": args.suite,
                                         "exit_code": args.exit_code}) + "\n")
        else:
            if not args.mode or not args.out or args.exit_code is not None:
                parser.error("finalizing evidence requires --mode, --out and --journal")
            registry = json.loads(REGISTRY.read_text())
            evidence = build_evidence(read_journal(args.journal), registry, args.mode)
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(evidence, indent=2) + "\n")
            print(f"test evidence: {len(evidence['tests'])} registered checks backed by execution receipts through {args.mode}; {args.out}")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"test evidence: {error}\n")


if __name__ == "__main__":
    main()
