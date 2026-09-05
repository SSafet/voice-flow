#!/usr/bin/env python3
"""VF-64 focused signed-app walkthrough using real AppKit views and local fixtures.

Build with scripts/install-agent-harness-qa.sh; this test never uses the daily app's
config root, mailbox, screenshots, credentials, or keyboard input.
"""
from __future__ import annotations

import argparse
import http.client
import json
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import time
from typing import Any

from e2e_agent_harness import SignedAppGate, expect, png_channel_range, scaffold_assistant, wait_for


class WorkspaceGate(SignedAppGate):
    def qa(self, method: str, path: str, payload: dict[str, Any] | None = None,
           expect_status: int = 200, token: str | None = None) -> Any:
        # Retry only a failed loopback TCP handshake, before any HTTP request
        # bytes are sent. A handler or response failure is never replayed.
        connection = None
        for attempt in range(4):
            candidate = http.client.HTTPConnection("127.0.0.1", self.qa_port, timeout=2)
            try:
                candidate.connect()
                connection = candidate
                break
            except (TimeoutError, socket.timeout):
                candidate.close()
                if attempt == 3:
                    raise
                print(f"Retrying local TCP connection for {method} {path}", flush=True)
                time.sleep(0.15)
        assert connection is not None
        try:
            connection.sock.settimeout(10)
            body = None if payload is None else json.dumps(payload).encode()
            headers = {"Accept": "application/json", "Authorization": "Bearer " + (self.token if token is None else token)}
            if body is not None:
                headers["Content-Type"] = "application/json"
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read()
            result = json.loads(raw) if raw else {}
            expect(response.status == expect_status,
                f"{method} {path}: HTTP {response.status}, expected {expect_status}: {result}")
            return result
        finally:
            connection.close()

    def workspace(self, destination: str, **payload: Any) -> dict[str, Any]:
        return self.qa("POST", "/__qa/workspace", {"destination": destination, **payload})

    def sources(self, action: str | None = None, **payload: Any) -> dict[str, Any]:
        if action is not None:
            self.qa("POST", "/__qa/sources", {"action": action, **payload})
        return self.qa("GET", "/__qa/sources")

    def source(self, source_id: str) -> dict[str, Any]:
        return next(row for row in self.sources()["sources"] if row["id"] == source_id)

    def snapshot(self, name: str) -> None:
        time.sleep(0.18)  # Allow the panel's explicit-open fade and layout to finish.
        result = self.qa("POST", "/__qa/ui/snapshot", {})
        path = Path(result["path"])
        expect(path.exists() and png_channel_range(path) > 20, f"Blank AppKit snapshot: {name}")
        shutil.copy2(path, self.artifacts / f"{name}.png")
        print(f"Captured {name}", flush=True)
        ui = self.state()["ui"]
        for suffix, logical_width in [("-920", 920), ("-720", 720)]:
            if name.endswith(suffix):
                expect(ui["controls"]["workspace_width"] == logical_width,
                    f"Workspace width for {name} was {ui['controls']['workspace_width']}")
        (self.artifacts / f"{name}.json").write_text(json.dumps(ui, indent=2) + "\n")

    def create_source(self, kind: str, name: str, location: Path, instructions: str) -> str:
        self.sources("connect")
        self.sources("edit", kind=kind, name=name, location=str(location), instructions=instructions)
        self.snapshot(f"connect-{kind}")
        result = self.sources("save")
        expect(not result["ui"]["error"], f"Source form failed: {result}")
        source_id = next(row["id"] for row in result["sources"] if row["name"] == name)
        self.sources("refresh", source_id=source_id)
        wait_for(f"{name} collected", lambda: self.source(source_id)["status"].get("itemCount", 0) > 0)
        return source_id

    def verify_workspace(self) -> None:
        fixtures = self.root / "fixtures"
        mail = fixtures / "mail"
        notes = fixtures / "notes"
        mail.mkdir(parents=True)
        notes.mkdir()
        (mail / "customer.eml").write_text(
            "From: customer@example.test\nTo: owner@example.test\n"
            "Subject: Product feedback\nDate: Sat, 5 Sep 2026 08:00:00 +0000\n"
            "Content-Type: text/plain; charset=utf-8\n\n"
            "VF64_EMAIL_EVIDENCE: The dictation recovered my long message.\n")
        mail_before = (mail / "customer.eml").read_bytes()
        (notes / "research.md").write_text(
            "# Product research\nVF64_DOCUMENT_EVIDENCE: Cite the collected document.\n")
        self.workspace("sources", width=920, height=680)
        self.snapshot("sources-inventory-920")
        expect(self.state()["ui"]["conversation_focus"] == "none", "Data claimed conversation capture focus")
        self.sources("connect")
        result = self.sources("save", kind="website", name="Invalid website", location="not a URL")
        expect(bool(result["ui"]["error"]), "Invalid source URL was accepted")
        self.snapshot("source-connect-error")
        self.sources("inventory")
        mail_id = self.create_source("emailCopies", "Customer email copies", mail,
            "Summarize customer requests from these collected copies. Cite the message subject; never send email.")
        self.sources("open", source_id=mail_id)
        self.snapshot("email-detail-920")
        self.sources("item", source_id=mail_id)
        self.snapshot("email-inspect-920")
        self.sources("back")
        self.sources("items", source_id=mail_id)
        self.snapshot("email-all-items-920")
        self.sources("back")
        self.sources("history", source_id=mail_id)
        self.snapshot("email-collection-history-920")
        self.sources("back")
        self.sources("edit", instructions="VF64_SOURCE_INSTRUCTIONS: Use only saved copies. Cite evidence.")
        self.sources("save")
        expect(self.source(mail_id)["instructions"] == "VF64_SOURCE_INSTRUCTIONS: Use only saved copies. Cite evidence.",
            "Source instructions did not persist")
        self.snapshot("email-instructions-saved")
        notes_id = self.create_source("localFolder", "Research notes", notes,
            "Use these local research notes as supporting evidence.")
        renamed = fixtures / "notes-offline"
        notes.rename(renamed)
        self.sources("refresh", source_id=notes_id)
        wait_for("collection error surfaced", lambda: self.source(notes_id)["status"].get("lastError"))
        expect(self.source(notes_id)["status"]["itemCount"] > 0, "Collection error erased the last-good copy")
        self.sources("open", source_id=notes_id)
        self.snapshot("source-stale-last-good")
        renamed.rename(notes)
        self.sources("refresh", source_id=notes_id)
        wait_for("collection recovered", lambda: not self.source(notes_id)["status"].get("lastError"))
        self.sources("pause", source_id=notes_id, paused=True)
        expect(self.source(notes_id)["enabled"] is False, "Pause did not persist")
        expect(self.source(notes_id)["status"]["itemCount"] > 0, "Pause erased saved copies")
        self.snapshot("source-paused")
        self.sources("pause", source_id=notes_id, paused=False)
        self.record("collection_failure_last_good_recovery_pause")
        self.sources("inventory")
        self.workspace("sources", width=720, height=540)
        self.snapshot("sources-inventory-720")
        self.sources("open", source_id=mail_id)
        self.snapshot("email-detail-720")
        self.record("source_connect_validate_collect_inspect_instructions_two_sizes")

        # Consumer links open the actual existing settings/editor controls.
        self.workspace("assistants", width=920, height=680,
            consumer_type="assistant", consumer_id="flora")
        selected = self.qa("POST", "/__qa/workspace/selection", {
            "selected_source_ids": [mail_id], "source_access_mode": "reviewCopies", "save": True})
        expect(mail_id in json.dumps(selected), f"Assistant source selection missing: {selected}")
        self.snapshot("assistant-source-selection-920")
        self.workspace("sources")
        self.workspace("assistants")
        returned = self.qa("POST", "/__qa/workspace/selection", {})
        expect(returned["selected_source_ids"] == [mail_id], "Data visit lost assistant selection")
        self.qa("POST", "/__qa/workspace/selection", {
            "selected_source_ids": [notes_id], "source_access_mode": "reviewCopies"})
        self.workspace("threads")
        self.workspace("assistants")
        draft = self.qa("POST", "/__qa/workspace/selection", {})
        expect(draft["selected_source_ids"] == [notes_id], "Cross-section navigation lost unsaved source selection")
        self.qa("POST", "/__qa/workspace/selection", {
            "selected_source_ids": [mail_id], "source_access_mode": "reviewCopies", "save": True})
        self.snapshot("assistant-selection-return")
        self.record("assistant_explicit_source_selection_and_unsaved_navigation_draft")

        self.configure_runtime()
        self.submit("PLAIN_TEXT_TURN: Review the selected saved email copies.", expected="gateway ok")
        conversation_id = self.state()["assistant"]["conversation_id"]
        self.qa("POST", "/__qa/panel", {"tab": "agents", "agents_destination": "threads",
            "thread_source": "assistant", "thread_id": conversation_id})
        self.snapshot("assistant-review-result")
        expect(self.state()["ui"]["controls"]["runtime_title"].startswith("Review copies"),
            "Canonical review thread did not expose its restricted runtime label")
        requests = [json.loads(line) for line in (self.artifacts / "provider-requests.jsonl").read_text().splitlines()]
        review = requests[-1]
        expect(review.get("stream") is False and review.get("tool_count") == 0,
            f"Review exposed agent tools or wrong protocol: {review}")
        expect(review.get("vf64_email_evidence") and review.get("vf64_source_instructions")
            and not review.get("vf64_document_evidence"), f"Assistant selection boundary failed: {review}")
        self.record("assistant_review_copies_turn_selected_evidence_no_tools")
        job_id = self.create_job("PLAIN_TEXT_TURN: Review saved customer email copies.", model_id="test/model")
        self.workspace("automations", consumer_type="automation", consumer_id=job_id)
        selected = self.qa("POST", "/__qa/workspace/selection", {
            "selected_source_ids": [mail_id, notes_id], "source_access_mode": "reviewCopies"})
        expect(mail_id in json.dumps(selected) and notes_id in json.dumps(selected),
            f"Automation exact selection missing: {selected}")
        self.snapshot("automation-source-selection-920")
        saved = self.qa("POST", "/__qa/workspace/selection", {"save": True})
        expect(not saved["error"], f"Automation save failed: {saved}")
        self.workspace("automations", consumer_type="automation", consumer_id=job_id)
        reloaded = self.qa("POST", "/__qa/workspace/selection", {})
        expect(set(reloaded["selected_source_ids"]) == {mail_id, notes_id}, "Automation selection did not persist")
        with sqlite3.connect(f"file:{self.root / 'agent-jobs.sqlite'}?mode=ro", uri=True) as database:
            duration = database.execute("SELECT max_duration_seconds FROM agent_jobs WHERE id = ?", (job_id,)).fetchone()[0]
        expect(duration == 30, f"Editing sources changed the valid 30-second runtime to {duration}")
        (self.artifacts / "automation-roundtrip.json").write_text(json.dumps({
            "job_id": job_id, "max_duration_seconds": duration, "selected_source_ids": reloaded["selected_source_ids"]}, indent=2) + "\n")
        self.run_job(job_id)
        wait_for("review automation completed", lambda: self.job(job_id)["state"] == "completed", timeout=45)
        requests = [json.loads(line) for line in (self.artifacts / "provider-requests.jsonl").read_text().splitlines()]
        review = requests[-1]
        expect(review.get("vf64_email_evidence") and review.get("vf64_document_evidence")
            and review.get("tool_count") == 0, f"Automation selection boundary failed: {review}")
        expect((mail / "customer.eml").read_bytes() == mail_before, "Review changed the original email file")
        self.record("automation_selected_copy_review_completed_no_tools_original_unchanged")

        # Existing daily surfaces remain readable at laptop size.
        for destination in ["now", "inbox", "threads", "assistants", "automations", "speech", "settings"]:
            self.workspace(destination, width=720, height=540)
            self.snapshot(f"legacy-{destination}-720")
            if destination in {"inbox", "speech", "settings"}:
                expect(self.state()["ui"]["conversation_focus"] == "none",
                    f"{destination} claimed assistant capture focus")
        self.record("legacy_daily_surfaces_and_capture_focus")
        self.workspace("sources", width=920, height=680)
        self.sources("open", source_id=mail_id)
        self.snapshot("sources-final-920")
        (self.artifacts / "sources-final.json").write_text(json.dumps(self.sources(), indent=2) + "\n")
        self.terminate_app()
        self.start_app()
        expect(self.source(mail_id)["status"]["itemCount"] > 0, "Restart lost collected email copies")
        self.workspace("sources", width=920, height=680)
        self.sources("open", source_id=mail_id)
        self.snapshot("email-after-restart")
        self.record("sources_and_copies_survive_restart")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    expect(not any(args.root.iterdir()), "VF-64 QA root must be fresh and empty")
    scaffold_assistant(args.root)
    gate = WorkspaceGate(args.app.resolve(), args.root.resolve(), args.repo.resolve(), args.artifacts.resolve())
    def interrupt(signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt(f"Signal {signum}")
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupt)
    report: dict[str, Any] = {"ok": False, "checks": gate.checks}
    try:
        gate.verify_bundle()
        gate.start_provider()
        gate.start_app()
        gate.verify_auth_and_isolation()
        gate.verify_workspace()
        report["ok"] = True
    except BaseException as error:
        report["error"] = str(error)
        if gate.app_process is not None and gate.app_process.poll() is None:
            with (args.artifacts / "failure-sockets.txt").open("w") as sockets:
                subprocess.run(["lsof", "-nP", "-a", "-p", str(gate.app_process.pid), "-i"], stdout=sockets)
            subprocess.run(["sample", str(gate.app_process.pid), "2", "-file",
                str(args.artifacts / "failure-sample.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise
    finally:
        report.update({"app": str(gate.app), "root": str(gate.root), "artifacts": str(gate.artifacts)})
        (args.artifacts / "vf64-report.json").write_text(json.dumps(report, indent=2) + "\n")
        gate.cleanup()
    print(f"VF-64 signed workspace walkthrough passed: {len(gate.checks)} checks")


if __name__ == "__main__":
    main()
