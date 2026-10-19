#!/usr/bin/env bash
# review-loop — generate a self-contained HTML dashboard of all review loops.
#
# Usage: dashboard.sh [--dir DIR]... [--out FILE] [--open|--no-open] [--serve [--port N]]
#                     [--with-user-config]
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
# The page embeds the current configuration (config.sh show --json) and lets
# you edit it. A static page may be committed or shared, so by default it
# carries only project-level configuration: user files (~/.config/review-loop,
# ~/.<provider>/review-loop.json) are listed without contents, and effective
# values from those files or environment overrides are hidden.
# --with-user-config embeds them anyway. A served
# page always has them, but it is rendered into a private temp file that the
# server deletes on exit; the configured output keeps the redacted page. Without --serve it is a static file: the page shows the
# config.sh command for your changes and can save the file through the
# browser. With --serve (needs python3) a loopback-only server applies changes
# through config.sh directly; it runs until Ctrl-C and regenerates the page on
# every load.
#
# The page embeds every loop's state, task, coder summaries, reviews and
# summary as JSON and renders them with no network access needed.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq > /dev/null 2>&1 || rl_die "'jq' is required"

DIRS=() OUT="" OPEN="" SERVE=0 PORT=8765 SERVE_TOKEN="" WITH_USER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIRS+=("${2:-}"); shift 2 ;;
    --dir=*) DIRS+=("${1#*=}"); shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --open) OPEN=1; shift ;;
    --no-open) OPEN=0; shift ;;
    --serve) SERVE=1; shift ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --serve-token) SERVE_TOKEN="${2:-}"; shift 2 ;;   # internal: regeneration by the server
    --with-user-config) WITH_USER=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) rl_die "unknown argument '$1'" ;;
  esac
done
printf '%s' "$PORT" | grep -qE '^[0-9]{1,5}$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || rl_die "invalid port '$PORT' (1-65535)"

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

# Configuration, as config.sh reports it, so the page can show and edit it; the
# default role templates are embedded too, so the agent-roles section can show
# what each role runs with and which {{placeholders}} a replacement may use.
(cd "$ROOT" && bash "$RL_SCRIPTS_DIR/config.sh" show --json) > "$WORK/config-show.json" 2>/dev/null || echo 'null' > "$WORK/config-show.json"
bash "$RL_SCRIPTS_DIR/config.sh" keys --json > "$WORK/config-keys.json" 2>/dev/null || echo '{"keys":[],"backends":[]}' > "$WORK/config-keys.json"
# Every existing per-provider file (any provider), so the page can merge edits
# into a file other than the running provider's instead of overwriting it.
: > "$WORK/provider-files.jsonl"
for base in "$ROOT" "$HOME"; do
  for f in "$base"/.*/"$RL_CONFIG_NAME"; do
    [ -f "$f" ] || continue
    pname=$(basename "$(dirname "$f")"); pname="${pname#.}"
    rl_valid_provider_name "$pname" || continue
    jq -c --arg l "$([ "$base" = "$ROOT" ] && echo project || echo user) $pname" --arg p "$f" --arg prov "$pname" \
      --arg scope "$([ "$base" = "$ROOT" ] && echo project || echo user)" \
      '{label: $l, path: $p, kind: "provider", provider: $prov, scope: $scope, exists: true, values: .}' "$f" >> "$WORK/provider-files.jsonl" 2>/dev/null || true
  done
done
jq -s . "$WORK/provider-files.jsonl" > "$WORK/provider-files.json"
if [ "$WITH_USER" = "0" ] && [ -z "$SERVE_TOKEN" ]; then
  # Static page: strip user-file contents and values sourced from user files
  # or environment overrides. Files stay listed (path, existence) so the panel
  # can explain where values come from.
  jq -c 'if . == null then . else
    .files |= map(if (.label | startswith("user ")) then .values = null | .redacted = true else . end)
    | . as $show
    | reduce ($show.sources | to_entries[] | select(.value | (startswith("user ") or startswith("env ")))) as $e
        (.; .effective |= setpath(($e.key | split(".")); null)
          | if (.prompt_files // {}) | has($e.key) then .prompt_files[$e.key] = null else . end)
    | .redacted_user_config = true end' "$WORK/config-show.json" > "$WORK/config-show.tmp" && mv "$WORK/config-show.tmp" "$WORK/config-show.json"
  jq -c 'map(select(.scope == "project"))' "$WORK/provider-files.json" > "$WORK/pf.tmp" && mv "$WORK/pf.tmp" "$WORK/provider-files.json"
fi
jq -s -c --arg root "$ROOT" --arg t "$(rl_now)" --arg script "$RL_SCRIPTS_DIR/config.sh" --arg token "$SERVE_TOKEN" \
  --slurpfile show "$WORK/config-show.json" --slurpfile keys "$WORK/config-keys.json" --slurpfile pf "$WORK/provider-files.json" \
  --arg home "$HOME" --arg ucfg "$(rl_user_config_dir)/config.json" \
  --rawfile rtpl "$RL_TEMPLATES_DIR/reviewer-prompt.md" --rawfile ctpl "$RL_TEMPLATES_DIR/coder-brief.md" \
  '{generated_at: $t, root: $root, loops: (sort_by([.state.started_at, .state.loop_id]) | reverse),
    config: {show: $show[0], keys: $keys[0].keys, backends: $keys[0].backends, script: $script,
             provider_files: $pf[0], home: $home, user_shared: $ucfg},
    templates: {reviewer: $rtpl, coder: $ctpl},
    serve: (if $token == "" then null else {token: $token} end)}' \
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

if [ "$SERVE" = "1" ] && [ -z "$SERVE_TOKEN" ]; then
  command -v python3 > /dev/null 2>&1 || rl_die "--serve needs python3"
  TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  # The served page carries the token and the user's own configuration, so it
  # is rendered into a private temp file (0600) that the server deletes on
  # exit. The configured output ($OUT, written above) stays the redacted,
  # shareable page. The server re-runs this script (with --serve-token) into
  # the private file on every page load so the data is always fresh.
  SERVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-loop-serve.XXXXXX")
  chmod 700 "$SERVE_DIR"
  SERVE_PAGE="$SERVE_DIR/dashboard.html"
  DIR_ARGS=(); for d in "${DIRS[@]}"; do DIR_ARGS+=(--dir "$d"); done
  bash "$0" --no-open --out "$SERVE_PAGE" "${DIR_ARGS[@]}" --serve-token "$TOKEN" --with-user-config > /dev/null
  chmod 600 "$SERVE_PAGE"
  echo "review-loop dashboard: serving on http://127.0.0.1:$PORT/ (Ctrl-C to stop)"
  echo "  static page (shareable, user config hidden): $OUT"
  echo "  changes made in the page are applied with: bash $RL_SCRIPTS_DIR/config.sh"
  if [ "$OPEN" = "1" ]; then
    if command -v open > /dev/null 2>&1; then open "http://127.0.0.1:$PORT/"
    elif command -v xdg-open > /dev/null 2>&1; then xdg-open "http://127.0.0.1:$PORT/"; fi
  fi
  REVIEW_LOOP_SERVE_TOKEN="$TOKEN" REVIEW_LOOP_SERVE_PAGE="$SERVE_PAGE" REVIEW_LOOP_SERVE_DIR="$SERVE_DIR" REVIEW_LOOP_SERVE_ROOT="$ROOT" \
  REVIEW_LOOP_SERVE_SCRIPTS="$RL_SCRIPTS_DIR" REVIEW_LOOP_SERVE_PORT="$PORT" REVIEW_LOOP_SERVE_DIRS="$(printf '%s\n' "${DIRS[@]}")" \
  exec python3 - << 'PY_SERVER'
import json, os, shutil, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ["REVIEW_LOOP_SERVE_TOKEN"]
PAGE = os.environ["REVIEW_LOOP_SERVE_PAGE"]
SERVE_DIR = os.environ["REVIEW_LOOP_SERVE_DIR"]
ROOT = os.environ["REVIEW_LOOP_SERVE_ROOT"]
SCRIPTS = os.environ["REVIEW_LOOP_SERVE_SCRIPTS"]
PORT = int(os.environ["REVIEW_LOOP_SERVE_PORT"])
DIRS = [d for d in os.environ.get("REVIEW_LOOP_SERVE_DIRS", "").split("\n") if d]
NAME_RE = __import__("re").compile(r"^[a-z0-9][a-z0-9_-]*$")
# The known configuration keys, from config.sh itself, so every key in a request
# is checked before anything is written.
KNOWN = set()
try:
    KNOWN = {k["key"] for k in json.loads(subprocess.run(["bash", os.path.join(SCRIPTS, "config.sh"), "keys", "--json"],
             cwd=ROOT, capture_output=True, text=True).stdout)["keys"]}
except Exception:
    pass

def regenerate():
    args = ["bash", os.path.join(SCRIPTS, "dashboard.sh"), "--no-open", "--out", PAGE, "--serve-token", TOKEN, "--with-user-config"]
    for d in DIRS:
        args += ["--dir", d]
    subprocess.run(args, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(os.environ, REVIEW_LOOP_DASHBOARD_OPEN="0"))
    try:
        os.chmod(PAGE, 0o600)
    except OSError:
        pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/index.html", "/dashboard.html"):
            self._json(404, {"ok": False, "output": "not found"}); return
        regenerate()
        with open(PAGE, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/config":
            self._json(404, {"ok": False, "output": "not found"}); return
        if self.headers.get("X-RL-Token") != TOKEN:
            self._json(403, {"ok": False, "output": "bad token (reload the page)"}); return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n).decode() or "{}")
        except Exception:
            self._json(400, {"ok": False, "output": "invalid JSON"}); return
        # Build the config.sh argv strictly from validated fields (no shell).
        flags = []
        scope = req.get("scope", "project")
        if scope not in ("project", "user"):
            self._json(400, {"ok": False, "output": "bad scope"}); return
        flags.append("--" + scope)
        mode = req.get("mode", "shared")
        if mode not in ("shared", "section", "file"):
            self._json(400, {"ok": False, "output": "bad mode"}); return
        if mode != "shared":
            name = str(req.get("provider") or "")
            if not NAME_RE.match(name) or name == "none":
                self._json(400, {"ok": False, "output": "bad provider name"}); return
            flags.append(("--provider=" if mode == "section" else "--provider-file=") + name)
        sets = req.get("set") or {}
        unsets = req.get("unset") or []
        if not isinstance(sets, dict) or not isinstance(unsets, list):
            self._json(400, {"ok": False, "output": "bad payload"}); return
        # Validate every key of both operations before either runs, so a bad
        # unset can never follow a set that already changed the file.
        for k in list(sets) + list(unsets):
            if not isinstance(k, str) or k not in KNOWN:
                self._json(400, {"ok": False, "output": "unknown key %r" % (k,)}); return
        if set(sets) & set(unsets):
            self._json(400, {"ok": False, "output": "a key cannot be both set and unset"}); return
        for k, v in sets.items():
            if not isinstance(v, (str, int, float, bool)):
                self._json(400, {"ok": False, "output": "bad value for %s" % k}); return
        outputs, ok = [], True
        cfg = os.path.join(SCRIPTS, "config.sh")
        if sets:
            r = subprocess.run(["bash", cfg, "set"] + flags + ["%s=%s" % (k, str(v)) for k, v in sets.items()],
                               cwd=ROOT, capture_output=True, text=True)
            outputs.append(r.stdout + r.stderr); ok = ok and r.returncode == 0
        if unsets and ok:
            r = subprocess.run(["bash", cfg, "unset"] + flags + [str(k) for k in unsets], cwd=ROOT, capture_output=True, text=True)
            outputs.append(r.stdout + r.stderr); ok = ok and r.returncode == 0
        if not sets and not unsets:
            outputs.append("nothing to change")
        self._json(200 if ok else 422, {"ok": ok, "output": "".join(outputs)})

import signal
signal.signal(signal.SIGTERM, lambda *a: (_ for _ in ()).throw(KeyboardInterrupt()))
HTTPServer.allow_reuse_address = True
status = 0
try:
    # Binding happens inside the cleanup block: a port that is invalid or in
    # use must not leave the private page (token + user configuration) behind.
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
except KeyboardInterrupt:
    pass
except OSError as e:
    sys.stderr.write("review-loop dashboard: cannot listen on 127.0.0.1:%d (%s)\n" % (PORT, e.strerror or e))
    status = 1
finally:
    # The private page never outlives the server, whether it ran or failed to start.
    shutil.rmtree(SERVE_DIR, ignore_errors=True)
sys.exit(status)
PY_SERVER
fi

echo "review-loop dashboard: $COUNT loop(s) from ${DIRS[*]}"
echo "  written to $OUT"
if [ "$OPEN" = "1" ]; then
  if command -v open > /dev/null 2>&1; then open "$OUT"
  elif command -v xdg-open > /dev/null 2>&1; then xdg-open "$OUT"
  else echo "  (no 'open'/'xdg-open' found; open the file manually)"; fi
fi
