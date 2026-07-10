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
| `claude-settings.json` | `~/.config/voice-flow/watcher/.claude/settings.json` | Pre-approves the tools that run needs (read/write there, python3, web search, voice-flow MCP). |
| `com.voiceflow.watcher-analyze.plist` | `~/Library/LaunchAgents/` (with `__HOME__` expanded) | launchd LaunchAgent: runs `claude -p` in the watcher dir daily at **21:37**. Shows as an "Anthropic PBC" background item in System Settings → Login Items. |
| `screenwatch-skill/SKILL.md` | `~/.claude/skills/screenwatch/SKILL.md` | The on-demand `/screenwatch` skill (analyze / optimize / status). |

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
