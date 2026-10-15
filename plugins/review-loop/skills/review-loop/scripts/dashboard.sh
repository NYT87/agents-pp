#!/usr/bin/env bash
# review-loop — generate a self-contained HTML dashboard of all review loops.
#
# Usage: dashboard.sh [--dir DIR]... [--out FILE] [--open|--no-open]
#   --dir DIR   storage dir to scan (repeatable; default: config dashboard.dirs,
#               or the configured loop dir)
#   --out FILE  where to write the page (default: config dashboard.out, or
#               <dir>/dashboard.html)
#   --open      open the page in the default browser afterwards
#   --no-open   do not open it (default comes from config dashboard.open, true)
# Config (.claude/review-loop.json or ~/.claude/review-loop.json):
#   {"dashboard": {"dirs": [".review-loop"], "out": "docs/loops.html",
#                  "open": true, "auto": false}}
#   "auto": true regenerates the page every time a loop ends.
# Env: REVIEW_LOOP_DASHBOARD_OPEN=0|1, REVIEW_LOOP_DASHBOARD_OUT=FILE
#
# The page embeds every loop's state, task, coder summaries, reviews and
# summary as JSON and renders them with no network access needed.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

DIRS=() OUT="" OPEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIRS+=("${2:-}"); shift 2 ;;
    --dir=*) DIRS+=("${1#*=}"); shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --open) OPEN=1; shift ;;
    --no-open) OPEN=0; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) rl_die "unknown argument '$1'" ;;
  esac
done

ROOT="$PWD"
CFG=$(rl_resolve_config)
if [ "${#DIRS[@]}" -eq 0 ]; then
  while IFS= read -r d; do [ -n "$d" ] && DIRS+=("$d"); done < <(jq -r '.dashboard.dirs[]? // empty' <<< "$CFG")
  [ "${#DIRS[@]}" -gt 0 ] || DIRS=("$(jq -r .dir <<< "$CFG")")
fi
[ -n "$OUT" ] || OUT=$(jq -r '.dashboard.out // ""' <<< "$CFG")
[ -n "$OPEN" ] || OPEN=$(jq -r 'if .dashboard.open == false then 0 else 1 end' <<< "$CFG")
TEMPLATE="$RL_TEMPLATES_DIR/dashboard.html"
[ -f "$TEMPLATE" ] || rl_die "template missing: $TEMPLATE"

# ── Collect loops ────────────────────────────────────────────────────────────
# Everything is accumulated in temp files and read by jq from disk: passing
# JSON through --argjson would hit ARG_MAX once a trail holds a few MB.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-loop-dashboard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LOOPS_FILE="$WORK/loops.jsonl"; : > "$LOOPS_FILE"

# Candidate loop dirs, deduplicated by their resolved physical path (symlinks
# followed) so repeated, overlapping or symlinked --dir values never count a
# loop twice. The first path seen is the one shown in the page.
CANDIDATES="$WORK/dirs.txt"; : > "$CANDIDATES"
for dir in "${DIRS[@]}"; do
  ABS=$(rl_abs_dir "$ROOT" "$dir")
  [ -d "$ABS" ] || continue
  for d in "$ABS"/*/; do
    d="${d%/}"
    rl_is_loop_dir "$d" || continue
    PHYS=$(cd "$d" 2>/dev/null && pwd -P) || continue
    printf '%s\t%s\n' "$PHYS" "$(rl_normalize_path "$d")" >> "$CANDIDATES"
  done
done

COUNT=0
while IFS=$'\t' read -r phys d; do
  [ -n "$phys" ] || continue
  ROUNDS_JSONL="$WORK/rounds.jsonl"; : > "$ROUNDS_JSONL"
  for cf in "$d"/round-[0-9][0-9]-coder.md "$d"/round-[0-9][0-9]-review.md; do
    [ -f "$cf" ] || continue
    n=$(basename "$cf" | sed -E 's/^round-0*([0-9]+)-.*/\1/')
    kind=$(basename "$cf" | sed -E 's/^round-[0-9]+-(coder|review)\.md$/\1/')
    jq -c -n --argjson n "$n" --arg k "$kind" --rawfile t "$cf" '{round: $n, ($k): $t}' >> "$ROUNDS_JSONL"
  done
  # merge the coder/review halves of each round into one object
  jq -s -c 'group_by(.round) | map(add | {round, coder: (.coder // null), review: (.review // null)}) | sort_by(.round)' \
    "$ROUNDS_JSONL" > "$WORK/files.json"
  SUMMARY=/dev/null; [ -f "$d/summary.md" ] && SUMMARY="$d/summary.md"
  TASK=/dev/null; [ -f "$d/task.md" ] && TASK="$d/task.md"
  jq -c -n --slurpfile st "$d/state.json" --slurpfile files "$WORK/files.json" \
    --rawfile task "$TASK" --rawfile summary "$SUMMARY" --arg dir "$d" \
    '{dir: $dir, state: $st[0], task: $task, summary: (if $summary == "" then null else $summary end), files: $files[0]}' \
    >> "$LOOPS_FILE"
  COUNT=$(( COUNT + 1 ))
done < <(sort -t "$(printf '\t')" -k1,1 -u -s "$CANDIDATES")

jq -s -c --arg root "$ROOT" --arg t "$(rl_now)" \
  '{generated_at: $t, root: $root, loops: (sort_by([.state.started_at, .state.loop_id]) | reverse)}' \
  "$LOOPS_FILE" | sed 's|</|<\\/|g' > "$WORK/data.json"

# ── Render ───────────────────────────────────────────────────────────────────
FIRST_ABS=$(rl_abs_dir "$ROOT" "${DIRS[0]}")
[ -n "$OUT" ] || OUT="$FIRST_ABS/dashboard.html"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
# Splice the data into the template without putting it on any command line.
awk -v datafile="$WORK/data.json" '
  index($0, "{{DATA}}") {
    pre = substr($0, 1, index($0, "{{DATA}}") - 1); post = substr($0, index($0, "{{DATA}}") + 8)
    printf "%s", pre
    while ((getline line < datafile) > 0) printf "%s", line
    close(datafile)
    print post; next
  }
  { print }' "$TEMPLATE" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "review-loop dashboard: $COUNT loop(s) from ${DIRS[*]}"
echo "  written to $OUT"
if [ "$OPEN" = "1" ]; then
  if command -v open > /dev/null 2>&1; then open "$OUT"
  elif command -v xdg-open > /dev/null 2>&1; then xdg-open "$OUT"
  else echo "  (no 'open'/'xdg-open' found; open the file manually)"; fi
fi
