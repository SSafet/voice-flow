"""Opt-in real Codex proof of assistant focus replacement and review interpretation.

Uses only a disposable workspace and synthetic context. The compiled daily_focus
test helper emits the shipping DailyFocus.prompt, so the model sees real policy.
Usage: python3 tests/daily_focus/verify_live.py /tmp/vf-daily-focus <evidence-dir>
"""
import datetime as dt
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
helper = pathlib.Path(sys.argv[1]).resolve()
evidence = pathlib.Path(sys.argv[2]).resolve()
evidence.mkdir(parents=True, exist_ok=True)
codex = shutil.which("codex")
assert codex, "Codex CLI unavailable"

with tempfile.TemporaryDirectory(prefix="vf-focus-live-") as directory:
    root = pathlib.Path(directory)
    focus = root / "FOCUS-NOW.md"
    receipts = []

    def invoke(name, instructions, request):
        output = root / (name + "-reply.txt")
        command = [codex, "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                   "--skip-git-repo-check", "--sandbox", "workspace-write", "-m", "gpt-5.6-luna",
                   "-c", 'model_reasoning_effort="low"', "-c", "mcp_servers={}",
                   "-c", "developer_instructions=" + json.dumps(instructions),
                   "-o", str(output), request]
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=100)
        assert result.returncode == 0, f"{name}: {result.stderr[-1500:]}"
        reply = output.read_text()
        (evidence / (name + ".txt")).write_text(reply)
        receipts.append({"case": name, "exit_code": result.returncode, "reply": reply})
        return reply

    def prompt():
        return subprocess.check_output([str(helper), "--prompt", str(focus)], text=True)

    def verify_file(expected, absent=None):
        text = focus.read_text()
        header, body = text.split("\n", 1)
        assert header.startswith("Updated: "), text
        timestamp = dt.datetime.fromisoformat(header[9:].replace("Z", "+00:00"))
        assert timestamp.astimezone().date() == dt.datetime.now().astimezone().date(), text
        assert expected in body and (not absent or absent not in body), text
        return text

    invoke("01-new-focus", prompt(), "Today I'm focusing on the ORCHID release checklist. Save that as my focus.")
    first = verify_file("ORCHID")
    (evidence / "first-focus.md").write_text(first)

    # Move the saved X briefing three days into the past, then use the real
    # current date for the user's Y update. No system clock is changed.
    old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=3)
    focus.write_text("Updated: " + old.isoformat(timespec="seconds").replace("+00:00", "Z")
                     + "\n\nToday focus on ORCHID release checklist.\n")
    assert "historical only" in prompt()
    invoke("02-replace-stale-focus", prompt(), "Today we're focusing on CEDAR onboarding friction. Save today's focus.")
    second = verify_file("CEDAR", "ORCHID")
    (evidence / "replacement-focus.md").write_text(second)

    # Exercise the actual review protocol's daily-briefing rule against a
    # synthetic review, without reading the real watcher archive or sending
    # notifications. This proves interpretation, not the nightly scheduler.
    protocol = (repo / "watcher/ANALYZE.md").read_text()
    rule = protocol.split("### Safet's daily briefing (VF-34)\n", 1)[1].split("\nSafet's day job", 1)[0]
    rule = rule.replace("`../FOCUS-NOW.md`", "`FOCUS-NOW.md`").replace(
        "`~/.config/voice-flow/FOCUS-NOW.md`", f"`{focus}`")
    instructions = "You are validating the daily-briefing section of the shipping Watcher protocol in an isolated fixture. " + rule
    review = invoke("03-review-current-focus", instructions,
        "Review today's synthetic observation: 35 minutes on CEDAR onboarding, 20 on ORCHID release notes. "
        "Read the briefing file and return JSON only with declared_focus and interpretation. Do not write any files.")
    review_json = json.loads(review.strip().removeprefix("```json").removesuffix("```").strip())
    assert "CEDAR" in review_json["declared_focus"] and "ORCHID" not in review_json["declared_focus"], review
    focus.write_text("Updated: " + old.isoformat(timespec="seconds").replace("+00:00", "Z") + "\n\nFocus on ORCHID.\n")
    stale = invoke("04-review-stale-focus", instructions,
        "Review today. Read the briefing file. Return JSON only with briefing_is_current (boolean) and declared_focus "
        "(null if today's focus is not declared). Do not write any files.")
    stale_json = json.loads(stale.strip().removeprefix("```json").removesuffix("```").strip())
    assert stale_json["briefing_is_current"] is False and stale_json["declared_focus"] is None, stale
    (evidence / "receipt.json").write_text(json.dumps({
        "checked_at": dt.datetime.now(dt.timezone.utc).isoformat(), "model": "gpt-5.6-luna",
        "scope": "Real assistant file writes and shipping Watcher daily-context rule; synthetic fixture, not full nightly review",
        "cases": receipts}, indent=2) + "\n")
    print("PASS: real assistant saved X, replaced three-day-old X with Y; review used Y and rejected stale focus")
