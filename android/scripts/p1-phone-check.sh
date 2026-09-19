#!/usr/bin/env bash
# P1 phone evidence — the command that observes 08 section 8 item 1 on Safet's
# phone: one dictation into another app's text field, performed by hand.
#
# Run it with the phone attached, unlocked and trusted:
#
#   android/scripts/p1-phone-check.sh
#
# It builds and installs the debug APK with the repository's own wrapper, prints
# the foreground services before and after the dictation, and prints the Android
# log since the run started, filtered to the app and to the two names that must
# not appear. It never decides whether the text reached the cursor: the screen
# recording does. It never deploys anything and never talks to production.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$WORKTREE/android"
EVIDENCE_DIR="$WORKTREE/docs/runtime-proof/voiceflow-android/P1"
PACKAGE="com.voiceflow.mobile"
APK="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
RUN_DAY="$(date '+%Y-%m-%d')"
RUN_STAMP="$(date '+%Y-%m-%d %H:%M')"
TRANSCRIPT="$EVIDENCE_DIR/phone-check-$RUN_DAY.txt"
RECORDING_DEFAULT="$EVIDENCE_DIR/dictation-$RUN_DAY.mp4"
FORBIDDEN_KIND="ForegroundServiceStartNotAllowedException"
FORBIDDEN_MIC="Foreground service started from background can not have microphone access"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/p1-phone-check.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'P1 phone check refused: %s\n' "$*" >&2; exit 1; }

# One line, "a, b, c", from a list of lines. `paste -sd ', '` cycles the two
# characters as separate delimiters and drops the space after the first.
commas() { awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { print "" }'; }

mkdir -p "$EVIDENCE_DIR"

main() {
  printf '== p1-phone-check.sh %s\n' "$RUN_STAMP"
  printf 'worktree: %s\n' "$WORKTREE"

  # ── 1. the phone must be reachable before anything is built ───────────────
  command -v adb >/dev/null 2>&1 || fail "adb is not on the PATH; put the Android platform-tools on it first"
  printf 'adb: %s\n' "$(command -v adb)"

  local attached
  attached="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
  if [ -z "$attached" ]; then
    local seen
    seen="$(adb devices | awk 'NR > 1 && NF { print $1" ("$2")" }' | commas)"
    if [ -n "$seen" ]; then
      fail "adb lists no device in the 'device' state; it sees: $seen"
    fi
    fail "adb devices lists no device; attach and authorise Safet's phone first"
  fi
  # One device, named: with a phone and an emulator both attached every later
  # adb call would answer "more than one device/emulator" and the run would die
  # at install, after a full build. Refuse here, and name the one we chose on
  # every call so a device appearing mid-run cannot redirect it.
  local count
  count="$(printf '%s\n' "$attached" | grep -c .)"
  if [ "$count" -ne 1 ]; then
    fail "adb lists $count devices in the 'device' state: $(printf '%s\n' "$attached" | commas). This run installs a debug build and reads one log — leave only Safet's phone attached."
  fi
  local -a device=(-s "$attached")
  printf 'device: %s\n' "$attached"

  # ── 2. the toolchain this Mac builds Android with, as check.sh selects it ──
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-/nowhere}/bin/javac" ]; then
    local candidate
    for candidate in \
      /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
      "$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    do
      if [ -n "$candidate" ] && [ -x "$candidate/bin/javac" ]; then
        export JAVA_HOME="$candidate"
        break
      fi
    done
  fi
  [ -x "${JAVA_HOME:-/nowhere}/bin/javac" ] || fail "no JDK 21 found; Gradle 9.3.1 and AGP 8.12 do not run on the system JDK 26"
  [ -d "$ANDROID_HOME/platforms/android-36" ] || fail "the Android SDK has no platform 36 at $ANDROID_HOME"
  printf 'JAVA_HOME: %s\nANDROID_HOME: %s\n' "$JAVA_HOME" "$ANDROID_HOME"

  # ── 3. build and install, and nothing but what was just built ─────────────
  printf '\n== build the debug APK with the repository wrapper\n'
  ( cd "$ANDROID_DIR" && ./gradlew :app:assembleDebug )
  [ -f "$APK" ] || fail "the build produced no debug APK at $APK; nothing is installed"
  printf 'apk: %s\n' "$APK"

  printf '\n== install it\n'
  adb "${device[@]}" install -r "$APK"

  printf '\n== clear the log so "since the run started" means this run\n'
  adb "${device[@]}" logcat -c
  printf 'log cleared at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

  # ── 4. the recording the run names, then the dictation by hand ────────────
  printf '\n== start the screen recording\n'
  printf 'Save the screen recording to this absolute path:\n  %s\n' "$RECORDING_DEFAULT"
  printf 'Recording path (Enter for the path above): '
  local recording_input=""
  read -r recording_input || true
  local recording="$RECORDING_DEFAULT"
  if [ -n "$recording_input" ]; then
    # The evidence line names this by absolute path. A folder that does not
    # exist is refused here rather than silently becoming "/<name>.mp4".
    local recording_dir
    recording_dir="$(dirname "$recording_input")"
    [ -d "$recording_dir" ] || fail "no folder at $recording_dir to hold the screen recording $recording_input; create it first"
    recording="$(cd "$recording_dir" && pwd)/$(basename "$recording_input")"
  fi
  printf 'the run will name this recording: %s\n' "$recording"

  printf '\n== the foreground services before the dictation\n'
  adb "${device[@]}" shell dumpsys activity services "$PACKAGE"

  printf '\n== dictate into another app, by hand\n'
  printf "  1. Open another app and put the cursor in its text field, for example Gmail's reply box.\n"
  printf '  2. Hold the side key. The dot appears red; speak into the phone.\n'
  printf '  3. Stop: hold the side key again, or tap the dot. The dot turns amber.\n'
  printf '  The text should arrive at the cursor with that app still focused.\n'
  printf 'Press Enter once the dictation has finished. '
  read -r _ || true

  printf '\n== the foreground services after the dictation\n'
  adb "${device[@]}" shell dumpsys activity services "$PACKAGE"

  # ── 5. the log since the run started, and the verdict it carries ──────────
  printf '\n== the log since the run started, filtered to the app and to the two names\n'
  adb "${device[@]}" logcat -d -v threadtime > "$TMP_DIR/logcat.txt"
  # One pass, so a line that names the app and carries a forbidden name is
  # printed once, in the order the log holds it.
  grep -F -e "$PACKAGE" -e "$FORBIDDEN_KIND" -e "$FORBIDDEN_MIC" \
    "$TMP_DIR/logcat.txt" > "$TMP_DIR/filtered.txt" || true
  cat "$TMP_DIR/filtered.txt"

  local result="PASS"
  if grep -qF "$FORBIDDEN_KIND" "$TMP_DIR/filtered.txt" || grep -qF "$FORBIDDEN_MIC" "$TMP_DIR/filtered.txt"; then
    result="FAIL"
  fi
  printf '\n== result: %s\n' "$result"
  if [ "$result" = "FAIL" ]; then
    printf '   the log holds a name that must not appear:\n'
    grep -F -e "$FORBIDDEN_KIND" -e "$FORBIDDEN_MIC" "$TMP_DIR/filtered.txt" || true
  fi
  printf "   Whether the text reached the cursor is not decided here; the screen recording shows it.\n"

  printf -- '- %s — p1-phone-check.sh %s. Screen recording: %s\n' \
    "$RUN_STAMP" "$result" "$recording" >> "$EVIDENCE_DIR/evidence.md"
  printf '\n== wrote %s\n' "$TRANSCRIPT"
  printf '== appended one line to %s\n' "$EVIDENCE_DIR/evidence.md"

  [ "$result" = "PASS" ]
}

main "$@" 2>&1 | tee -a "$TRANSCRIPT"
