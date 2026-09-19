#!/bin/bash
# Work package V10, subtraction (R12, ruling C20).
#
# The Queue, the daily focus and the native panes that moved into the interface's
# Settings are deleted in the same piece of work that replaces them. These greps
# must be able to fail: the script first proves its own search finds a token when
# the token is there, then requires the tokens to be gone from the Mac's sources.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
die() { echo "not ok - $1" >&2; exit 1; }

# The positive control: the search below must find a token that is present.
PROBE="$(mktemp /tmp/v10-subtraction.XXXXXX)"
trap 'rm -f "$PROBE"' EXIT
printf 'queue_enabled and voiceflow_queue and WorkspaceSettingsContent\n' > "$PROBE"
grep -F "queue_enabled" "$PROBE" >/dev/null || die "the subtraction grep finds a token when it is there"
ok "the subtraction check is able to fail"

# The files the design deletes whole.
for gone in swift/Queue.swift swift/QueueEditor.swift swift/QueueEditorStore.swift \
            swift/DailyFocus.swift swift/DailyFocusEditor.swift; do
    [ ! -e "$gone" ] || die "$gone is deleted"
done
ok "the Queue and daily-focus files are gone"

[ ! -d tests/queue_editor ] || die "tests/queue_editor is deleted"
[ ! -d tests/daily_focus ] || die "tests/daily_focus is deleted"
ok "the deleted stores' test suites are gone"

# The setting and the tool the design deletes by name.
for token in queue_enabled "voiceflow_queue" "WorkspaceSettingsContent" "NextQueue" "queueEnabled" "QueueEditorStore"; do
    if grep -rIn --include='*.swift' -F "$token" swift >/dev/null; then
        die "the Mac's sources no longer mention $token"
    fi
done
ok "queue_enabled, voiceflow_queue and the queue wiring are gone from swift/"

grep -F '"queue"' tests/test_registry.json >/dev/null && die "the queue suite is gone from tests/test_registry.json"
ok "the queue suite is gone from the test registry"

# The replacements are in place: the one native Settings window, the Mac settings
# half, the launch supervision and the Today note.
for present in swift/Settings/SettingsWindowController.swift swift/Settings/MacSettings.swift \
               swift/Settings/MacSettingsStore.swift swift/Settings/MacSettingsService.swift \
               swift/Settings/MacPersonaOperations.swift swift/Settings/TodayNote.swift \
               swift/Launch/LaunchAgent.swift swift/Launch/LaunchSupervisor.swift \
               launchd/com.voiceflow.agent.plist; do
    [ -e "$present" ] || die "$present exists"
done
ok "the one Settings window, the Mac settings half, launch supervision and the Today note exist"

# The launch agent ships inside the app bundle, where SMAppService.agent looks.
grep -n "Contents/Library/LaunchAgents" install.sh >/dev/null || die "install.sh stages the launch agent into the bundle"
ok "install.sh stages the launch agent into the bundle"

echo "all $PASS checks passed"
