#!/usr/bin/env bash
# review-loop — continue a loop that stopped at its round cap, with extra rounds.
#
# Usage: continue.sh [N | --rounds N] [--loop ID] [--dir DIR] [--session ID]
#   N, --rounds N  extra review rounds to allow (default 1)
#   --loop ID      the loop to continue (default: the most recent loop in the
#                  storage dir that stopped at its cap)
#   --dir DIR      storage dir to look in (default: the configured dir)
#   --session ID   Claude Code session id of the coder (binds the Stop hook;
#                  a different session than before stores the coder usage
#                  recorded so far per session, so totals and round deltas stay
#                  right even when returning to an earlier session)
#
# The loop is re-opened where it stopped: max_rounds grows by N, the pointer is
# restored, the stale summary is kept aside, and review.sh applies the last
# review's pending transition (it resumes from the installed review without
# running the reviewer again), so the next round starts exactly as after any
# changes_requested verdict. review.sh keeps owning every state transition.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

ROUNDS=1 LOOP="" FLAG_DIR="" FLAG_SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="${2:-}"; shift 2 ;;
    --rounds=*) ROUNDS="${1#*=}"; shift ;;
    --loop) LOOP="${2:-}"; shift 2 ;;
    --loop=*) LOOP="${1#*=}"; shift ;;
    --dir) FLAG_DIR="${2:-}"; shift 2 ;;
    --dir=*) FLAG_DIR="${1#*=}"; shift ;;
    --session) FLAG_SESSION="${2:-}"; shift 2 ;;
    --session=*) FLAG_SESSION="${1#*=}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [1-9]*) ROUNDS="$1"; shift ;;
    *) rl_die "unknown argument '$1' (usage: continue.sh [N | --rounds N] [--loop ID] [--dir DIR])" ;;
  esac
done
printf '%s' "$ROUNDS" | grep -qE '^[1-9][0-9]*$' || rl_die "the number of extra rounds must be a positive integer (got '$ROUNDS')"

ROOT="$PWD"
if rl_load_loop; then
  rl_die "review loop $RL_LOOP_ID is still active (round $(rl_state_get "$RL_LOOP_DIR" round) of $(rl_state_get "$RL_LOOP_DIR" max_rounds)); finish it, or cancel it with cancel.sh, before continuing another loop"
fi

CFG=$(rl_resolve_config)
DIR=${FLAG_DIR:-$(jq -r .dir <<< "$CFG")}
ABS_DIR=$(rl_abs_dir "$ROOT" "$DIR")
# A storage dir can be shared by several projects: only a loop started from
# THIS project (state.root, recorded by start.sh) may be re-opened here, or the
# pointer would activate another project's loop. Loops recorded before root was
# stored are accepted.
loop_root() { jq -r '.root // ""' "$1/state.json" 2>/dev/null; }
owned_here() {
  local r; r=$(loop_root "$1")
  [ -z "$r" ] || [ "$(cd "$r" 2>/dev/null && pwd -P)" = "$(pwd -P)" ]
}
if [ -n "$LOOP" ]; then
  rl_valid_loop_id "$LOOP" || rl_die "invalid loop id '$LOOP'"
  LOOP_DIR="$ABS_DIR/$LOOP"
  [ -f "$LOOP_DIR/state.json" ] || rl_die "no loop $LOOP in $ABS_DIR"
  owned_here "$LOOP_DIR" || rl_die "loop $LOOP belongs to another project ($(loop_root "$LOOP_DIR")); run continue.sh from there"
else
  # The most recent loop that ran out of rounds. Loop ids sort by start time
  # and the glob expands in ascending order, so walk it backwards; no word
  # splitting, so paths with spaces survive.
  LOOP_DIR=""
  CANDIDATES=()
  for d in "$ABS_DIR"/*/; do
    d="${d%/}"
    [ -d "$d" ] && rl_valid_loop_id "$(basename "$d")" || continue
    CANDIDATES+=("$d")
  done
  for (( i = ${#CANDIDATES[@]} - 1; i >= 0; i-- )); do
    d="${CANDIDATES[$i]}"
    [ -f "$d/state.json" ] || continue
    [ "$(jq -r '.outcome // ""' "$d/state.json" 2>/dev/null)" = "max_rounds_reached" ] || continue
    owned_here "$d" || continue
    LOOP_DIR="$d"; break
  done
  [ -n "$LOOP_DIR" ] || rl_die "no loop of this project stopped at its round cap in $ABS_DIR (pass --loop ID, or --dir DIR for another storage dir)"
fi

LOOP_ID=$(rl_state_get "$LOOP_DIR" loop_id)
OUTCOME=$(jq -r '.outcome // ""' "$LOOP_DIR/state.json")
[ "$(rl_state_get "$LOOP_DIR" active)" != "true" ] || rl_die "loop $LOOP_ID is still active; finish or cancel it first"
[ "$OUTCOME" = "max_rounds_reached" ] || rl_die "loop $LOOP_ID finished with outcome '${OUTCOME:-unknown}', not at its round cap; only a loop that ran out of rounds can be continued"
ROUND=$(rl_state_get "$LOOP_DIR" round)
MAX_ROUNDS=$(rl_state_get "$LOOP_DIR" max_rounds)
NN=$(rl_round_nn "$ROUND")
[ -f "$LOOP_DIR/round-$NN-review.md" ] || rl_die "the last review ($LOOP_DIR/round-$NN-review.md) is missing; the loop cannot be continued"
NEW_MAX=$(( MAX_ROUNDS + ROUNDS ))
# Session: --session binds the loop (and the Stop hook) to the coder's session;
# without it the previous binding is kept. A CHANGE of session keeps the coder
# usage right per session: the closing session's cumulative total is stored in
# state.sessions[] (one entry per session id, latest total wins); the new
# session starts from its own stored total when it was used before (so the
# next round is the delta since then, never a recount) or from nothing; and
# coder_usage_carry, which rl_coder_usage_total adds to the current session's
# total, is the sum over the OTHER sessions' stored totals. The transcript
# reference and the round baseline are cleared so the next round measures the
# new session's transcript.
OLD_SESSION=$(rl_state_get "$LOOP_DIR" session_id)
SESSION_ID="$OLD_SESSION"
if printf '%s' "$FLAG_SESSION" | grep -qE '^[A-Za-z0-9_-]{8,}$'; then SESSION_ID="$FLAG_SESSION"; fi
SESSION_FILTER=""
CARRY="null"; PRIOR="null"
if [ -n "$OLD_SESSION" ] && [ "$SESSION_ID" != "$OLD_SESSION" ]; then
  OLD_CUM=$(jq -c '.coder_usage_cum // null' "$LOOP_DIR/state.json")
  # The new session's own stored total, and the other sessions' totals summed.
  PRIOR=$(jq -c --arg sid "$SESSION_ID" '((.sessions // []) | map(select(.id == $sid)) | last | .cum) // null' "$LOOP_DIR/state.json")
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [ "$CARRY" = "null" ]; then CARRY="$u"; else CARRY=$(rl_usage_add "$CARRY" "$u"); fi
  done < <(jq -c --arg osid "$OLD_SESSION" --arg sid "$SESSION_ID" --argjson ocum "$OLD_CUM" \
    '(((.sessions // []) | map(select(.id != $osid))) + [{id: $osid, cum: $ocum}])[] | select(.id != $sid and .cum != null) | .cum' "$LOOP_DIR/state.json")
  SESSION_FILTER='| .sessions = (((.sessions // []) | map(select(.id != $osid))) + [{id: $osid, until: $t, round: $r, cum: $ocum}])
   | .transcript_path = null | .coder_usage_base = null | .coder_usage_cum = $prior | .coder_usage_carry = $carry'
  rl_log "$LOOP_DIR" "continued in another session ($OLD_SESSION -> $SESSION_ID): its usage so far stored, $([ "$PRIOR" = "null" ] && echo "new session starts from nothing" || echo "resuming the new session's earlier total"), transcript and baseline reset"
else
  OLD_CUM="null"
fi

# Re-open in an order that leaves the capped loop intact if anything fails:
# the pointer first (nothing else has changed if it cannot be written), then
# the state (the pointer is removed again if that fails), then the summary
# written at the cap is kept aside for the record (the final one is written
# again when the loop ends, so a failed move is only a warning).
EXT_N=$(( $(jq -r '(.extensions // []) | length' "$LOOP_DIR/state.json") + 1 ))
POINTER="$ROOT/$RL_POINTER_REL"
{ mkdir -p "$ROOT/.claude" && [ ! -d "$POINTER" ] && printf '%s\n' "$LOOP_DIR" > "$POINTER"; } 2> /dev/null \
  || rl_die "cannot write $POINTER; the loop is left as it was (still at its cap). Fix the cause, then run this script again."
rl_state_update "$LOOP_DIR" --argjson m "$NEW_MAX" --argjson n "$ROUNDS" --argjson old "$MAX_ROUNDS" --argjson r "$ROUND" \
  --arg t "$(rl_now)" --arg sid "$SESSION_ID" --arg osid "$OLD_SESSION" --argjson carry "$CARRY" --argjson prior "$PRIOR" --argjson ocum "$OLD_CUM" \
  '.active = true | .phase = "coding" | .outcome = null | .finished_at = null | .retries = 0 | .max_rounds = $m
   | .session_id = (if $sid == "" then null else $sid end)
   | .extensions = ((.extensions // []) + [{at: $t, rounds: $n, from_max: $old, to_max: $m, at_round: $r}])'"$SESSION_FILTER" \
  || { rm -f "$POINTER"; rl_die "cannot update $LOOP_DIR/state.json; the loop is left as it was (still at its cap). Fix the cause, then run this script again."; }
if [ -f "$LOOP_DIR/summary.md" ] && ! mv -f "$LOOP_DIR/summary.md" "$LOOP_DIR/summary.before-extension-$EXT_N.md" 2> /dev/null; then
  rl_log "$LOOP_DIR" "warning: could not keep summary.md aside as summary.before-extension-$EXT_N.md"
  echo "review-loop: warning: could not keep $LOOP_DIR/summary.md aside; it will be overwritten when the loop ends" >&2
fi
rl_log "$LOOP_DIR" "continued: +$ROUNDS round(s), max_rounds $MAX_ROUNDS -> $NEW_MAX (extension $EXT_N, at round $ROUND)"

echo "Review loop $LOOP_ID continued with $ROUNDS extra round(s): max rounds $MAX_ROUNDS -> $NEW_MAX."
echo "  dir: $LOOP_DIR"
echo "  the summary written at the cap is kept at $LOOP_DIR/summary.before-extension-$EXT_N.md"
echo
# Round $ROUND's review is installed and its transition is pending: review.sh
# resumes from it and starts round $(( ROUND + 1 )).
set +e
bash "$RL_SCRIPTS_DIR/review.sh"
RC=$?
set -e
rl_dashboard_auto "$LOOP_DIR" "$ROOT"
exit "$RC"
