#!/usr/bin/env python3
"""Focused executable contract for the preserved-data reading index."""

import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote


SCRIPT = Path(__file__).with_name("export-preserved-local-archive.py")


def write(path: Path, value: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def put(path: Path, value):
    write(path, json.dumps(value))


class ArchiveContract(unittest.TestCase):
    def test_links_originals_without_copying_media_or_indexing_credentials(self):
        with tempfile.TemporaryDirectory(prefix="voiceflow-readable-") as temporary:
            parent = Path(temporary)
            raw = parent / "raw"
            raw.mkdir()
            original_home = Path("/synthetic/voice-flow")
            put(raw / "dictations.json", [{"id": "d1", "time": "2026-01-01", "destination": "kept",
                                             "text": "A private thought", "captureId": "cap-1",
                                             "attachments": [str(original_home / "captures/cap-1/frames/one.jpg")]}])
            put(raw / "messages.json", [{"time": "2026-01-01", "session": "s1", "text": "Legacy note"}])
            put(raw / "inbox.json", [{"time": "2026-01-01", "session": "s1", "text": "Pending note",
                                       "attachments": []}])
            put(raw / "pushes.json", {"s1": [{"text": "Push note"}]})
            put(raw / "slots.json", {"s1": 1})
            put(raw / "queue/queue.json", {"items": [{"id": "q1", "text": "Next thing", "done": False}]})
            write(raw / "assistants/flora/assistant.md", "Persona instructions\n")
            write(raw / "assistants/flora/memory/core.md", "Core memory\n")
            write(raw / "assistants/flora/memory/ledger.md", "Ledger\n")
            write(raw / "assistants/flora/skills/summarize/SKILL.md", "Skill\n")
            write(raw / "knowledge/focus-attention/index.md", "Focus\n")
            put(raw / "captures/cap-1/meta.json", {"id": "cap-1", "frames": [{"file": "frames/one.jpg"}]})
            write(raw / "captures/cap-1/transcript.md", "A narrated capture\n")
            write(raw / "captures/cap-1/frames/one.jpg", "synthetic media bytes")
            write(raw / "captures/cap-1/frames/extra.jpg", "other synthetic media")
            put(raw / "annotations.json", {"version": 2, "items": []})
            write(raw / "watcher/2026-01-01/activity.jsonl", '{"kind":"synthetic"}\n')
            write(raw / "watcher/2026-01-01/one.jpg", "synthetic watcher media")
            write(raw / "watcher/2026-01-01/review.md", "Review\n")
            put(raw / "source-snapshots/source-1/snapshot/meta.json", {"sourceID": "source-1",
                "items": [{"title": "Fetched page", "relativePath": "item.txt"}], "skippedCount": 0})
            write(raw / "source-snapshots/source-1/snapshot/item.txt", "Fetched text\n")
            put(raw / "assistant-sessions.json", {"sessions": [{"id": "held-1", "title": "Held thread",
                "messages": [{"role": "user", "at": 1, "text": "Needs screenshot", "attachmentNote": "one image"}]}]})
            report = parent / "import-report.json"
            put(report, {"skipped": [{"sourceConversationId": "held-1", "reasons": ["missing image"]}]})
            write(raw / "settings.json", "SYNTHETIC_SECRET")
            write(raw / "cloud-sync-account.json", "SYNTHETIC_SECRET")
            write(raw / "sync-token", "SYNTHETIC_SECRET")
            sql = parent / "sqlite-online"
            sql.mkdir()
            for name, tables in (("agent-jobs.sqlite", ("agent_jobs", "agent_runs")),
                                 ("threads.sqlite", ("projects", "threads", "turns", "items", "attachments"))):
                with sqlite3.connect(sql / name) as database:
                    for table in tables:
                        database.execute(f'create table "{table}" (id text)')
            with sqlite3.connect(sql / "cloud-sync.sqlite") as database:
                database.execute("create table cloud_accounts (token text)")
                database.execute("insert into cloud_accounts values ('SYNTHETIC_SECRET')")
            source_before = (raw / "dictations.json").read_bytes()
            output = parent / "readable"
            result = subprocess.run([sys.executable, str(SCRIPT), "--snapshot-root", str(raw),
                "--output-dir", str(output), "--sqlite-root", str(sql), "--import-report", str(report),
                "--original-home", str(original_home)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((output / "receipt.json").read_text())
            self.assertEqual(receipt["unresolved"], [])
            self.assertEqual(receipt["counts"]["dictations"], 1)
            self.assertEqual(receipt["counts"]["sourceItems"], 1)
            self.assertEqual(receipt["counts"]["heldThreads"], 1)
            self.assertEqual(receipt["counts"]["heldMessages"], 1)
            self.assertEqual((raw / "dictations.json").read_bytes(), source_before)
            self.assertFalse(any(file.suffix == ".jpg" for file in output.rglob("*")))
            self.assertEqual(os.stat(output / "INDEX.md").st_mode & 0o777, 0o600)
            self.assertIn("Needs screenshot", (output / "held-history.md").read_text())
            self.assertIn("one.jpg", (output / "captures.md").read_text())
            self.assertIn("Fetched page", (output / "sources/0001.md").read_text())
            for page in output.rglob("*.md"):
                content = page.read_text()
                self.assertNotIn("SYNTHETIC_SECRET", content)
                self.assertNotIn("cloud-sync-account", content)
                for relative in re.findall(r"\]\(([^)]+)\)", content):
                    self.assertTrue((page.parent / unquote(relative)).is_file(), (page, relative))


if __name__ == "__main__":
    unittest.main()
