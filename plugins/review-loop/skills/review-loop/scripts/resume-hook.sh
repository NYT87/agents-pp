#!/usr/bin/env bash
# review-loop — Claude Code UserPromptSubmit hook.
#
# The user's reply is the real end of a pause: record it so the coder time of
# the round excludes exactly the waiting time. Never blocks; always prints
# valid JSON; does nothing when no loop is paused.
set -u
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

emit() { printf '{}\n'; exit 0; }
trap 'emit' ERR

HOOK_INPUT=$(cat || true)
[ "${REVIEW_LOOP_NESTED:-}" = "1" ] && emit
command -v jq > /dev/null 2>&1 || emit

CWD=$(jq -r '.cwd // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)
if [ -n "$CWD" ] && [ -d "$CWD" ]; then cd "$CWD" || true; fi
SESSION_ID=$(jq -r '.session_id // empty' <<< "$HOOK_INPUT" 2>/dev/null || true)

rl_load_loop || emit
BOUND=$(rl_state_get "$RL_LOOP_DIR" session_id)
if [ -n "$BOUND" ] && [ -n "$SESSION_ID" ] && [ "$BOUND" != "$SESSION_ID" ]; then emit; fi
rl_resume_pause "$RL_LOOP_DIR" "user reply" || true
emit
