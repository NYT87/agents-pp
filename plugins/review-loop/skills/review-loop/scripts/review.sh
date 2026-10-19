#!/usr/bin/env bash
# review-loop — run the reviewer backend for the current round.
#
# Owns every state transition after a review:
#   approved                      -> finalize (summary.md, pointer removed)
#   changes_requested, round<max  -> round+1, phase coding
#   changes_requested, round>=max -> finalize (max rounds reached)
# Exit 0 when a review was installed and its transition applied (whatever the
# verdict), 1 otherwise. A review whose transition failed (e.g. the next brief
# could not be built) stays installed: the next run resumes from it instead of
# running the reviewer again.
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

# ── Transition ───────────────────────────────────────────────────────────────
# Applies this round's installed review (VERDICT, BLOCKING and the round's
# timings) to the loop state. Shared by a fresh review and a resumed one.
apply_verdict() {
  echo
  if [ "$VERDICT" = "approved" ]; then
    rl_state_update "$RL_LOOP_DIR" --arg v "$VERDICT" '.verdict = $v | .retries = 0'
    rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "approved" "done" "Approved by the reviewer in round $ROUND."
    cat << OUT
review-loop: APPROVED in round $ROUND of $MAX_ROUNDS (coder $([ "$UNDERESTIMATED" = true ] && printf 'at least ')$(rl_fmt_dur "$CODER_S"), review $(rl_fmt_dur "$ELAPSED")).
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
review-loop: CHANGES REQUESTED in round $ROUND (coder $([ "$UNDERESTIMATED" = true ] && printf 'at least ')$(rl_fmt_dur "$CODER_S"), review $(rl_fmt_dur "$ELAPSED")), and the maximum of $MAX_ROUNDS round(s) is reached.
  review:  $REVIEW_FILE
  summary: $RL_LOOP_DIR/summary.md

The loop is finished without approval. Read the summary, report the unresolved
comments (by ID) to the user, and stop. Do not continue changing code.
OUT
    exit 0
  fi

  NEXT=$(( ROUND + 1 ))
  NEXT_NN=$(rl_round_nn "$NEXT")
  # The next round's brief is re-rendered only now, after a changes_requested
  # verdict that leaves rounds to go: the coder's prompt files are needed for the
  # next round alone, so a missing one must never block an approval or the final
  # round. If it cannot be built or written, the round is NOT advanced: the review
  # stays installed and the next run of this script resumes from it.
  NEXT_BRIEF=$(rl_coder_brief "$RL_LOOP_DIR") || {
    rl_log "$RL_LOOP_DIR" "review.sh: coder brief for round $NEXT could not be built; round $ROUND not advanced"
    echo "review-loop: round $ROUND not advanced; the review is kept at $REVIEW_FILE and the next run resumes from it." >&2
    exit 1
  }
  # Install the brief before the state moves on: a brief that cannot be written
  # must never leave the coder on round $NEXT with round $ROUND's instructions.
  BRIEF_TMP="$RL_LOOP_DIR/coder-brief.md.tmp"
  if ! { [ ! -d "$RL_LOOP_DIR/coder-brief.md" ] && printf '%s\n' "$NEXT_BRIEF" > "$BRIEF_TMP" && mv -f "$BRIEF_TMP" "$RL_LOOP_DIR/coder-brief.md"; }; then
    rm -f "$BRIEF_TMP" 2> /dev/null || true
    rl_log "$RL_LOOP_DIR" "review.sh: coder brief for round $NEXT could not be written; round $ROUND not advanced"
    rl_die "cannot write $RL_LOOP_DIR/coder-brief.md (round $ROUND not advanced; the review is kept at $REVIEW_FILE and the next run resumes from it). Fix the cause, then run this script again."
  fi
  rl_state_update "$RL_LOOP_DIR" --arg v "$VERDICT" --argjson r "$NEXT" --arg t "$(rl_now)" --argjson e "$(rl_epoch)" \
    '.verdict = $v | .round = $r | .phase = "coding" | .retries = 0
     | .round_started_at = $t | .round_started_epoch = $e | .paused_s = 0 | .failed_review_s = 0 | del(.paused_at_epoch) | del(.coder_time_underestimated)'
  rl_log "$RL_LOOP_DIR" "review.sh: advanced to round $NEXT (coder brief re-rendered)"
  cat << OUT
review-loop: CHANGES REQUESTED in round $ROUND of $MAX_ROUNDS ($BLOCKING blocking item(s); coder $([ "$UNDERESTIMATED" = true ] && printf 'at least ')$(rl_fmt_dur "$CODER_S"), review $(rl_fmt_dur "$ELAPSED")).
  review: $REVIEW_FILE$([ "$USAGE_ON" = "1" ] && printf '\n  usage:  %s/usage.md' "$RL_LOOP_DIR")

Now starting round $NEXT. Do not stop; do this:
  0. Re-read your brief, regenerated for this round: $RL_LOOP_DIR/coder-brief.md
  1. Read the review and address EVERY comment by ID: fix it, or decline it with a clear reason.
  2. Write $RL_LOOP_DIR/round-$NEXT_NN-coder.md (template: $RL_TEMPLATES_DIR/coder-summary.md)
     including the "Responses to the previous review" table with one row per comment ID.
  3. Run again: bash $RL_SCRIPTS_DIR/review.sh
OUT
  exit 0
}

# ── Resume a pending transition ──────────────────────────────────────────────
# A review installed for the current round is valid and final (review files are
# installed only after validation): it means the transition after it failed.
# Apply it again rather than run the reviewer a second time, which could replace
# the verdict and drop its blocking comments.
if [ -f "$REVIEW_FILE" ] && ! rl_parse_verdict <(rl_review_body "$REVIEW_FILE") > /dev/null; then
  # Reviews are installed atomically, so a body without its final VERDICT line
  # is a file an older version left half-written (or a hand edit): never trust
  # it. Keep it for inspection and review the round again.
  mv -f "$REVIEW_FILE" "$RL_LOOP_DIR/round-$NN-review.truncated.md"
  rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND review has no verdict line in its body (truncated?); moved to round-$NN-review.truncated.md"
  echo "review-loop: warning: $REVIEW_FILE is incomplete (no VERDICT line in its body); moved to round-$NN-review.truncated.md, reviewing the round again"
fi
if [ -f "$REVIEW_FILE" ]; then
  VERDICT=$(rl_review_meta "$REVIEW_FILE" verdict)
  case "$VERDICT" in
    approved|changes_requested) ;;
    *) rl_die "the installed review $REVIEW_FILE has no usable verdict in its front matter. Move it away, then run this script again." ;;
  esac
  BLOCKING=$(rl_review_meta "$REVIEW_FILE" blocking)
  case "$BLOCKING" in ''|*[!0-9]*) BLOCKING=$(rl_count_blocking "$REVIEW_FILE") ;; esac
  RINFO=$(jq -c --argjson r "$ROUND" '((.rounds // []) | map(select(.round == $r)) | last) // {}' "$RL_LOOP_DIR/state.json")
  if [ "$RINFO" = "{}" ]; then
    # Reviews are recorded before they are installed, so a missing record means
    # an older loop or a hand-edited state.json. Restore what the review itself
    # carries; the durations and usage of that run are gone.
    rl_state_update "$RL_LOOP_DIR" --argjson r "$ROUND" --arg v "$VERDICT" --argjson b "$BLOCKING" \
      '.rounds = ((.rounds // []) | map(select(.round != $r))) + [{round: $r, verdict: $v, blocking: $b, coder_duration_s: null, coder_time_underestimated: false, duration_s: null}]' \
      || rl_die "cannot record round $ROUND in $RL_LOOP_DIR/state.json. Fix the cause, then run this script again."
    if [ "$USAGE_ON" = "1" ]; then rl_write_usage_md "$RL_LOOP_DIR"; fi
    rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND record restored from the installed review (durations and usage unknown)"
    echo "review-loop: warning: round $ROUND had no record in state.json; restored from the review (durations and usage unknown)"
    RINFO=$(jq -c --argjson r "$ROUND" '((.rounds // []) | map(select(.round == $r)) | last) // {}' "$RL_LOOP_DIR/state.json")
  fi
  ELAPSED=$(jq -r '.duration_s // 0' <<< "$RINFO")
  CODER_S=$(jq -r '.coder_duration_s // empty' <<< "$RINFO")
  UNDERESTIMATED=$(jq -r '.coder_time_underestimated // false' <<< "$RINFO")
  echo "review-loop: round $ROUND/$MAX_ROUNDS — a review is already installed (verdict: $VERDICT); resuming its pending transition without running the reviewer again"
  rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND resumed from the installed review (verdict=$VERDICT blocking=$BLOCKING)"
  apply_verdict
fi

# ── A fresh review needs the coder's summary and a backend ───────────────────
# (checked only now: a pending transition needs neither, and the summary may
# be gone by the time it is resumed)
if [ ! -s "$CODER_FILE" ]; then
  rl_log "$RL_LOOP_DIR" "review.sh: coder summary missing for round $ROUND"
  rl_die "coder summary missing. Write $CODER_FILE (template: $RL_TEMPLATES_DIR/coder-summary.md), then run this script again."
fi
[ -f "$BACKEND_SCRIPT" ] || rl_die "unknown backend '$BACKEND' ($BACKEND_SCRIPT not found)"
# Leftovers of an interrupted run; anything that cannot be removed (say, a
# directory in the way) fails the install below with a clear message instead.
rm -f "$RAW_FILE" "$RAW_FILE.tmp" "$REVIEW_FILE.tmp" 2> /dev/null || true

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

P_REVIEWER=$(jq -r '.prompts.reviewer // ""' "$RL_LOOP_DIR/state.json")
P_REVIEWER_EXTRA=$(jq -r '.prompts.reviewer_extra // ""' "$RL_LOOP_DIR/state.json")
PROMPT=$(rl_role_prompt "$RL_ROOT" reviewer "$RL_TEMPLATES_DIR/reviewer-prompt.md" "$P_REVIEWER" "$P_REVIEWER_EXTRA")
PROMPT=${PROMPT//'{{ROUND}}'/$ROUND}
PROMPT=${PROMPT//'{{MAX_ROUNDS}}'/$MAX_ROUNDS}
PROMPT=${PROMPT//'{{TASK}}'/$TASK}
PROMPT=${PROMPT//'{{CODER_SUMMARY}}'/$CODER_SUMMARY}
PROMPT=${PROMPT//'{{PREVIOUS_REVIEWS}}'/$PREVIOUS_REVIEWS}
PROMPT=${PROMPT//'{{DIFF_INSTRUCTIONS}}'/$DIFF_INSTRUCTIONS}
PROMPT=${PROMPT//'{{REVIEW_FORMAT}}'/$REVIEW_FORMAT}
PROMPT=${PROMPT//'{{LOOP_DIR}}'/$RL_LOOP_DIR}
PROMPT=${PROMPT//'{{ROOT}}'/$RL_ROOT}
PROMPT=${PROMPT//'{{BACKEND}}'/$BACKEND}
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# ── Coder time for this round (round start -> now, pauses excluded) ──────────
if [ -n "$(rl_state_get "$RL_LOOP_DIR" paused_at_epoch)" ]; then
  # No UserPromptSubmit hook recorded the user's reply; end the pause now. The
  # work done since the reply is then counted as paused.
  rl_resume_pause "$RL_LOOP_DIR" "review.sh fallback" late || true
fi
UNDERESTIMATED=$(rl_state_get "$RL_LOOP_DIR" coder_time_underestimated)
if [ "$UNDERESTIMATED" = "true" ]; then
  echo "review-loop: warning: a pause in this round was only ended at the next stop or now, not at your reply, so the round's coder time is underestimated (install the plugin hooks, including UserPromptSubmit, to record resumes)"
else
  UNDERESTIMATED=false
fi
CODER_S=$(rl_round_coder_seconds "$RL_LOOP_DIR") || CODER_S=""
rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND coder time ${CODER_S:-unknown}s"

# ── Run the backend ──────────────────────────────────────────────────────────
echo "review-loop: round $ROUND/$MAX_ROUNDS — coder worked $([ "$UNDERESTIMATED" = true ] && printf 'at least ')$(rl_fmt_dur "$CODER_S"); running reviewer backend '$BACKEND'${MODEL:+ (model: $MODEL)}"
rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND backend=$BACKEND model=${MODEL:-default} start"
START=$(rl_epoch)
set +e
REVIEW_LOOP_NESTED=1 REVIEW_LOOP_MODEL="$MODEL" REVIEW_LOOP_ROUND="$ROUND" REVIEW_LOOP_USAGE="$USAGE_ON" \
  REVIEW_LOOP_LOOP_DIR="$RL_LOOP_DIR" REVIEW_LOOP_ROOT="$RL_ROOT" \
  bash "$BACKEND_SCRIPT" "$PROMPT_FILE" "$RAW_FILE"
RC=$?
set -e
ELAPSED=$(( $(rl_epoch) - START ))

# A failed attempt must not count as coder time when the round is retried.
note_failed_attempt() {
  rl_state_update "$RL_LOOP_DIR" --argjson e "$ELAPSED" '.failed_review_s = ((.failed_review_s // 0) + $e)' || true
  rl_log "$RL_LOOP_DIR" "review.sh: failed attempt took ${ELAPSED}s (excluded from coder time)"
}

if [ "$RC" -ne 0 ]; then
  rm -f "$RAW_FILE" "$RAW_FILE.tmp"
  note_failed_attempt
  rl_log "$RL_LOOP_DIR" "review.sh: backend '$BACKEND' failed (exit=$RC, ${ELAPSED}s)"
  rl_die "reviewer backend '$BACKEND' failed (exit $RC after ${ELAPSED}s). Check the output above and $RL_LOOP_DIR/loop.log, fix the cause, then run this script again."
fi
if [ ! -s "$RAW_FILE" ]; then
  note_failed_attempt
  rl_log "$RL_LOOP_DIR" "review.sh: backend '$BACKEND' produced no output (${ELAPSED}s)"
  rl_die "reviewer backend '$BACKEND' produced no output. Run this script again."
fi

# ── Validate and install ─────────────────────────────────────────────────────
if ! VERDICT=$(rl_parse_verdict "$RAW_FILE"); then
  note_failed_attempt
  mv "$RAW_FILE" "$RL_LOOP_DIR/round-$NN-review.invalid.md"
  rl_log "$RL_LOOP_DIR" "review.sh: no verdict found in backend output (${ELAPSED}s)"
  rl_die "the reviewer's output contains no 'VERDICT: approved|changes_requested' line (kept at $RL_LOOP_DIR/round-$NN-review.invalid.md). Run this script again."
fi
if ! PROBLEM=$(rl_validate_review "$RAW_FILE" "$VERDICT"); then
  note_failed_attempt
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
# ── Record the round (usage only when enabled) ───────────────────────────────
# Recorded BEFORE the review is installed: an installed review always has its
# entry in state.rounds[], which a resumed transition relies on. If this write
# fails nothing is installed and the next run reviews the round again.
if [ "$USAGE_ON" = "1" ]; then
  REVIEWER_USAGE=$(rl_normalize_usage "$RAW_FILE.usage.json")
  CODER_USAGE="null"
  # The coder's usage for a round is the session total since the round's
  # baseline. The baseline is the total when the previous round was recorded
  # (coder_usage_cum); a retry of THIS round (its record already exists, e.g.
  # the install failed) keeps the baseline it started from (coder_usage_base),
  # so the work done before the failed attempt is not lost. Both are updated in
  # the same write as the record so they never disagree with it.
  CUM_FILTER=""
  CODER_CUM="null"; CODER_BASE="null"
  if CODER_CUM=$(rl_coder_usage_cumulative "$RL_LOOP_DIR"); then
    if [ "$(jq --argjson r "$ROUND" '[.rounds[]? | select(.round == $r)] | length' "$RL_LOOP_DIR/state.json")" -gt 0 ]; then
      CODER_BASE=$(jq -c '.coder_usage_base // null' "$RL_LOOP_DIR/state.json")
    else
      CODER_BASE=$(jq -c '.coder_usage_cum // null' "$RL_LOOP_DIR/state.json")
    fi
    if [ "$CODER_BASE" != "null" ]; then CODER_USAGE=$(rl_usage_sub "$CODER_CUM" "$CODER_BASE"); else CODER_USAGE="$CODER_CUM"; fi
    CUM_FILTER='| .coder_usage_cum = $cum | .coder_usage_base = $base'
  else
    CODER_CUM="null"
  fi
  rl_state_update "$RL_LOOP_DIR" --argjson r "$ROUND" --arg v "$VERDICT" --argjson b "$BLOCKING" --argjson d "$ELAPSED" --argjson cd "${CODER_S:-null}" --argjson u "$UNDERESTIMATED" \
    --argjson rev "$REVIEWER_USAGE" --argjson cod "$CODER_USAGE" --argjson cum "$CODER_CUM" --argjson base "$CODER_BASE" \
    '.rounds = ((.rounds // []) | map(select(.round != $r))) + [{round: $r, verdict: $v, blocking: $b, coder_duration_s: $cd, coder_time_underestimated: $u, duration_s: $d, reviewer: $rev, coder: $cod}]'"$CUM_FILTER" \
    || rl_die "cannot record round $ROUND in $RL_LOOP_DIR/state.json (the review was not installed). Fix the cause, then run this script again."
  rl_write_usage_md "$RL_LOOP_DIR"
  rl_log "$RL_LOOP_DIR" "review.sh: usage reviewer=$(jq -r '"\(.input_tokens)+\(.cached_input_tokens)c in / \(.output_tokens) out, cost \(.cost_usd // "n/a")"' <<< "$REVIEWER_USAGE") coder=$(jq -r 'if . == null then "n/a" else "\(.input_tokens)+\(.cached_input_tokens)c in / \(.output_tokens) out" end' <<< "$CODER_USAGE")"
else
  rl_state_update "$RL_LOOP_DIR" --argjson r "$ROUND" --arg v "$VERDICT" --argjson b "$BLOCKING" --argjson d "$ELAPSED" --argjson cd "${CODER_S:-null}" --argjson u "$UNDERESTIMATED" \
    '.rounds = ((.rounds // []) | map(select(.round != $r))) + [{round: $r, verdict: $v, blocking: $b, coder_duration_s: $cd, coder_time_underestimated: $u, duration_s: $d}]' \
    || rl_die "cannot record round $ROUND in $RL_LOOP_DIR/state.json (the review was not installed). Fix the cause, then run this script again."
fi

# ── Install ──────────────────────────────────────────────────────────────────
# Written to a temporary file and renamed only once complete: an interrupted
# or failed write must never leave a review file behind, since the next run
# would resume from it as if it were whole. A directory at the final path is
# refused too: mv would silently drop the file inside it.
INSTALL_TMP="$REVIEW_FILE.tmp"
if ! {
  [ ! -d "$REVIEW_FILE" ] && {
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
  } > "$INSTALL_TMP" && mv -f "$INSTALL_TMP" "$REVIEW_FILE"
}; then
  rm -f "$INSTALL_TMP" 2> /dev/null || true
  rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND review could not be installed at $REVIEW_FILE"
  rl_die "cannot install $REVIEW_FILE (nothing was installed; the reviewer runs again on the next attempt). Fix the cause, then run this script again."
fi
rm -f "$RAW_FILE" "$RAW_FILE".*
rl_log "$RL_LOOP_DIR" "review.sh: round $ROUND verdict=$VERDICT blocking=$BLOCKING (${ELAPSED}s)"


apply_verdict
