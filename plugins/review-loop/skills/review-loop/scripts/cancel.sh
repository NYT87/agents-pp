#!/usr/bin/env bash
# review-loop — cancel the active loop.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

if ! rl_load_loop; then
  echo "No active review loop found."
  exit 0
fi

PHASE=$(rl_state_get "$RL_LOOP_DIR" phase)
ROUND=$(rl_state_get "$RL_LOOP_DIR" round)
rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "cancelled" "cancelled" "Cancelled by the user."
echo "Review loop cancelled (id: $RL_LOOP_ID, was at phase: $PHASE, round: $ROUND)."
echo "Summary: $RL_LOOP_DIR/summary.md"
