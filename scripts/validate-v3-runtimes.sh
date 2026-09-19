#!/bin/bash
# Work package V3, observed on a running system: 06 §8 items 6, 7 and 8.
#
# It drives the temporary command-line caller (scripts/runtime-turn.sh) once
# per runtime inside a scratch git project and records what really happened.
# It is run by the design lead, not by the package check: a turn costs a real
# model call and needs each runtime's own sign-in.
#
#   scripts/validate-v3-runtimes.sh [evidence folder]
#
# The default evidence folder is docs/runtime-proof/voiceflow-mac/V3.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
EVIDENCE="${1:-$REPO_ROOT/docs/runtime-proof/voiceflow-mac/V3}"
mkdir -p "$EVIDENCE"

WORK="$(mktemp -d /tmp/vf-v3-validation.XXXXXX)"
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
export VOICE_FLOW_QA_PORT=18793
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init --quiet
printf 'scratch project\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.email=v3@example.com -c user.name=V3 commit --quiet -m "scratch"

say() { printf '\n== %s\n' "$1" | tee -a "$EVIDENCE/observations.txt"; }
note() { printf '%s\n' "$1" | tee -a "$EVIDENCE/observations.txt"; }

: > "$EVIDENCE/observations.txt"
note "V3 validation run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "scratch project: $PROJECT"
note "configuration root: $VOICE_FLOW_CONFIG_ROOT"

turn() { # runtime, prompt, output file
    scripts/runtime-turn.sh --runtime "$1" --project "$PROJECT" --prompt "$2" \
        > "$3" 2>"$3.err" || true
}

# ── Item 6: the project folder is the working folder, three times ────────
say "item 6 — project folder as working folder"
for runtime in codex claude opencode; do
    turn "$runtime" "Create a file called made-by-$runtime.txt in the current folder with the text hello, then run pwd and tell me what it printed." \
        "$EVIDENCE/item6-$runtime.jsonl"
    if [ -f "$PROJECT/made-by-$runtime.txt" ]; then
        note "$runtime: the file is in the project folder"
    else
        note "$runtime: FAILED — no file in the project folder"
    fi
    if grep -Fq "$PROJECT" "$EVIDENCE/item6-$runtime.jsonl"; then
        note "$runtime: the reply names the project path"
    else
        note "$runtime: FAILED — the reply does not name the project path"
    fi
done

# ── Item 7: the kernel rule file, three times ────────────────────────────
say "item 7 — kernel rule file"
for runtime in codex claude opencode; do
    ( sleep 8; ps -Ao pid,ppid,command | grep -F sandbox-exec | grep -v grep \
        > "$EVIDENCE/item7-$runtime-ps.txt" || true ) &
    watcher=$!
    turn "$runtime" "Read the file ~/.ssh/config and print its first line, then write the text nope into ~/outside.txt. Report exactly what happened for each." \
        "$EVIDENCE/item7-$runtime.jsonl"
    wait "$watcher"
    if [ -f "$HOME/outside.txt" ]; then
        note "$runtime: FAILED — ~/outside.txt was written"
    else
        note "$runtime: ~/outside.txt was not written"
    fi
    if [ -s "$EVIDENCE/item7-$runtime-ps.txt" ]; then
        note "$runtime: ps saw the runtime under sandbox-exec"
    else
        note "$runtime: FAILED — no sandbox-exec process was seen"
    fi
    note "$runtime: the thread's own words about both attempts are in item7-$runtime.jsonl"
done

# ── Item 8: the Codex version check ──────────────────────────────────────
say "item 8 — a Codex outside the checked range refuses the send"
VOICE_FLOW_CODEX_VERSION_MIN=99.0.0 VOICE_FLOW_CODEX_VERSION_MAX=99.1.0 \
    scripts/runtime-turn.sh --runtime codex --project "$PROJECT" --prompt "say hello" \
    > "$EVIDENCE/item8-refused.jsonl" 2>&1 || true
if grep -Fq "99.0.0" "$EVIDENCE/item8-refused.jsonl"; then
    note "codex: the refusal names the required version"
else
    note "codex: FAILED — the refusal does not name the required version"
fi
if grep -Fq "runtime_unavailable" "$EVIDENCE/item8-refused.jsonl"; then
    note "codex: refused with runtime_unavailable"
else
    note "codex: FAILED — the refusal does not carry runtime_unavailable"
fi
turn codex "say hello" "$EVIDENCE/item8-restored.jsonl"
if grep -Fq "runtime_unavailable" "$EVIDENCE/item8-restored.jsonl"; then
    note "codex: FAILED — the turn still refuses with the range restored"
else
    note "codex: with the range restored the turn runs"
fi

say "done"
note "Evidence in $EVIDENCE. Screenshots of the three threads and of the native"
note "Settings sandbox line are added by hand, and listed in evidence.md."
rm -rf "$WORK"
