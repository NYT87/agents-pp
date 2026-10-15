#!/usr/bin/env bash
# review-loop — create, inspect and update the configuration file.
#
# Usage:
#   config.sh show      [--user|--project] [--json]   current values, per file and effective
#   config.sh create    [--user|--project]            create the file ({}) if it does not exist
#   config.sh set       [--user|--project] KEY=VALUE ...
#   config.sh unset     [--user|--project] KEY ...
#   config.sh init      [--user|--project] [--yes]    interactive wizard (Enter keeps a value, "-" clears
#                                                     model / dashboard.out / dashboard.dirs)
#   config.sh gitignore [--dry-run]                   add the loop's paths to .gitignore
#   config.sh keys                                    list keys with types and descriptions
#
# Scope: --project writes ./.claude/review-loop.json (default), --user writes
# ~/.claude/review-loop.json. Effective precedence stays: flags > env > project > user > defaults.
#
# Keys:
#   backend         reviewer backend (a script in scripts/backends/)   string
#   model           model passed to the backend ("" = backend default) string
#   max_rounds      review rounds before the loop gives up             integer >= 1
#   dir             storage dir for loop folders                        string
#   usage           record token usage per round                        boolean
#   dashboard.dirs  dirs the dashboard scans ("" = the loop dir)        comma-separated list
#   dashboard.out   dashboard output file ("" = <dir>/dashboard.html)  string
#   dashboard.open  open the dashboard in the browser                   boolean
#   dashboard.auto  regenerate the dashboard whenever a loop ends       boolean
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

KEYS="backend model max_rounds dir usage dashboard.dirs dashboard.out dashboard.open dashboard.auto"
key_type() {
  case "$1" in
    backend|model|dir|dashboard.out) echo string ;;
    max_rounds) echo integer ;;
    usage|dashboard.open|dashboard.auto) echo boolean ;;
    dashboard.dirs) echo list ;;
    *) return 1 ;;
  esac
}
# Keys that may legitimately be empty; the wizard clears them with "-".
key_clearable() { case "$1" in model|dashboard.out|dashboard.dirs) return 0 ;; *) return 1 ;; esac; }

key_help() {
  case "$1" in
    backend) echo "reviewer backend ($(ls "$RL_BACKENDS_DIR" | sed 's/\.sh$//' | grep -v '^fake$' | tr '\n' ' ' | sed 's/ $//'))" ;;
    model) echo "model passed to the backend (empty = backend default)" ;;
    max_rounds) echo "review rounds before the loop gives up" ;;
    dir) echo "storage dir for loop folders" ;;
    usage) echo "record token usage and cost per round" ;;
    dashboard.dirs) echo "dirs the dashboard scans, comma-separated (empty = the loop dir)" ;;
    dashboard.out) echo "dashboard output file (empty = <dir>/dashboard.html)" ;;
    dashboard.open) echo "open the dashboard in the browser after generating it" ;;
    dashboard.auto) echo "regenerate the dashboard automatically whenever a loop ends" ;;
  esac
}

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

# ── Arguments ────────────────────────────────────────────────────────────────
CMD="${1:-}"; [ $# -gt 0 ] && shift
SCOPE=project JSON=0 YES=0 DRY=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --user) SCOPE=user; shift ;;
    --project) SCOPE=project; shift ;;
    --json) JSON=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
ROOT="$PWD"
PROJECT_FILE="$ROOT/.claude/review-loop.json"
USER_FILE="$HOME/.claude/review-loop.json"
case "$SCOPE" in user) TARGET="$USER_FILE" ;; *) TARGET="$PROJECT_FILE" ;; esac

# ── Helpers ──────────────────────────────────────────────────────────────────
read_file() { if [ -f "$1" ]; then jq -c . "$1" 2>/dev/null || rl_die "$1 is not valid JSON"; else echo '{}'; fi; }
write_file() { # FILE JSON
  mkdir -p "$(dirname "$1")"
  jq . <<< "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}
path_filter() { printf '%s' "$1" | jq -R 'split(".")'; }
get_in() { jq -c --argjson p "$(path_filter "$2")" 'getpath($p)' <<< "$1"; }
display() { # JSON value -> human string
  jq -r 'if . == null then "-" elif type == "array" then (if length == 0 then "(none)" else join(",") end) elif . == "" then "(empty)" else tostring end' <<< "$1"
}

# coerce KEY RAW -> JSON value, or exit 1 with a message
coerce() {
  local key="$1" raw="$2" type
  type=$(key_type "$key") || { echo "unknown key '$key' (see: config.sh keys)" >&2; return 1; }
  case "$type" in
    string)
      if [ "$key" = "backend" ]; then
        printf '%s' "$raw" | grep -qE '^[a-z0-9_-]+$' && [ -f "$RL_BACKENDS_DIR/$raw.sh" ] \
          || { echo "unknown backend '$raw' (available: $(ls "$RL_BACKENDS_DIR" | sed 's/\.sh$//' | grep -v '^fake$' | tr '\n' ' ' | sed 's/ $//'))" >&2; return 1; }
      fi
      if [ "$key" = "dir" ] && [ -z "$raw" ]; then echo "dir cannot be empty" >&2; return 1; fi
      jq -n --arg v "$raw" '$v' ;;
    integer)
      printf '%s' "$raw" | grep -qE '^[1-9][0-9]*$' || { echo "$key must be a positive integer (got '$raw')" >&2; return 1; }
      echo "$raw" ;;
    boolean)
      case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) echo true ;;
        0|false|no|n|off) echo false ;;
        *) echo "$key must be true or false (got '$raw')" >&2; return 1 ;;
      esac ;;
    list)
      jq -n --arg v "$raw" '$v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))' ;;
  esac
}

apply_set() { # KEY RAW -> updates $NEW
  local key="$1" raw="$2" val
  val=$(coerce "$key" "$raw") || exit 1
  NEW=$(jq -c --argjson p "$(path_filter "$key")" --argjson v "$val" 'setpath($p; $v)' <<< "$NEW")
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd_keys() {
  for k in $KEYS; do printf '  %-16s %-9s %s\n' "$k" "$(key_type "$k")" "$(key_help "$k")"; done
}

cmd_show() {
  local eff proj usr def
  eff=$(rl_resolve_config)
  proj=$(read_file "$PROJECT_FILE"); usr=$(read_file "$USER_FILE")
  def=$(HOME=/nonexistent REVIEW_LOOP_DIR= REVIEW_LOOP_MAX_ROUNDS= REVIEW_LOOP_BACKEND= REVIEW_LOOP_MODEL= REVIEW_LOOP_USAGE= \
        REVIEW_LOOP_DASHBOARD_OPEN= REVIEW_LOOP_DASHBOARD_OUT= bash -c 'cd / && . "$1" && rl_resolve_config' _ "$RL_SCRIPTS_DIR/lib.sh")
  if [ "$JSON" = "1" ]; then
    jq -n --argjson e "$eff" --argjson p "$proj" --argjson u "$usr" --argjson d "$def" \
      --arg pf "$PROJECT_FILE" --arg uf "$USER_FILE" --arg scope "$SCOPE" --arg target "$TARGET" \
      --argjson pe "$([ -f "$PROJECT_FILE" ] && echo true || echo false)" --argjson ue "$([ -f "$USER_FILE" ] && echo true || echo false)" \
      '{scope: $scope, target: $target, effective: $e, defaults: $d,
        project: {path: $pf, exists: $pe, values: $p}, user: {path: $uf, exists: $ue, values: $u}}'
    return
  fi
  echo "review-loop configuration"
  echo "  project file: $PROJECT_FILE ($([ -f "$PROJECT_FILE" ] && echo exists || echo missing))"
  echo "  user file:    $USER_FILE ($([ -f "$USER_FILE" ] && echo exists || echo missing))"
  echo
  printf '  %-16s %-22s %-22s %-22s %s\n' key effective project user default
  for k in $KEYS; do
    printf '  %-16s %-22s %-22s %-22s %s\n' "$k" "$(display "$(get_in "$eff" "$k")")" \
      "$(display "$(get_in "$proj" "$k")")" "$(display "$(get_in "$usr" "$k")")" "$(display "$(get_in "$def" "$k")")"
  done
  echo
  echo "  (effective = flags > env > project > user > defaults; edit with: config.sh set KEY=VALUE)"
}

cmd_create() {
  if [ -f "$TARGET" ]; then echo "$TARGET already exists"; return 0; fi
  write_file "$TARGET" '{}'
  echo "Created $TARGET (empty: every value is inherited, see: config.sh show)"
}

cmd_set() {
  [ "${#ARGS[@]}" -gt 0 ] || rl_die "usage: config.sh set [--user|--project] KEY=VALUE ..."
  NEW=$(read_file "$TARGET")
  local a
  for a in "${ARGS[@]}"; do
    case "$a" in *=*) ;; *) rl_die "expected KEY=VALUE, got '$a'" ;; esac
    apply_set "${a%%=*}" "${a#*=}"
  done
  write_file "$TARGET" "$NEW"
  echo "Updated $TARGET"
  jq . "$TARGET" | sed 's/^/  /'
}

cmd_unset() {
  [ "${#ARGS[@]}" -gt 0 ] || rl_die "usage: config.sh unset [--user|--project] KEY ..."
  NEW=$(read_file "$TARGET")
  local k
  for k in "${ARGS[@]}"; do
    key_type "$k" > /dev/null || rl_die "unknown key '$k'"
    NEW=$(jq -c --argjson p "$(path_filter "$k")" 'delpaths([$p]) | if .dashboard == {} then del(.dashboard) else . end' <<< "$NEW")
  done
  write_file "$TARGET" "$NEW"
  echo "Updated $TARGET"
  jq . "$TARGET" | sed 's/^/  /'
}

# A .gitignore pattern matching loop-id folder names (YYYYMMDD-HHMMSS-xxxxxx),
# used when the storage dir is the project root so future loops are covered.
RL_LOOP_ID_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'

# gitignore_paths -> entries worth ignoring, one per line, as "KIND<TAB>VALUE":
# "L" = literal root-relative path (escaped before writing), "P" = ready-made
# pattern. Lists the pointer file; the loop storage dir as a whole (or, when it
# is the project root itself, the loop-id pattern, since folders that do not
# exist yet cannot be enumerated); only the verified loop folders inside extra
# dashboard scan dirs, since those may hold unrelated files; and the dashboard
# output file (explicit, or its default location).
gitignore_paths() {
  local eff abs rel d dirs=() line
  eff=$(rl_resolve_config)
  dirs+=("$(jq -r .dir <<< "$eff")")
  while IFS= read -r d; do [ -n "$d" ] && dirs+=("$d"); done < <(jq -r '.dashboard.dirs[]? // empty' <<< "$eff")
  printf 'L\t/%s\n' "$RL_POINTER_REL"
  abs=$(rl_abs_dir "$ROOT" "${dirs[0]}"); rel=$(rl_rel_to_root "$ROOT" "$abs")
  if [ -n "$rel" ]; then
    printf 'L\t/%s/\n' "$rel"
  elif [ "$abs" = "$ROOT" ]; then
    printf 'P\t/%s/\n' "$RL_LOOP_ID_GLOB"
  fi
  for d in "${dirs[@]:1}"; do
    abs=$(rl_abs_dir "$ROOT" "$d")
    for line in "$abs"/*/; do
      line="${line%/}"
      rl_is_loop_dir "$line" || continue
      rel=$(rl_rel_to_root "$ROOT" "$line")
      [ -n "$rel" ] && printf 'L\t/%s/\n' "$rel"
    done
  done
  d=$(jq -r '.dashboard.out // ""' <<< "$eff")
  if [ -n "$d" ]; then
    abs=$(rl_abs_dir "$ROOT" "$d")
  else
    # same default as dashboard.sh: first dashboard.dirs entry, else the loop dir
    abs="$(rl_abs_dir "$ROOT" "${dirs[1]:-${dirs[0]}}")/dashboard.html"
  fi
  rel=$(rl_rel_to_root "$ROOT" "$abs")
  [ -n "$rel" ] && printf 'L\t/%s\n' "$rel"
  return 0
}

# gitignore_escape PATH -> the path as a literal .gitignore pattern: backslash,
# "*", "?", "[", "]" are escaped, and a leading "#" or "!" too, so a directory
# named "arch*ive" ignores only itself and not "archive" or "archXive".
gitignore_escape() {
  printf '%s' "$1" | sed -e 's/[][\\*?]/\\&/g' -e 's/^\([#!]\)/\\\1/' -e 's/^\/\([#!]\)/\/\\\1/'
}

# ignored_already FILE LINE -> 0 when .gitignore has an equivalent entry: the
# escaped pattern, or the raw path written by hand ("/x/", "x/", "/x" and "x"
# all count), so existing files are respected.
ignored_already() {
  local want raw
  want=$(printf '%s' "$2" | sed 's|^/||; s|/$||')
  raw=$(printf '%s' "$3" | sed 's|^/||; s|/$||')
  [ -f "$1" ] && sed 's|^/||; s|/$||' "$1" | grep -qxF -e "$want" -e "$raw"
}

cmd_gitignore() {
  local gi="$ROOT/.gitignore" kind line pattern added=0 missing=()
  while IFS=$'\t' read -r kind line; do
    [ -n "$line" ] || continue
    if [ "$kind" = "P" ]; then pattern="$line"; else pattern=$(gitignore_escape "$line"); fi
    ignored_already "$gi" "$pattern" "$line" && continue
    missing+=("$pattern")
  done < <(gitignore_paths | sort -u)
  if [ "${#missing[@]}" -eq 0 ]; then
    echo ".gitignore already covers the review-loop paths"
    return 0
  fi
  if [ "$DRY" = "1" ]; then
    echo "Would add to $gi:"; printf '  %s\n' "${missing[@]}"
    return 0
  fi
  { [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo; [ -f "$gi" ] && echo; echo "# review-loop"; printf '%s\n' "${missing[@]}"; } >> "$gi"
  added=${#missing[@]}
  echo "Added $added line(s) to $gi:"; printf '  %s\n' "${missing[@]}"
}

cmd_init() {
  local eff k cur raw val type
  eff=$(rl_resolve_config)
  NEW=$(read_file "$TARGET")
  if [ -f "$TARGET" ]; then echo "Updating $TARGET (press Enter to keep the current value)"; else echo "Creating $TARGET (press Enter to keep the current value)"; fi
  echo
  for k in $KEYS; do
    type=$(key_type "$k")
    cur=$(display "$(get_in "$eff" "$k")")
    while :; do
      if [ "$YES" = "1" ]; then raw=""; else
        printf '  %s — %s%s\n' "$k" "$(key_help "$k")" "$(key_clearable "$k" && printf ' (type - to clear)')"
        printf '    [%s]: ' "$cur"
        IFS= read -r raw < /dev/stdin || raw=""
      fi
      if [ -z "$raw" ]; then
        # Enter keeps things as they are: the key is not written, so inherited
        # (user-file or default) values stay inherited instead of being frozen.
        break
      fi
      if [ "$raw" = "-" ] && key_clearable "$k"; then
        # Explicit reset: write the empty value so it overrides any inherited one.
        raw=""
      fi
      if val=$(coerce "$k" "$raw"); then
        NEW=$(jq -c --argjson p "$(path_filter "$k")" --argjson v "$val" 'setpath($p; $v)' <<< "$NEW"); break
      fi
      [ "$YES" = "1" ] && break
    done
  done
  write_file "$TARGET" "$NEW"
  echo
  echo "Wrote $TARGET (only the values you set; the rest stay inherited, see: config.sh show)"
  jq . "$TARGET" | sed 's/^/  /'
  echo
  # Last step: .gitignore, now that the paths are known.
  local missing
  missing=$(DRY=1 cmd_gitignore)
  if printf '%s' "$missing" | grep -q '^Would add'; then
    printf '%s\n' "$missing"
    if [ "$YES" = "1" ]; then raw="n"; else printf '  Add these to .gitignore? [y/N]: '; IFS= read -r raw < /dev/stdin || raw="n"; fi
    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in y|yes) DRY=0 cmd_gitignore ;; *) echo "  .gitignore left unchanged" ;; esac
  else
    echo "$missing"
  fi
}

case "$CMD" in
  show) cmd_show ;;
  create) cmd_create ;;
  set) cmd_set ;;
  unset) cmd_unset ;;
  init) cmd_init ;;
  gitignore) cmd_gitignore ;;
  keys) cmd_keys ;;
  ""|-h|--help|help) usage ;;
  *) rl_die "unknown command '$CMD' (show|create|set|unset|init|gitignore|keys)" ;;
esac
