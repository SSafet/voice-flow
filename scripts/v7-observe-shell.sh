#!/bin/bash
# Work package V7 — the observation the design lead runs for the facts on a
# running system: 06 §8 items 16, 17 and 19, and 02 §8 items 4, 5, 6 and 16.
#
# This is the one V7 artefact that needs a visible window, so it is NOT run by
# check.sh: check.sh only runs it with --dry-run. It refuses to do anything real
# unless VOICE_FLOW_ALLOW_WINDOWS=1 is exported, because launching VoiceFlow
# shows windows, asks for permissions, and binds the owner's port 8792.
#
# Usage:
#   bash scripts/v7-observe-shell.sh --dry-run     # print the plan, touch nothing
#   VOICE_FLOW_ALLOW_WINDOWS=1 bash scripts/v7-observe-shell.sh
#
# Real run: builds the app, launches it from a throwaway bundle with a throwaway
# configuration root under /tmp, and walks the operator through the three
# recordings. Evidence goes under docs/runtime-proof/voiceflow-mac/V7/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

EVIDENCE_DIR="$REPO_ROOT/docs/runtime-proof/voiceflow-mac/V7"
BUNDLE_DIR="$(mktemp -d /tmp/voice-flow-v7-bundle.XXXXXX)"
CONFIG_ROOT="$(mktemp -d /tmp/voice-flow-v7-config.XXXXXX)"

plan() {
    cat <<'PLAN'
V7 observation plan (06 §8 items 16, 17, 19; 02 §8 items 4, 5, 6, 16)

  Build:    swift build -c release --package-path <worktree>
  Launch:   the built voice-flow binary, from a throwaway bundle under /tmp,
            with VOICE_FLOW_CONFIG_ROOT=<tmp> and never the installed app.
  WARNING:  the running app binds localhost:8792, which is the owner's port.
            Do not run this while the owner is using VoiceFlow unless the
            windows are wanted on screen.

  Item 16 (window, 06 §8): move the window to the second display, resize it,
    click another app and watch it stay, close it and reopen it (it returns to
    the same place), unplug the monitor and reopen (the laptop arrangement
    returns), the Dock icon is present only while open; copy and paste work in
    the composer. Record it; save the recording under:
      docs/runtime-proof/voiceflow-mac/V7/window-06-08-16.mov
  Item 17 (voice into a thread, 06 §8): ⌃⌥2 with the window closed dictates
    into that thread; with the window open on a thread the same hotkey puts the
    words into the composer; on the draft screen the hotkey held while circling
    something puts the words and the annotated capture into the draft composer;
    sending opens a thread in the chosen project folder. Record it as:
      docs/runtime-proof/voiceflow-mac/V7/voice-06-08-17.mov
  Item 19 (Escape, 06 §8): annotation editing, a turn holding the
    desktop-control lease, and the pill card; record it as:
      docs/runtime-proof/voiceflow-mac/V7/escape-06-08-19.mov
  Item 02 §8 4/5/6/16: accounts and devices; the three cases of dictation,
    a hotkey capture and an annotation reaching the right composer; and the
    window and capabilities. Screenshots and command output beside the
    recordings.

  The bridge conformance page: open http://localhost:8792/__bridge-check in
  the window and keep the copied table as:
      docs/runtime-proof/voiceflow-mac/V7/bridge-check-mac.txt
  It never calls auth.signOut (W4 ruling): its row for auth.signOut reads
  "not exercised here: signs the app out".
PLAN
}

if [ "$DRY_RUN" = 1 ]; then
    plan
    echo "dry run: nothing was built, launched or written"
    exit 0
fi

if [ "${VOICE_FLOW_ALLOW_WINDOWS:-}" != "1" ]; then
    echo "refusing to show windows: export VOICE_FLOW_ALLOW_WINDOWS=1 to run this" >&2
    plan >&2
    exit 2
fi

echo "== building =="
swift build -c release --package-path "$REPO_ROOT" -Xswiftc -suppress-warnings

BIN="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)/voice-flow"
mkdir -p "$BUNDLE_DIR"
cp "$BIN" "$BUNDLE_DIR/voice-flow"
[ -d "$REPO_ROOT/swift/Resources" ] && cp -R "$REPO_ROOT/swift/Resources/." "$BUNDLE_DIR/" || true

mkdir -p "$EVIDENCE_DIR"
echo "== launching (own try-again bundle; the installed app is never touched) =="
VOICE_FLOW_CONFIG_ROOT="$CONFIG_ROOT" VOICE_FLOW_QA_PORT=18793 "$BUNDLE_DIR/voice-flow" &

plan
echo
echo "Evidence folder: $EVIDENCE_DIR"
echo "Configuration root (throwaway): $CONFIG_ROOT"
echo "When the recordings are saved, write $EVIDENCE_DIR/evidence.md naming what"
echo "was observed, when, and by which command."
