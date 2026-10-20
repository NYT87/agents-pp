#!/usr/bin/env bash
# review-loop backend: fake (for tests).
#
# Contract: fake.sh PROMPT_FILE OUTPUT_FILE
# Pops the first line of $REVIEW_LOOP_FAKE_FILE and acts on it:
#   approved               approved review with one optional nit
#   changes_requested      one blocking comment
#   approved_with_blocking says approved but contains a blocking comment
#   prose                  prose + fenced frontmatter + bold verdict (approved)
#   garbage                no verdict at all
#   verdict_only           a bare "VERDICT: approved" line, no sections
#   cr_no_comments         changes_requested without any comment
#   fail                   exit 1, writes nothing
#   partial                writes OUTPUT_FILE then exits 1
# Missing file or empty line -> approved.
# Writes OUTPUT_FILE.usage.json with fixed numbers when REVIEW_LOOP_USAGE=1.
# `fake.sh --models` prints a fixed catalog (three models: two with levels, one
# with an empty list, i.e. unknown capabilities); with
# REVIEW_LOOP_FAKE_ENV_FILE set, a run records the model and effort it got.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

if [ "${1:-}" = "--models" ]; then
  jq -cn '{backend: "fake", source: "built in",
    models: [{id: "fake-fast",    label: "Fake fast",    efforts: ["low","high"],       default_effort: "low",  default: true},
             {id: "fake-smart",   label: "Fake smart",   efforts: ["low","high","max"], default_effort: "high", default: false},
             {id: "fake-mystery", label: "Fake mystery", efforts: [],                   default_effort: null,   default: false}],
    efforts: ["low","high","max"], default_model: "fake-fast", default_effort: "low"}'
  exit 0
fi

PROMPT_FILE="$1"
OUTPUT_FILE="$2"
[ -n "${REVIEW_LOOP_FAKE_ENV_FILE:-}" ] && printf 'MODEL=%s\nEFFORT=%s\n' "${REVIEW_LOOP_MODEL:-}" "${REVIEW_LOOP_EFFORT:-}" > "$REVIEW_LOOP_FAKE_ENV_FILE"
ROUND="${REVIEW_LOOP_ROUND:-1}"

# Test clock: advance REVIEW_LOOP_FAKE_CLOCK by REVIEW_LOOP_FAKE_TAKES seconds so
# an attempt has a measurable duration without sleeping.
if [ -n "${REVIEW_LOOP_FAKE_CLOCK:-}" ] && [ -n "${REVIEW_LOOP_FAKE_TAKES:-}" ] && [ -f "$REVIEW_LOOP_FAKE_CLOCK" ]; then
  echo $(( $(cat "$REVIEW_LOOP_FAKE_CLOCK") + REVIEW_LOOP_FAKE_TAKES )) > "$REVIEW_LOOP_FAKE_CLOCK"
fi

MODE="approved"
if [ -n "${REVIEW_LOOP_FAKE_FILE:-}" ] && [ -s "$REVIEW_LOOP_FAKE_FILE" ]; then
  MODE=$(head -1 "$REVIEW_LOOP_FAKE_FILE")
  tail -n +2 "$REVIEW_LOOP_FAKE_FILE" > "$REVIEW_LOOP_FAKE_FILE.tmp" && mv "$REVIEW_LOOP_FAKE_FILE.tmp" "$REVIEW_LOOP_FAKE_FILE"
fi
[ -n "$MODE" ] || MODE="approved"
[ -n "${REVIEW_LOOP_FAKE_LAST_PROMPT:-}" ] && cp "$PROMPT_FILE" "$REVIEW_LOOP_FAKE_LAST_PROMPT"

prev_section() {
  if [ "$ROUND" -gt 1 ]; then
    echo "## Previous comments"
    echo
    local id
    while IFS= read -r id; do
      printf -- '- %s: %s\n' "$id" "$1"
    done < <(rl_review_history "$REVIEW_LOOP_LOOP_DIR" "$ROUND" | jq -r '.ids[]')
    echo
  fi
}

TMP="$OUTPUT_FILE.tmp"
case "$MODE" in
  custom) cp "$REVIEW_LOOP_FAKE_REVIEW_FILE" "$TMP" ;;
  approved)
    {
      prev_section resolved
      echo "## Comments"; echo
      echo "## Optional"; echo
      echo "### R${ROUND}-C1"; echo "- severity: low"; echo "- blocking: no"
      echo "- file: README.md"; echo "- line: 1"; echo "- description: nit"; echo "- suggested fix: none"; echo
      echo "## Assessment"; echo; echo "Looks good."; echo
      echo "VERDICT: approved"
    } > "$TMP" ;;
  changes_requested)
    {
      prev_section unresolved
      echo "## Comments"; echo
      echo "### R${ROUND}-C1"; echo "- severity: high"; echo "- blocking: yes"
      echo "- file: src/app.py"; echo "- line: 10"; echo "- description: bug"; echo "- suggested fix: fix it"; echo
      echo "## Assessment"; echo; echo "Not done yet."; echo
      echo "VERDICT: changes_requested"
    } > "$TMP" ;;
  approved_with_blocking)
    {
      echo "## Comments"; echo
      echo "### R${ROUND}-C1"; echo "- severity: high"; echo "- blocking: yes"
      echo "- file: src/app.py"; echo "- line: 10"; echo "- description: bug"; echo "- suggested fix: fix it"; echo
      echo "## Assessment"; echo; echo "Mostly fine."; echo
      echo "VERDICT: approved"
    } > "$TMP" ;;
  prose)
    {
      echo "Sure! Here is my review of the changes."; echo
      echo '```markdown'; echo "---"; echo "**verdict:** approved"; echo "---"; echo
      echo "## Comments"; echo; echo "None."; echo; echo "## Assessment"; echo; echo "Fine."; echo '```'
    } > "$TMP" ;;
  verdict_only)
    printf 'VERDICT: approved\n' > "$TMP" ;;
  cr_no_comments)
    {
      echo "## Comments"; echo; echo "## Assessment"; echo; echo "Needs work."; echo
      echo "VERDICT: changes_requested"
    } > "$TMP" ;;
  garbage)
    printf 'I could not complete the review.\n' > "$TMP" ;;
  fail)
    echo "fake backend: simulated failure" >&2
    exit 1 ;;
  partial)
    printf 'VERDICT: approved\n' > "$OUTPUT_FILE"
    exit 1 ;;
  *)
    echo "fake backend: unknown mode '$MODE'" >&2
    exit 1 ;;
esac
mv "$TMP" "$OUTPUT_FILE"
# Usage sidecar (fixed numbers so tests can assert on them), only when enabled
if [ "${REVIEW_LOOP_USAGE:-0}" = "1" ]; then
  jq -n '{model: "fake-model", input_tokens: 1000, cached_input_tokens: 500, cache_write_tokens: 100,
          output_tokens: 200, reasoning_tokens: 50, cost_usd: 0.01, num_turns: 3}' > "$OUTPUT_FILE.usage.json"
fi
