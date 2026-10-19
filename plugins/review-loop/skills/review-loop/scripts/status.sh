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
echo "  round:       $ROUND / $(rl_state_get "$RL_LOOP_DIR" max_rounds)$(jq -r '.extensions // [] | if length > 0 then " (extended: +\(map(.rounds) | add) round(s) in \(length) extension(s))" else "" end' "$RL_LOOP_DIR/state.json")"
echo "  backend:     $(rl_state_get "$RL_LOOP_DIR" backend) (model: $(rl_state_get "$RL_LOOP_DIR" model | sed 's/^$/default/'))"
echo "  usage:       $(rl_usage_enabled "$RL_LOOP_DIR" && echo on || echo off)"
echo "  prompts:     $(jq -r '.prompts // {} | "reviewer \(.reviewer // "" | if . == "" then "default" else . end) (+ \(.reviewer_extra // "" | if . == "" then "no extra" else . end)), coder \(.coder // "" | if . == "" then "default" else . end) (+ \(.coder_extra // "" | if . == "" then "no extra" else . end))"' "$RL_LOOP_DIR/state.json")"
echo "  last verdict: $(rl_state_get "$RL_LOOP_DIR" verdict | sed 's/^$/none/')"
echo "  started:     $(rl_state_get "$RL_LOOP_DIR" started_at)"
echo "  retries:     $(rl_state_get "$RL_LOOP_DIR" retries)"
CODER_S=$(rl_round_coder_seconds "$RL_LOOP_DIR") || CODER_S=""
echo "  coder time:  $([ "$(rl_state_get "$RL_LOOP_DIR" coder_time_underestimated)" = "true" ] && printf 'at least ')$(rl_fmt_dur "$CODER_S") on round $ROUND so far$([ "$(rl_state_get "$RL_LOOP_DIR" phase)" = "paused" ] && echo " (paused)")$([ "$(rl_state_get "$RL_LOOP_DIR" coder_time_underestimated)" = "true" ] && echo " (a pause ended late: underestimated)")"
if [ "$(jq -r '(.rounds // []) | length' "$RL_LOOP_DIR/state.json")" != "0" ]; then
  echo
  echo "Rounds so far:"
  jq -r '.rounds[]? | "\(.round)\t\(.verdict // "-")\t\(.blocking // "-")\t\(.coder_duration_s // "-")\t\(.duration_s // "-")\t\(if .coder_time_underestimated then "y" else "n" end)"' "$RL_LOOP_DIR/state.json" \
    | while IFS=$'\t' read -r rn rv rb rc rd ru; do
        printf '  round %s: %s, %s blocking, coder %s%s%s, review %s\n' "$rn" "$rv" "$rb" "$([ "$ru" = "y" ] && printf 'at least ')" "$(rl_fmt_dur "$rc")" "$([ "$ru" = "y" ] && printf ' (a pause ended late)')" "$(rl_fmt_dur "$rd")"
      done
fi
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
