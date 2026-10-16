#!/usr/bin/env bash
# review-loop — create, inspect and update the configuration files.
#
# Usage:
#   config.sh show      [scope] [--json]          current values, where each comes from
#   config.sh create    [scope]                   create the file ({}) if it does not exist
#   config.sh set       [scope] KEY=VALUE ...
#   config.sh unset     [scope] KEY ...
#   config.sh init      [scope] [--yes]           interactive wizard (Enter keeps a value, "-" clears
#                                                 model / dashboard.out / dashboard.dirs)
#   config.sh gitignore [--dry-run]               add the loop's paths to .gitignore
#   config.sh keys                                list keys with types and descriptions
#
# Scope (which file, and where inside it):
#   --project                ./.review-loop.json, shared by every provider      (default)
#   --user                   ~/.config/review-loop/config.json, shared, every project
#   --provider [NAME]        the "providers.NAME" section of the chosen shared file
#   --provider-file [NAME]   a separate file for one provider: ./.NAME/review-loop.json
#                            (or ~/.NAME/review-loop.json with --user), e.g. .claude/, .codex/
#   NAME defaults to the running provider (REVIEW_LOOP_PROVIDER, else "claude"); an explicit
#   NAME also selects whose effective values show/init report.
#
# Effective precedence: flags > REVIEW_LOOP_* env > project provider file > project shared
# (providers section over top-level) > user provider file > user shared > defaults.
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

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; }

# ── Arguments ────────────────────────────────────────────────────────────────
CMD="${1:-}"; [ $# -gt 0 ] && shift
SCOPE=project JSON=0 YES=0 DRY=0 MODE=shared PNAME="" EXPLICIT=0
ARGS=()
# Provider names are validated as whole strings by rl_valid_provider_name (lib.sh):
# a letter or digit followed by letters, digits, "_" or "-". Nothing starting with
# "-" (or containing a newline) qualifies, so a following flag is never taken as a name.
take_name() { # optional NAME after --provider / --provider-file
  # Returns 1 when no name follows: the next word is a flag, a KEY=VALUE, a
  # config key or a command. Anything else was meant as a name: it is printed
  # lower-cased when valid, and the command fails when it is not, so an invalid
  # name never silently falls back to the running provider.
  [ $# -gt 1 ] || return 1
  local n
  case "$2" in -*|*=*) return 1 ;; show|create|set|unset|init|gitignore|keys) return 1 ;; esac
  key_type "$2" > /dev/null 2>&1 && return 1
  n=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  rl_valid_provider_name "$n" || rl_die "invalid provider name '$2' (letters, digits, '_' and '-', not starting with '-')"
  printf '%s' "$n"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --user) SCOPE=user; EXPLICIT=1; shift ;;
    --project) SCOPE=project; EXPLICIT=1; shift ;;
    --provider=*) MODE=section; EXPLICIT=1; PNAME="${1#*=}"; shift ;;
    --provider) MODE=section; EXPLICIT=1; if PNAME=$(take_name "$@"); then shift 2; else PNAME=""; shift; fi ;;
    --provider-file=*) MODE=file; EXPLICIT=1; PNAME="${1#*=}"; shift ;;
    --provider-file) MODE=file; EXPLICIT=1; if PNAME=$(take_name "$@"); then shift 2; else PNAME=""; shift; fi ;;
    --json) JSON=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
ROOT="$PWD"
PROVIDER=$(rl_provider)
AUTO_NOTE=""
# No scope flag at all: when the project's shared file does not exist yet but
# this provider's own project file does (e.g. a legacy .claude/review-loop.json),
# edit that file, since it outranks the shared one and a write there would be
# masked. Any explicit flag (--project, --user, --provider, --provider-file)
# targets exactly what it names; masked writes are then reported by warn_masked.
if [ "$EXPLICIT" = "0" ] && [ -n "$PROVIDER" ] \
   && [ ! -f "$ROOT/.$RL_CONFIG_NAME" ] && [ -f "$ROOT/.$PROVIDER/$RL_CONFIG_NAME" ]; then
  MODE=file; PNAME="$PROVIDER"
  AUTO_NOTE="using the existing $ROOT/.$PROVIDER/$RL_CONFIG_NAME (no shared $ROOT/.$RL_CONFIG_NAME yet; pass --project to create the shared file instead)"
fi
if [ "$MODE" != "shared" ]; then
  PNAME=$(printf '%s' "$PNAME" | tr '[:upper:]' '[:lower:]')
  [ -n "$PNAME" ] || PNAME="$PROVIDER"
  [ -n "$PNAME" ] || rl_die "no provider given and none selected (pass --provider NAME or set REVIEW_LOOP_PROVIDER)"
  rl_valid_provider_name "$PNAME" || rl_die "invalid provider name '$PNAME' (letters, digits, '_' and '-', not starting with '-')"
  [ "$PNAME" != "none" ] || rl_die "'none' is not a provider: it disables provider files and sections, so values stored under it could never apply"
  # An explicit provider selects whose configuration is shown, edited and
  # resolved, even from another provider's session.
  PROVIDER="$PNAME"
  export REVIEW_LOOP_PROVIDER="$PNAME"
fi
case "$SCOPE" in user) BASE="$HOME"; SHARED="$(rl_user_config_dir)/config.json" ;; *) BASE="$ROOT"; SHARED="$ROOT/.$RL_CONFIG_NAME" ;; esac
case "$MODE" in
  file) TARGET="$BASE/.$PNAME/$RL_CONFIG_NAME"; SECTION='[]'; WHERE="$TARGET" ;;
  section) TARGET="$SHARED"; SECTION="$(jq -cn --arg p "$PNAME" '["providers", $p]')"; WHERE="$TARGET (providers.$PNAME)" ;;
  *) TARGET="$SHARED"; SECTION='[]'; WHERE="$TARGET" ;;
esac

# ── Helpers ──────────────────────────────────────────────────────────────────
read_file() { if [ -f "$1" ]; then jq -c . "$1" 2>/dev/null || rl_die "$1 is not valid JSON"; else echo '{}'; fi; }
write_file() { # FILE JSON
  mkdir -p "$(dirname "$1")"
  jq . <<< "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}
path_filter() { printf '%s' "$1" | jq -R 'split(".")'; }
get_in() { jq -c --argjson p "$(path_filter "$2")" 'getpath($p)' <<< "$1"; }
# Paths inside the target file, prefixed with the provider section when one is selected.
tpath() { jq -cn --argjson s "$SECTION" --argjson p "$(path_filter "$1")" '$s + $p'; }
set_in_target() { # KEY JSONVALUE -> updates $NEW
  NEW=$(jq -c --argjson p "$(tpath "$1")" --argjson v "$2" 'setpath($p; $v)' <<< "$NEW")
}
target_values() { jq -c --argjson s "$SECTION" 'getpath($s) // {}' <<< "$NEW"; }
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
  set_in_target "$key" "$val"
}

# warn_masked KEY... -> after a write, warn for every key whose effective value
# still comes from a higher-precedence source than the file just written.
warn_masked() {
  local eff k wrote have src
  eff=$(rl_resolve_config)
  for k in "$@"; do
    wrote=$(get_in "$(target_values)" "$k"); have=$(get_in "$eff" "$k")
    [ "$wrote" = "$have" ] && continue
    src=$(rl_config_source "$k")
    echo "warning: $k=$(display "$wrote") was written to $WHERE but the effective value is $(display "$have"), set by $src; change it there (e.g. --provider-file $PROVIDER) or remove the override" >&2
  done
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd_keys() {
  for k in $KEYS; do printf '  %-16s %-9s %s\n' "$k" "$(key_type "$k")" "$(key_help "$k")"; done
}

cmd_show() {
  local eff def label path kind
  eff=$(rl_resolve_config)
  def=$(HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent REVIEW_LOOP_PROVIDER=none REVIEW_LOOP_DIR= REVIEW_LOOP_MAX_ROUNDS= REVIEW_LOOP_BACKEND= \
        REVIEW_LOOP_MODEL= REVIEW_LOOP_USAGE= REVIEW_LOOP_DASHBOARD_OPEN= REVIEW_LOOP_DASHBOARD_OUT= \
        bash -c 'cd / && . "$1" && rl_resolve_config' _ "$RL_SCRIPTS_DIR/lib.sh")
  if [ "$JSON" = "1" ]; then
    local files='[]'
    while IFS=$'\t' read -r label path kind; do
      files=$(jq -c --argjson a "$files" --arg l "$label" --arg p "$path" --arg k "$kind" \
        --argjson e "$([ -f "$path" ] && echo true || echo false)" --argjson v "$(read_file "$path")" -n \
        '$a + [{label: $l, path: $p, kind: $k, exists: $e, values: $v}]')
    done < <(rl_config_files)
    jq -n --argjson e "$eff" --argjson d "$def" --argjson f "$files" --arg prov "$PROVIDER" \
      --arg scope "$SCOPE" --arg mode "$MODE" --arg target "$TARGET" --argjson section "$SECTION" \
      --argjson te "$([ -f "$TARGET" ] && echo true || echo false)" \
      --argjson se "$(NEW=$(read_file "$TARGET"); if [ "$SECTION" = "[]" ]; then [ -f "$TARGET" ] && echo true || echo false; else jq -c --argjson s "$SECTION" 'getpath($s) != null' <<< "$NEW"; fi)" \
      --arg note "$AUTO_NOTE" \
      '{provider: (if $prov == "" then null else $prov end), scope: $scope, mode: $mode, target: $target,
        section: $section, target_exists: $te, section_exists: $se, note: (if $note == "" then null else $note end),
        effective: $e, defaults: $d, files: $f}'
    return
  fi
  echo "review-loop configuration"
  echo "  provider: ${PROVIDER:-none} ($([ "$MODE" != "shared" ] && echo "selected with --provider" || echo "set REVIEW_LOOP_PROVIDER to override"))"
  echo "  files, lowest precedence first:"
  while IFS=$'\t' read -r label path kind; do
    printf '    %-16s %s (%s)\n' "$label" "$path" "$([ -f "$path" ] && echo exists || echo missing)"
  done < <(rl_config_files)
  echo "  writes go to: $WHERE"
  [ -n "$AUTO_NOTE" ] && echo "  note: $AUTO_NOTE"
  echo
  printf '  %-16s %-22s %-40s %s\n' key effective "set by" default
  for k in $KEYS; do
    printf '  %-16s %-22s %-40s %s\n' "$k" "$(display "$(get_in "$eff" "$k")")" "$(rl_config_source "$k")" "$(display "$(get_in "$def" "$k")")"
  done
  echo
  echo "  (edit with: config.sh set [--user] [--provider NAME | --provider-file NAME] KEY=VALUE)"
}

cmd_create() {
  NEW=$(read_file "$TARGET")
  if [ -f "$TARGET" ]; then
    if [ "$SECTION" = "[]" ] || [ "$(jq -c --argjson s "$SECTION" 'getpath($s) != null' <<< "$NEW")" = "true" ]; then
      echo "$WHERE already exists"; return 0
    fi
    NEW=$(jq -c --argjson s "$SECTION" 'setpath($s; {})' <<< "$NEW")
  elif [ "$SECTION" != "[]" ]; then
    NEW=$(jq -cn --argjson s "$SECTION" 'null | setpath($s; {})')
  else
    NEW='{}'
  fi
  write_file "$TARGET" "$NEW"
  echo "Created $WHERE (empty: every value is inherited, see: config.sh show)"
}

cmd_set() {
  [ "${#ARGS[@]}" -gt 0 ] || rl_die "usage: config.sh set [--user|--project] KEY=VALUE ..."
  NEW=$(read_file "$TARGET")
  local a keys=()
  for a in "${ARGS[@]}"; do
    case "$a" in *=*) ;; *) rl_die "expected KEY=VALUE, got '$a'" ;; esac
    apply_set "${a%%=*}" "${a#*=}"
    keys+=("${a%%=*}")
  done
  write_file "$TARGET" "$NEW"
  [ -n "$AUTO_NOTE" ] && echo "note: $AUTO_NOTE"
  echo "Updated $WHERE"
  jq . "$TARGET" | sed 's/^/  /'
  warn_masked "${keys[@]}"
}

cmd_unset() {
  [ "${#ARGS[@]}" -gt 0 ] || rl_die "usage: config.sh unset [--user|--project] KEY ..."
  NEW=$(read_file "$TARGET")
  local k
  for k in "${ARGS[@]}"; do
    key_type "$k" > /dev/null || rl_die "unknown key '$k'"
    NEW=$(jq -c --argjson p "$(tpath "$k")" --argjson s "$SECTION" \
      'delpaths([$p]) | (if (getpath($s + ["dashboard"]) == {}) then delpaths([$s + ["dashboard"]]) else . end)' <<< "$NEW")
  done
  write_file "$TARGET" "$NEW"
  echo "Updated $WHERE"
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
  local eff k cur raw val type written=()
  eff=$(rl_resolve_config)
  NEW=$(read_file "$TARGET")
  if [ -f "$TARGET" ]; then echo "Updating $WHERE (press Enter to keep the current value)"; else echo "Creating $WHERE (press Enter to keep the current value)"; fi
  echo "  provider: ${PROVIDER:-none}"
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
        set_in_target "$k" "$val"; written+=("$k"); break
      fi
      [ "$YES" = "1" ] && break
    done
  done
  write_file "$TARGET" "$NEW"
  echo
  [ -n "$AUTO_NOTE" ] && echo "note: $AUTO_NOTE"
  echo "Wrote $WHERE (only the values you set; the rest stay inherited, see: config.sh show)"
  jq . "$TARGET" | sed 's/^/  /'
  [ "${#written[@]}" -gt 0 ] && warn_masked "${written[@]}"
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

no_args() { [ "${#ARGS[@]}" -eq 0 ] || rl_die "unexpected argument '${ARGS[0]}' for '$CMD'"; }
case "$CMD" in
  show) no_args; cmd_show ;;
  create) no_args; cmd_create ;;
  set) cmd_set ;;
  unset) cmd_unset ;;
  init) no_args; cmd_init ;;
  gitignore) no_args; cmd_gitignore ;;
  keys) no_args; cmd_keys ;;
  ""|-h|--help|help) usage ;;
  *) rl_die "unknown command '$CMD' (show|create|set|unset|init|gitignore|keys)" ;;
esac
