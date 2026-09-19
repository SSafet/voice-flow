#!/bin/bash
# Work package V10 — the running-system facts of 06 §8 item 13 (relaunch) and
# item 18 (Today). Run later by the design lead on a Mac, with the app installed
# from this worktree. It never touches /Applications/Voice Flow.app,
# ~/.config/voice-flow or port 8792: the run uses a QA bundle, a throwaway
# configuration root under /tmp and port 18793.
#
#   V10_APP="/tmp/v10-run/Voice Flow QA.app" \
#   V10_CONFIG_ROOT="/tmp/v10-run/config" \
#   bash docs/runtime-proof/voiceflow-mac/V10/validate.sh
#
# One `ok`/`not ok` line per machine-checkable fact; the two facts that need eyes
# and a screenshot are printed as MANUAL with the exact command and what to look at.
set -euo pipefail

APP="${V10_APP:?set V10_APP to a QA bundle built from this worktree}"
CONFIG_ROOT="${V10_CONFIG_ROOT:?set V10_CONFIG_ROOT to a folder under /tmp}"
PORT="${V10_PORT:-18793}"
LABEL="com.voiceflow.agent"
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
bad() { echo "not ok - $1" >&2; exit 1; }
manual() { echo "MANUAL - $1"; }

case "$CONFIG_ROOT" in
    /tmp/*|/private/tmp/*) ;;
    *) bad "V10_CONFIG_ROOT must be under /tmp, not the owner's ~/.config/voice-flow" ;;
esac
[ "$PORT" != "8792" ] || bad "V10 never uses port 8792"

APP_BIN="$APP/Contents/MacOS/voice-flow"
[ -x "$APP_BIN" ] || bad "the QA app is at $APP"
PLIST="$APP/Contents/Library/LaunchAgents/$LABEL.plist"
[ -f "$PLIST" ] || bad "the launch agent ships inside the bundle at Contents/Library/LaunchAgents"

# Fact 0 (item 13, mechanism): the agent is registered with launchd, and the
# property list restarts only an unsuccessful exit.
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || bad "the agent $LABEL is registered in launchd"
ok "the launch agent is registered"

# Fact 1 (item 13): after kill -9 the app is running again without being opened by hand.
rm -rf "$CONFIG_ROOT"; mkdir -p "$CONFIG_ROOT"
VOICE_FLOW_CONFIG_ROOT="$CONFIG_ROOT" VOICE_FLOW_QA_PORT="$PORT" open -n "$APP"
for _ in $(seq 1 100); do
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.1
done
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || bad "the app listens on $PORT"
FIRST_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t | head -n 1)"
kill -9 "$FIRST_PID"
for _ in $(seq 1 150); do
    NOW_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
    [ -n "$NOW_PID" ] && [ "$NOW_PID" != "$FIRST_PID" ] && break
    sleep 0.1
done
NOW_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
[ -n "$NOW_PID" ] && [ "$NOW_PID" != "$FIRST_PID" ] || bad "the app did not come back after kill -9"
ok "after kill -9 the app is running again without being opened by hand (pid $NOW_PID)"
manual "screenshot the interrupted state, and confirm with 'ps' that no runtime process was left behind"

# Fact 2 (item 13): Quit from the menu stays quit.
osascript -e "tell application \"Voice Flow QA\" to quit" >/dev/null 2>&1 || true
sleep 4
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && bad "the app is still listening after Quit"
sleep 4
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && bad "the app came back after a menu Quit; a successful exit must stay quit"
ok "Quit from the menu stays quit"

# Fact 3 (item 18): editing Today.md changes the Mac window's Today line without a
# reload. The phone writes it through the files interface; here the same bytes are
# written in place, which is what the watcher sees.
GENERAL="$CONFIG_ROOT/projects/general"
mkdir -p "$GENERAL"
printf 'Ship the platform. Walk at 17:00.\n' > "$GENERAL/Today.md"
manual "with the window open on the first turn, edit Today.md from the phone (or run: printf 'New focus' > $GENERAL/Today.md) and screenshot the Today line changing without a reload"
manual "ask the thread 'what is planned today?' and screenshot the answer naming the new text"

echo "all $PASS checks passed; the MANUAL lines are 06 §8 items 13 and 18 and need a screenshot each"
