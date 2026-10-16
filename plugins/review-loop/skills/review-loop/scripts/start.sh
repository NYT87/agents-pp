#!/usr/bin/env bash
# review-loop — start a new coder/reviewer loop in the current project.
#
# Usage: start.sh [--backend NAME] [--model MODEL] [--max-rounds N] [--dir DIR]
#                 [--force] [--git-exclude] <task description>
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat << 'HELP'
Usage: start.sh [options] <task description>

Options:
  --backend NAME     reviewer backend (codex, claude, ... see scripts/backends/)
  --model MODEL      model passed to the backend (empty = backend default)
  --max-rounds N     stop after N review rounds without approval (default 5)
  --dir DIR          storage dir for loop folders (default .review-loop)
  --usage            record token usage/cost per round and agent (default: off)
  --no-usage         disable usage recording for this loop
  --session ID       Claude Code session id of the coder (enables coder usage tracking
                     without the Stop hook; the skill passes it automatically)
  --force            cancel an already active loop first
  --git-exclude      add the loop dir and pointer to .git/info/exclude
  -h, --help         show this help

Config precedence: flags > REVIEW_LOOP_* env > ./.<provider>/review-loop.json
                   > ./.review-loop.json (its providers.<provider> section over its
                   top-level keys) > ~/.<provider>/review-loop.json
                   > ~/.config/review-loop/config.json > defaults
                   (provider: REVIEW_LOOP_PROVIDER, else claude; see config.sh show)
HELP
}

FLAG_BACKEND="" FLAG_MODEL="" FLAG_MAX="" FLAG_DIR="" FLAG_SESSION="" FLAG_USAGE="" FORCE=0 GIT_EXCLUDE=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) FLAG_BACKEND="${2:-}"; shift 2 ;;
    --backend=*) FLAG_BACKEND="${1#*=}"; shift ;;
    --model) FLAG_MODEL="${2:-}"; shift 2 ;;
    --model=*) FLAG_MODEL="${1#*=}"; shift ;;
    --max-rounds) FLAG_MAX="${2:-}"; shift 2 ;;
    --max-rounds=*) FLAG_MAX="${1#*=}"; shift ;;
    --dir) FLAG_DIR="${2:-}"; shift 2 ;;
    --dir=*) FLAG_DIR="${1#*=}"; shift ;;
    --session) FLAG_SESSION="${2:-}"; shift 2 ;;
    --session=*) FLAG_SESSION="${1#*=}"; shift ;;
    --usage) FLAG_USAGE="true"; shift ;;
    --no-usage) FLAG_USAGE="false"; shift ;;
    --force) FORCE=1; shift ;;
    --git-exclude) GIT_EXCLUDE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

TASK="${ARGS[*]:-}"
[ -n "$TASK" ] || { usage >&2; rl_die "no task description provided"; }
command -v jq > /dev/null 2>&1 || rl_die "'jq' is required (brew install jq / apt install jq)"

ROOT="$PWD"

# Existing loop? (Only refuse here; --force cancels it after validation below,
# so a bad invocation never destroys a working loop.)
EXISTING=0
if rl_load_loop; then
  EXISTING=1
  if [ "$FORCE" != "1" ]; then
    rl_die "a review loop is already active ($RL_LOOP_ID, round $(rl_state_get "$RL_LOOP_DIR" round)). Use /review-cancel or --force."
  fi
fi

CFG=$(rl_resolve_config)
CFG=$(jq -c --arg be "$FLAG_BACKEND" --arg model "$FLAG_MODEL" --arg mr "$FLAG_MAX" --arg dir "$FLAG_DIR" --arg usage "$FLAG_USAGE" '
  . + (if $be != "" then {backend: $be} else {} end)
    + (if $model != "" then {model: $model} else {} end)
    + (if $mr != "" then {max_rounds: ($mr | tonumber)} else {} end)
    + (if $dir != "" then {dir: $dir} else {} end)
    + (if $usage != "" then {usage: ($usage == "true")} else {} end)' <<< "$CFG")

BACKEND=$(jq -r .backend <<< "$CFG")
MODEL=$(jq -r .model <<< "$CFG")
MAX_ROUNDS=$(jq -r .max_rounds <<< "$CFG")
DIR=$(jq -r .dir <<< "$CFG")
USAGE=$(jq -r '.usage == true' <<< "$CFG")

printf '%s' "$MAX_ROUNDS" | grep -qE '^[1-9][0-9]*$' || rl_die "max_rounds must be a positive integer (got '$MAX_ROUNDS')"
printf '%s' "$BACKEND" | grep -qE '^[a-z0-9_-]+$' || rl_die "invalid backend name '$BACKEND'"
[ -f "$RL_BACKENDS_DIR/$BACKEND.sh" ] || rl_die "unknown backend '$BACKEND' (no $RL_BACKENDS_DIR/$BACKEND.sh)"

case "$BACKEND" in
  codex|claude)
    command -v "$BACKEND" > /dev/null 2>&1 || echo "warning: '$BACKEND' CLI not found on PATH; review.sh will fail until it is installed" >&2 ;;
esac

# Git base reference
BASE_REF="null"
if git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  if BASE_SHA=$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null); then
    BASE_REF="\"$BASE_SHA\""
  else
    BASE_REF="\"$RL_EMPTY_TREE\""
  fi
fi

# Session id: only accept something that looks like an id (the skill passes
# ${CLAUDE_SESSION_ID}; if it was not substituted we get a literal placeholder).
SESSION_ID=""
if printf '%s' "$FLAG_SESSION" | grep -qE '^[A-Za-z0-9_-]{8,}$'; then SESSION_ID="$FLAG_SESSION"; fi

LOOP_ID=$(rl_new_loop_id)
ABS_DIR=$(rl_abs_dir "$ROOT" "$DIR")
LOOP_DIR="$ABS_DIR/$LOOP_ID"
mkdir -p "$LOOP_DIR" "$ROOT/.claude" || rl_die "cannot create $LOOP_DIR"
[ -w "$LOOP_DIR" ] && [ -w "$ROOT/.claude" ] || rl_die "cannot write to $LOOP_DIR or $ROOT/.claude"

printf '%s\n' "$TASK" > "$LOOP_DIR/task.md"

jq -n \
  --arg id "$LOOP_ID" --arg be "$BACKEND" --arg model "$MODEL" --argjson mr "$MAX_ROUNDS" \
  --arg dir "$DIR" --argjson base "$BASE_REF" --arg root "$ROOT" --arg t "$(rl_now)" --argjson e "$(rl_epoch)" --arg sid "$SESSION_ID" --argjson usage "$USAGE" \
  '{loop_id: $id, active: true, phase: "coding", round: 1, max_rounds: $mr,
    backend: $be, model: $model, base_ref: $base, dir: $dir, root: $root, usage: $usage,
    session_id: (if $sid == "" then null else $sid end), started_at: $t, retries: 0, verdict: null, rounds: [],
    round_started_at: $t, round_started_epoch: $e, paused_s: 0, failed_review_s: 0}' > "$LOOP_DIR/state.json"

# Only now, with the new loop fully written, retire the old one (--force).
if [ "$EXISTING" = "1" ]; then
  rl_finalize "$RL_LOOP_DIR" "$RL_ROOT" "cancelled" "cancelled" "Cancelled by start.sh --force."
  echo "Cancelled previous loop $RL_LOOP_ID"
fi

printf '%s\n' "$LOOP_DIR" > "$ROOT/$RL_POINTER_REL"
rl_log "$LOOP_DIR" "started loop $LOOP_ID backend=$BACKEND model=${MODEL:-default} max_rounds=$MAX_ROUNDS usage=$USAGE base_ref=$BASE_REF"

if [ "$GIT_EXCLUDE" = "1" ] && [ -d "$ROOT/.git" ]; then
  REL_DIR=$(rl_rel_to_root "$ROOT" "$ABS_DIR")
  [ -z "$REL_DIR" ] && REL_DIR=$(rl_rel_to_root "$ROOT" "$LOOP_DIR")
  {
    [ -n "$REL_DIR" ] && echo "/$REL_DIR/"
    echo "/$RL_POINTER_REL"
  } >> "$ROOT/.git/info/exclude"
  echo "Added loop dir and pointer to .git/info/exclude"
fi

cat << OUT

Review loop started
  id:         $LOOP_ID
  dir:        $LOOP_DIR
  backend:    $BACKEND${MODEL:+ (model: $MODEL)}
  max rounds: $MAX_ROUNDS
  usage:      $([ "$USAGE" = "true" ] && echo "recorded in usage.md" || echo "off (enable with --usage)")
  task:       $LOOP_DIR/task.md

Protocol
  1. Implement the task completely.
  2. Write $LOOP_DIR/round-01-coder.md (template: $RL_TEMPLATES_DIR/coder-summary.md).
  3. Run: bash $RL_SCRIPTS_DIR/review.sh   (use a long timeout, reviews take minutes)
  4. Follow the instructions review.sh prints; repeat until the verdict is "approved".

Use /review-status to inspect and /review-cancel to abort.
OUT
