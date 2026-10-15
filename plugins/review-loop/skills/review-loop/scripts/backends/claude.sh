#!/usr/bin/env bash
# review-loop backend: claude (Claude Code headless, `claude -p`).
#
# Contract: claude.sh PROMPT_FILE OUTPUT_FILE
#   Runs a one-shot, read-only Claude Code session in the current directory and
#   writes its final message to OUTPUT_FILE (only on success) plus token usage
#   and cost to OUTPUT_FILE.usage.json when REVIEW_LOOP_USAGE=1.
# Env:
#   REVIEW_LOOP_MODEL         model passed as `--model` (empty = default).
#                             A stronger model than the coder is a good choice.
#   REVIEW_LOOP_CLAUDE_FLAGS  extra flags appended to the command line.
#
# Isolation: `--setting-sources user` skips the project's hooks and settings,
# `--disable-slash-commands` keeps it from invoking skills (including this
# one), and REVIEW_LOOP_NESTED=1 (exported by review.sh) makes the review-loop
# Stop hook a no-op inside the nested session.
set -euo pipefail
PROMPT_FILE="$1"
OUTPUT_FILE="$2"

command -v claude > /dev/null 2>&1 || {
  echo "review-loop/claude: 'claude' CLI not found. Install: npm install -g @anthropic-ai/claude-code" >&2
  exit 1
}

args=(-p --output-format json --setting-sources user --disable-slash-commands
      --no-session-persistence --permission-mode dontAsk)
[ -n "${REVIEW_LOOP_MODEL:-}" ] && args+=(--model "$REVIEW_LOOP_MODEL")
# shellcheck disable=SC2206
extra=(${REVIEW_LOOP_CLAUDE_FLAGS:-})
# --allowedTools is variadic, so it goes last.
args+=(${extra[@]+"${extra[@]}"} --allowedTools "Read,Glob,Grep,Bash(git diff*),Bash(git status*),Bash(git log*),Bash(git show*)")

echo "review-loop/claude: running headless reviewer (no output until it finishes)..." >&2
set +e
JSON=$(REVIEW_LOOP_NESTED=1 claude "${args[@]}" < "$PROMPT_FILE")
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "review-loop/claude: claude exited with $RC" >&2
  printf '%s\n' "$JSON" | head -c 2000 >&2
  exit 1
fi
if ! printf '%s' "$JSON" | jq -e '(.is_error // false) == false and ((.result // "") | length > 0)' > /dev/null 2>&1; then
  echo "review-loop/claude: no usable result in claude output" >&2
  printf '%s\n' "$JSON" | head -c 2000 >&2
  exit 1
fi
TMP="$OUTPUT_FILE.tmp"
printf '%s' "$JSON" | jq -r '.result' > "$TMP"
# Usage sidecar from the result envelope (input_tokens = uncached input)
[ "${REVIEW_LOOP_USAGE:-0}" = "1" ] && printf '%s' "$JSON" | jq -c '{
  model: ((.modelUsage // {}) | keys | join(",") | if . == "" then "default" else . end),
  input_tokens: (.usage.input_tokens // 0),
  cached_input_tokens: (.usage.cache_read_input_tokens // 0),
  cache_write_tokens: (.usage.cache_creation_input_tokens // 0),
  output_tokens: (.usage.output_tokens // 0),
  reasoning_tokens: (.usage.output_tokens_details.thinking_tokens // 0),
  cost_usd: (.total_cost_usd // null),
  num_turns: (.num_turns // null)}' > "$OUTPUT_FILE.usage.json" 2>/dev/null || true
mv "$TMP" "$OUTPUT_FILE"
