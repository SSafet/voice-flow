#!/usr/bin/env python3
"""Regression tests for evidence that must be backed by actual suite receipts."""
from __future__ import annotations

import copy
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from record_test_evidence import (
    ROOT, artifact_exclusions, build_evidence, source_snapshot,
    validate_evidence, validate_journal, validate_registry,
)


class EvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="vf-evidence-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        (self.root / "swift").mkdir()
        (self.root / "swift/main.swift").write_text("let answer = 1\n")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.registry = {
            "version": 1,
            "runners": {tier: {"required_suites": [suite]} for tier, suite in
                        [("unit", "alpha"), ("live", "beta"), ("e2e", "signed_e2e"),
                         ("release", "release_soak")]},
            "tests": [
                {"id": "contract:a", "runner": "unit", "suites": ["alpha"]},
                {"id": "live:b", "runner": "live", "suites": ["alpha", "beta"]},
                {"id": "e2e:c", "runner": "e2e", "suites": ["signed_e2e"]},
                {"id": "soak:d", "runner": "release", "suites": ["release_soak"]},
            ],
        }

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.root, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def journal(self, mode: str = "unit", suites: list[str] | None = None) -> list[dict]:
        return [{"type": "start", "version": 1, "mode": mode,
                 "source": source_snapshot(self.root)}] + [
            {"type": "suite", "suite": name, "exit_code": 0}
            for name in (["alpha"] if suites is None else suites)]

    def test_standalone_recorder_cannot_invent_passes(self) -> None:
        output = self.root / "evidence.json"
        result = subprocess.run(
            ["python3", str(ROOT / "tests/record_test_evidence.py"), "--mode", "release",
             "--out", str(output)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--journal", result.stderr)
        self.assertFalse(output.exists())

    def test_missing_empty_and_partial_journals_fail(self) -> None:
        for journal in [[], self.journal(suites=[]), self.journal("live")]:
            with self.subTest(journal=journal), self.assertRaises(ValueError):
                validate_journal(journal, self.registry,
                                 journal[0]["mode"] if journal else "unit", self.root)

    def test_cli_start_record_finalize_and_audit(self) -> None:
        tests = self.root / "tests"
        tests.mkdir()
        script = tests / "record_test_evidence.py"
        shutil.copyfile(ROOT / "tests/record_test_evidence.py", script)
        (tests / "test_registry.json").write_text(json.dumps(self.registry))
        journal, output = tests / "execution.jsonl", tests / "evidence.json"

        def invoke(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["python3", str(script), "--journal", str(journal), *args],
                                  capture_output=True, text=True)

        self.assertNotEqual(invoke("--mode", "unit", "--out", str(output)).returncode, 0)
        start = invoke("--mode", "unit", "--out", str(output), "--start")
        self.assertEqual(start.returncode, 0, start.stderr)
        self.assertNotEqual(invoke("--mode", "unit", "--start").returncode, 0)
        incomplete = invoke("--mode", "unit", "--out", str(output))
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("missing successful execution receipts", incomplete.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(invoke("--suite", "alpha", "--exit-code", "0").returncode, 0)
        completed = invoke("--mode", "unit", "--out", str(output))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        validate_evidence(json.loads(output.read_text()), self.registry, "unit", self.root)
        self.assertEqual(invoke("--suite", "failure", "--exit-code", "1").returncode, 0)
        failed = invoke("--mode", "unit", "--out", str(output))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("suite did not pass", failed.stderr)

    def test_failure_and_duplicate_receipts_fail(self) -> None:
        for status in [1, -9, False, "0", None]:
            journal = self.journal()
            journal[1]["exit_code"] = status
            with self.subTest(status=status), self.assertRaises(ValueError):
                validate_journal(journal, self.registry, "unit", self.root)
        journal = self.journal()
        journal.append(copy.deepcopy(journal[1]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate_journal(journal, self.registry, "unit", self.root)

    def test_complete_journal_preserves_test_to_suite_mapping(self) -> None:
        journal = self.journal("live", ["alpha", "beta"])
        evidence = build_evidence(journal, self.registry, "live", self.root)
        validate_evidence(evidence, self.registry, "live", self.root)
        self.assertEqual([row["id"] for row in evidence["tests"]], ["contract:a", "live:b"])
        self.assertEqual(evidence["tests"][1]["suites"], ["alpha", "beta"])
        self.assertFalse(evidence["source"]["dirty"])

    def test_release_requires_soak_receipt(self) -> None:
        journal = self.journal("release", ["alpha", "beta", "signed_e2e"])
        with self.assertRaisesRegex(ValueError, "release_soak"):
            validate_journal(journal, self.registry, "release", self.root)

    def test_source_change_invalidates_journal_and_saved_evidence(self) -> None:
        journal = self.journal()
        evidence = build_evidence(journal, self.registry, "unit", self.root)
        (self.root / "swift/main.swift").write_text("let answer = 2\n")
        for validate in [lambda: validate_journal(journal, self.registry, "unit", self.root),
                         lambda: validate_evidence(evidence, self.registry, "unit", self.root)]:
            with self.assertRaisesRegex(ValueError, "source checkout changed"):
                validate()

    def test_existing_dirty_source_is_identified_and_supported(self) -> None:
        (self.root / "swift/main.swift").write_text("let answer = 2\n")
        evidence = build_evidence(self.journal(), self.registry, "unit", self.root)
        self.assertTrue(evidence["source"]["dirty"])
        validate_evidence(evidence, self.registry, "unit", self.root)

    def test_new_untracked_test_fixture_invalidates_evidence(self) -> None:
        journal = self.journal()
        (self.root / "tests").mkdir()
        (self.root / "tests/fixture.json").write_text('{"new":true}')
        with self.assertRaisesRegex(ValueError, "source checkout changed"):
            validate_journal(journal, self.registry, "unit", self.root)

    def test_reports_and_declared_artifacts_do_not_change_source_identity(self) -> None:
        journal_path = self.root / "tests/receipts.jsonl"
        evidence_path = self.root / "tests/evidence.json"
        exclusions = artifact_exclusions([journal_path, evidence_path], self.root)
        journal = self.journal()
        journal[0]["excluded_paths"] = exclusions
        (self.root / "tests").mkdir()
        journal_path.write_text("receipt\n")
        evidence_path.write_text("{}")
        (self.root / "design").mkdir()
        (self.root / "design/quality.md").write_text("Reported test results\n")
        validate_journal(journal, self.registry, "unit", self.root)
        with self.assertRaisesRegex(ValueError, "tracked source"):
            source_snapshot(self.root, ["swift/main.swift"])

    def test_saved_evidence_cannot_change_revision_mapping_or_claim_extra_tests(self) -> None:
        valid = build_evidence(self.journal(), self.registry, "unit", self.root)
        for field, value in [("revision", "0" * 40), ("version", 1),
                             ("tests", valid["tests"] + [{"id": "unexecuted", "status": "passed"}])]:
            evidence = copy.deepcopy(valid)
            evidence[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_evidence(evidence, self.registry, "unit", self.root)
        evidence = copy.deepcopy(valid)
        evidence["journal"] = []
        with self.assertRaises(ValueError):
            validate_evidence(evidence, self.registry, "unit", self.root)

    def test_registry_cannot_claim_live_suite_in_unit_tier(self) -> None:
        self.registry["tests"][0]["suites"] = ["beta"]
        with self.assertRaisesRegex(ValueError, "before it executes"):
            validate_registry(self.registry)


if __name__ == "__main__":
    unittest.main()
