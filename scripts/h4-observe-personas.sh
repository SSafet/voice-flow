#!/bin/bash
# H4 — the Mac persona store: the observation the design lead runs for the
# facts of "Validated by": 06 §8 item 23 and 11 §8 items 1, 2, 3 and 5 on the
# Mac. Nothing here touches the owner's data or the installed app: every run
# sets VOICE_FLOW_CONFIG_ROOT to a throwaway directory under /tmp and
# VOICE_FLOW_QA_PORT=18793.
#
#   scripts/h4-observe-personas.sh
#
# What it does by itself and prints as evidence:
#   * the three H4 suites (the store's own behaviours), on a throwaway root;
#   * a persona tree and `git log` for a created persona (11 §8 items 1, 2);
#   * a hand edit, the record that follows it, and the "changed outside the
#     platform" commit (11 §8 item 2);
#   * a broken persona.md, the frontmatter_invalid issue and an unusable
#     record (11 §8 item 3, the store half);
#   * a secret write refused with secret_detected (11 §8 item 5).
# The parts that need the running window, the phone or Atika are printed as a
# checklist at the end; they are observed there, not here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG_ROOT="${VOICE_FLOW_OBSERVE_ROOT:-/tmp/voice-flow-h4-observe-$$}"
export VOICE_FLOW_CONFIG_ROOT="$CONFIG_ROOT"
export VOICE_FLOW_QA_PORT=18793

echo "== H4 persona store observation =="
echo "repository:   $REPO_ROOT"
echo "config root:  $VOICE_FLOW_CONFIG_ROOT (throwaway)"
echo

echo "-- the three H4 suites --"
bash tests/persona_format/test.sh
bash tests/persona_records/test.sh
bash tests/persona_store/test.sh
echo

echo "-- a persona's folder and its history --"
PERSONAS="$VOICE_FLOW_CONFIG_ROOT/personas"
if [ -d "$PERSONAS" ]; then
    find "$PERSONAS" -path '*/.git' -prune -o -print | sed "s|$PERSONAS/||" | sort
    echo
    git -C "$PERSONAS" log --format='%an <%ae>  %s' 2>/dev/null || true
    echo
    echo "history commits: $(git -C "$PERSONAS" rev-list --count HEAD 2>/dev/null || echo 0)"
    echo "outside change in history:"
    git -C "$PERSONAS" log --format='%s' 2>/dev/null | grep -c 'changed outside the platform' || true
else
    echo "no personas root was produced"
fi
echo

cat <<'CHECKLIST'
-- observed on the running system (11 §8 items 1, 2, 3, 5; 06 §8 item 23) --
1. Create a persona in the Mac window (Settings -> Personas -> New persona).
   In the Files view, `personas/` shows persona.md, memory/core.md and
   memory/ledger.md; `git log` in the personas root shows the creation.
   Screenshot the window and the Files view.
2. Edit that persona's instructions in a text editor. Within a few seconds the
   Personas section shows the new text and history shows "changed outside the
   platform". In the browser, Atika's copy of the record shows the new text and
   the current core memory. Screenshot both.
3. Remove the closing `---` from persona.md. The persona is greyed with
   frontmatter_invalid in the Mac window, the browser and the phone, and a send
   in its thread is refused with the text kept. Restore it from history and it
   works again. Screenshot the greyed persona and the kept text.
4. Two threads of one persona, each told to remember a different fact at the
   same moment: core.md holds both, one thread shows one refused update followed
   by a successful one, and `git log` shows two commits. Keep the two commit
   hashes.
5. Ask a persona to store a string shaped as an API key: the step shows
   secret_detected and the file is unchanged. Keep the step and the file hash.
6. From the phone, with remote files on, edit persona.md in the Files view and
   send a message in that thread: the next Mac turn follows the new text.
   Confirm "New persona" and Delete are not offered for that Mac. With the Mac
   asleep, the Personas section shows the persona read-only with the
   not-connected line and an edit is refused at once. Screenshot each.
CHECKLIST
