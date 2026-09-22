"""Fast checks that the T3 QA installer rejects unsafe destinations before building."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
INSTALLER = PROJECT / "scripts/install-agent-harness-qa.sh"


class QAPackageDestinationTests(unittest.TestCase):
    def run_installer(self, destination, *, include_sha=True, include_destination=True):
        environment = os.environ.copy()
        environment.pop("VOICE_FLOW_T3_ARCHIVE_SHA256", None)
        environment.pop("VOICE_FLOW_QA_APP_DEST", None)
        environment.update({
            "VOICE_FLOW_T3_ARCHIVE": "/nonexistent/reviewed-t3.tar.gz",
            "VOICE_FLOW_BUILD_PYTHON": str(PROJECT / ".venv/bin/python"),
        })
        if include_sha:
            environment["VOICE_FLOW_T3_ARCHIVE_SHA256"] = "0" * 64
        if include_destination:
            environment["VOICE_FLOW_QA_APP_DEST"] = str(destination)
        return subprocess.run(
            [str(INSTALLER)], cwd=PROJECT, env=environment,
            capture_output=True, text=True, timeout=10,
        )

    def test_rejects_invalid_or_live_destinations_before_archive_staging(self):
        with tempfile.TemporaryDirectory(prefix="vf-qa-destination-") as raw:
            root = Path(raw)
            cases = [
                ("relative", Path("relative.app"), "absolute .app path"),
                ("extension", root / "artifact", "absolute .app path"),
                ("installed", Path("/Applications/Voice Flow T3 QA.app"), "installed-app or live-data"),
                ("live data", Path.home() / ".config/voice-flow/qa.app", "installed-app or live-data"),
            ]
            for name, destination, reason in cases:
                with self.subTest(name=name):
                    result = self.run_installer(destination)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(reason, result.stderr)
                    self.assertNotIn("FileNotFoundError", result.stderr)

    def test_refuses_existing_destination_without_changing_it(self):
        with tempfile.TemporaryDirectory(prefix="vf-qa-destination-") as raw:
            root = Path(raw)
            destination = root / "existing.app"
            destination.mkdir()
            sentinel = destination / "sentinel"
            sentinel.write_text("preserved")
            result = self.run_installer(destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("destination must be new", result.stderr)
            self.assertEqual(sentinel.read_text(), "preserved")

            link = root / "link.app"
            link.symlink_to(destination, target_is_directory=True)
            result = self.run_installer(link)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("destination must be new", result.stderr)
            self.assertTrue(link.is_symlink())
            self.assertEqual(sentinel.read_text(), "preserved")

    def test_requires_reviewed_sha_and_explicit_destination(self):
        with tempfile.TemporaryDirectory(prefix="vf-qa-destination-") as raw:
            destination = Path(raw) / "new.app"
            missing_sha = self.run_installer(destination, include_sha=False)
            self.assertNotEqual(missing_sha.returncode, 0)
            self.assertIn("reviewed T3 archive SHA256", missing_sha.stderr)
            missing_destination = self.run_installer(destination, include_destination=False)
            self.assertNotEqual(missing_destination.returncode, 0)
            self.assertIn("explicit new isolated app destination", missing_destination.stderr)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
