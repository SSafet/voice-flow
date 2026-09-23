#!/usr/bin/env python3
"""Build a small, private reading index over an explicit VoiceFlow snapshot.

The original JSON, Markdown, SQLite and media remain authoritative. This command
only writes Markdown pointers and a count/relationship receipt beside the snapshot.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
from urllib.parse import quote


LIVE_HOMES = (Path.home() / ".config" / "voice-flow", Path.home() / ".t3")


def within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def safe_file(root: Path, path: Path) -> Path | None:
    try:
        actual = path.resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    return actual if within(actual, root) and actual.is_file() else None


def read_json(root: Path, path: Path):
    file = safe_file(root, path)
    if file is None:
        raise ValueError(f"Missing or escaping snapshot file: {path.relative_to(root)}")
    return json.loads(file.read_text(encoding="utf-8"))


def visible(value: object, limit: int = 120) -> str:
    text = str(value if value is not None else "").replace("\n", " ").replace("\r", " ")
    text = text[:limit] + ("…" if len(text) > limit else "")
    return re.sub(r"([\\`*_[\]<>|])", r"\\\1", text)


def block(value: object) -> str:
    text = str(value if value is not None else "").replace("\x00", "\\0")
    fence = "~" * max(3, 1 + max((len(x) for x in re.findall(r"~+", text)), default=0))
    return f"{fence}text\n{text}\n{fence}\n"


class Archive:
    def __init__(self, snapshot: Path, output: Path):
        self.snapshot = snapshot
        self.output = output
        self.unresolved: list[str] = []
        self.counts: dict[str, int] = {}

    def link(self, page: Path, target: Path, label: str) -> str:
        relative = os.path.relpath(target, page.parent)
        return f"[{visible(label)}]({quote(relative, safe='/.:')})"

    def write(self, relative: str, content: str):
        path = self.output / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open("x", encoding="utf-8") as stream:
            os.chmod(path, 0o600)
            stream.write(content)
        return path

    def original(self, relative: str) -> Path | None:
        path = self.snapshot / relative
        return safe_file(self.snapshot, path)

    def note_missing(self, category: str, relative: str):
        self.unresolved.append(f"{category}: {relative}")

    def mapped_attachment(self, original: object, original_home: Path | None) -> Path | None:
        if not isinstance(original, str):
            return None
        candidate = Path(original)
        if candidate.is_absolute():
            if original_home is None or not within(candidate, original_home):
                return None
            candidate = self.snapshot / candidate.relative_to(original_home)
        else:
            candidate = self.snapshot / candidate
        return safe_file(self.snapshot, candidate)

    def dictations(self, original_home: Path | None):
        source = self.original("dictations.json")
        if source is None:
            self.counts["dictations"] = 0
            return
        rows = read_json(self.snapshot, source)
        if not isinstance(rows, list):
            raise ValueError("dictations.json must be an array")
        page = self.output / "dictations.md"
        lines = ["# Dictations", "", f"{len(rows)} preserved entries. {self.link(page, source, 'Original JSON')}", ""]
        for index, row in enumerate(rows, 1):
            if not isinstance(row, dict):
                self.note_missing("dictations", f"row {index} is not an object")
                continue
            lines += [f"## {index}. {visible(row.get('time') or row.get('timestamp'))} — {visible(row.get('destination'))}", "",
                      block(row.get("text"))]
            capture_id = row.get("captureId")
            if isinstance(capture_id, str):
                capture = self.original(f"captures/{capture_id}/meta.json")
                if capture:
                    lines += [f"Capture: {self.link(page, capture, capture_id)}", ""]
                else:
                    self.note_missing("dictation capture", capture_id)
            for attachment in row.get("attachments", []) if isinstance(row.get("attachments", []), list) else []:
                mapped = self.mapped_attachment(attachment, original_home)
                if mapped:
                    lines += [f"Attachment: {self.link(page, mapped, mapped.name)}", ""]
                else:
                    self.note_missing("dictation attachment", str(attachment))
        self.counts["dictations"] = len(rows)
        self.write("dictations.md", "\n".join(lines))

    def notes(self, original_home: Path | None):
        page = self.output / "notes-and-queue.md"
        lines = ["# Notes, inbox, queue and focus", "", "Original JSON remains the complete record.", ""]
        for name, heading in (("messages.json", "Legacy messages"), ("inbox.json", "Pending inbox")):
            file = self.original(name)
            if file is None:
                continue
            rows = read_json(self.snapshot, file)
            if not isinstance(rows, list):
                raise ValueError(f"{name} must be an array")
            self.counts[name] = len(rows)
            lines += [f"## {heading} ({len(rows)})", "", self.link(page, file, "Original JSON"), ""]
            for index, row in enumerate(rows, 1):
                if not isinstance(row, dict):
                    self.note_missing(name, f"row {index} is not an object")
                    continue
                lines += [f"### {index}. {visible(row.get('time'))} — session {visible(row.get('session'))}", "",
                          block(row.get("text"))]
                for attachment in row.get("attachments", []) if isinstance(row.get("attachments", []), list) else []:
                    mapped = self.mapped_attachment(attachment, original_home)
                    if mapped:
                        lines += [f"Attachment: {self.link(page, mapped, mapped.name)}", ""]
                    else:
                        self.note_missing("inbox attachment", str(attachment))
        queue = self.original("queue/queue.json")
        if queue:
            data = read_json(self.snapshot, queue)
            items = data.get("items", []) if isinstance(data, dict) else []
            if not isinstance(items, list):
                raise ValueError("queue.json items must be an array")
            self.counts["queueItems"] = len(items)
            lines += [f"## What's next ({len(items)})", "", self.link(page, queue, "Original queue JSON"), ""]
            for item in items:
                if isinstance(item, dict):
                    lines += [f"- {'[x]' if item.get('done') else '[ ]'} {visible(item.get('text'), 500)}"]
            lines += [""]
        for name, label in (("pushes.json", "Push and note records"), ("slots.json", "Focus slots")):
            file = self.original(name)
            if file:
                data = read_json(self.snapshot, file)
                count = len(data) if isinstance(data, (dict, list)) else 0
                self.counts[name] = count
                lines += [f"## {label} ({count})", "", self.link(page, file, "Original JSON"), ""]
        self.write("notes-and-queue.md", "\n".join(lines) + "\n")

    def assistants_and_knowledge(self):
        page = self.output / "assistants-and-knowledge.md"
        lines = ["# Assistant instructions, memory and knowledge", "",
                 "These links open the original authored files; runtime and credential directories are excluded.", ""]
        count = 0
        assistants = self.snapshot / "assistants"
        if assistants.is_dir():
            for assistant in sorted(assistants.iterdir()):
                if not assistant.is_dir() or assistant.is_symlink():
                    continue
                allowed = [assistant / "assistant.md", assistant / "memory/core.md", assistant / "memory/ledger.md"]
                allowed.extend(sorted((assistant / "skills").glob("*/SKILL.md")))
                links = [self.link(page, file, file.relative_to(assistant).as_posix()) for file in allowed
                         if safe_file(self.snapshot, file)]
                if links:
                    count += 1
                    lines += [f"## {visible(assistant.name)}", "", " · ".join(links), ""]
        self.counts["assistants"] = count
        knowledge = self.snapshot / "knowledge"
        kcount = 0
        if knowledge.is_dir():
            for file in sorted(knowledge.rglob("*.md")):
                if safe_file(self.snapshot, file):
                    kcount += 1
                    lines += [f"- {self.link(page, file, file.relative_to(knowledge).as_posix())}"]
        self.counts["knowledgeMarkdown"] = kcount
        self.write("assistants-and-knowledge.md", "\n".join(lines) + "\n")

    def captures(self):
        page = self.output / "captures.md"
        lines = ["# Captures and annotations", "", "Frame links point to original media; no media is copied.", ""]
        root = self.snapshot / "captures"
        referenced: set[Path] = set()
        bundles = 0
        if root.is_dir():
            for meta in sorted(root.glob("*/meta.json")):
                if not safe_file(self.snapshot, meta):
                    continue
                data = read_json(self.snapshot, meta)
                if not isinstance(data, dict):
                    raise ValueError("Capture metadata must be an object")
                bundles += 1
                lines += [f"## {visible(data.get('id') or meta.parent.name)}", "",
                          self.link(page, meta, "Metadata"), ""]
                transcript = safe_file(self.snapshot, meta.parent / "transcript.md")
                if transcript:
                    lines += [self.link(page, transcript, "Transcript and ordered frame index"), ""]
                else:
                    self.note_missing("capture transcript", str(meta.parent.relative_to(self.snapshot)))
                frames = data.get("frames", [])
                if not isinstance(frames, list):
                    raise ValueError("Capture frames must be an array")
                for index, frame in enumerate(frames, 1):
                    rel = frame.get("file") if isinstance(frame, dict) else None
                    if not isinstance(rel, str) or Path(rel).is_absolute() or ".." in Path(rel).parts:
                        self.note_missing("capture frame", f"{meta.parent.name} #{index} invalid path")
                        continue
                    file = safe_file(self.snapshot, meta.parent / rel)
                    if file and within(file, meta.parent.resolve()):
                        referenced.add(file)
                        lines += [f"- Frame {index}: {self.link(page, file, rel)}"]
                    else:
                        self.note_missing("capture frame", f"{meta.parent.name}/{rel}")
                lines += [""]
            extras = [file for file in sorted(root.rglob("*.jpg")) if safe_file(self.snapshot, file) and
                      file.resolve() not in referenced]
            if extras:
                lines += [f"## Other original JPEGs ({len(extras)})", ""]
                lines += [f"- {self.link(page, file, file.relative_to(root).as_posix())}" for file in extras]
        annotations = self.original("annotations.json")
        if annotations:
            data = read_json(self.snapshot, annotations)
            count = len(data.get("items", [])) if isinstance(data, dict) and isinstance(data.get("items"), list) else 0
            lines += ["", f"## Live overlay annotations ({count})", "", self.link(page, annotations, "Original annotation JSON"), ""]
            self.counts["annotations"] = count
        self.counts["captureBundles"] = bundles
        self.counts["captureFrameReferences"] = len(referenced)
        self.counts["otherCaptureJpegs"] = len(extras) if root.is_dir() else 0
        self.write("captures.md", "\n".join(lines) + "\n")

    def watcher(self):
        page = self.output / "watcher.md"
        lines = ["# Screen watcher", "", "Days link to original activity/review files and media folders. Frames are not copied or reindexed one by one.", ""]
        root = self.snapshot / "watcher"
        days = 0
        frames = 0
        if root.is_dir():
            for day in sorted(root.iterdir()):
                if not day.is_dir() or day.is_symlink():
                    continue
                days += 1
                jpgs = (file for file in day.rglob("*.jpg") if safe_file(self.snapshot, file))
                count = sum(1 for _ in jpgs)
                frames += count
                lines += [f"## {visible(day.name)} — {count} original frames", "",
                          f"Browse original folder: `{day.relative_to(self.snapshot).as_posix()}/`", ""]
                for pattern in ("*.jsonl", "*.md"):
                    for file in sorted(day.rglob(pattern)):
                        if safe_file(self.snapshot, file):
                            lines += [f"- {self.link(page, file, file.relative_to(day).as_posix())}"]
                lines += [""]
            for file in sorted(root.iterdir()):
                if file.suffix == ".md" and safe_file(self.snapshot, file):
                    lines += [f"- {self.link(page, file, file.name)}"]
        self.counts["watcherDays"] = days
        self.counts["watcherFrames"] = frames
        self.write("watcher.md", "\n".join(lines) + "\n")

    def sources(self):
        page = self.output / "source-snapshots.md"
        lines = ["# Collected and fetched source snapshots", "",
                 "Each page links its original metadata and text items. Collection metadata remains the original record.", ""]
        root = self.snapshot / "source-snapshots"
        snapshots = 0
        items = 0
        if root.is_dir():
            for meta in sorted(root.rglob("*.json")):
                if not safe_file(self.snapshot, meta):
                    continue
                data = read_json(self.snapshot, meta)
                if not isinstance(data, dict) or not isinstance(data.get("items"), list):
                    self.note_missing("source metadata", str(meta.relative_to(self.snapshot)))
                    continue
                snapshots += 1
                rows = data["items"]
                name = f"sources/{snapshots:04d}.md"
                detail = self.output / name
                detail_lines = [f"# Source snapshot {snapshots}", "", self.link(detail, meta, "Original metadata"), "",
                                f"Source ID: `{visible(data.get('sourceID'))}` · Items: {len(rows)} · Skipped: {data.get('skippedCount', 0)}", ""]
                for index, item in enumerate(rows, 1):
                    items += 1
                    rel = item.get("relativePath") if isinstance(item, dict) else None
                    if not isinstance(rel, str) or Path(rel).is_absolute() or ".." in Path(rel).parts:
                        self.note_missing("source item", f"{meta.relative_to(self.snapshot)} #{index} invalid path")
                        continue
                    file = safe_file(self.snapshot, meta.parent / rel)
                    if file and within(file, meta.parent.resolve()):
                        detail_lines += [f"- {self.link(detail, file, f'Item {index}')} — {visible(item.get('title'), 160)}"]
                    else:
                        self.note_missing("source item", f"{meta.relative_to(self.snapshot)} #{index}: {rel}")
                self.write(name, "\n".join(detail_lines) + "\n")
                lines += [f"- {self.link(page, detail, f'Snapshot {snapshots}')} — {visible(data.get('sourceID'))}; {len(rows)} items"]
        self.counts["sourceSnapshots"] = snapshots
        self.counts["sourceItems"] = items
        self.write("source-snapshots.md", "\n".join(lines) + "\n")

    def held_history(self, report: Path | None):
        page = self.output / "held-history.md"
        source = self.original("assistant-sessions.json")
        lines = ["# Legacy assistant history", ""]
        if source is None:
            self.write("held-history.md", "\n".join(lines) + "\n")
            return
        lines += ["The full original history remains available even when a conversation needs an unresolved attachment.",
                  self.link(page, source, "Full original assistant-sessions JSON"), ""]
        if report:
            data = json.loads(report.read_text(encoding="utf-8"))
            skipped = data.get("skipped", [])
            history = read_json(self.snapshot, source)
            sessions = {s.get("id"): s for s in history.get("sessions", []) if isinstance(s, dict)}
            held_messages = 0
            if not isinstance(skipped, list):
                raise ValueError("Import report skipped must be an array")
            for row in skipped:
                if not isinstance(row, dict):
                    continue
                source_id = row.get("sourceConversationId")
                session = sessions.get(source_id)
                if session is None:
                    self.note_missing("held history", str(source_id))
                    continue
                lines += [f"## {visible(session.get('title') or source_id)}", "",
                          f"Source conversation: `{visible(source_id)}`", "",
                          "This conversation remains in the original JSON pending the reported attachment decision.", ""]
                for reason in row.get("reasons", []) if isinstance(row.get("reasons"), list) else []:
                    lines += [f"- Blocker: {visible(reason, 500)}"]
                lines += [""]
                for index, message in enumerate(session.get("messages", []), 1):
                    if not isinstance(message, dict):
                        continue
                    held_messages += 1
                    lines += [f"### {index}. {visible(message.get('role'))} — {visible(message.get('at'))}", "",
                              block(message.get("text"))]
                    if message.get("attachmentNote"):
                        lines += [f"Attachment note: {visible(message['attachmentNote'], 500)}", ""]
            self.counts["heldThreads"] = len(skipped)
            self.counts["heldMessages"] = held_messages
        self.write("held-history.md", "\n".join(lines) + "\n")

    def sqlite(self, sqlite_root: Path | None):
        page = self.output / "sqlite.md"
        lines = ["# Existing SQLite archives", "",
                 "These are online snapshot copies of the original databases. Only user-content tables are inventoried here; cloud account/auth data is excluded.", ""]
        for name, tables in (("agent-jobs.sqlite", ("agent_jobs", "agent_runs")),
                             ("threads.sqlite", ("projects", "threads", "turns", "items", "attachments"))):
            if sqlite_root is None:
                continue
            file = safe_file(sqlite_root, sqlite_root / name)
            if file is None:
                continue
            connection = sqlite3.connect(f"file:{quote(str(file), safe='/')}?mode=ro&immutable=1", uri=True)
            try:
                connection.execute("pragma query_only=on")
                lines += [f"## {name}", "", self.link(page, file, "Original SQLite snapshot"), ""]
                for table in tables:
                    exists = connection.execute("select 1 from sqlite_master where type='table' and name=?", (table,)).fetchone()
                    if exists:
                        count = connection.execute(f'select count(*) from "{table}"').fetchone()[0]
                        self.counts[f"{name}:{table}"] = count
                        lines += [f"- `{table}`: {count} rows"]
                lines += [""]
            finally:
                connection.close()
        self.write("sqlite.md", "\n".join(lines) + "\n")

    def finish(self):
        page = self.output / "INDEX.md"
        sections = (("Dictations", "dictations.md"), ("Notes, inbox, queue and focus", "notes-and-queue.md"),
                    ("Assistant instructions and knowledge", "assistants-and-knowledge.md"),
                    ("Captures and annotations", "captures.md"), ("Watcher", "watcher.md"),
                    ("Fetched source snapshots", "source-snapshots.md"),
                    ("Held assistant history", "held-history.md"), ("SQLite snapshots", "sqlite.md"))
        lines = ["# Preserved VoiceFlow local data", "",
                 "This is a reading index over an explicit preserved snapshot. The linked originals remain the record; nothing here starts a provider or changes the daily app.", ""]
        lines += [f"- {self.link(page, self.output / file, title)}" for title, file in sections
                  if (self.output / file).is_file()]
        lines += ["", f"Unresolved archive links: {len(self.unresolved)}. Held conversation attachment decisions are listed separately in Held assistant history. See `receipt.json` for exact paths and reasons.", ""]
        self.write("INDEX.md", "\n".join(lines))
        self.write("receipt.json", json.dumps({"version": 1, "counts": self.counts,
                                                "unresolved": self.unresolved}, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sqlite-root", type=Path)
    parser.add_argument("--import-report", type=Path)
    parser.add_argument("--original-home", type=Path, help="Original path prefix for attachment links; never opened")
    args = parser.parse_args()
    for label, path in (("snapshot root", args.snapshot_root), ("output dir", args.output_dir)):
        if not path.is_absolute():
            parser.error(f"{label} must be absolute")
    snapshot = args.snapshot_root.resolve(strict=True)
    if not snapshot.is_dir() or any(within(snapshot, live.resolve()) for live in LIVE_HOMES):
        parser.error("snapshot root must be an isolated preserved directory")
    output = args.output_dir
    parent = output.parent.resolve(strict=True)
    if parent != snapshot.parent or output.exists():
        parser.error("output must be a new sibling directory beside the snapshot")
    sqlite_root = args.sqlite_root.resolve(strict=True) if args.sqlite_root else None
    if sqlite_root and (sqlite_root.parent != snapshot.parent or not sqlite_root.is_dir()):
        parser.error("SQLite root must be a sibling snapshot directory")
    original_home = args.original_home.resolve() if args.original_home else None
    if original_home and not args.original_home.is_absolute():
        parser.error("original home must be absolute")
    report = args.import_report.resolve(strict=True) if args.import_report else None
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=parent))
    os.chmod(stage, 0o700)
    try:
        archive = Archive(snapshot, stage)
        archive.dictations(original_home)
        archive.notes(original_home)
        archive.assistants_and_knowledge()
        archive.captures()
        archive.watcher()
        archive.sources()
        archive.held_history(report)
        archive.sqlite(sqlite_root)
        archive.finish()
        stage.rename(output)
    except BaseException:
        shutil.rmtree(stage)
        raise
    print(json.dumps({"output": str(output), "counts": archive.counts,
                      "unresolvedReferences": len(archive.unresolved)}))


if __name__ == "__main__":
    main()
