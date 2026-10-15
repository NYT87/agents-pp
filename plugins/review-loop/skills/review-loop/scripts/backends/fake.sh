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
set -euo pipefail
PROMPT_FILE="$1"
OUTPUT_FILE="$2"
ROUND="${REVIEW_LOOP_ROUND:-1}"
PREV=$(( ROUND - 1 ))

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
    echo "- R${PREV}-C1: $1"
    echo
  fi
}

TMP="$OUTPUT_FILE.tmp"
case "$MODE" in
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
