#!/usr/bin/env bash
# review-loop — shared helpers. Source this file; do not execute it.
#
# Every script in this directory locates its siblings through this file, so the
# skill folder works both inside the plugin and copied standalone into
# ~/.claude/skills/review-loop.

RL_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RL_SKILL_DIR="$(dirname "$RL_SCRIPTS_DIR")"
RL_TEMPLATES_DIR="$RL_SKILL_DIR/templates"
RL_BACKENDS_DIR="$RL_SCRIPTS_DIR/backends"
RL_POINTER_REL=".claude/review-loop.active"
RL_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
RL_PAUSE_MARKER="REVIEW-LOOP: PAUSE"
RL_MAX_RETRIES=3

rl_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

rl_die() { echo "review-loop: $*" >&2; exit 1; }

# rl_log LOOP_DIR MESSAGE...
rl_log() {
  local dir="$1"; shift
  [ -d "$dir" ] || return 0
  echo "[$(rl_now)] $*" >> "$dir/loop.log" 2>/dev/null || true
}

# Walk up from $PWD until a pointer file is found. Prints the project root.
rl_find_root() {
  local d="$PWD"
  while :; do
    if [ -f "$d/$RL_POINTER_REL" ]; then
      echo "$d"
      return 0
    fi
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

rl_valid_loop_id() {
  printf '%s' "$1" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'
}

rl_new_loop_id() {
  local hex
  if command -v openssl > /dev/null 2>&1; then
    hex=$(openssl rand -hex 3)
  else
    hex=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  echo "$(date +%Y%m%d-%H%M%S)-${hex}"
}

# Normalize an absolute path lexically: collapse "//", "/./" and "/../".
rl_normalize_path() {
  local IFS='/' part out=""
  for part in $1; do
    case "$part" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  echo "${out:-/}"
}

# Resolve the storage dir to a normalized absolute path. $1 root, $2 configured dir.
rl_abs_dir() {
  case "$2" in
    /*) rl_normalize_path "$2" ;;
    *) rl_normalize_path "$1/$2" ;;
  esac
}

# Path of a dir relative to root ("" when the dir is the root itself or outside it).
rl_rel_to_root() {
  local root="$1" path="$2"
  case "$path" in
    "$root"/*) echo "${path#"$root"/}" ;;
    *) echo "" ;;
  esac
}

# rl_is_loop_dir DIR -> 0 when DIR holds a review loop: loop-shaped name and a
# state.json whose loop_id matches it. A project folder that merely looks like
# a loop id is not a loop and must stay visible to the reviewer.
rl_is_loop_dir() {
  local base
  base=$(basename "$1")
  rl_valid_loop_id "$base" || return 1
  [ "$(jq -r '.loop_id // empty' "$1/state.json" 2>/dev/null)" = "$base" ]
}

# rl_exclude_paths ROOT DIR LOOP_DIR -> root-relative paths (one per line) of
# the review loop's own files: the pointer, and either the configured dir when
# it is a strict subdirectory of the root, or (e.g. --dir .) every verified
# loop folder found directly under it, so the project itself is never excluded.
rl_exclude_paths() {
  local root="$1" abs rel d
  echo "$RL_POINTER_REL"
  abs=$(rl_abs_dir "$root" "$2")
  rel=$(rl_rel_to_root "$root" "$abs")
  if [ -n "$rel" ]; then
    echo "$rel"
    return 0
  fi
  for d in "$abs"/*/ "$3"; do
    d="${d%/}"
    rl_is_loop_dir "$d" || continue
    rel=$(rl_rel_to_root "$root" "$d")
    [ -n "$rel" ] && echo "$rel"
  done | sort -u
  return 0
}

# rl_git_excludes ROOT DIR LOOP_DIR -> the same list as git pathspecs
rl_git_excludes() {
  rl_exclude_paths "$@" | sed 's/^/:(exclude)/'
}

# rl_find_excludes ROOT DIR LOOP_DIR -> the same list as find(1) arguments
# (relative to ".", one argument per line: "-not", "-path", "./x/*", ...)
rl_find_excludes() {
  rl_exclude_paths "$@" | while IFS= read -r rel; do
    printf -- '-not\n-path\n./%s\n-not\n-path\n./%s/*\n' "$rel" "$rel"
  done
}

# rl_resolve_config -> JSON with dir, max_rounds, backend, model, usage.
# Precedence (low -> high): defaults, ~/.claude/review-loop.json,
# ./.claude/review-loop.json, REVIEW_LOOP_* env. Flags are applied by start.sh.
rl_resolve_config() {
  local defaults='{"dir":".review-loop","max_rounds":5,"backend":"codex","model":"","usage":false}'
  local user_cfg="{}" proj_cfg="{}" env_cfg
  if [ -f "$HOME/.claude/review-loop.json" ]; then
    user_cfg=$(jq -c . "$HOME/.claude/review-loop.json" 2>/dev/null) || user_cfg="{}"
  fi
  if [ -f ".claude/review-loop.json" ]; then
    proj_cfg=$(jq -c . ".claude/review-loop.json" 2>/dev/null) || proj_cfg="{}"
  fi
  env_cfg=$(jq -n \
    --arg dir "${REVIEW_LOOP_DIR:-}" \
    --arg mr "${REVIEW_LOOP_MAX_ROUNDS:-}" \
    --arg be "${REVIEW_LOOP_BACKEND:-}" \
    --arg model "${REVIEW_LOOP_MODEL:-}" \
    --arg usage "${REVIEW_LOOP_USAGE:-}" \
    '{}
     + (if $dir   != "" then {dir: $dir} else {} end)
     + (if $mr    != "" then {max_rounds: ($mr | tonumber)} else {} end)
     + (if $be    != "" then {backend: $be} else {} end)
     + (if $model != "" then {model: $model} else {} end)
     + (if $usage != "" then {usage: ($usage | ascii_downcase | IN("1","true","yes","on"))} else {} end)')
  jq -n --argjson d "$defaults" --argjson u "$user_cfg" --argjson p "$proj_cfg" --argjson e "$env_cfg" \
    '$d * $u * $p * $e'
}

# rl_state_get LOOP_DIR KEY
rl_state_get() {
  jq -r --arg k "$2" '.[$k] // empty' "$1/state.json" 2>/dev/null
}

# rl_state_update LOOP_DIR [jq options...] FILTER  (atomic rewrite)
rl_state_update() {
  local dir="$1"; shift
  local tmp="$dir/state.json.tmp.$$"
  if jq "$@" "$dir/state.json" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$dir/state.json"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Load the active loop. Sets RL_ROOT, RL_POINTER, RL_LOOP_DIR, RL_LOOP_ID.
# Returns 1 (and clears a dangling pointer) when there is no usable loop.
rl_load_loop() {
  RL_ROOT=$(rl_find_root) || return 1
  RL_POINTER="$RL_ROOT/$RL_POINTER_REL"
  RL_LOOP_DIR=$(head -1 "$RL_POINTER" 2>/dev/null || true)
  if [ -z "$RL_LOOP_DIR" ] || [ ! -d "$RL_LOOP_DIR" ] || ! jq -e . "$RL_LOOP_DIR/state.json" > /dev/null 2>&1; then
    rm -f "$RL_POINTER"
    return 1
  fi
  RL_LOOP_ID=$(rl_state_get "$RL_LOOP_DIR" loop_id)
  if ! rl_valid_loop_id "$RL_LOOP_ID"; then
    rm -f "$RL_POINTER"
    return 1
  fi
  local cfg_dir
  cfg_dir=$(rl_abs_dir "$RL_ROOT" "$(rl_state_get "$RL_LOOP_DIR" dir)")
  case "$RL_LOOP_DIR" in
    "$cfg_dir"/*) ;;
    *) rm -f "$RL_POINTER"; return 1 ;;
  esac
  if [ "$(rl_state_get "$RL_LOOP_DIR" active)" != "true" ]; then
    rm -f "$RL_POINTER"
    return 1
  fi
  return 0
}

rl_round_nn() { printf '%02d' "$1"; }

# Strip code fences so frontmatter wrapped in ``` still parses.
rl_strip_fences() { sed -e 's/^[[:space:]]*```.*$//' "$1"; }

# rl_parse_verdict FILE -> prints approved|changes_requested; returns 1 if none.
# Tolerant: matches "verdict: approved", "**verdict:** approved", "> verdict: x",
# "VERDICT: changes_requested". Lines with both values (spec text) never match.
rl_parse_verdict() {
  local line v
  line=$(rl_strip_fences "$1" \
    | grep -iE '^[[:space:]>*`_|-]*verdict[*`_]*[[:space:]]*:[*`_]*[[:space:]]*[*`"'"'"']*(approved|changes_requested)[*`"'"'"']*[[:space:]|]*$' \
    | tail -1) || true
  [ -n "$line" ] || return 1
  v=$(printf '%s' "$line" | grep -oiE 'approved|changes_requested' | head -1 | tr '[:upper:]' '[:lower:]')
  [ -n "$v" ] || return 1
  echo "$v"
}

# rl_validate_review FILE VERDICT -> prints a problem description and returns 1
# when the review lacks the documented structure (a Comments section, a
# non-empty Assessment, and at least one comment or unresolved item when
# changes are requested). A bare verdict line is not a usable review.
rl_validate_review() {
  local body
  body=$(rl_strip_fences "$1")
  if ! printf '%s\n' "$body" | grep -qiE '^[[:space:]]*#+[[:space:]]*comments([[:space:]]|$)'; then
    echo "missing a '## Comments' section"; return 1
  fi
  if ! printf '%s\n' "$body" | grep -qiE '^[[:space:]]*#+[[:space:]]*assessment([[:space:]]|$)'; then
    echo "missing a '## Assessment' section"; return 1
  fi
  if ! printf '%s\n' "$body" | awk 'BEGIN{IGNORECASE=1} tolower($0) ~ /^[[:space:]]*#+[[:space:]]*assessment/ {on=1; next} on && /^[[:space:]]*#/ {on=0} on && tolower($0) !~ /^[[:space:]]*(verdict[[:space:]]*:)?[[:space:]]*$/ && tolower($0) !~ /^[[:space:]*`>_-]*verdict[*`_]*[[:space:]]*:/ {found=1} END{exit !found}'; then
    echo "the '## Assessment' section is empty"; return 1
  fi
  if [ "$2" = "changes_requested" ]; then
    if ! printf '%s\n' "$body" | grep -qE '^[[:space:]]*#+[[:space:]]*R[0-9]+-C[0-9]+' \
       && [ "$(rl_count_blocking "$1")" -eq 0 ]; then
      echo "changes were requested but no comment (### R<round>-C<n>) or unresolved item is listed"; return 1
    fi
  fi
  return 0
}

# rl_count_blocking FILE -> number of blocking items:
#   "- blocking: yes" lines + "- R1-C2: unresolved|declined-rejected" lines.
rl_count_blocking() {
  local a b
  a=$(rl_strip_fences "$1" | grep -ciE '^[[:space:]>*`_|-]*blocking[*`_]*[[:space:]]*:[*`_]*[[:space:]]*[*`"'"'"']*yes[*`"'"'"']*[[:space:]|]*$') || a=0
  b=$(rl_strip_fences "$1" | grep -ciE '^[[:space:]>*`_|-]*R[0-9]+-C[0-9]+[*`_]*[[:space:]]*:[*`_]*[[:space:]]*[*`_]*(unresolved|declined-rejected)') || b=0
  echo $(( a + b ))
}

# rl_blocking_ids FILE -> IDs that are still blocking (one per line).
rl_blocking_ids() {
  rl_strip_fences "$1" | awk '
    /^[[:space:]]*#+[[:space:]]*R[0-9]+-C[0-9]+/ {
      if (id != "" && blocking) print id
      match($0, /R[0-9]+-C[0-9]+/); id = substr($0, RSTART, RLENGTH); blocking = 0; next
    }
    tolower($0) ~ /^[[:space:]>*`_|-]*blocking[*`_]*[[:space:]]*:[*`_]*[[:space:]]*[*`"'\'']*yes/ { blocking = 1 }
    tolower($0) ~ /^[[:space:]>*`_|-]*r[0-9]+-c[0-9]+[*`_]*[[:space:]]*:[*`_]*[[:space:]]*[*`_]*(unresolved|declined-rejected)/ {
      match($0, /R[0-9]+-C[0-9]+/); print substr($0, RSTART, RLENGTH)
    }
    END { if (id != "" && blocking) print id }
  ' | sort -u
}

# ── Usage recording ──────────────────────────────────────────────────────────
# Normalized usage object (all backends and the coder transcript use it):
#   {model, input_tokens (uncached), cached_input_tokens, cache_write_tokens,
#    output_tokens, reasoning_tokens, cost_usd|null, num_turns|null}
RL_USAGE_ZERO='{"model":"default","input_tokens":0,"cached_input_tokens":0,"cache_write_tokens":0,"output_tokens":0,"reasoning_tokens":0,"cost_usd":null,"num_turns":null}'

# rl_usage_enabled LOOP_DIR -> 0 when usage tracking is on for this loop
rl_usage_enabled() { [ "$(rl_state_get "$1" usage)" = "true" ]; }

# rl_normalize_usage FILE -> normalized JSON (zeros when the file is missing/invalid)
rl_normalize_usage() {
  local out
  out=$(jq -c '{model: (.model // "default"), input_tokens: (.input_tokens // 0),
    cached_input_tokens: (.cached_input_tokens // 0), cache_write_tokens: (.cache_write_tokens // 0),
    output_tokens: (.output_tokens // 0), reasoning_tokens: (.reasoning_tokens // 0),
    cost_usd: (.cost_usd // null), num_turns: (.num_turns // null)}' "$1" 2>/dev/null) || out=""
  [ -n "$out" ] && echo "$out" || echo "$RL_USAGE_ZERO"
}

# rl_usage_add JSON_A JSON_B -> sum (cost stays null only when both are null)
rl_usage_add() {
  jq -cn --argjson a "$1" --argjson b "$2" '{
    model: ([$a.model, $b.model] | map(select(. != null and . != "default")) | unique | join(",") | if . == "" then "default" else . end),
    input_tokens: ($a.input_tokens + $b.input_tokens),
    cached_input_tokens: ($a.cached_input_tokens + $b.cached_input_tokens),
    cache_write_tokens: ($a.cache_write_tokens + $b.cache_write_tokens),
    output_tokens: ($a.output_tokens + $b.output_tokens),
    reasoning_tokens: ($a.reasoning_tokens + $b.reasoning_tokens),
    cost_usd: (if $a.cost_usd == null and $b.cost_usd == null then null else (($a.cost_usd // 0) + ($b.cost_usd // 0)) end),
    num_turns: (if $a.num_turns == null and $b.num_turns == null then null else (($a.num_turns // 0) + ($b.num_turns // 0)) end)}'
}

# rl_usage_sub CUMULATIVE PREVIOUS -> delta (never negative)
rl_usage_sub() {
  jq -cn --argjson a "$1" --argjson b "$2" '{
    model: $a.model,
    input_tokens: ([$a.input_tokens - $b.input_tokens, 0] | max),
    cached_input_tokens: ([$a.cached_input_tokens - $b.cached_input_tokens, 0] | max),
    cache_write_tokens: ([$a.cache_write_tokens - $b.cache_write_tokens, 0] | max),
    output_tokens: ([$a.output_tokens - $b.output_tokens, 0] | max),
    reasoning_tokens: ([$a.reasoning_tokens - $b.reasoning_tokens, 0] | max),
    cost_usd: (if $a.cost_usd == null then null else ([$a.cost_usd - ($b.cost_usd // 0), 0] | max) end),
    num_turns: (if $a.num_turns == null then null else ([$a.num_turns - ($b.num_turns // 0), 0] | max) end)}'
}

# rl_transcript_path LOOP_DIR -> path of the coder session transcript, or empty.
# Uses state.transcript_path (set by the Stop hook) or finds it by session_id.
rl_transcript_path() {
  local tp sid f
  tp=$(rl_state_get "$1" transcript_path)
  if [ -n "$tp" ] && [ -f "$tp" ]; then echo "$tp"; return 0; fi
  sid=$(rl_state_get "$1" session_id)
  [ -n "$sid" ] || return 1
  printf '%s' "$sid" | grep -qE '^[A-Za-z0-9_-]{8,}$' || return 1
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# rl_transcript_usage TRANSCRIPT SINCE_ISO -> normalized usage of all assistant
# messages at or after SINCE (deduplicated by message id; subagents included).
rl_transcript_usage() {
  local out
  out=$(jq -sc --arg since "$2" '
    [.[] | select(.type == "assistant" and ((.timestamp // "") >= $since) and (.message.usage != null))]
    | unique_by(.message.id // .uuid)
    | {model: ([.[].message.model // empty] | unique | join(",") | if . == "" then "default" else . end),
       input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
       cached_input_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
       cache_write_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
       output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
       reasoning_tokens: (map(.message.usage.output_tokens_details.thinking_tokens // 0) | add // 0),
       cost_usd: null, num_turns: length}' "$1" 2>/dev/null) || out=""
  [ -n "$out" ] && echo "$out" || echo "$RL_USAGE_ZERO"
}

# rl_coder_usage_cumulative LOOP_DIR -> usage since the loop started, or empty when unknown.
rl_coder_usage_cumulative() {
  local tp started
  tp=$(rl_transcript_path "$1") || return 1
  started=$(rl_state_get "$1" started_at)
  rl_transcript_usage "$tp" "$started"
}

# rl_reviewer_usage_total LOOP_DIR -> sum of reviewer usage over recorded rounds
rl_reviewer_usage_total() {
  local total="$RL_USAGE_ZERO" u
  while IFS= read -r u; do
    [ -n "$u" ] && total=$(rl_usage_add "$total" "$u")
  done < <(jq -c '.rounds[]?.reviewer // empty' "$1/state.json" 2>/dev/null)
  echo "$total"
}

rl_usage_row() { # LABEL USAGE_JSON [DURATION]
  jq -r --arg l "$1" --arg d "${3:-}" '
    def n: if . == null then "-" else tostring end;
    "| \($l) | \(.model) | \(.input_tokens) | \(.cached_input_tokens) | \(.cache_write_tokens) | \(.output_tokens) | \(.reasoning_tokens) | \(.cost_usd | if . == null then "-" else (. * 10000 | round / 10000 | tostring) end) | \(.num_turns | n) | \($d | if . == "" then "-" else . end) |"' <<< "$2"
}

# rl_usage_table LOOP_DIR -> Markdown table of per-round usage plus totals
rl_usage_table() {
  local dir="$1" round label coder reviewer dur coder_total reviewer_total
  echo "| Round / agent | Model | Input (uncached) | Cached input | Cache write | Output | Reasoning | Cost USD | Turns | Duration s |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r round coder reviewer dur; do
    [ -n "$round" ] || continue
    if [ "$coder" != "null" ]; then rl_usage_row "round $round coder" "$coder"; fi
    rl_usage_row "round $round reviewer" "$reviewer" "$dur"
  done < <(jq -r '.rounds[]? | [.round, (.coder | tojson), (.reviewer | tojson), (.duration_s // "")] | @tsv' "$dir/state.json" 2>/dev/null)
  coder_total=$(rl_coder_usage_cumulative "$dir") || coder_total=""
  reviewer_total=$(rl_reviewer_usage_total "$dir")
  if [ -n "$coder_total" ]; then rl_usage_row "TOTAL coder" "$coder_total"; else echo "| TOTAL coder | n/a (no session transcript found) | | | | | | | | |"; fi
  rl_usage_row "TOTAL reviewer" "$reviewer_total"
}

# rl_write_usage_md LOOP_DIR
rl_write_usage_md() {
  {
    echo "# Usage"
    echo
    echo "Tokens per round and agent. Coder numbers come from the Claude Code session transcript"
    echo "and cover everything the session did during the loop; reviewer numbers come from the backend."
    echo
    rl_usage_table "$1"
  } > "$1/usage.md" 2>/dev/null || true
}

# rl_finalize LOOP_DIR ROOT OUTCOME PHASE [DETAIL]
# Writes summary.md, marks the loop inactive and removes the pointer.
rl_finalize() {
  local dir="$1" root="$2" outcome="$3" phase="$4" detail="${5:-}"
  local round backend loop_id last_review nn ids
  round=$(rl_state_get "$dir" round)
  backend=$(rl_state_get "$dir" backend)
  loop_id=$(rl_state_get "$dir" loop_id)
  ids=""
  last_review=$(ls "$dir"/round-*-review.md 2>/dev/null | sort | tail -1 || true)
  if [ -n "$last_review" ]; then
    ids=$(rl_blocking_ids "$last_review")
  fi
  {
    echo "# Review loop summary"
    echo
    echo "- loop_id: $loop_id"
    echo "- outcome: $outcome"
    echo "- rounds: ${round:-0}"
    echo "- backend: $backend"
    echo "- finished_at: $(rl_now)"
    [ -n "$detail" ] && { echo; echo "$detail"; }
    echo
    if [ -n "$ids" ]; then
      echo "## Unresolved blocking comments"
      echo
      echo "$ids" | sed 's/^/- /'
      echo
      echo "See $(basename "$last_review") for details."
    else
      echo "No unresolved blocking comments."
    fi
    if rl_usage_enabled "$dir"; then
      echo
      echo "## Usage"
      echo
      rl_usage_table "$dir"
    fi
    echo
    echo "## Files"
    echo
    ls "$dir" | grep -E '^round-' | sed 's/^/- /'
  } > "$dir/summary.md" 2>/dev/null || true
  rl_usage_enabled "$dir" && rl_write_usage_md "$dir"
  nn=$(rl_now)
  rl_state_update "$dir" --arg p "$phase" --arg o "$outcome" --arg t "$nn" \
    '.active = false | .phase = $p | .outcome = $o | .finished_at = $t' || true
  rm -f "$root/$RL_POINTER_REL"
  rl_log "$dir" "finalized: outcome=$outcome phase=$phase"
}
