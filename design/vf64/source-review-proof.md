# Copies-only review: implementation and proof

Implemented explicit source selections and the **Review copies only** execution mode for assistants and automations. Automations store their own selections; later assistant edits cannot change them. Existing assistants/jobs migrate to no sources and normal access. Unknown persisted mode values fail safe to copies-only review.

A copies-only turn makes one app-owned model completion through Voice Flow's existing OpenRouter gateway. It starts neither Codex nor OpenCode, registers no agent-tool session, exposes no tools/functions, and never interprets model output as commands. Provider replies containing tool/function actions are rejected. Existing normal runtime behavior remains available under **Normal assistant access**.

Sources are frozen at turn start and included on resumed as well as fresh turns. Missing sources or sources with no retained successful copy fail before a model call. A failed refresh retains the last good copy with its collection timestamp and failure. Source guidance and imported evidence stay separate. Review turns invalidate native runtime bindings so switching back rebuilds from canonical history.

## Verification

- `tests/source_review/main.swift`: passed. Tests assistant duplication/reopen, independent automation selection, source instruction changes, frozen evidence, stale/missing source handling, actual outgoing selected context, no tools/functions, rejection of action replies, credential failure without fallback, cancellation, unchanged mailbox fixture, unknown mode safety, and canonical history reseeding.
- `tests/model_gateway/main.swift`: existing streaming, authorization, and budget regression passed after adding upstream cancellation.
- `tests/assistants/main.swift`: passed, including raw legacy assistant.md save/reopen with source selection and copies-only mode (new fields are appended even when absent from the original frontmatter order).
- `tests/agent_jobs/main.swift`: passed, including additive legacy migration with empty source selections and standard access.
- `tests/agent_prompt/main.swift`: passed, including source context on resumed turns.
- `python3 tests/source_review/transport_proof.py /tmp/vf-source-review-tests`: passed using the production SourceReviewRuntime → ModelGateway → URLSession path against a local model/mailbox HTTP fixture.

The gateway also tracks each accepted client task. Stopping one gateway or disconnecting its client cancels its in-flight provider request, without cancelling another gateway. A delayed HTTP fixture verifies prompt cancellation, no late final response, and successful subsequent review. This proves local request cancellation, not a provider billing guarantee.

Actual HTTP proof output:

```json
{"delayed_upstream_cancelled":true,"gateway_credential_replacement":true,"gateway_output_limit":512,"late_final_events":0,"mailbox_requests":0,"malicious_action_rejected":true,"model_requests":4,"result":"passed","subsequent_gateway_request_passed":true,"tools_exposed":false}
```

The HTTP fixture verifies four real model requests (normal response, attempted tool action, cancelled delayed response, and successful response after cancellation), the gateway's credential replacement and output cap, and zero requests to mailbox routes. This is a deterministic local transport test, not a paid live OpenRouter model evaluation.

The review mode requires an OpenRouter key/model even when the normal runtime picker says Codex. The ordinary runtime's permissions remain unchanged; selecting source copies alone is not a security boundary. The no-actions boundary is the separate copies-only execution path.

## Integration audit fixes

The legacy New automation alert now initializes source options and saves its exact source IDs and access mode; choosing Review copies only can no longer accidentally create a normal-access automation. Its OpenRouter model check applies in review mode regardless of the normal runtime picker. The QA editor and QA job creation reflect the same configuration.

The conversation header now resolves access from the active automation first, then the frozen foreground turn, then the saved Assistant default. A normal-access automation owned by a copies-only Assistant cannot be mislabeled as contained.
