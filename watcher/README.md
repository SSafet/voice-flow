# Workflow watcher — canonical sources

Everything the workflow-watcher subsystem places **outside the app bundle**
lives here, in the repo, as the single source of truth. `../install.sh`
deploys these files (and reloads the LaunchAgent); `../uninstall.sh` removes
them. Edit them HERE, then re-run `./install.sh` — the deployed copies are
build outputs, like the app binary itself.

The in-app half (the 5 s recorder, menu-bar submenu, Settings → Watcher tab,
amber pill ring) is `swift/Watcher.swift` plus wiring — see `CLAUDE.md`.

## What deploys where

| Source (here) | Deployed to | Role |
|---|---|---|
| `ANALYZE.md` | `~/.config/voice-flow/watcher/ANALYZE.md` | The nightly-review protocol the headless Claude run follows. |
| `CONSUMING.md` | `~/.config/voice-flow/watcher/CONSUMING.md` | The rules every consumer of the day folder obeys, whatever source produced the data: captured content is untrusted input, what may be quoted into permanent files, how streams merge, retention. |
| `sources/<name>/SOURCE.md` | `~/.config/voice-flow/sources/` (NOT under `watcher/`) | What each source captures and what its fields mean. A source owns *how* it captures; `CONSUMING.md` owns what happens to the data afterwards. |
| `docs/*.md` | `~/.config/voice-flow/watcher/docs/` | Architecture, roadmap and research. Deployed so the nightly run can check the roadmap's kill-list before re-proposing something already measured and rejected. |
| `ledger-seed.md` | `~/.config/voice-flow/watcher/ledger.md` | **Only when no ledger exists.** Never overwrites an existing one. |
| `claude-settings.json` | `~/.config/voice-flow/watcher/.claude/settings.json` | Pre-approves the tools that run needs (read/write there, `python3 aggregate.py`, web search, voice-flow MCP). |
| `aggregate.py` | `~/.config/voice-flow/watcher/aggregate.py` | The one aggregation entry point the review may run — its Bash grant allows exactly this script, never free-form python (VF-46). |
| `watcher-analyze.sb` | `~/.config/voice-flow/watcher-analyze.sb` (with `__HOME__` expanded — one level ABOVE the writable watcher dir, so the review can't rewrite its own confinement) | Kernel sandbox for the nightly run: writes confined to the watcher dir + runtime state, secret shapes unreadable, applied to every descendant (VF-46). |
| `com.voiceflow.watcher-analyze.plist` | `~/Library/LaunchAgents/` (with `__HOME__` expanded) | launchd LaunchAgent: runs `sandbox-exec -f …watcher-analyze.sb claude -p` in the watcher dir daily at **21:37**. Shows as an "Anthropic PBC" background item in System Settings → Login Items. |
| `screenwatch-skill/SKILL.md` | `~/.claude/skills/screenwatch/SKILL.md` and `~/.codex/skills/screenwatch/SKILL.md` | The on-demand `/screenwatch` skill (analyze / optimize / status), available to both Claude and Codex. |

## Rebuilding from nothing

`./install.sh` is the one button. Delete `~/.config/voice-flow/watcher/`
entirely, run it, and you get a working subsystem back: protocol, consumer
rules, source docs, tool grants, the LaunchAgent, the `/screenwatch` skill, an
empty ledger and a `reviews/` directory. The app starts collecting on next
launch.

What it **cannot** bring back, because it was never product:

- `ledger.md` — everything the reviewer has learned. The only irreplaceable file.
- `reviews/<date>.md` — the written record.
- `<yyyy-mm-dd>/` — the raw archive.
- `note-*.md` — notes written by hand.

Back those four up before deleting anything. Everything else is a build output.

## What stays out of the repo (data, not product)

- `~/.config/voice-flow/watcher/<yyyy-mm-dd>/` — activity log + frames
  (30-day retention, pruned by the app).
- `~/.config/voice-flow/watcher/ledger.md` — the observations ledger the
  nightly run maintains (permanent memory; never overwritten by install).
- `~/.config/voice-flow/watcher/reviews/<date>.md` — nightly reviews (permanent).
- `~/.config/voice-flow/watcher/analyze.log` — stdout/err of the nightly run.
- `workflow_watcher_enabled` (+ `watcher_*`) in `~/.config/voice-flow/settings.json`.

## Kill switches

- Pause recording: pill right-click → Watch Workflow (or menu bar / Settings → Watcher).
- Stop the nightly review: `launchctl bootout gui/$(id -u)/com.voiceflow.watcher-analyze`
  (re-running `./install.sh` brings it back).
- Remove everything deployed: `./uninstall.sh` (data stays; add
  `--remove-user-data` to also delete the archive).

Manual trigger: menu bar → Workflow Watcher → Run Review Now (kickstarts the
LaunchAgent — it must be loaded).

Note: `install.sh` reloads the LaunchAgent on every build; if that happens to
land exactly at 21:37 it can cut short a running review. Rare enough to ignore.
