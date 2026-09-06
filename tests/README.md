# Verification

Run the deterministic gate from the repository root:

```bash
./scripts/test-agent-harness.sh --unit
```

This compiles the release and QA apps, checks that QA routes are absent from
the release binary, and runs the Swift contracts plus Python backend, provider
fixture, harness CLI, and evidence tests. It creates an isolated configuration
root under `/tmp` and removes the build directory on exit. Python backend tests
use `.venv`; create it with `uv sync` if needed.

## Fast feedback

Run one unit suite while developing:

```bash
./scripts/test-agent-harness.sh --unit --only inbox
./scripts/test-agent-harness.sh --unit --only backend_protocol
./scripts/test-agent-harness.sh --unit --only data_sources
./scripts/test-agent-harness.sh --unit --only capture_store
./scripts/test-agent-harness.sh --unit --only codex_appserver
./scripts/test-agent-harness.sh --unit --only opencode_http
./scripts/test-agent-harness.sh --unit --only workspace_ui
```

Suite names match the `compile_and_run` or `run_unit_command` names in the
script. `app` runs both app builds and the QA-route checks. An unknown suite
fails. Each build and test prints its duration, so slow or failing stages are
visible.

`--only` is available for the unit tier. It skips unrelated app builds and
tests, and never emits full-gate evidence. Run the full unit gate before
considering an integrated change verified.

`workspace_ui` exercises native AppKit rows, composers, and setup editors with
isolated data, including keyboard/accessibility activation and draft retention.

## Evidence and higher tiers

The full harness records successful suite completions in an execution journal.
Evidence generation requires all suites for the selected tier and checks that
the source fingerprint is unchanged since the run started. The evidence embeds
the journal; the catalog validator verifies it again. A catalog entry is a
capability-to-suite mapping, not a measurement of line or branch coverage.

The default evidence output is `/tmp/voice-flow-agent-evidence-unit.json` for
the unit tier. Set `VOICE_FLOW_EVIDENCE_PATH` to keep the result elsewhere.
Set `VOICE_FLOW_TEST_ARTIFACTS` to a directory to retain execution receipts,
runtime logs, and available canary/UI artifacts on success or failure:

```bash
VOICE_FLOW_TEST_ARTIFACTS=/tmp/voice-flow-diagnostics ./scripts/test-agent-harness.sh --live
```

An unavailable artifact destination does not mask a test failure or prevent
process/build-directory cleanup. Receipts from an incomplete run are diagnostic
data; they are insufficient to produce passing gate evidence.

`--live` adds real runtime probes; `--e2e` adds isolated signed-app interaction;
`--nightly` adds a two-hour soak; `--release` includes the four-hour soak.
These tiers have additional runtime, account, or desktop prerequisites. A unit
pass does not claim those checks ran. See `tests/test_registry.json` for the
required suites and mappings for each tier.
