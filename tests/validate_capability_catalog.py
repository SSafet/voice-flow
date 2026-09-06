#!/usr/bin/env python3
"""Validate the capability ledger and source-exposed MCP tool coverage."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from record_test_evidence import validate_registry, validate_evidence


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "tests" / "capabilities.json"
REGISTRY = ROOT / "tests" / "test_registry.json"
RUNNER_ORDER = {"unit": 0, "live": 1, "e2e": 2, "release": 3}


def fail(message: str) -> None:
    print(f"capability catalog: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--release",
        action="store_true",
        help="also require every referenced repository test path to exist",
    )
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--mode", choices=RUNNER_ORDER)
    args = parser.parse_args()

    raw = json.loads(CATALOG.read_text())
    if raw.get("version") != 1 or not isinstance(raw.get("capabilities"), list):
        fail("expected version 1 with a capabilities array")

    capabilities = raw["capabilities"]
    ids: set[str] = set()
    surfaces: set[str] = set()
    risks = {"medium", "high", "critical"}
    kinds = {"existing", "new"}

    for index, capability in enumerate(capabilities):
        prefix = f"entry {index + 1}"
        capability_id = capability.get("id")
        if not isinstance(capability_id, str) or not re.fullmatch(r"[A-Z]+-[0-9]{2}", capability_id):
            fail(f"{prefix} has invalid id {capability_id!r}")
        if capability_id in ids:
            fail(f"duplicate id {capability_id}")
        ids.add(capability_id)
        if not capability.get("area") or not capability.get("name"):
            fail(f"{capability_id} needs area and name")
        if capability.get("risk") not in risks:
            fail(f"{capability_id} has invalid risk")
        if capability.get("kind") not in kinds:
            fail(f"{capability_id} has invalid kind")
        tests = capability.get("tests")
        if not isinstance(tests, list) or not tests or not all(isinstance(item, str) and item for item in tests):
            fail(f"{capability_id} needs at least one test id")
        surface = capability.get("surface")
        if surface:
            if surface in surfaces:
                fail(f"duplicate surface {surface}")
            surfaces.add(surface)
        if args.release:
            for test in tests:
                if test.startswith(("tests/", "scripts/")):
                    path = ROOT / test.split(":", 1)[0]
                    if not path.exists():
                        fail(f"{capability_id} references missing {path.relative_to(ROOT)}")

    source = (ROOT / "swift" / "MCP.swift").read_text()
    source_tools = set(re.findall(r'^\s+"name":\s+"([a-z][a-z0-9_]+)",\s*$', source, re.MULTILINE))
    catalog_tools = {surface.removeprefix("mcp:") for surface in surfaces if surface.startswith("mcp:")}
    if source_tools != catalog_tools:
        missing = sorted(source_tools - catalog_tools)
        stale = sorted(catalog_tools - source_tools)
        fail(f"MCP coverage mismatch; missing={missing}, stale={stale}")

    registry = json.loads(REGISTRY.read_text())
    try:
        validate_registry(registry)
    except ValueError as error:
        fail(str(error))
    if registry.get("version") != 1 or set(registry.get("runners", {})) != set(RUNNER_ORDER):
        fail("test registry must declare version 1 and unit/live/e2e/release runners")
    registered: dict[str, str] = {}
    for row in registry.get("tests", []):
        test_id = row.get("id")
        runner = row.get("runner")
        if test_id in registered:
            fail(f"test registry duplicates {test_id}")
        if runner not in RUNNER_ORDER:
            fail(f"test registry gives {test_id!r} invalid runner {runner!r}")
        registered[test_id] = runner
    referenced = {test for capability in capabilities for test in capability["tests"]}
    if set(registered) != referenced:
        fail(
            "test registry mismatch; missing="
            f"{sorted(referenced - set(registered))}, stale={sorted(set(registered) - referenced)}"
        )

    if args.evidence:
        if not args.mode:
            fail("--evidence requires --mode")
        evidence = json.loads(args.evidence.read_text())
        try:
            validate_evidence(evidence, registry, args.mode, ROOT)
        except (ValueError, OSError) as error:
            fail(str(error))

    areas = len({capability["area"] for capability in capabilities})
    print(
        f"capability catalog: {len(capabilities)} capabilities across {areas} areas; "
        f"MCP {len(source_tools)}/15; registry {len(registered)}/{len(referenced)}"
    )


if __name__ == "__main__":
    main()
