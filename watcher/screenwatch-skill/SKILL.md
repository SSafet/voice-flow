---
name: screenwatch
description: Analyze the Voice Flow workflow-watcher archive — build daily activity notes, track recurring workflow inefficiencies, and suggest optimizations. Use for "/screenwatch analyze [date]", "/screenwatch optimize [focus]", "/screenwatch status", or any question about what the user was doing on a past day / how to improve their workflow based on observed behavior.
---

# Screenwatch analysis (Voice Flow watcher)

## Data layout
- `~/.config/voice-flow/watcher/YYYY-MM-DD/activity.jsonl` — one line per 5s tick:
  `{t, e, app, title, url, frame}`. `frame` names a screenshot in the same folder
  and is present only when the screen changed. `url` is present when a known
  browser was frontmost. Gaps in `e` = idle (>90s), locked screen, or watcher off.
- `~/.config/voice-flow/watcher/YYYY-MM-DD/frame-*.jpg` — ~1568px screenshots (30-day retention).
- `~/.config/voice-flow/watcher/YYYY-MM-DD/cam-*.jpg` — optional body-camera frames (`cam` field on the tick line): posture, lighting, phone pickups. Read at most ~6 per day.
- The day folder is an **open observation bus**: any `<source>.jsonl` (merge by `e`), `<source>-HH-MM-SS.<ext>` artifact, or `note-*.md` free-text observation is first-class input. Always read the notes — they usually name the day's experiment condition. To log a note for tonight's review from any session: Write `~/.config/voice-flow/watcher/$(date +%F)/note-HH-MM-SS.md`.
- `~/.config/voice-flow/watcher/reviews/YYYY-MM-DD.md` — analysis output (kept forever).
- `~/.config/voice-flow/watcher/ledger.md` — observations ledger with sighting counts and
  statuses: watching → confirmed (3+ sightings, 2+ days) → suggested → adopted | rejected.
- `~/.config/voice-flow/watcher/ANALYZE.md` — the full nightly protocol (a LaunchAgent runs
  it at 21:37; this skill is the on-demand version and follows the same rules).

## Cost discipline (important)
Metadata first, vision second. The JSONL log answers most questions (what apps,
how long, how often switching, which URLs) for near-zero tokens. Aggregate it
with a python3 script via the shell — never read raw JSONL into context. Only
Read screenshots where metadata can't tell the story: target 10–30 images per
analyzed day, never all of them.

## `analyze [date]` (default: today; use yesterday if today has <100 lines)
Follow steps 2–8 of `~/.config/voice-flow/watcher/ANALYZE.md` for the given day:
aggregate into activity blocks / per-app time / switch rate / top titles+URLs /
churn bursts (>6 app switches in 2 min); look at frames from block transitions,
longest blocks, and churn bursts; update the ledger; write the review file.
Surface via voice-flow MCP `show_panel` + `notify_user` when connected (daytime
runs may also `speak` one sentence if the user asked out loud).

## `optimize [focus]`
1. Read `ledger.md` and the last ~7 days of `reviews/`.
2. Every `confirmed` entry without an adopted/rejected resolution becomes a
   specific recommendation: the exact hotkey, the replacement tool (verify it's
   current via web search — never put his data in the query), or an automation
   you can build on the spot (script, Raycast command, Chrome extension, Claude
   Code slash command, Voice Flow feature).
3. Rank by estimated time saved per week. Present the top 3–5; offer to
   implement the buildable ones now.
4. If `focus` is given (e.g. "browser", "email"), filter to that area.

## `status`
Report: is Voice Flow running (`pgrep -x voice-flow`) and is the watcher enabled
(`workflow_watcher_enabled` in `~/.config/voice-flow/settings.json`); today's
line + frame count and disk usage of the watcher dir; `last-reviewed` from
`ledger.md`; whether the LaunchAgent is loaded
(`launchctl print gui/$UID/com.voiceflow.watcher-analyze`).
