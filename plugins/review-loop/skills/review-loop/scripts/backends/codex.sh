#!/usr/bin/env bash
# review-loop backend: codex (OpenAI Codex CLI).
#
# Contract: codex.sh PROMPT_FILE OUTPUT_FILE
#   Runs `codex exec` in the current directory with the prompt on stdin and
#   writes the agent's final message to OUTPUT_FILE (only on success) plus
#   token usage to OUTPUT_FILE.usage.json when REVIEW_LOOP_USAGE=1 (Codex
#   reports tokens, not cost).
# Env:
#   REVIEW_LOOP_MODEL        model passed as `-m` (empty = codex default)
#   REVIEW_LOOP_CODEX_FLAGS  extra flags; default "-s read-only --ephemeral".
#                            Setting it REPLACES the default, so include a
#                            sandbox flag, e.g. "-s workspace-write" to let the
#                            reviewer run tests.
set -euo pipefail
PROMPT_FILE="$1"
OUTPUT_FILE="$2"

command -v codex > /dev/null 2>&1 || {
  echo "review-loop/codex: 'codex' CLI not found. Install: npm install -g @openai/codex" >&2
  exit 1
}

TMP="$OUTPUT_FILE.tmp"
EVENTS="$OUTPUT_FILE.events.jsonl"
rm -f "$TMP" "$EVENTS"
args=(exec --skip-git-repo-check --color never -o "$TMP")
[ -n "${REVIEW_LOOP_MODEL:-}" ] && args+=(-m "$REVIEW_LOOP_MODEL")
# shellcheck disable=SC2206
extra=(${REVIEW_LOOP_CODEX_FLAGS:--s read-only --ephemeral})

if [ "${REVIEW_LOOP_USAGE:-0}" != "1" ]; then
  # Usage tracking off: plain streaming run, no sidecar.
  codex "${args[@]}" ${extra[@]+"${extra[@]}"} - < "$PROMPT_FILE"
  if [ ! -s "$TMP" ]; then
    echo "review-loop/codex: codex finished but produced no final message" >&2
    rm -f "$TMP"
    exit 1
  fi
  mv "$TMP" "$OUTPUT_FILE"
  exit 0
fi

# Usage tracking on: --json gives us token usage; tee the events and print a
# readable progress line for each one so the user still sees what happens.
set +e
codex "${args[@]}" --json ${extra[@]+"${extra[@]}"} - < "$PROMPT_FILE" \
  | tee "$EVENTS" \
  | jq --unbuffered -r '
      if .type == "item.completed" then
        (if .item.type == "command_execution" then "  $ " + ((.item.command // "") | .[0:160])
         elif .item.type == "agent_message" then "  > " + ((.item.text // "") | gsub("\n"; " ") | .[0:160])
         elif .item.type == "reasoning" then "  [thinking] " + ((.item.text // "") | gsub("\n"; " ") | .[0:120])
         else empty end)
      elif .type == "turn.completed" then
        "  turn completed: \(.usage.input_tokens // 0) in (\(.usage.cached_input_tokens // 0) cached) / \(.usage.output_tokens // 0) out tokens"
      elif .type == "error" then "  error: " + (.message // tostring)
      else empty end' >&2
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
  echo "review-loop/codex: codex exited with $RC" >&2
  rm -f "$TMP"
  exit "$RC"
fi
if [ ! -s "$TMP" ]; then
  echo "review-loop/codex: codex finished but produced no final message" >&2
  rm -f "$TMP"
  exit 1
fi

# Usage sidecar from turn.completed events (input_tokens = uncached input)
MODEL="${REVIEW_LOOP_MODEL:-}"
if [ -z "$MODEL" ] && [ -f "$HOME/.codex/config.toml" ]; then
  MODEL=$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$HOME/.codex/config.toml" | head -1)
fi
jq -sc --arg model "${MODEL:-default}" '
  [.[] | select(.type == "turn.completed") | .usage] |
  {model: $model,
   input_tokens: ((map(.input_tokens // 0) | add // 0) - (map(.cached_input_tokens // 0) | add // 0) | if . < 0 then 0 else . end),
   cached_input_tokens: (map(.cached_input_tokens // 0) | add // 0),
   cache_write_tokens: (map(.cache_write_input_tokens // 0) | add // 0),
   output_tokens: (map(.output_tokens // 0) | add // 0),
   reasoning_tokens: (map(.reasoning_output_tokens // 0) | add // 0),
   cost_usd: null, num_turns: length}' "$EVENTS" > "$OUTPUT_FILE.usage.json" 2>/dev/null || true
rm -f "$EVENTS"
mv "$TMP" "$OUTPUT_FILE"
