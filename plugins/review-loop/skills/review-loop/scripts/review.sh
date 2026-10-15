#!/usr/bin/env bash
# review-loop — run the reviewer backend for the current round.
#
# Owns every state transition after a review:
#   approved                      -> finalize (summary.md, pointer removed)
#   changes_requested, round<max  -> round+1, phase coding
#   changes_requested, round>=max -> finalize (max rounds reached)
# Exit 0 when a review was installed (whatever the verdict), 1 otherwise.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"
rl_load_loop || rl_die "no active review loop (run /review-loop <task> first)"
cd "$RL_ROOT"

ROUND=$(rl_state_get "$RL_LOOP_DIR" round)
MAX_ROUNDS=$(rl_state_get "$RL_LOOP_DIR" max_rounds)
BACKEND=$(rl_state_get "$RL_LOOP_DIR" backend)
MODEL=$(rl_state_get "$RL_LOOP_DIR" model)
BASE_REF=$(rl_state_get "$RL_LOOP_DIR" base_ref)
DIR=$(rl_state_get "$RL_LOOP_DIR" dir)
NN=$(rl_round_nn "$ROUND")
USAGE_ON=0; rl_usage_enabled "$RL_LOOP_DIR" && USAGE_ON=1

CODER_FILE="$RL_LOOP_DIR/round-$NN-coder.md"
PROMPT_FILE="$RL_LOOP_DIR/round-$NN-prompt.md"
RAW_FILE="$RL_LOOP_DIR/round-$NN-review.raw.md"
REVIEW_FILE="$RL_LOOP_DIR/round-$NN-review.md"
BACKEND_SCRIPT="$RL_BACKENDS_DIR/$BACKEND.sh"

if [ ! -s "$CODER_FILE" ]; then
  rl_log "$RL_LOOP_DIR" "review.sh: coder summary missing for round $ROUND"
  rl_die "coder summary missing. Write $CODER_FILE (template: $RL_TEMPLATES_DIR/coder-summary.md), then run this script again."
fi
[ -f "$BACKEND_SCRIPT" ] || rl_die "unknown backend '$BACKEND' ($BACKEND_SCRIPT not found)"
rm -f "$REVIEW_FILE" "$RAW_FILE" "$RAW_FILE.tmp"

# ── Build the prompt ─────────────────────────────────────────────────────────
TASK=$(cat "$RL_LOOP_DIR/task.md")
CODER_SUMMARY=$(cat "$CODER_FILE")
REVIEW_FORMAT=$(sed "s/{{ROUND}}/$ROUND/g" "$RL_TEMPLATES_DIR/review-format.md")

PREVIOUS_REVIEWS=""
if [ "$ROUND" -gt 1 ]; then
  PREVIOUS_REVIEWS="## Previous reviews (verify each comment ID below was addressed)"$'\n'
  for ((r = 1; r < ROUND; r++)); do
    f="$RL_LOOP_DIR/round-$(rl_round_nn "$r")-review.md"
    [ -f "$f" ] || continue
    PREVIOUS_REVIEWS+=$'\n'"### Review of round $r"$'\n\n'"$(cat "$f")"$'\n'
  done
fi

EXCLUDES=$(rl_git_excludes "$RL_ROOT" "$DIR" "$RL_LOOP_DIR" | sed "s/.*/'&'/" | tr '\n' ' ')
FIND_EXCLUDES=$(rl_exclude_paths "$RL_ROOT" "$DIR" "$RL_LOOP_DIR" | sed "s|.*|-not -path './&' -not -path './&/*'|" | tr '\n' ' ')
if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "null" ]; then
  DIFF_INSTRUCTIONS="The project is a git repository at \`$RL_ROOT\`. The loop started at commit \`$BASE_REF\` (the coder may have committed since; review everything after that point):

\`\`\`
git diff $BASE_REF -- . $EXCLUDES
git status --porcelain --untracked-files=all -- . $EXCLUDES
\`\`\`

Untracked files listed by \`git status\` are new files; read them in full."
else
  DIFF_INSTRUCTIONS="The project at \`$RL_ROOT\` is not a git repository. Review the files modified since the loop started, for example:

\`\`\`
find . -type f -newer '$RL_LOOP_DIR/task.md' $FIND_EXCLUDES
\`\`\`"
fi

PROMPT=$(cat "$RL_TEMPLATES_DIR/reviewer-prompt.md")
PROMPT=${PROMPT//'{{ROUND}}'/$ROUND}
PROMPT=${PROMPT//'{{MAX_ROUNDS}}'/$MAX_ROUNDS}
PROMPT=${PROMPT//'{{TASK}}'/$TASK}
PROMPT=${PROMPT//'{{CODER_SUMMARY}}'/$CODER_SUMMARY}
PROMPT=${PROMPT//'{{PREVIOUS_REVIEWS}}'/$PREVIOUS_REVIEWS}
PROMPT=${PROMPT//'{{DIFF_INSTRUCTIONS}}'/$DIFF_INSTRUCTIONS}
PROMPT=${PROMPT//'{{REVIEW_FORMAT}}'/$REVIEW_FORMAT}
PROMPT=${PROMPT//'{{LOOP_DIR}}'/$RL_LOOP_DIR}
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# ── Run the backend ──────────────────────────────────────────────────────────
echo "review-loop: round $ROUND/$MAX_ROUNDS — running reviewer backend '$BACKEND'${MODEL:+ (model: $MODEL)}"
rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND backend=$BACKEND model=${MODEL:-default} start"
START=$(date +%s)
set +e
REVIEW_LOOP_NESTED=1 REVIEW_LOOP_MODEL="$MODEL" REVIEW_LOOP_ROUND="$ROUND" REVIEW_LOOP_USAGE="$USAGE_ON" \
  REVIEW_LOOP_LOOP_DIR="$RL_LOOP_DIR" REVIEW_LOOP_ROOT="$RL_ROOT" \
  bash "$BACKEND_SCRIPT" "$PROMPT_FILE" "$RAW_FILE"
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))

if [ "$RC" -ne 0 ]; then
  rm -f "$RAW_FILE" "$RAW_FILE.tmp"
  rl_log "$RL_LOOP_DIR" "review.sh: backend '$BACKEND' failed (exit=$RC, ${ELAPSED}s)"
  rl_die "reviewer backend '$BACKEND' failed (exit $RC after ${ELAPSED}s). Check the output above and $RL_LOOP_DIR/loop.log, fix the cause, then run this script again."
fi
if [ ! -s "$RAW_FILE" ]; then
  rl_log "$RL_LOOP_DIR" "review.sh: backend '$BACKEND' produced no output (${ELAPSED}s)"
  rl_die "reviewer backend '$BACKEND' produced no output. Run this script again."
fi

# ── Validate and install ─────────────────────────────────────────────────────
if ! VERDICT=$(rl_parse_verdict "$RAW_FILE"); then
  mv "$RAW_FILE" "$RL_LOOP_DIR/round-$NN-review.invalid.md"
  rl_log "$RL_LOOP_DIR" "review.sh: no verdict found in backend output (${ELAPSED}s)"
  rl_die "the reviewer's output contains no 'VERDICT: approved|changes_requested' line (kept at $RL_LOOP_DIR/round-$NN-review.invalid.md). Run this script again."
fi
if ! PROBLEM=$(rl_validate_review "$RAW_FILE" "$VERDICT"); then
  mv "$RAW_FILE" "$RL_LOOP_DIR/round-$NN-review.invalid.md"
  rm -f "$RAW_FILE".*
  rl_log "$RL_LOOP_DIR" "review.sh: review rejected: $PROBLEM (${ELAPSED}s)"
  rl_die "the reviewer's output is not a usable review: $PROBLEM (kept at $RL_LOOP_DIR/round-$NN-review.invalid.md). Run this script again."
fi
BLOCKING=$(rl_count_blocking "$RAW_FILE")
if [ "$VERDICT" = "approved" ] && [ "$BLOCKING" -gt 0 ]; then
  rl_log "$RL_LOOP_DIR" "review.sh: verdict 'approved' downgraded to 'changes_requested' ($BLOCKING blocking item(s))"
  echo "review-loop: reviewer said 'approved' but listed $BLOCKING blocking item(s); treating as changes_requested"
  VERDICT="changes_requested"
fi
{
  echo "---"
  echo "verdict: $VERDICT"
  echo "round: $ROUND"
  echo "backend: $BACKEND"
  echo "model: ${MODEL:-default}"
  echo "blocking: $BLOCKING"
  echo "generated_at: $(rl_now)"
  echo "---"
  echo
  cat "$RAW_FILE"
} > "$REVIEW_FILE"
rm -f "$RAW_FILE"
rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND verdict=$VERDICT blocking=$BLOCKING (${ELAPSED}s)"

# ── Record the round (usage only when enabled) ───────────────────────────────
if [ "$USAGE_ON" = "1" ]; then
  REVIEWER_USAGE=$(rl_normalize_usage "$RAW_FILE.usage.json")
  CODER_USAGE="null"
  if CODER_CUM=$(rl_coder_usage_cumulative "$RL_LOOP_DIR"); then
    PREV_CUM=$(jq -c '.coder_usage_cum // empty' "$RL_LOOP_DIR/state.json")
    if [ -n "$PREV_CUM" ]; then CODER_USAGE=$(rl_usage_sub "$CODER_CUM" "$PREV_CUM"); else CODER_USAGE="$CODER_CUM"; fi
    rl_state_update "$RL_LOOP_DIR" --argjson c "$CODER_CUM" '.coder_usage_cum = $c'
  fi
  rl_state_update "$RL_LOOP_DIR" --argjson r "$ROUND" --arg v "$VERDICT" --argjson b "$BLOCKING" --argjson d "$ELAPSED" \
    --argjson rev "$REVIEWER_USAGE" --argjson cod "$CODER_USAGE" \
    '.rounds = ((.rounds // []) | map(select(.round != $r))) + [{round: $r, verdict: $v, blocking: $b, duration_s: $d, reviewer: $rev, coder: $cod}]'
  rl_write_usage_md "$RL_LOOP_DIR"
  rl_log "$RL_LOOP_DIR" "review.sh: usage reviewer=$(jq -r '"\(.input_tokens)+\(.cached_input_tokens)c in / \(.output_tokens) out, cost \(.cost_usd // "n/a")"' <<< "$REVIEWER_USAGE") coder=$(jq -r 'if . == null then "n/a" else "\(.input_tokens)+\(.cached_input_tokens)c in / \(.output_tokens) out" end' <<< "$CODER_USAGE")"
else
  rl_state_update "$RL_LOOP_DIR" --argjson r "$ROUND" --arg v "$VERDICT" --argjson b "$BLOCKING" --argjson d "$ELAPSED" \
    '.rounds = ((.rounds // []) | map(select(.round != $r))) + [{round: $r, verdict: $v, blocking: $b, duration_s: $d}]'
fi
rm -f "$RAW_FILE".*

# ── Transition ───────────────────────────────────────────────────────────────
echo
if [ "$VERDICT" = "approved" ]; then
  rl_state_update "$RL_LOOP_DIR" --arg v "$VERDICT" '.verdict = $v | .retries = 0'
  rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "approved" "done" "Approved by the reviewer in round $ROUND."
  cat << OUT
review-loop: APPROVED in round $ROUND of $MAX_ROUNDS (${ELAPSED}s).
  review:  $REVIEW_FILE
  summary: $RL_LOOP_DIR/summary.md$([ "$USAGE_ON" = "1" ] && printf '\n  usage:   %s/usage.md' "$RL_LOOP_DIR")

The loop is finished. Report the outcome to the user (mention any optional
nits from the review you chose not to apply) and stop.
OUT
  exit 0
fi

if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
  rl_state_update "$RL_LOOP_DIR" --arg v "$VERDICT" '.verdict = $v | .retries = 0'
  rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "max_rounds_reached" "done" "The reviewer still requested changes after $ROUND round(s); the loop stopped at the configured maximum."
  cat << OUT
review-loop: CHANGES REQUESTED in round $ROUND, and the maximum of $MAX_ROUNDS round(s) is reached.
  review:  $REVIEW_FILE
  summary: $RL_LOOP_DIR/summary.md

The loop is finished without approval. Read the summary, report the unresolved
comments (by ID) to the user, and stop. Do not continue changing code.
OUT
  exit 0
fi

NEXT=$(( ROUND + 1 ))
NEXT_NN=$(rl_round_nn "$NEXT")
rl_state_update "$RL_LOOP_DIR" --arg v "$VERDICT" --argjson r "$NEXT" \
  '.verdict = $v | .round = $r | .phase = "coding" | .retries = 0'
rl_log "$RL_LOOP_DIR" "review.sh: advanced to round $NEXT"
cat << OUT
review-loop: CHANGES REQUESTED in round $ROUND of $MAX_ROUNDS ($BLOCKING blocking item(s), ${ELAPSED}s).
  review: $REVIEW_FILE$([ "$USAGE_ON" = "1" ] && printf '\n  usage:  %s/usage.md' "$RL_LOOP_DIR")

Now starting round $NEXT. Do not stop; do this:
  1. Read the review and address EVERY comment by ID: fix it, or decline it with a clear reason.
  2. Write $RL_LOOP_DIR/round-$NEXT_NN-coder.md (template: $RL_TEMPLATES_DIR/coder-summary.md)
     including the "Responses to the previous review" table with one row per comment ID.
  3. Run again: bash $RL_SCRIPTS_DIR/review.sh
OUT
