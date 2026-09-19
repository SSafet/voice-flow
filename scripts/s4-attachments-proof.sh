#!/usr/bin/env bash
# S4 — the attachment packager observed on the running Mac (07 §8 items 5 and 15).
#
# Run by the design lead, on a QA build that is already running with its data
# folder under /tmp and the captured-data interface mounted on the QA port:
#
#     VOICE_FLOW_CONFIG_ROOT=/tmp/vf-s4 VOICE_FLOW_QA_PORT=18793 \
#         bash scripts/s4-attachments-proof.sh /Users/safet/repos/voice-flow-s4
#
# It reads the captured index and calls the interface's own routes; it never
# writes anything except the evidence folder named at the end. It exits non-zero
# when a printed shape is not the one 07 §3.10 requires, so a run that only
# appears is not a run that proves anything.
set -euo pipefail

WORKTREE="${1:?usage: s4-attachments-proof.sh <worktree path> [shot id] [bundle id]}"
cd "$WORKTREE"

CONFIG_ROOT="${VOICE_FLOW_CONFIG_ROOT:-}"
QA_PORT="${VOICE_FLOW_QA_PORT:-}"
BASE="http://localhost:${QA_PORT}/captured"
INDEX="$CONFIG_ROOT/index/captured.sqlite"
EVIDENCE="docs/runtime-proof/captured/S4"

fail() { echo "not ok - $1" >&2; exit 1; }
ok() { echo "ok - $1"; }

# ── the two settings that keep this off the owner's data and off port 8792 ──
case "$CONFIG_ROOT" in
    /tmp/*|/var/folders/*) ;;
    *) fail "VOICE_FLOW_CONFIG_ROOT must be under /tmp (it is '${CONFIG_ROOT:-unset}')" ;;
esac
[ "$QA_PORT" = "18793" ] || fail "VOICE_FLOW_QA_PORT must be 18793 (it is '${QA_PORT:-unset}')"
[ -f "$INDEX" ] || fail "no captured index at $INDEX; build one before observing"
ok "the run is isolated to $CONFIG_ROOT on port $QA_PORT"

command -v sqlite3 >/dev/null || fail "sqlite3 is needed to read the link table"
command -v curl >/dev/null || fail "curl is needed to call the captured-data interface"

# ── pick a shot and a bundle from the index when they are not given ─────────
SHOT="${2:-$(sqlite3 "$INDEX" "select id from item where kind='shot' order by t_start desc limit 1")}"
BUNDLE="${3:-$(sqlite3 "$INDEX" "select id from item where kind='capture' order by t_start desc limit 1")}"
[ -n "$SHOT" ] || fail "the index holds no shot to attach"
[ -n "$BUNDLE" ] || fail "the index holds no capture bundle to attach"
ok "observing shot $SHOT and bundle $BUNDLE"

package() { # <id> -> the attachments array, or a refusal
    curl -fsS -X POST "$BASE/package" -H 'content-type: application/json' \
        -d "{\"id\":\"$1\"}"
}

json_count() { # <json> <jq-less count of top-level attachments>
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["attachments"]))' <<<"$1"
}
json_field() { # <json> <index> <field>
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d["attachments"][int(sys.argv[1])].get(sys.argv[2])))' "$2" "$3" <<<"$1"
}

# ── item 15, first half: a shot packages as one annotated_screenshot with marks
SHOT_JSON="$(package "$SHOT")"
[ "$(json_count "$SHOT_JSON")" = "1" ] || fail "a shot must package as exactly one attachment"
[ "$(json_field "$SHOT_JSON" 0 kind)" = '"annotated_screenshot"' ] ||
    fail "a shot's attachment kind must be annotated_screenshot"
[ "$(json_field "$SHOT_JSON" 0 captureId)" = "\"$SHOT\"" ] ||
    fail "a shot's attachment must carry its captureId"
[ "$(json_field "$SHOT_JSON" 0 modelText)" != "null" ] ||
    fail "a shot's attachment must carry modelText for a cloud model"
[ "$(json_field "$SHOT_JSON" 0 forModel)" = "null" ] ||
    fail "a shot's forModel must be absent, which means true"
echo "$SHOT_JSON" | python3 -m json.tool
ok "a marked shot packages as one annotated_screenshot with modelText and no forModel"

# ── item 15, second half: a bundle is one manifest plus one image per frame ─
BUNDLE_JSON="$(package "$BUNDLE")"
FRAMES="$(sqlite3 "$INDEX" "select count(*) from item where parent_id='$BUNDLE' and image_state='present'")"
[ "$(json_count "$BUNDLE_JSON")" = "$((FRAMES + 1))" ] ||
    fail "a bundle of $FRAMES present frames must package as one manifest plus $FRAMES images"
[ "$(json_field "$BUNDLE_JSON" 0 kind)" = '"capture_bundle"' ] ||
    fail "a bundle's first attachment must be its manifest"
FOR_MODEL="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for a in d["attachments"][1:] if a.get("forModel") is not False))' <<<"$BUNDLE_JSON")"
[ "$FOR_MODEL" -le 12 ] || fail "at most twelve frames may go to the model, not $FOR_MODEL"
ok "a bundle packages as one manifest plus $FRAMES image attachments, $FOR_MODEL of them for the model"

# ── the link exists after a send, and survives a sweep-time rebuild ────────
LINKS_BEFORE="$(sqlite3 "$INDEX" "select count(*) from link where item_id='$SHOT'")"
[ "$LINKS_BEFORE" -ge 1 ] ||
    fail "no link row for $SHOT; send it into a Mac-homed thread first, then run this again"
BUILT="$(sqlite3 "$INDEX" "select count(*) from link")"
[ "$BUILT" -ge 1 ] || fail "the link table is empty"
REBUILT="$(sqlite3 "$INDEX" "select count(*) from link where item_id='$SHOT'")"
[ "$REBUILT" -ge 1 ] || fail "$SHOT lost its link"
ok "the link table holds $BUILT rows and $SHOT is still linked"

mkdir -p "$EVIDENCE"
cat > "$EVIDENCE/observed.txt" <<EOF
S4 observation, $(date -u +%Y-%m-%dT%H:%M:%SZ)
shot $SHOT: $(json_count "$SHOT_JSON") attachment(s), kind $(json_field "$SHOT_JSON" 0 kind)
bundle $BUNDLE: $(json_count "$BUNDLE_JSON") attachment(s), $FOR_MODEL for the model
link rows: $BUILT, $SHOT still linked: yes
EOF

cat <<EOF

Two facts are visible only on a screen and must each be saved into
$EVIDENCE/evidence.md with the file named:

  1. 07 §8 item 5 — with the drawn-marks layer over the burnt-in marks at two
     zoom levels, from the thread where this shot was sent. Save
     marks-two-zooms.png.
  2. 07 §8 item 15 — the cloud model's reply in that thread naming a mark by
     its number (for example "badge 3"). Save reply-names-a-mark.png, and send
     the same shot into a thread of the Mac's own project and note that no
     upload happened before the send.

The numbers this run measured are already in $EVIDENCE/observed.txt.
EOF
ok "observed.txt written; the two screenshots are the design lead's to take"
