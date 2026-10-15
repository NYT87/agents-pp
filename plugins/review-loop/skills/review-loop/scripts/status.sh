#!/usr/bin/env bash
# review-loop — print the state of the active loop (if any).
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

if ! rl_load_loop; then
  echo "No active review loop."
  exit 0
fi

ROUND=$(rl_state_get "$RL_LOOP_DIR" round)
NN=$(rl_round_nn "$ROUND")
echo "Review loop: $RL_LOOP_ID"
echo "  dir:         $RL_LOOP_DIR"
echo "  phase:       $(rl_state_get "$RL_LOOP_DIR" phase)"
echo "  round:       $ROUND / $(rl_state_get "$RL_LOOP_DIR" max_rounds)"
echo "  backend:     $(rl_state_get "$RL_LOOP_DIR" backend) (model: $(rl_state_get "$RL_LOOP_DIR" model | sed 's/^$/default/'))"
echo "  usage:       $(rl_usage_enabled "$RL_LOOP_DIR" && echo on || echo off)"
echo "  last verdict: $(rl_state_get "$RL_LOOP_DIR" verdict | sed 's/^$/none/')"
echo "  started:     $(rl_state_get "$RL_LOOP_DIR" started_at)"
echo "  retries:     $(rl_state_get "$RL_LOOP_DIR" retries)"
echo
echo "Round $ROUND files:"
if [ -f "$RL_LOOP_DIR/round-$NN-coder.md" ]; then
  echo "  coder summary: present"
else
  echo "  coder summary: MISSING -> write $RL_LOOP_DIR/round-$NN-coder.md"
fi
echo "  review:        not yet run (run: bash $RL_SCRIPTS_DIR/review.sh)"
PREV=$(ls "$RL_LOOP_DIR"/round-*-review.md 2>/dev/null | sort | tail -1 || true)
[ -n "$PREV" ] && echo "  previous review: $PREV"
if rl_usage_enabled "$RL_LOOP_DIR"; then
  echo
  echo "Usage so far:"
  rl_usage_table "$RL_LOOP_DIR" | sed 's/^/  /'
fi
echo
echo "Task:"
sed 's/^/  /' "$RL_LOOP_DIR/task.md"
