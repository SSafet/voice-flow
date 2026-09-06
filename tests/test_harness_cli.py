"""CLI validation, suite isolation and failure propagation without real builds."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HARNESS = Path(__file__).resolve().parents[1] / "scripts/test-agent-harness.sh"


class HarnessCLITests(unittest.TestCase):
    def invoke(self, *arguments):
        with tempfile.TemporaryDirectory(prefix="vf-harness-cli-") as directory:
            root = Path(directory)
            log = root / "tools-called"
            for name in ("swiftc", "python3", "xcrun"):
                tool = root / name
                tool.write_text('#!/bin/sh\necho invoked >> "$VF_CLI_TEST_LOG"\nexit 86\n')
                tool.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(HARNESS), *arguments],
                env={**os.environ, "PATH": f"{root}:/usr/bin:/bin", "VF_CLI_TEST_LOG": str(log)},
                capture_output=True, text=True, timeout=5,
            )
            return result, log.exists()

    def test_invalid_arguments_fail_before_any_build_or_validation(self):
        for arguments in (("--bogus",), ("--unit", "unexpected"),
                          ("--only",), ("--only", "--unit"),
                          ("--live", "--only", "inbox"),
                          ("--unit", "--release")):
            with self.subTest(arguments=arguments):
                result, invoked = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(invoked, "invalid input reached an expensive build step")
                self.assertIn("usage:", result.stderr)

    def test_help_does_not_build(self):
        result, invoked = self.invoke("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(invoked)
        self.assertIn("--only", result.stdout)


class HarnessSuiteTests(unittest.TestCase):
    def invoke_suite(self, suite, *, compile_status=0, run_status=0, transport_status=0,
                     artifact_destination=None):
        # Copy the real script so even accidentally selected absolute-path tools
        # resolve inside the fixture, never to the checkout's Python environment.
        with tempfile.TemporaryDirectory(prefix="vf-harness-suite-") as directory:
            root = Path(directory)
            script = root / "scripts/test-agent-harness.sh"
            script.parent.mkdir()
            script.write_text(HARNESS.read_text())
            (root / "swift").mkdir()
            (root / "swift/Fixture.swift").write_text("// No Swift compiler runs.\n")
            log = root / "tools-called"
            evidence = root / "evidence.json"
            build_root_file = root / "build-root"
            artifacts = root / "artifacts"
            if artifact_destination == "file":
                artifacts.write_text("An invalid destination must remain untouched.")
            tools = root / "tools"
            tools.mkdir()
            stubs = {
                # Keep even leaked build directories inside the fixture on failure.
                "mktemp": '#!/bin/sh\nexec /usr/bin/mktemp -d "$VF_CLI_TEMP_ROOT/build.XXXXXX"\n',
                "xcrun": "#!/bin/sh\necho /tmp/mock-sdk\n",
                "python3": r'''#!/bin/sh
printf 'python %s\n' "$*" >> "$VF_CLI_TEST_LOG"
case "$1" in
  *transport_proof.py) exit "$VF_CLI_TRANSPORT_STATUS" ;;
  *record_test_evidence.py) touch "$VOICE_FLOW_EVIDENCE_PATH" ;;
esac
exit 0
''',
                "swiftc": r'''#!/bin/sh
printf 'swift %s\n' "$*" >> "$VF_CLI_TEST_LOG"
printf '%s\n' "${VOICE_FLOW_CONFIG_ROOT%/config}" > "$VF_CLI_BUILD_ROOT_FILE"
if [ -n "$VOICE_FLOW_TEST_ARTIFACTS" ]; then
    mkdir -p "${VOICE_FLOW_CONFIG_ROOT%/config}/e2e-artifacts"
    echo 'Synthetic UI failure evidence' > "${VOICE_FLOW_CONFIG_ROOT%/config}/e2e-artifacts/failure.txt"
fi
[ "$VF_CLI_COMPILE_STATUS" = 0 ] || exit "$VF_CLI_COMPILE_STATUS"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; destination="$1"; break; fi
    shift
done
cat > "$destination" <<'RUNNER'
#!/bin/sh
printf 'run %s\n' "$0" >> "$VF_CLI_TEST_LOG"
if [ -n "$VOICE_FLOW_TEST_ARTIFACTS" ]; then
    mkdir -p "$VOICE_FLOW_CONFIG_ROOT/runtime/opencode/fixture/logs"
    echo 'Synthetic runtime failure evidence' > "$VOICE_FLOW_CONFIG_ROOT/runtime/opencode/fixture/logs/opencode.log"
fi
exit "$VF_CLI_RUN_STATUS"
RUNNER
chmod +x "$destination"
''',
            }
            for name, content in stubs.items():
                tool = tools / name
                tool.write_text(content)
                tool.chmod(0o755)
            backend_python = root / ".venv/bin/python"
            backend_python.parent.mkdir(parents=True)
            backend_python.write_text(stubs["python3"])
            backend_python.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(script), "--only", suite],
                env={**os.environ, "PATH": f"{tools}:/usr/bin:/bin",
                     "VF_CLI_TEST_LOG": str(log), "VOICE_FLOW_EVIDENCE_PATH": str(evidence),
                     "VOICE_FLOW_TEST_ARTIFACTS": str(artifacts) if artifact_destination else "",
                     "VF_CLI_BUILD_ROOT_FILE": str(build_root_file),
                     "VF_CLI_TEMP_ROOT": str(root),
                     "VF_CLI_COMPILE_STATUS": str(compile_status),
                     "VF_CLI_RUN_STATUS": str(run_status),
                     "VF_CLI_TRANSPORT_STATUS": str(transport_status)},
                capture_output=True, text=True, timeout=10,
            )
            calls = log.read_text().splitlines() if log.exists() else []
            self.assertFalse(evidence.exists(), "selected suite emitted full-gate evidence")
            self.assertFalse(any("record_test_evidence.py" in call for call in calls), calls)
            if build_root_file.exists():
                build_root = Path(build_root_file.read_text().strip())
                self.assertFalse(build_root.exists(), f"harness failed to remove build root: {build_root} (exit {result.returncode})")
            saved_artifacts = ({path.name: path.read_text() for path in artifacts.iterdir()}
                               if artifacts.is_dir() else {})
            if artifact_destination == "file":
                self.assertEqual(artifacts.read_text(), "An invalid destination must remain untouched.")
            return result, calls, saved_artifacts

    def assert_single_compile(self, calls, suite):
        compiles = [call for call in calls if call.startswith("swift ")]
        self.assertEqual(len(compiles), 1, calls)
        self.assertIn(f"tests/{suite}/main.swift", compiles[0])

    def test_selected_suite_builds_and_runs_only_itself_without_evidence(self):
        result, calls, _ = self.invoke_suite("inbox")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_single_compile(calls, "inbox")
        runs = [call for call in calls if call.startswith("run ")]
        self.assertEqual(len(runs), 1, calls)
        self.assertTrue(runs[0].endswith("/inbox"), runs)
        self.assertEqual([call for call in calls if call.startswith("python ")], [
            "python tests/validate_capability_catalog.py",
            "python tests/validate_runtime_manifest.py",
        ])
        self.assertIn("selected unit suite 'inbox' passed; full gate not run", result.stdout)

    def test_compile_and_test_failures_propagate_without_success(self):
        for options, status, expected_runs in (({"compile_status": 23}, 23, 0),
                                              ({"run_status": 29}, 29, 1)):
            with self.subTest(options=options):
                result, calls, _ = self.invoke_suite("inbox", **options)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assert_single_compile(calls, "inbox")
                self.assertEqual(sum(call.startswith("run ") for call in calls), expected_runs)
                self.assertNotIn("passed; full gate not run", result.stdout)
                self.assertIn(f"exit {status}", result.stderr)

    def test_source_review_transport_failure_propagates(self):
        result, calls, _ = self.invoke_suite("source_review", transport_status=31)
        self.assertEqual(result.returncode, 31, result.stderr)
        self.assert_single_compile(calls, "source_review")
        self.assertEqual(sum("transport_proof.py" in call for call in calls), 1, calls)
        self.assertNotIn("passed; full gate not run", result.stdout)
        self.assertIn("FAIL: source_review transport", result.stderr)

    def test_bad_artifact_destination_preserves_failure_and_cleans_build(self):
        for options, status in (({"compile_status": 23}, 23), ({"run_status": 29}, 29)):
            with self.subTest(options=options):
                result, calls, _ = self.invoke_suite("inbox", artifact_destination="file", **options)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assert_single_compile(calls, "inbox")
                self.assertNotIn("passed; full gate not run", result.stdout)

    def test_failed_targeted_suite_retains_runtime_log_and_cleans_build(self):
        result, calls, artifacts = self.invoke_suite("inbox", run_status=29,
                                                   artifact_destination="directory")
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assert_single_compile(calls, "inbox")
        self.assertEqual(artifacts.get("opencode-fixture.log"), "Synthetic runtime failure evidence\n")
        self.assertEqual(artifacts.get("failure.txt"), "Synthetic UI failure evidence\n")

    def test_unknown_suite_never_compiles_or_reports_success(self):
        result, calls, _ = self.invoke_suite("missing_suite")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(any(call.startswith(("swift ", "run ")) for call in calls), calls)
        self.assertIn("Unknown unit suite: missing_suite", result.stderr)
        self.assertNotIn("passed; full gate not run", result.stdout)


if __name__ == "__main__":
    unittest.main()
