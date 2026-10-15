#!/usr/bin/env bash
# review-loop — Claude Code Stop hook.
#
# While a loop is active in this session, block Claude from stopping and tell
# it what to do next. All state transitions happen in review.sh; this hook only
# enforces "keep going until the reviewer approves". Always prints valid JSON
# and never traps the user: on any internal error the loop is aborted visibly.
set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TRAP_LOOP_DIR="" TRAP_ROOT=""

emit_allow() { printf '{}\n'; exit 0; }
emit_allow_msg() {
  jq -n --arg m "$1" '{systemMessage: $m}' 2>/dev/null || printf '{}\n'
  exit 0
}
emit_block() {
  jq -n --arg r "$1" '{decision: "block", reason: $r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"review-loop: the review loop is still active; run review.sh and continue until approved."}\n'
  exit 0
}
on_err() {
  if [ -n "$TRAP_LOOP_DIR" ]; then
    rl_log "$TRAP_LOOP_DIR" "ERROR: stop hook failed at line $1; aborting loop"
    rl_state_update "$TRAP_LOOP_DIR" '.active = false | .phase = "failed" | .outcome = "hook_error"' 2>/dev/null || true
    rm -f "$TRAP_ROOT/$RL_POINTER_REL" 2>/dev/null || true
  fi
  jq -n '{systemMessage: "review-loop: hook error, loop aborted (see loop.log)"}' 2>/dev/null \
    || printf '{"systemMessage":"review-loop: hook error, loop aborted (see loop.log)"}\n'
  exit 0
}
trap 'on_err $LINENO' ERR

HOOK_INPUT=$(cat || true)

[ "${REVIEW_LOOP_NESTED:-}" = "1" ] && emit_allow
command -v jq > /dev/null 2>&1 || emit_allow

CWD=$(jq -r '.cwd // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)
if [ -n "$CWD" ] && [ -d "$CWD" ]; then cd "$CWD" || true; fi
SESSION_ID=$(jq -r '.session_id // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)
LAST_MSG=$(jq -r '.last_assistant_message // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)
STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<< "$HOOK_INPUT" 2>/dev/null || true)

rl_load_loop || emit_allow
TRAP_LOOP_DIR="$RL_LOOP_DIR" TRAP_ROOT="$RL_ROOT"

PHASE=$(rl_state_get "$RL_LOOP_DIR" phase)
ROUND=$(rl_state_get "$RL_LOOP_DIR" round)
MAX_ROUNDS=$(rl_state_get "$RL_LOOP_DIR" max_rounds)
RETRIES=$(rl_state_get "$RL_LOOP_DIR" retries)
BASE_REF=$(rl_state_get "$RL_LOOP_DIR" base_ref)
DIR=$(rl_state_get "$RL_LOOP_DIR" dir)
BOUND=$(rl_state_get "$RL_LOOP_DIR" session_id)
: "${RETRIES:=0}"
rl_log "$RL_LOOP_DIR" "stop hook: phase=$PHASE round=$ROUND retries=$RETRIES session=${SESSION_ID:-?} stop_hook_active=$STOP_ACTIVE"

# ── Session binding ──────────────────────────────────────────────────────────
TRANSCRIPT=""
if rl_usage_enabled "$RL_LOOP_DIR"; then
  TRANSCRIPT=$(jq -r '.transcript_path // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)
fi
if [ -z "$BOUND" ]; then
  if [ -n "$SESSION_ID" ]; then
    rl_state_update "$RL_LOOP_DIR" --arg s "$SESSION_ID" --arg t "$TRANSCRIPT" \
      '.session_id = $s | (if $t != "" then .transcript_path = $t else . end)'
  fi
elif [ -n "$SESSION_ID" ] && [ "$BOUND" != "$SESSION_ID" ]; then
  rl_log "$RL_LOOP_DIR" "stop hook: foreign session $SESSION_ID (loop bound to $BOUND); allowing"
  emit_allow
fi

if [ -n "$TRANSCRIPT" ] && [ "$(rl_state_get "$RL_LOOP_DIR" transcript_path)" != "$TRANSCRIPT" ] \
   && { [ -z "$BOUND" ] || [ "$BOUND" = "$SESSION_ID" ]; }; then
  rl_state_update "$RL_LOOP_DIR" --arg t "$TRANSCRIPT" '.transcript_path = $t'
fi

# ── Terminal phases ──────────────────────────────────────────────────────────
case "$PHASE" in
  coding|paused) ;;
  *)
    rl_log "$RL_LOOP_DIR" "stop hook: phase '$PHASE' is terminal; clearing pointer"
    rm -f "$RL_POINTER"
    emit_allow ;;
esac

# ── Pause marker ─────────────────────────────────────────────────────────────
if [ "$PHASE" = "paused" ]; then
  # Fallback resume (the UserPromptSubmit hook normally did this already).
  rl_resume_pause "$RL_LOOP_DIR" "stop hook fallback" late || true
elif printf '%s' "$LAST_MSG" | grep -qF "$RL_PAUSE_MARKER"; then
  rl_state_update "$RL_LOOP_DIR" --argjson now "$(rl_epoch)" '.phase = "paused" | .paused_at_epoch = $now'
  rl_log "$RL_LOOP_DIR" "stop hook: paused by marker"
  emit_allow_msg "review-loop: paused (loop $RL_LOOP_ID, round $ROUND). It resumes on your next message; /review-cancel aborts it."
fi

# ── Work detection ───────────────────────────────────────────────────────────
has_changes() {
  local excl=() line
  if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "null" ] && git -C "$RL_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    while IFS= read -r line; do excl+=("$line"); done < <(rl_git_excludes "$RL_ROOT" "$DIR" "$RL_LOOP_DIR")
    if ! git -C "$RL_ROOT" diff --quiet "$BASE_REF" -- . "${excl[@]}" 2>/dev/null; then return 0; fi
    [ -n "$(git -C "$RL_ROOT" status --porcelain --untracked-files=all -- . "${excl[@]}" 2>/dev/null)" ] && return 0
    return 1
  fi
  local found fexcl=()
  while IFS= read -r line; do fexcl+=("$line"); done < <(rl_find_excludes "$RL_ROOT" "$DIR" "$RL_LOOP_DIR")
  found=$(cd "$RL_ROOT" && find . -type f -newer "$RL_LOOP_DIR/task.md" \
    -not -path "./.git/*" ${fexcl[@]+"${fexcl[@]}"} 2>/dev/null | head -1)
  [ -n "$found" ]
}

RETRIES=$(( RETRIES + 1 ))
rl_state_update "$RL_LOOP_DIR" --argjson n "$RETRIES" '.retries = $n'

if ! has_changes; then
  if [ "$RETRIES" -gt "$RL_MAX_RETRIES" ]; then
    rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "no_work" "failed" "The loop was stopped $RETRIES times without any changes to the project."
    emit_allow_msg "review-loop: aborted, no changes were made for the task (summary: $RL_LOOP_DIR/summary.md)"
  fi
  emit_block "Review loop $RL_LOOP_ID is active (round $ROUND of $MAX_ROUNDS) but no changes to the project were detected. Implement the task described in $RL_LOOP_DIR/task.md before stopping. When the implementation is complete, write $RL_LOOP_DIR/round-$(rl_round_nn "$ROUND")-coder.md (template: $RL_TEMPLATES_DIR/coder-summary.md) and run: bash $RL_SCRIPTS_DIR/review.sh
If you genuinely need input from the user, end your message with the line '$RL_PAUSE_MARKER'. To abort the loop, run /review-cancel."
fi

if [ "$RETRIES" -gt "$RL_MAX_RETRIES" ]; then
  rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "review_not_run" "failed" "The loop was stopped $RETRIES times in round $ROUND without a successful reviewer run."
  emit_allow_msg "review-loop: aborted, the reviewer was never run successfully in round $ROUND (summary: $RL_LOOP_DIR/summary.md)"
fi

NN=$(rl_round_nn "$ROUND")
CODER_FILE="$RL_LOOP_DIR/round-$NN-coder.md"
MSG="Review loop $RL_LOOP_ID is active (round $ROUND of $MAX_ROUNDS) and the reviewer has not approved the work yet. Do not stop until it does."
if [ "$ROUND" -gt 1 ]; then
  PREV_NN=$(rl_round_nn "$(( ROUND - 1 ))")
  MSG+="
First make sure EVERY comment in $RL_LOOP_DIR/round-$PREV_NN-review.md is addressed: fix it, or decline it with a clear reason."
fi
if [ -s "$CODER_FILE" ]; then
  MSG+="
1. $CODER_FILE exists; update it if it no longer reflects your changes."
else
  MSG+="
1. Write $CODER_FILE following $RL_TEMPLATES_DIR/coder-summary.md"
  [ "$ROUND" -gt 1 ] && MSG+=" (include the per-ID response table for the previous review)."
fi
MSG+="
2. Run exactly this command with a 600000 ms timeout (the reviewer takes minutes): bash $RL_SCRIPTS_DIR/review.sh
3. Follow the instructions it prints. Stop only after it reports 'APPROVED' or that the maximum number of rounds was reached.
If you genuinely need input from the user, end your message with the line '$RL_PAUSE_MARKER'. To abort the loop, run /review-cancel."
emit_block "$MSG"
