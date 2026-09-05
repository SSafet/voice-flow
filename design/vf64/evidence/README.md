# VF-64 delivery proof

The main Voice Flow window now brings Data, Assistants, Automations, conversations, Inbox, Speech and Settings into one workspace. Sources have inspectable local copies, collection health/history, editable usage instructions and explicit assistant/automation assignments.

Installed September 5, 2026 at `/Applications/Voice Flow.app`, signed with the existing Developer ID. `codesign --verify --deep --strict` passed and the dictation backend started successfully. The installed source collectors loaded 200 dictations, 27 assistant conversations and seven capture bundles without errors. [Installation](installation.log), [startup](installed-startup.log), [source health](installed-source-health.json), [final source hashes](final-source-sha256.json), [binary hash](installed-binary-sha256.txt).

## Signed application walkthrough

**Passed all 10 walkthrough checks**, plus a supplemental canonical reply/header check at both window sizes, using the final signed build. [Machine-readable report](vf64-report.json), [walkthrough output](signed-workspace.log), [provider request evidence](provider-requests.jsonl).

The walkthrough connected email/document sources, inspected actual saved content and history, edited instructions, recovered from collection failures, paused/resumed collection, preserved unsaved navigation drafts, saved assistant and independent automation selections, and completed both review paths. Provider request assertions proved the selected evidence and guidance reached the model with no tools; unselected documents stayed out of the assistant request and original email bytes remained unchanged. Saving source settings also preserved a 30-second automation runtime. All existing navigation destinations worked at 720×540, and collected copies survived app restart.

| Screenshot | What it proves |
| --- | --- |
| [Data inventory at laptop size](sources-inventory-720.png) | Connected sources and collection status in the persistent workspace |
| [Collected email contents](email-inspect-920.png) | Actual saved copy is readable inside the app |
| [Actual review conversation](review-thread-720.png) | Canonical reply with the disabled Review copies · OpenRouter header |
| [Assistant assignment](assistant-source-selection-920.png) | Explicit source selection and copies-only mode |
| [Automation assignment](automation-source-selection-920.png) | Independent selection, access mode and model configuration |
| [Integrated settings](legacy-settings-720.png) | Existing settings remain reachable in the workspace |
| [Source detail](sources-final-920.png) | Collection health, evidence and configuration |
| [After restart](email-after-restart.png) | Saved copies survive relaunch |

## Automated verification

- Full `scripts/test-agent-harness.sh --unit`: passed, including production and QA compilation, 76 registered checks and nine transcription tests. [Full output](unit-gate.log), [registry evidence](unit-evidence.json).
- Real HTTP source collection: success, changed content, failure retaining the last good copy, oversized responses, pause/cancellation, independent polling and retention: passed in the full gate.
- Copies-only review through the production gateway: four real loopback model requests, zero mailbox requests, no exposed tools, attempted action rejected, delayed upstream cancellation and no late final events: passed. [Details](../source-review-proof.md).
- Provider fixture regression: all three tests passed, covering unchanged streaming output, ordinary completions and action responses retained for rejection. [Output](provider-fixture-tests.log).

The full gate used the exact Swift files listed in [unit source hashes](unit-tested-source-sha256.json). Subsequent changes were limited to two automation duration/interval formatting lines and the two Manage sources button styles; the final signed walkthrough and production build validate those changes.

## Scope

Website sources read public HTTP(S) text/HTML/JSON endpoints. Folder sources read text documents and logs. Email sources collect exported EML/mbox files; they do not sync a live mailbox. Collection runs while Voice Flow is open, with visible limits and retention. Review copies only uses an OpenRouter model/key and has no action tools; normal assistant access retains its existing permissions.

Model evaluations here use deterministic local provider fixtures, not a paid live model. Screenshots show real AppKit views in an isolated signed app using synthetic data.

## Reproduce

```sh
./scripts/test-agent-harness.sh --unit
python3 -m unittest discover -s tests -p test_fake_openai_server.py
VOICE_FLOW_QA_OPTIMIZATION=-Onone VOICE_FLOW_QA_APP_DEST='/tmp/vf64-proof/Voice Flow QA.app' ./scripts/install-agent-harness-qa.sh
python3 tests/vf64_workspace_e2e.py --app '/tmp/vf64-proof/Voice Flow QA.app' --root /tmp/vf64-proof/fresh-run --artifacts /tmp/vf64-proof/fresh-artifacts
```

Use a fresh empty isolated root. The visual walkthrough used a signed unoptimized QA build; the full gate and installed production build used optimization. Do not relaunch the daily app through `install.sh --relaunch` during a walkthrough: its existing process-name termination also stops the QA app.
