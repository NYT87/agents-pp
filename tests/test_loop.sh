#!/usr/bin/env bash
# review-loop state-machine tests. Plain bash; needs jq and git.
# Run: bash tests/test_loop.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S="$HERE/../plugins/review-loop/skills/review-loop/scripts"
PASS=0 FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate from the real user config and force the fake backend.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export REVIEW_LOOP_BACKEND=fake
export REVIEW_LOOP_FAKE_FILE="$TMP/verdicts"
unset REVIEW_LOOP_DIR REVIEW_LOOP_MAX_ROUNDS REVIEW_LOOP_MODEL REVIEW_LOOP_NESTED REVIEW_LOOP_DASHBOARD_OUT
export REVIEW_LOOP_DASHBOARD_OPEN=0   # never launch a browser from the tests
export REVIEW_LOOP_PROVIDER=claude    # deterministic provider regardless of where the suite runs
export XDG_CONFIG_HOME="$HOME/.config"

pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1: $2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "output does not contain '$2': $(printf '%s' "$3" | head -c 300)"; fi; }
assert_not_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "output contains '$2'"; else pass "$1"; fi; }
assert_file() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing file $2"; fi; }
assert_no_file() { if [ -e "$2" ]; then fail "$1" "unexpected file $2"; else pass "$1"; fi; }
section() { echo; echo "== $1"; }

verdicts() { printf '%s\n' "$@" > "$REVIEW_LOOP_FAKE_FILE"; }

new_repo() {
  local d="$TMP/$1"
  mkdir -p "$d" && git -C "$d" init -q && echo hi > "$d/README.md" && git -C "$d" add . \
    && git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  echo "$d"
}
hook() { # REPO SESSION [LAST_MSG]
  local out
  out=$(jq -n --arg c "$1" --arg s "$2" --arg m "${3:-}" \
    '{cwd: $c, session_id: $s, last_assistant_message: $m, stop_hook_active: false}' \
    | (cd "$1" && bash "$S/stop-hook.sh" 2>> "$TMP/hook.stderr"))
  printf '%s' "$out" | jq -e . > /dev/null 2>&1 || fail "hook prints valid JSON" "$out"
  printf '%s' "$out"
}
decision() { printf '%s' "$1" | jq -r '.decision // "allow"'; }
reason() { printf '%s' "$1" | jq -r '.reason // ""'; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""'; }
pointer() { cat "$1/.claude/review-loop.active" 2>/dev/null; }
st() { jq -r ".$2" "$1/state.json"; }   # st LOOP_DIR KEY
start() { (cd "$1" && shift && bash "$S/start.sh" "$@" 2>&1); }
review() { (cd "$1" && bash "$S/review.sh" 2>&1); }
coder() { printf '# summary\n' > "$1/round-$(printf '%02d' "$2")-coder.md"; }

# ─────────────────────────────────────────────────────────────────────────────
section "no active loop"
R=$(new_repo r0)
assert_eq "hook allows with no loop" "{}" "$(hook "$R" s1)"
assert_contains "status reports no loop" "No active review loop" "$(cd "$R" && bash "$S/status.sh")"
assert_contains "cancel reports no loop" "No active review loop" "$(cd "$R" && bash "$S/cancel.sh")"

section "happy path: changes_requested then approved"
R=$(new_repo r1)
OUT=$(start "$R" --max-rounds 3 "add a greet function")
assert_contains "start prints id" "Review loop started" "$OUT"
L=$(pointer "$R")
assert_file "state.json created" "$L/state.json"
assert_eq "task saved" "add a greet function" "$(cat "$L/task.md")"
assert_eq "base_ref is a sha" "40" "$(st "$L" base_ref | tr -d '\n' | wc -c | tr -d ' ')"
assert_contains "start refuses when active" "already active" "$(start "$R" "another task")"

H=$(hook "$R" s1)
assert_eq "no changes -> block" "block" "$(decision "$H")"
assert_contains "no changes message" "no changes to the project were detected" "$(reason "$H")"
assert_eq "retries incremented" "1" "$(st "$L" retries)"
assert_eq "session bound" "s1" "$(st "$L" session_id)"

echo 'def greet(): pass' > "$R/app.py"
H=$(hook "$R" s1)
assert_eq "changes -> block" "block" "$(decision "$H")"
assert_contains "asks for coder summary" "round-01-coder.md" "$(reason "$H")"
assert_contains "asks to run review.sh" "scripts/review.sh" "$(reason "$H")"
assert_contains "mentions round" "round 1 of 3" "$(reason "$H")"

OUT=$(review "$R"); RC=$?
assert_eq "review.sh fails without coder summary" "1" "$RC"
assert_contains "explains missing summary" "coder summary missing" "$OUT"
assert_no_file "no review installed" "$L/round-01-review.md"

coder "$L" 1
verdicts changes_requested approved
OUT=$(review "$R"); RC=$?
assert_eq "review.sh ok on changes_requested" "0" "$RC"
assert_contains "prints CHANGES REQUESTED" "CHANGES REQUESTED in round 1 of 3" "$OUT"
assert_contains "tells next steps" "round-02-coder.md" "$OUT"
assert_file "review installed" "$L/round-01-review.md"
assert_file "prompt kept" "$L/round-01-prompt.md"
assert_contains "canonical frontmatter" "verdict: changes_requested" "$(head -3 "$L/round-01-review.md")"
assert_eq "round advanced" "2" "$(st "$L" round)"
assert_eq "phase coding" "coding" "$(st "$L" phase)"
assert_eq "retries reset by review" "0" "$(st "$L" retries)"
assert_contains "prompt embeds task" "add a greet function" "$(cat "$L/round-01-prompt.md")"
assert_contains "prompt has diff instructions" "git diff $(st "$L" base_ref)" "$(cat "$L/round-01-prompt.md")"

H=$(hook "$R" s1)
assert_contains "round 2 block references previous review" "round-01-review.md" "$(reason "$H")"
assert_contains "round 2 block asks for round-02 summary" "round-02-coder.md" "$(reason "$H")"

coder "$L" 2
OUT=$(review "$R")
assert_contains "prints APPROVED" "APPROVED in round 2 of 3" "$OUT"
assert_contains "round 2 prompt embeds previous review" "Review of round 1" "$(cat "$L/round-02-prompt.md")"
assert_no_file "pointer removed on approval" "$R/.claude/review-loop.active"
assert_eq "state inactive" "false" "$(st "$L" active)"
assert_eq "phase done" "done" "$(st "$L" phase)"
assert_eq "outcome approved" "approved" "$(st "$L" outcome)"
assert_contains "summary outcome" "outcome: approved" "$(cat "$L/summary.md")"
assert_eq "hook allows after approval" "{}" "$(hook "$R" s1)"
assert_contains "log has verdicts" "verdict=approved" "$(cat "$L/loop.log")"

section "max rounds reached"
R=$(new_repo r2)
start "$R" --max-rounds 2 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
coder "$L" 1; verdicts changes_requested changes_requested
review "$R" > /dev/null
coder "$L" 2
OUT=$(review "$R")
assert_contains "max rounds message" "maximum of 2 round(s) is reached" "$OUT"
assert_eq "outcome max_rounds_reached" "max_rounds_reached" "$(st "$L" outcome)"
assert_no_file "pointer removed" "$R/.claude/review-loop.active"
assert_contains "summary lists unresolved ids" "R2-C1" "$(cat "$L/summary.md")"
assert_contains "summary lists prior unresolved id" "R1-C1" "$(cat "$L/summary.md")"
assert_eq "hook allows after cap" "{}" "$(hook "$R" s1)"

section "max_rounds=1"
R=$(new_repo r3)
start "$R" --max-rounds 1 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
coder "$L" 1; verdicts changes_requested
assert_contains "single round cap" "maximum of 1 round(s)" "$(review "$R")"
assert_eq "finished" "false" "$(st "$L" active)"

section "nested guard, foreign session, dangling pointer, corrupt state"
R=$(new_repo r4)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
assert_eq "nested env allows" "{}" "$(REVIEW_LOOP_NESTED=1 hook "$R" s1)"
hook "$R" s1 > /dev/null
assert_eq "foreign session allows" "{}" "$(hook "$R" s2)"
assert_eq "foreign session leaves retries" "1" "$(st "$L" retries)"
assert_eq "same session still blocks" "block" "$(decision "$(hook "$R" s1)")"
assert_file "pointer still present" "$R/.claude/review-loop.active"
cp "$L/state.json" "$TMP/state.bak"; echo '{not json' > "$L/state.json"
assert_eq "corrupt state allows" "{}" "$(hook "$R" s1)"
assert_no_file "corrupt state removes pointer" "$R/.claude/review-loop.active"
printf '%s\n' "$TMP/nowhere" > "$R/.claude/review-loop.active"
assert_eq "dangling pointer allows" "{}" "$(hook "$R" s1)"
assert_no_file "dangling pointer removed" "$R/.claude/review-loop.active"
printf '%s\n' "$L" > "$R/.claude/review-loop.active"; cp "$TMP/state.bak" "$L/state.json"
jq '.loop_id = "../../evil"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
assert_eq "invalid loop_id allows" "{}" "$(hook "$R" s1)"
assert_no_file "invalid loop_id removes pointer" "$R/.claude/review-loop.active"

section "cancel, force, status"
R=$(new_repo r5)
start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_contains "status shows round" "round:       1 / 5" "$(cd "$R" && bash "$S/status.sh")"
assert_contains "cancel reports" "Review loop cancelled" "$(cd "$R" && bash "$S/cancel.sh")"
assert_eq "cancelled outcome" "cancelled" "$(st "$L" outcome)"
assert_no_file "cancel removes pointer" "$R/.claude/review-loop.active"
assert_eq "hook allows after cancel" "{}" "$(hook "$R" s1)"
start "$R" "task2" > /dev/null; L2=$(pointer "$R")
OUT=$(start "$R" --force "task3")
assert_contains "force cancels previous" "Cancelled previous loop" "$OUT"
assert_eq "previous marked cancelled" "cancelled" "$(st "$L2" outcome)"
L3=$(pointer "$R")
assert_eq "new loop active" "true" "$(st "$L3" active)"
assert_eq "new loop differs" "1" "$([ "$L2" != "$L3" ] && echo 1)"

section "config precedence"
R=$(new_repo r6)
echo '{"max_rounds": 7, "dir": "reviews"}' > "$HOME/.claude/review-loop.json"
start "$R" "t" > /dev/null; L=$(pointer "$R")
assert_eq "user config max_rounds" "7" "$(st "$L" max_rounds)"
assert_contains "user config dir" "/reviews/" "$L"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
mkdir -p "$R/.claude"; echo '{"max_rounds": 8}' > "$R/.claude/review-loop.json"
start "$R" "t" > /dev/null; L=$(pointer "$R")
assert_eq "project config overrides user" "8" "$(st "$L" max_rounds)"
assert_contains "project inherits user dir" "/reviews/" "$L"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
REVIEW_LOOP_MAX_ROUNDS=9 start "$R" "t" > /dev/null; L=$(pointer "$R")
assert_eq "env overrides project" "9" "$(st "$L" max_rounds)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
REVIEW_LOOP_MAX_ROUNDS=9 start "$R" --max-rounds 2 --dir .rl --model gpt-x "t" > /dev/null; L=$(pointer "$R")
assert_eq "flag overrides env" "2" "$(st "$L" max_rounds)"
assert_eq "flag model stored" "gpt-x" "$(st "$L" model)"
assert_contains "flag dir used" "/.rl/" "$L"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
rm "$HOME/.claude/review-loop.json"
assert_contains "bad max_rounds rejected" "positive integer" "$(start "$R" --max-rounds 0 "t")"
assert_contains "unknown backend rejected" "unknown backend" "$(start "$R" --backend nope "t")"
assert_contains "no task rejected" "no task description" "$(start "$R")"

section "verdict parsing"
P="$TMP/parse"; mkdir -p "$P"
parse() { (cd "$S" && bash -c '. ./lib.sh; rl_parse_verdict "$1"' _ "$1"); }
blocking() { (cd "$S" && bash -c '. ./lib.sh; rl_count_blocking "$1"' _ "$1"); }
printf 'Sure, here is the review.\n```markdown\n---\n**verdict:** approved\n---\n```\n' > "$P/a"
assert_eq "prose + fenced bold verdict" "approved" "$(parse "$P/a")"
printf -- '---\nverdict: approved | changes_requested\n---\n' > "$P/b"
assert_eq "spec line never matches" "" "$(parse "$P/b")"
printf 'verdict: approved\n\nsome text\n\nVERDICT: changes_requested\n' > "$P/c"
assert_eq "last verdict wins" "changes_requested" "$(parse "$P/c")"
printf '> Verdict: "Approved"\n' > "$P/d"
assert_eq "quoted, capitalised, blockquote" "approved" "$(parse "$P/d")"
printf 'no verdict here\n' > "$P/e"
assert_eq "no verdict -> empty" "" "$(parse "$P/e")"
printf '### R1-C1\n- blocking: yes\n### R1-C2\n- **blocking:** no\n- R0-C1: unresolved\n- R0-C2: declined-rejected — nope\n- R0-C3: declined-accepted\n| blocking: yes |\n' > "$P/f"
assert_eq "blocking count" "4" "$(blocking "$P/f")"

section "reviewer output validation"
R=$(new_repo r7)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"; coder "$L" 1
verdicts fail
OUT=$(review "$R"); RC=$?
assert_eq "backend failure -> rc 1" "1" "$RC"
assert_contains "backend failure message" "backend 'fake' failed" "$OUT"
assert_no_file "no review on failure" "$L/round-01-review.md"
verdicts partial
review "$R" > /dev/null
assert_no_file "partial output not installed" "$L/round-01-review.md"
assert_no_file "raw removed" "$L/round-01-review.raw.md"
verdicts garbage
OUT=$(review "$R"); RC=$?
assert_eq "garbage -> rc 1" "1" "$RC"
assert_contains "garbage message" "contains no 'VERDICT" "$OUT"
assert_file "invalid output kept" "$L/round-01-review.invalid.md"
assert_no_file "no review on garbage" "$L/round-01-review.md"
assert_eq "round unchanged after failures" "1" "$(st "$L" round)"
verdicts approved_with_blocking
OUT=$(review "$R")
assert_contains "downgrade notice" "treating as changes_requested" "$OUT"
assert_contains "downgraded frontmatter" "verdict: changes_requested" "$(head -3 "$L/round-01-review.md")"
assert_eq "downgrade advances round" "2" "$(st "$L" round)"
coder "$L" 2; verdicts prose
assert_contains "prose output approved" "APPROVED" "$(review "$R")"

section "git edge cases"
R="$TMP/unborn"; mkdir -p "$R" && git -C "$R" init -q
start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_eq "unborn HEAD uses empty tree" "4b825dc642cb6eb9a060e54bf8d69288fbee4904" "$(st "$L" base_ref)"
assert_contains "unborn: no changes detected" "no changes" "$(reason "$(hook "$R" s1)")"
echo x > "$R/new.txt"
assert_contains "unborn: untracked file counts" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L" 1; verdicts approved
assert_contains "unborn: review works" "APPROVED" "$(review "$R")"

R="$TMP/nogit"; mkdir -p "$R"
start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_eq "non-git base_ref null" "null" "$(st "$L" base_ref)"
touch -t 202001010000 "$L/task.md"
assert_contains "non-git: no changes" "no changes" "$(reason "$(hook "$R" s1)")"
echo x > "$R/new.txt"
assert_contains "non-git: change detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L" 1; verdicts approved
OUT=$(review "$R")
assert_contains "non-git: review works" "APPROVED" "$OUT"
assert_contains "non-git prompt uses find" "find . -type f -newer" "$(cat "$L/round-01-prompt.md")"

R=$(new_repo r8)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"; git -C "$R" add f; git -C "$R" -c user.email=t@t -c user.name=t commit -qm work
assert_contains "committed work still detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
mkdir -p "$R/sub"
assert_eq "hook from subdirectory finds loop" "block" "$(decision "$(hook "$R/sub" s1)")"
(cd "$R/sub" && bash "$S/status.sh" | grep -q "Review loop:") && pass "status from subdirectory" || fail "status from subdirectory" "not found"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
start "$R" --git-exclude "task" > /dev/null
assert_contains "git-exclude adds dir" "/.review-loop/" "$(cat "$R/.git/info/exclude")"
assert_contains "git-exclude adds pointer" "/.claude/review-loop.active" "$(cat "$R/.git/info/exclude")"
assert_contains "excluded dir invisible to git" "no changes" "$(reason "$(hook "$R" s1)")"

section "retry exhaustion, retries reset, pause"
R=$(new_repo r9)
start "$R" "task" > /dev/null; L=$(pointer "$R")
hook "$R" s1 > /dev/null; hook "$R" s1 > /dev/null; hook "$R" s1 > /dev/null
H=$(hook "$R" s1)
assert_eq "4th stop without work allows" "allow" "$(decision "$H")"
assert_contains "aborted message" "no changes were made" "$(sysmsg "$H")"
assert_eq "outcome no_work" "no_work" "$(st "$L" outcome)"
assert_no_file "pointer removed" "$R/.claude/review-loop.active"

R=$(new_repo r10)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
hook "$R" s1 > /dev/null; hook "$R" s1 > /dev/null; hook "$R" s1 > /dev/null
H=$(hook "$R" s1)
assert_contains "reviewer never run -> abort" "reviewer was never run" "$(sysmsg "$H")"
assert_eq "outcome review_not_run" "review_not_run" "$(st "$L" outcome)"

R=$(new_repo r11)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
hook "$R" s1 > /dev/null; hook "$R" s1 > /dev/null
assert_eq "retries accumulate" "2" "$(st "$L" retries)"
coder "$L" 1; verdicts changes_requested; review "$R" > /dev/null
assert_eq "review resets retries" "0" "$(st "$L" retries)"
H=$(hook "$R" s1 "I need to know which database to use. $(printf 'REVIEW-LOOP: PAUSE')")
assert_eq "pause allows" "allow" "$(decision "$H")"
assert_contains "pause message" "paused" "$(sysmsg "$H")"
assert_eq "phase paused" "paused" "$(st "$L" phase)"
assert_file "pointer kept while paused" "$R/.claude/review-loop.active"
H=$(hook "$R" s1 "continuing")
assert_eq "resume blocks" "block" "$(decision "$H")"
assert_eq "phase back to coding" "coding" "$(st "$L" phase)"

section "hook robustness"
R=$(new_repo r12)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
chmod 555 "$L"
H=$(hook "$R" s1)
chmod 755 "$L"
assert_contains "internal error is visible" "hook error" "$(sysmsg "$H")"
assert_no_file "internal error removes pointer" "$R/.claude/review-loop.active"
start "$R" "task" > /dev/null; L=$(pointer "$R")
mkdir -p "$TMP/badbin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/badbin/jq"; chmod +x "$TMP/badbin/jq"
OUT=$(jq -n --arg c "$R" '{cwd: $c, session_id: "s1"}' | (cd "$R" && PATH="$TMP/badbin:$PATH" bash "$S/stop-hook.sh"))
printf '%s' "$OUT" | jq -e . > /dev/null 2>&1 && pass "broken jq still yields JSON" || fail "broken jq still yields JSON" "$OUT"
OUT=$(printf 'not json' | (cd "$R" && bash "$S/stop-hook.sh"))
printf '%s' "$OUT" | jq -e . > /dev/null 2>&1 && pass "malformed stdin still yields JSON" || fail "malformed stdin still yields JSON" "$OUT"

section "usage recording (opt-in)"
R=$(new_repo r13)
start "$R" --max-rounds 3 --usage "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
assert_eq "usage flag stored" "true" "$(st "$L" usage)"
# coder transcript fixture: one entry before the loop, one message split in two lines, one more message
jq '.started_at = "2020-01-01T00:00:00Z"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
TR="$TMP/transcript.jsonl"
{
  echo '{"type":"assistant","timestamp":"2019-12-31T23:59:59.000Z","message":{"id":"m0","model":"claude-x","usage":{"input_tokens":999,"output_tokens":999}}}'
  echo '{"type":"assistant","timestamp":"2021-01-01T00:00:01.000Z","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":20,"output_tokens":100,"output_tokens_details":{"thinking_tokens":30}}}}'
  echo '{"type":"assistant","timestamp":"2021-01-01T00:00:02.000Z","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":20,"output_tokens":100,"output_tokens_details":{"thinking_tokens":30}}}}'
  echo '{"type":"user","timestamp":"2021-01-01T00:00:03.000Z","message":{"role":"user","content":"hi"}}'
  echo '{"type":"assistant","timestamp":"2021-01-01T00:00:04.000Z","message":{"id":"m2","model":"claude-y","usage":{"input_tokens":5,"cache_read_input_tokens":500,"output_tokens":50}}}'
} > "$TR"
U=$(cd "$S" && bash -c '. ./lib.sh; rl_transcript_usage "$1" "2020-01-01T00:00:00Z"' _ "$TR")
assert_eq "transcript: dedup + time filter output" "150" "$(jq .output_tokens <<< "$U")"
assert_eq "transcript: uncached input" "15" "$(jq .input_tokens <<< "$U")"
assert_eq "transcript: cached input" "1500" "$(jq .cached_input_tokens <<< "$U")"
assert_eq "transcript: reasoning" "30" "$(jq .reasoning_tokens <<< "$U")"
assert_eq "transcript: turns" "2" "$(jq .num_turns <<< "$U")"
assert_eq "transcript: models" "claude-x,claude-y" "$(jq -r .model <<< "$U")"
H=$(jq -n --arg c "$R" --arg t "$TR" '{cwd: $c, session_id: "s1", transcript_path: $t}' | (cd "$R" && bash "$S/stop-hook.sh"))
assert_eq "hook stores transcript path" "$TR" "$(st "$L" transcript_path)"
coder "$L" 1; verdicts changes_requested approved
review "$R" > /dev/null
assert_eq "round 1 reviewer usage recorded" "1000" "$(jq '.rounds[0].reviewer.input_tokens' "$L/state.json")"
assert_eq "round 1 reviewer cost" "0.01" "$(jq '.rounds[0].reviewer.cost_usd' "$L/state.json")"
assert_eq "round 1 coder usage recorded" "150" "$(jq '.rounds[0].coder.output_tokens' "$L/state.json")"
assert_eq "coder cumulative stored" "150" "$(jq '.coder_usage_cum.output_tokens' "$L/state.json")"
assert_file "usage.md written" "$L/usage.md"
assert_contains "usage.md has reviewer row" "| round 1 reviewer | fake-model | 1000 | 500 | 100 | 200 | 50 | 0.01 | 3 |" "$(cat "$L/usage.md")"
assert_no_file "sidecar cleaned" "$L/round-01-review.raw.md.usage.json"
assert_contains "status shows usage" "round 1 reviewer | fake-model" "$(cd "$R" && bash "$S/status.sh")"
echo '{"type":"assistant","timestamp":"2021-01-01T00:00:05.000Z","message":{"id":"m3","model":"claude-x","usage":{"input_tokens":1,"output_tokens":25}}}' >> "$TR"
coder "$L" 2; review "$R" > /dev/null
assert_eq "round 2 coder delta" "25" "$(jq '.rounds[1].coder.output_tokens' "$L/state.json")"
assert_eq "two rounds recorded" "2" "$(jq '.rounds | length' "$L/state.json")"
SUM=$(cat "$L/summary.md")
assert_contains "summary has usage section" "## Usage" "$SUM"
assert_contains "summary reviewer total" "| TOTAL reviewer | fake-model | 2000 | 1000 | 200 | 400 | 100 | 0.02 | 6 |" "$SUM"
assert_contains "summary coder total" "| TOTAL coder | claude-x,claude-y | 16 | 1500 | 20 | 175 | 30 | - | 3 |" "$SUM"

R=$(new_repo r14)
mkdir -p "$HOME/.claude/projects/-some-project"
cp "$TR" "$HOME/.claude/projects/-some-project/abcdef12-3456-7890-abcd-ef1234567890.jsonl"
start "$R" --usage --session abcdef12-3456-7890-abcd-ef1234567890 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
assert_eq "session flag stored" "abcdef12-3456-7890-abcd-ef1234567890" "$(st "$L" session_id)"
jq '.started_at = "2020-01-01T00:00:00Z"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
coder "$L" 1; verdicts approved; review "$R" > /dev/null
assert_eq "coder usage found via session id glob" "175" "$(jq '.rounds[0].coder.output_tokens' "$L/state.json")"
assert_eq "hook treats start session as owner" "{}" "$(hook "$R" other-session)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null) || true
start "$R" --force --usage --session '${CLAUDE_SESSION_ID}' "task" > /dev/null; L=$(pointer "$R")
assert_eq "unsubstituted placeholder ignored" "null" "$(st "$L" session_id)"
coder "$L" 1; echo x > "$R/g"; verdicts approved; review "$R" > /dev/null
assert_eq "no transcript -> coder usage null" "null" "$(jq '.rounds[0].coder' "$L/state.json")"
assert_contains "summary says n/a" "TOTAL coder | n/a" "$(cat "$L/summary.md")"

section "usage disabled by default"
R=$(new_repo r15)
OUT=$(start "$R" "task"); L=$(pointer "$R"); echo x > "$R/f"
assert_eq "default usage false" "false" "$(st "$L" usage)"
assert_contains "start says usage off" "usage:      off" "$OUT"
H=$(jq -n --arg c "$R" --arg t "$TR" '{cwd: $c, session_id: "s1", transcript_path: $t}' | (cd "$R" && bash "$S/stop-hook.sh"))
assert_eq "hook does not store transcript when off" "null" "$(st "$L" transcript_path)"
coder "$L" 1; verdicts changes_requested approved
OUT=$(review "$R")
assert_not_contains "review output omits usage.md" "usage.md" "$OUT"
assert_no_file "no usage.md when off" "$L/usage.md"
assert_eq "round recorded without usage" "1" "$(jq '.rounds | length' "$L/state.json")"
assert_eq "no reviewer usage field" "null" "$(jq '.rounds[0].reviewer' "$L/state.json")"
assert_eq "no coder usage field" "null" "$(jq '.rounds[0].coder' "$L/state.json")"
assert_eq "round verdict still recorded" "changes_requested" "$(jq -r '.rounds[0].verdict' "$L/state.json")"
assert_not_contains "status omits usage" "Usage so far" "$(cd "$R" && bash "$S/status.sh")"
assert_contains "status shows usage off" "usage:       off" "$(cd "$R" && bash "$S/status.sh")"
coder "$L" 2; review "$R" > /dev/null
assert_not_contains "summary omits usage section" "## Usage" "$(cat "$L/summary.md")"
assert_no_file "no sidecar leftovers" "$L/round-02-review.raw.md.usage.json"

R=$(new_repo r16)
REVIEW_LOOP_USAGE=true start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_eq "env enables usage" "true" "$(st "$L" usage)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
mkdir -p "$R/.claude"; echo '{"usage": true}' > "$R/.claude/review-loop.json"
start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_eq "config enables usage" "true" "$(st "$L" usage)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
start "$R" --no-usage "task" > /dev/null; L=$(pointer "$R")
assert_eq "--no-usage overrides config" "false" "$(st "$L" usage)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
REVIEW_LOOP_USAGE=0 start "$R" "task" > /dev/null; L=$(pointer "$R")
assert_eq "env 0 overrides config" "false" "$(st "$L" usage)"

section "storage dir edge cases (--dir .)"
norm() { (cd "$S" && bash -c '. ./lib.sh; rl_normalize_path "$1"' _ "$1"); }
assert_eq "normalize ./" "/a/b" "$(norm "/a/b/.")"
assert_eq "normalize .." "/a/c" "$(norm "/a/b/../c")"
assert_eq "normalize //" "/a/b" "$(norm "//a//b/")"
R=$(new_repo r17)
start "$R" --dir . "task" > /dev/null; L=$(pointer "$R")
assert_eq "dir . resolves to root/<id>" "$R/$(basename "$L")" "$L"
assert_contains "dir .: no changes yet" "no changes" "$(reason "$(hook "$R" s1)")"
echo changed >> "$R/README.md"
assert_contains "dir .: real change detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L" 1; verdicts approved; review "$R" > /dev/null
assert_contains "dir .: prompt excludes only the loop dir" ":(exclude)$(basename "$L")" "$(cat "$L/round-01-prompt.md")"
assert_not_contains "dir .: prompt never excludes ." "':(exclude).'" "$(cat "$L/round-01-prompt.md")"
start "$R" --dir . --git-exclude "task" > /dev/null; L=$(pointer "$R")
assert_contains "dir .: git-exclude uses loop dir" "/$(basename "$L")/" "$(cat "$R/.git/info/exclude")"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
start "$R" --dir ./sub/../.rl/ "task" > /dev/null; L=$(pointer "$R")
assert_contains "relative dir normalized" "$R/.rl/" "$L"
echo more >> "$R/README.md"
assert_contains "normalized dir: change detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"

section "--force validates before cancelling"
R=$(new_repo r18)
start "$R" "task" > /dev/null; L=$(pointer "$R")
OUT=$(start "$R" --force --backend nope "task2"); RC=$?
assert_eq "bad --force fails" "1" "$RC"
assert_contains "bad --force explains" "unknown backend" "$OUT"
assert_eq "previous loop still active" "true" "$(st "$L" active)"
assert_eq "pointer intact" "$L" "$(pointer "$R")"
assert_not_contains "nothing cancelled" "Cancelled previous loop" "$OUT"
OUT=$(start "$R" --force --max-rounds x "task2")
assert_eq "bad max-rounds keeps loop" "true" "$(st "$L" active)"
OUT=$(start "$R" --force "task3")
assert_contains "valid --force cancels" "Cancelled previous loop" "$OUT"
assert_eq "old loop cancelled" "cancelled" "$(st "$L" outcome)"

section "review structure validation"
R=$(new_repo r19)
start "$R" "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"; coder "$L" 1
verdicts verdict_only
OUT=$(review "$R"); RC=$?
assert_eq "bare verdict rejected" "1" "$RC"
assert_contains "bare verdict message" "not a usable review: missing a '## Comments' section" "$OUT"
assert_no_file "bare verdict not installed" "$L/round-01-review.md"
assert_file "bare verdict kept as invalid" "$L/round-01-review.invalid.md"
assert_eq "loop still active" "true" "$(st "$L" active)"
verdicts cr_no_comments
OUT=$(review "$R"); RC=$?
assert_eq "changes_requested without comments rejected" "1" "$RC"
assert_contains "no-comments message" "no comment" "$OUT"
V="$TMP/v"; mkdir -p "$V"
validate() { (cd "$S" && bash -c '. ./lib.sh; rl_validate_review "$1" "$2"' _ "$1" "$2"); }
printf '## Comments\n\n## Assessment\n\nVERDICT: approved\n' > "$V/a"
assert_contains "empty assessment rejected" "empty" "$(validate "$V/a" approved)"
printf '## Comments\n\nNone.\n\n## Assessment\n\nSolid.\n\nVERDICT: approved\n' > "$V/b"
assert_eq "minimal approved review accepted" "" "$(validate "$V/b" approved)"
printf '## Previous comments\n\n- R1-C1: unresolved\n\n## Comments\n\n## Assessment\n\nStill broken.\n\nVERDICT: changes_requested\n' > "$V/c"
assert_eq "unresolved previous item counts as a comment" "" "$(validate "$V/c" changes_requested)"
verdicts approved
assert_contains "valid review after rejections" "APPROVED" "$(review "$R")"

section "--force survives an uncreatable dir"
R=$(new_repo r20)
start "$R" "task" > /dev/null; L=$(pointer "$R")
OUT=$(start "$R" --force --dir /dev/null/rl "task2" 2>&1); RC=$?
assert_eq "uncreatable dir fails" "1" "$RC"
assert_contains "uncreatable dir message" "cannot create" "$OUT"
assert_eq "old loop still active after mkdir failure" "true" "$(st "$L" active)"
assert_eq "pointer intact after mkdir failure" "$L" "$(pointer "$R")"

section "several loops stored at the project root"
R=$(new_repo r21)
start "$R" --dir . "task" > /dev/null; L1=$(pointer "$R")
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
start "$R" --dir . "task2" > /dev/null; L2=$(pointer "$R")
assert_contains "second root loop: old loop dir is not a change" "no changes" "$(reason "$(hook "$R" s1)")"
echo changed >> "$R/README.md"
assert_contains "second root loop: real change detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L2" 1; verdicts approved; review "$R" > /dev/null
assert_contains "prompt excludes old loop dir" ":(exclude)$(basename "$L1")" "$(cat "$L2/round-01-prompt.md")"
assert_contains "prompt excludes current loop dir" ":(exclude)$(basename "$L2")" "$(cat "$L2/round-01-prompt.md")"
mkdir -p "$R/20261015-120000-abcdef"; echo real > "$R/20261015-120000-abcdef/data.txt"
(cd "$R" && bash "$S/cancel.sh" > /dev/null) || true
start "$R" --dir . "task3" > /dev/null; L3=$(pointer "$R")
assert_contains "loop-shaped project folder counts as a change" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L3" 1; verdicts approved; review "$R" > /dev/null
assert_not_contains "prompt keeps loop-shaped project folder visible" ":(exclude)20261015-120000-abcdef" "$(cat "$L3/round-01-prompt.md")"
assert_contains "prompt still excludes real archived loops" ":(exclude)$(basename "$L1")" "$(cat "$L3/round-01-prompt.md")"
echo '{"loop_id":"other"}' > "$R/20261015-120000-abcdef/state.json"
start "$R" --dir . "task4" > /dev/null; L4=$(pointer "$R")
assert_contains "mismatched state.json is not a loop" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
R="$TMP/nogit2"; mkdir -p "$R"
start "$R" --dir . "task" > /dev/null; L1=$(pointer "$R")
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
start "$R" --dir . "task2" > /dev/null; L2=$(pointer "$R")
touch -t 202001010000 "$L2/task.md"
assert_contains "non-git root loops: old loop dir is not a change" "no changes" "$(reason "$(hook "$R" s1)")"
echo x > "$R/new.txt"
assert_contains "non-git root loops: real change detected" "round-01-coder.md" "$(reason "$(hook "$R" s1)")"
coder "$L2" 1; verdicts approved; review "$R" > /dev/null
assert_contains "non-git prompt excludes old loop dir" "-not -path './$(basename "$L1")/*'" "$(cat "$L2/round-01-prompt.md")"

section "dashboard"
R=$(new_repo r22)
OUT=$(cd "$R" && bash "$S/dashboard.sh")
assert_contains "dashboard with no loops" "0 loop(s)" "$OUT"
assert_file "dashboard written even when empty" "$R/.review-loop/dashboard.html"
start "$R" --usage "task one </script><script>alert(1)</script>" > /dev/null; L1=$(pointer "$R"); echo x > "$R/f"
coder "$L1" 1; verdicts changes_requested approved; review "$R" > /dev/null; coder "$L1" 2; review "$R" > /dev/null
jq '.started_at = "2020-01-01T00:00:00Z"' "$L1/state.json" > "$L1/s.tmp" && mv "$L1/s.tmp" "$L1/state.json"
start "$R" "task two" > /dev/null; L2=$(pointer "$R")
mkdir -p "$R/.review-loop/20261015-120000-abcdef"; echo notaloop > "$R/.review-loop/20261015-120000-abcdef/x"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --out out/dash.html)
assert_contains "dashboard counts loops" "2 loop(s)" "$OUT"
assert_file "dashboard custom out path" "$R/out/dash.html"
H=$(cat "$R/out/dash.html")
assert_contains "dashboard embeds loop ids" "$(basename "$L1")" "$H"
assert_contains "dashboard embeds second loop" "$(basename "$L2")" "$H"
assert_not_contains "dashboard skips non-loop folder" "20261015-120000-abcdef" "$H"
assert_not_contains "script tag in task is escaped" "</script><script>alert" "$H"
J=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/out/dash.html")
assert_eq "embedded data is valid JSON with 2 loops" "2" "$(printf '%s' "$J" | jq '.loops | length')"
assert_eq "embedded rounds carry usage" "1000" "$(printf '%s' "$J" | jq '[.loops[] | select(.state.loop_id == "'"$(basename "$L1")"'")][0].state.rounds[0].reviewer.input_tokens')"
assert_eq "embedded files carry review text" "true" "$(printf '%s' "$J" | jq '[.loops[] | select(.state.loop_id == "'"$(basename "$L1")"'")][0].files[0].review | contains("verdict: changes_requested")')"
assert_eq "newest loop first" "$(basename "$L2")" "$(printf '%s' "$J" | jq -r '.loops[0].state.loop_id')"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --dir .review-loop --dir nowhere)
assert_contains "missing --dir tolerated" "2 loop(s)" "$OUT"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --dir .review-loop --dir ./.review-loop/ --dir "$R/.review-loop")
assert_contains "repeated --dir counted once" "2 loop(s)" "$OUT"
J=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "repeated --dir embeds each loop once" "2" "$(printf '%s' "$J" | jq '.loops | length')"
ln -s "$R/.review-loop" "$R/reviews-link"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --dir .review-loop --dir reviews-link)
assert_contains "symlinked --dir counted once" "2 loop(s)" "$OUT"
J=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "symlinked --dir embeds each loop once" "2" "$(printf '%s' "$J" | jq '.loops | length')"
assert_eq "first path seen is kept" "$R/.review-loop" "$(printf '%s' "$J" | jq -r '.loops[0].dir' | xargs dirname)"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --dir reviews-link)
assert_contains "symlinked dir alone works" "2 loop(s)" "$OUT"
head -c 3000000 /dev/zero | tr '\0' 'a' > "$L2/round-01-coder.md"
OUT=$(cd "$R" && bash "$S/dashboard.sh"); RC=$?
assert_eq "3 MB trail still generates" "0" "$RC"
assert_contains "3 MB trail counted" "2 loop(s)" "$OUT"
J=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "3 MB summary embedded intact" "3000000" "$(printf '%s' "$J" | jq '[.loops[] | select(.state.loop_id == "'"$(basename "$L2")"'")][0].files[0].coder | length')"

section "dashboard config"
R=$(new_repo r23)
mkdir -p "$R/.claude" "$R/archive"
start "$R" "task" > /dev/null; L=$(pointer "$R"); (cd "$R" && bash "$S/cancel.sh" > /dev/null)
cp -R "$L" "$R/archive/"
echo '{"dashboard": {"dirs": [".review-loop", "archive"], "out": "docs/loops.html"}}' > "$R/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$S/dashboard.sh")
assert_contains "config dirs scanned" "2 loop(s) from .review-loop archive" "$OUT"
assert_file "config out used" "$R/docs/loops.html"
OUT=$(cd "$R" && bash "$S/dashboard.sh" --dir archive --out custom.html)
assert_contains "flags override config dirs" "1 loop(s) from archive" "$OUT"
assert_file "flags override config out" "$R/custom.html"
OUT=$(cd "$R" && REVIEW_LOOP_DASHBOARD_OUT=env.html bash "$S/dashboard.sh")
assert_file "env overrides config out" "$R/env.html"
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\necho "OPENED $1" > "%s/opened.txt"\n' "$TMP" > "$TMP/fakebin/open"; chmod +x "$TMP/fakebin/open"
rm -f "$TMP/opened.txt"
(cd "$R" && PATH="$TMP/fakebin:$PATH" REVIEW_LOOP_DASHBOARD_OPEN= bash "$S/dashboard.sh" > /dev/null)
assert_file "open defaults to true from config" "$TMP/opened.txt"
rm -f "$TMP/opened.txt"
(cd "$R" && PATH="$TMP/fakebin:$PATH" REVIEW_LOOP_DASHBOARD_OPEN= bash "$S/dashboard.sh" --no-open > /dev/null)
assert_no_file "--no-open wins" "$TMP/opened.txt"
echo '{"dashboard": {"open": false}}' > "$R/.claude/review-loop.json"
(cd "$R" && PATH="$TMP/fakebin:$PATH" REVIEW_LOOP_DASHBOARD_OPEN= bash "$S/dashboard.sh" > /dev/null)
assert_no_file "config open:false respected" "$TMP/opened.txt"
(cd "$R" && PATH="$TMP/fakebin:$PATH" REVIEW_LOOP_DASHBOARD_OPEN= bash "$S/dashboard.sh" --open > /dev/null)
assert_file "--open overrides config" "$TMP/opened.txt"
rm -f "$TMP/opened.txt"
echo '{"dashboard": {"auto": true, "out": "auto.html"}}' > "$R/.claude/review-loop.json"
rm -f "$R/auto.html"
start "$R" "task2" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"; coder "$L" 1; verdicts approved
(cd "$R" && PATH="$TMP/fakebin:$PATH" REVIEW_LOOP_DASHBOARD_OPEN= bash "$S/review.sh" > /dev/null)
assert_file "auto regenerates on loop end" "$R/auto.html"
assert_no_file "auto never opens a browser" "$TMP/opened.txt"
assert_contains "auto logged" "dashboard regenerated" "$(cat "$L/loop.log")"
rm -f "$R/auto.html"; start "$R" "task3" > /dev/null; (cd "$R" && bash "$S/cancel.sh" > /dev/null)
assert_file "auto regenerates on cancel" "$R/auto.html"
echo '{}' > "$R/.claude/review-loop.json"; rm -f "$R/auto.html"
start "$R" "task4" > /dev/null; (cd "$R" && bash "$S/cancel.sh" > /dev/null)
assert_no_file "auto off by default" "$R/auto.html"
dash_ids() { sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$1" | jq -r '.loops[].state.loop_id'; }
echo '{"dashboard": {"auto": true, "out": "auto.html"}}' > "$R/.claude/review-loop.json"; rm -f "$R/auto.html"
start "$R" --dir custom "task5" > /dev/null; L=$(pointer "$R"); (cd "$R" && bash "$S/cancel.sh" > /dev/null)
assert_contains "auto includes a loop stored with --dir" "$(basename "$L")" "$(dash_ids "$R/auto.html")"
assert_eq "auto still includes the default dir (4 loops) plus custom" "5" "$(dash_ids "$R/auto.html" | grep -c .)"
echo '{"dashboard": {"auto": true, "out": "auto.html", "dirs": ["archive"]}}' > "$R/.claude/review-loop.json"; rm -f "$R/auto.html"
start "$R" --dir custom2 "task6" > /dev/null; L=$(pointer "$R"); (cd "$R" && bash "$S/cancel.sh" > /dev/null)
IDS=$(dash_ids "$R/auto.html")
assert_contains "auto with dashboard.dirs includes the loop's dir" "$(basename "$L")" "$IDS"
assert_eq "auto with dashboard.dirs scans archive too" "2" "$(printf '%s\n' "$IDS" | grep -c .)"
echo '{}' > "$R/.claude/review-loop.json"

section "config command"
C="$S/config.sh"
R=$(new_repo r24); rm -f "$HOME/.claude/review-loop.json"
assert_eq "keys lists every key" "9" "$(bash "$C" keys | grep -c .)"
OUT=$(cd "$R" && bash "$C" show)
assert_contains "show: missing project file" "review-loop.json (missing)" "$OUT"
assert_contains "show: backend row shows env value and default" "codex" "$(printf '%s' "$OUT" | grep '^  backend ' | grep 'fake')"
J=$(cd "$R" && bash "$C" show --json)
assert_eq "show json: scope project" "project" "$(jq -r .scope <<< "$J")"
assert_eq "show json: target is the shared project file" "$R/.review-loop.json" "$(jq -r .target <<< "$J")"
assert_eq "show json: provider detected" "claude" "$(jq -r .provider <<< "$J")"
assert_eq "show json: project shared missing" "false" "$(jq '[.files[] | select(.label == "project shared")][0].exists' <<< "$J")"
assert_eq "show json: four files consulted" "4" "$(jq '.files | length' <<< "$J")"
assert_eq "show json: effective default rounds" "5" "$(jq .effective.max_rounds <<< "$J")"
OUT=$(cd "$R" && bash "$C" set backend=claude model=opus max_rounds=3 usage=yes dashboard.dirs=".review-loop, archive" dashboard.auto=1)
assert_contains "set reports file" "Updated $R/.review-loop.json" "$OUT"
F="$R/.review-loop.json"
assert_eq "set: string" "claude" "$(jq -r .backend "$F")"
assert_eq "set: integer typed" "3" "$(jq .max_rounds "$F")"
assert_eq "set: boolean from yes" "true" "$(jq .usage "$F")"
assert_eq "set: list split and trimmed" '[".review-loop","archive"]' "$(jq -c .dashboard.dirs "$F")"
assert_eq "set: nested boolean from 1" "true" "$(jq .dashboard.auto "$F")"
(cd "$R" && bash "$C" set --user max_rounds=7 dir=reviews > /dev/null)
UF="$HOME/.config/review-loop/config.json"
assert_eq "set --user writes the user shared file" "7" "$(jq .max_rounds "$UF")"
J=$(cd "$R" && bash "$C" show --json)
assert_eq "effective: project beats user" "3" "$(jq .effective.max_rounds <<< "$J")"
assert_eq "effective: user fills gaps" "reviews" "$(jq -r .effective.dir <<< "$J")"
assert_contains "show names the source of each value" "max_rounds       3                      project shared" "$(cd "$R" && bash "$C" show)"
assert_contains "show names the user source" "dir              reviews                user shared" "$(cd "$R" && bash "$C" show)"
BEFORE=$(cat "$F")
for bad in backend=nope max_rounds=0 max_rounds=x max_rounds=9007199254740992 max_rounds=10000000000000000 usage=maybe nokey=1 dir= ; do
  OUT=$(cd "$R" && bash "$C" set "$bad" 2>&1); RC=$?
  assert_eq "set rejects $bad" "1" "$RC"
done
assert_contains "backend error lists real backends only" "(available: claude codex)" "$(cd "$R" && bash "$C" set backend=nope 2>&1)"
assert_contains "too-large integer explains the bound" "too large (max 9007199254740991" "$(cd "$R" && bash "$C" set max_rounds=9007199254740992 2>&1)"
(cd "$R" && bash "$C" set max_rounds=9007199254740991 > /dev/null)
assert_eq "2^53-1 stored exactly" "9007199254740991" "$(jq .max_rounds "$F")"
(cd "$R" && bash "$C" set max_rounds=3 > /dev/null)
assert_eq "invalid set leaves file untouched" "$BEFORE" "$(cat "$F")"
assert_contains "set needs KEY=VALUE" "expected KEY=VALUE" "$(cd "$R" && bash "$C" set backend 2>&1)"
(cd "$R" && bash "$C" unset model dashboard.auto dashboard.dirs > /dev/null)
assert_eq "unset removes key" "null" "$(jq .model "$F")"
assert_eq "unset drops empty dashboard object" "null" "$(jq .dashboard "$F")"
assert_contains "unset unknown key" "unknown key" "$(cd "$R" && bash "$C" unset nope 2>&1)"
(cd "$R" && bash "$C" set max_rounds=3 > /dev/null)
start "$R" "t" > /dev/null; L=$(pointer "$R")
assert_eq "start.sh picks up the written config" "3" "$(st "$L" max_rounds)"
assert_contains "start.sh picks up user dir" "/reviews/" "$L"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)

OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore dry-run: pointer" "/.claude/review-loop.active" "$OUT"
assert_contains "gitignore dry-run: storage dir from user config" "/reviews/" "$OUT"
assert_no_file "dry-run writes nothing" "$R/.gitignore"
printf 'reviews/\n' > "$R/.gitignore"
OUT=$(cd "$R" && bash "$C" gitignore)
assert_contains "gitignore adds the missing lines" "Added 2 line(s)" "$OUT"
assert_contains "gitignore adds the default dashboard file" "/reviews/dashboard.html" "$OUT"
assert_eq "gitignore respects an equivalent existing entry" "1" "$(grep -cE '^/?reviews/?$' "$R/.gitignore")"
assert_contains "gitignore header" "# review-loop" "$(cat "$R/.gitignore")"
assert_contains "gitignore idempotent" "already covers" "$(cd "$R" && bash "$C" gitignore)"
(cd "$R" && bash "$C" set dashboard.out=docs/loops.html dashboard.dirs="archive,$TMP/elsewhere" > /dev/null)
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: dashboard out inside root" "/docs/loops.html" "$OUT"
assert_eq "gitignore: extra dashboard dir without loops adds nothing" "0" "$(printf '%s\n' "$OUT" | grep -c 'archive')"
assert_not_contains "gitignore: dir outside root skipped" "elsewhere" "$OUT"
rm -f "$UF"
mkdir -p "$R/archive"; cp -R "$L" "$R/archive/"; echo unrelated > "$R/archive/README.md"
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: extra dashboard dir offers its loop folder" "/archive/$(basename "$L")/" "$OUT"
assert_eq "gitignore: extra dashboard dir itself never ignored" "0" "$(printf '%s\n' "$OUT" | grep -cxF '  /archive/')"

R=$(new_repo r26); rm -f "$HOME/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" create)
assert_contains "create: makes the file" "Created $R/.review-loop.json" "$OUT"
assert_eq "create: empty object" "{}" "$(jq -c . "$R/.review-loop.json")"
(cd "$R" && bash "$C" set max_rounds=2 > /dev/null)
assert_contains "create: existing file untouched" "already exists" "$(cd "$R" && bash "$C" create)"
assert_eq "create: values preserved" "2" "$(jq .max_rounds "$R/.review-loop.json")"
OUT=$(cd "$R" && bash "$C" create --user)
assert_file "create --user" "$HOME/.config/review-loop/config.json"; rm -f "$HOME/.config/review-loop/config.json"
start "$R" "seed" > /dev/null; L=$(pointer "$R"); (cd "$R" && bash "$S/cancel.sh" > /dev/null)
mkdir -p "$R/my reviews"
(cd "$R" && bash "$C" set dir="my reviews" dashboard.dirs="other dir,arch*ive" > /dev/null)
mkdir -p "$R/other dir" "$R/arch*ive"
cp -R "$L" "$R/other dir/"; cp -R "$L" "$R/arch*ive/"
echo keep > "$R/other dir/notes.md"
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: dir with spaces kept whole" "/my reviews/" "$OUT"
assert_contains "gitignore: default dashboard output under the first dashboard dir" "/other dir/dashboard.html" "$OUT"
assert_contains "gitignore: scan dir with spaces yields its loop folder only" "/other dir/$(basename "$L")/" "$OUT"
assert_eq "gitignore: scan dir line absent" "0" "$(printf '%s\n' "$OUT" | grep -cxF '  /other dir/')"
assert_contains "gitignore: glob characters escaped" "/arch\\*ive/$(basename "$L")/" "$OUT"
assert_eq "gitignore: glob scan dir itself absent" "0" "$(printf '%s\n' "$OUT" | grep -cxF '  /arch\*ive/')"
rm -f "$R/.gitignore"; (cd "$R" && bash "$C" gitignore > /dev/null)
ID=$(basename "$L")
(cd "$R" && git check-ignore -q --no-index "arch*ive/$ID/state.json") && pass "git ignores the escaped glob dir" || fail "git ignores the escaped glob dir" "$(cat "$R/.gitignore")"
(cd "$R" && git check-ignore -q --no-index "archXive/$ID/state.json") && fail "git does not ignore a look-alike dir" "matched" || pass "git does not ignore a look-alike dir"
(cd "$R" && git check-ignore -q --no-index "archive/$ID/state.json") && fail "git does not ignore archive" "matched" || pass "git does not ignore archive"
(cd "$R" && git check-ignore -q --no-index "other dir/$ID/state.json") && pass "git ignores the loop folder in the spaced dir" || fail "git ignores the loop folder in the spaced dir" "$(cat "$R/.gitignore")"
(cd "$R" && git check-ignore -q --no-index "other dir/notes.md") && fail "git keeps unrelated files in a scan dir" "ignored" || pass "git keeps unrelated files in a scan dir"
(cd "$R" && git check-ignore -q --no-index "my reviews/anything") && pass "git ignores the storage dir" || fail "git ignores the storage dir" "$(cat "$R/.gitignore")"
assert_contains "gitignore: escaped entries are idempotent" "already covers" "$(cd "$R" && bash "$C" gitignore)"
mkdir -p "$R/[brackets]"; (cd "$R" && bash "$C" set dir="[brackets]" > /dev/null)
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: brackets escaped" '/\[brackets\]/' "$OUT"
(cd "$R" && bash "$C" gitignore > /dev/null)
(cd "$R" && git check-ignore -q --no-index "[brackets]/x") && pass "git ignores the bracket dir" || fail "git ignores the bracket dir" "$(cat "$R/.gitignore")"
(cd "$R" && git check-ignore -q --no-index "b/x") && fail "git does not treat brackets as a class" "matched" || pass "git does not treat brackets as a class"
(cd "$R" && bash "$C" set dir="my reviews" > /dev/null); rm -f "$R/.gitignore"
(cd "$R" && bash "$C" set dir=.review-loop dashboard.dirs=archive dashboard.out= > /dev/null)
mkdir -p "$R/archive"
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: default dashboard follows first dashboard.dirs entry" "/archive/dashboard.html" "$OUT"
assert_not_contains "gitignore: not the loop dir's dashboard then" "/.review-loop/dashboard.html" "$OUT"
(cd "$R" && bash "$S/dashboard.sh" > /dev/null)
assert_file "gitignore: offered path is where dashboard.sh writes" "$R/archive/dashboard.html"
(cd "$R" && bash "$C" set dir=. dashboard.dirs= > /dev/null); rm -f "$R/.gitignore"
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
GLOB='/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/'
assert_contains "gitignore dir=.: loop-id pattern before any loop exists" "$GLOB" "$OUT"
assert_eq "gitignore dir=.: never ignores the root" "0" "$(printf '%s\n' "$OUT" | grep -cE '^  //?$')"
assert_contains "gitignore dir=.: root dashboard.html" "/dashboard.html" "$OUT"
assert_contains "gitignore dir=.: pointer still listed" "/.claude/review-loop.active" "$OUT"
(cd "$R" && bash "$C" gitignore > /dev/null)
assert_eq "gitignore dir=.: no bare slash entry" "0" "$(grep -cx '/' "$R/.gitignore")"
assert_eq "gitignore dir=.: pattern written unescaped" "1" "$(grep -cxF "$GLOB" "$R/.gitignore")"
start "$R" "t" > /dev/null; L=$(pointer "$R"); (cd "$R" && bash "$S/cancel.sh" > /dev/null)
(cd "$R" && git check-ignore -q --no-index "$(basename "$L")/state.json") && pass "git ignores a loop created after gitignore ran" || fail "git ignores a loop created after gitignore ran" "$(cat "$R/.gitignore")"
(cd "$R" && git check-ignore -q --no-index "docs/x") && fail "git keeps ordinary folders at the root" "ignored" || pass "git keeps ordinary folders at the root"
(cd "$R" && git check-ignore -q --no-index "2026101-120000-abcdef/x") && fail "git keeps near-miss folder names" "ignored" || pass "git keeps near-miss folder names"
assert_contains "gitignore dir=.: idempotent with the pattern" "already covers" "$(cd "$R" && bash "$C" gitignore)"
(cd "$R" && bash "$C" unset dir dashboard.dirs > /dev/null)

R=$(new_repo r25); rm -f "$HOME/.claude/review-loop.json"
OUT=$(cd "$R" && printf 'nope\nclaude\n\nabc\n4\n\nyes\n\n\nno\n\ny\n' | bash "$C" init 2>&1)
F="$R/.review-loop.json"
assert_contains "init: creating message" "Creating $F" "$OUT"
assert_contains "init: shows current value as default" "[fake]:" "$OUT"
assert_contains "init: invalid backend re-asked" "unknown backend 'nope'" "$OUT"
assert_eq "init: backend from second answer" "claude" "$(jq -r .backend "$F")"
assert_contains "init: invalid integer re-asked" "positive integer" "$OUT"
assert_eq "init: integer from retry" "4" "$(jq .max_rounds "$F")"
assert_eq "init: usage yes" "true" "$(jq .usage "$F")"
assert_eq "init: open no" "false" "$(jq .dashboard.open "$F")"
assert_eq "init: Enter leaves inherited keys unwritten" "null" "$(jq .dir "$F")"
assert_contains "init: explains unwritten keys" "only the values you set" "$OUT"
assert_contains "init: gitignore offered last" "Add these to .gitignore?" "$OUT"
assert_contains "init: gitignore written on y" "/.review-loop/" "$(cat "$R/.gitignore")"
assert_contains "init: gitignore includes default dashboard file" "/.review-loop/dashboard.html" "$(cat "$R/.gitignore")"
(cd "$R" && bash "$C" set --user model=opus > /dev/null)
OUT=$(cd "$R" && printf '\n\n9\n\n\n\n\n\n\nn\n' | bash "$C" init 2>&1)
assert_contains "init: updating message" "Updating $F" "$OUT"
assert_contains "init: shows inherited value" "[opus]:" "$OUT"
assert_eq "init: Enter keeps inherited value out of the file" "null" "$(jq .model "$F")"
assert_eq "init: changed value written" "9" "$(jq .max_rounds "$F")"
assert_eq "init: untouched value kept" "claude" "$(jq -r .backend "$F")"
assert_contains "init: gitignore already covered" "already covers" "$OUT"
(cd "$R" && bash "$C" set model=opus dashboard.out=docs/d.html dashboard.dirs=a,b > /dev/null)
OUT=$(cd "$R" && printf '\n-\n\n\n\n-\n-\n\n\nn\n' | bash "$C" init 2>&1)
assert_contains "init: clear hint shown for clearable keys" "(type - to clear)" "$OUT"
assert_eq "init: - clears model" '""' "$(jq -c .model "$F")"
assert_eq "init: - clears dashboard.dirs to []" "[]" "$(jq -c .dashboard.dirs "$F")"
assert_eq "init: - clears dashboard.out" '""' "$(jq -c .dashboard.out "$F")"
assert_eq "init: cleared model overrides the user file" "" "$(cd "$R" && bash "$C" show --json | jq -r .effective.model)"
OUT=$(cd "$R" && printf -- '-\n\n-\n-\n5\n\n\n\n\n\n\nn\n' | bash "$C" init 2>&1)
assert_contains "init: - is invalid for backend" "unknown backend '-'" "$OUT"
assert_contains "init: - is invalid for max_rounds" "positive integer (got '-')" "$OUT"
assert_eq "init: retry after - works" "5" "$(jq .max_rounds "$F")"
OUT=$(cd "$R" && bash "$C" init --user --yes)
assert_contains "init --yes: no prompts" "Wrote $HOME/.config/review-loop/config.json" "$OUT"
assert_eq "init --yes: keeps existing user value" "opus" "$(jq -r .model "$HOME/.config/review-loop/config.json")"
assert_eq "init --yes: existing file untouched for other keys" "null" "$(jq .max_rounds "$HOME/.config/review-loop/config.json")"
rm -f "$HOME/.config/review-loop/config.json"
assert_contains "unknown command" "unknown command" "$(cd "$R" && bash "$C" bogus 2>&1)"

section "providers"
R=$(new_repo r34); rm -rf "$HOME/.config/review-loop" "$HOME/.claude/review-loop.json"
cfg() { (cd "$R" && env "$@" bash "$S/config.sh" show --json | jq -c '{p: .provider, b: .effective.backend, m: .effective.model, r: .effective.max_rounds, d: .effective.dir}'); }
mkdir -p "$HOME/.config/review-loop"
echo '{"max_rounds": 4, "providers": {"claude": {"max_rounds": 6}, "codex": {"model": "o-reviewer"}}}' > "$HOME/.config/review-loop/config.json"
assert_eq "user shared top-level applies to any provider" '{"p":null,"b":"fake","m":"","r":4,"d":".review-loop"}' "$(cfg REVIEW_LOOP_PROVIDER=none)"
assert_eq "providers.claude section applies under claude" '{"p":"claude","b":"fake","m":"","r":6,"d":".review-loop"}' "$(cfg REVIEW_LOOP_PROVIDER=claude)"
assert_eq "providers.codex section applies under codex" '{"p":"codex","b":"fake","m":"o-reviewer","r":4,"d":".review-loop"}' "$(cfg REVIEW_LOOP_PROVIDER=codex)"
assert_eq "provider names are case-insensitive" '"claude"' "$(cd "$R" && REVIEW_LOOP_PROVIDER=Claude bash "$S/config.sh" show --json | jq .provider)"
assert_eq "invalid provider name counts as unset (claude)" '"claude"' "$(cd "$R" && REVIEW_LOOP_PROVIDER='../x' bash "$S/config.sh" show --json | jq .provider)"
assert_eq "auto-detect claude from CLAUDECODE" '"claude"' "$(cd "$R" && env -u REVIEW_LOOP_PROVIDER CLAUDECODE=1 bash "$S/config.sh" show --json | jq .provider)"
assert_eq "plain shell defaults to claude" '"claude"' "$(cd "$R" && env -u REVIEW_LOOP_PROVIDER -u CLAUDECODE bash "$S/config.sh" show --json | jq .provider)"
assert_eq "plain shell still reads legacy ~/.claude section values" '6' "$(cd "$R" && env -u REVIEW_LOOP_PROVIDER -u CLAUDECODE bash "$S/config.sh" show --json | jq .effective.max_rounds)"
echo '{"max_rounds": 8}' > "$R/.review-loop.json"
assert_eq "project shared beats user shared and its section" '{"p":"claude","b":"fake","m":"","r":8,"d":".review-loop"}' "$(cfg REVIEW_LOOP_PROVIDER=claude)"
mkdir -p "$HOME/.claude"; echo '{"dir": "user-claude"}' > "$HOME/.claude/review-loop.json"
assert_eq "user provider file beats user shared, below project shared" '{"p":"claude","b":"fake","m":"","r":8,"d":"user-claude"}' "$(cfg REVIEW_LOOP_PROVIDER=claude)"
mkdir -p "$R/.claude" "$R/.codex"; echo '{"max_rounds": 9}' > "$R/.claude/review-loop.json"; echo '{"max_rounds": 2, "dir": "codex-loops"}' > "$R/.codex/review-loop.json"
assert_eq "project provider file wins under claude" '{"p":"claude","b":"fake","m":"","r":9,"d":"user-claude"}' "$(cfg REVIEW_LOOP_PROVIDER=claude)"
assert_eq "project provider file wins under codex" '{"p":"codex","b":"fake","m":"o-reviewer","r":2,"d":"codex-loops"}' "$(cfg REVIEW_LOOP_PROVIDER=codex)"
assert_eq "provider files ignored with provider none" '{"p":null,"b":"fake","m":"","r":8,"d":".review-loop"}' "$(cfg REVIEW_LOOP_PROVIDER=none)"
assert_eq "env still beats every file" '{"p":"claude","b":"fake","m":"","r":1,"d":"user-claude"}' "$(cfg REVIEW_LOOP_PROVIDER=claude REVIEW_LOOP_MAX_ROUNDS=1)"
SHOW=$(cd "$R" && REVIEW_LOOP_PROVIDER=codex bash "$S/config.sh" show)
assert_contains "show: set-by names the provider file" "max_rounds       2                      project codex" "$SHOW"
assert_contains "show: set-by names the section" "model            o-reviewer             user shared (providers.codex)" "$SHOW"
assert_contains "show: set-by names env" "backend          fake                   env REVIEW_LOOP_BACKEND" "$SHOW"
assert_contains "show lists the codex files" "project codex    $R/.codex/review-loop.json (exists)" "$SHOW"
start "$R" "t" > /dev/null; L=$(pointer "$R")
assert_eq "start.sh resolves through the provider files" "9" "$(st "$L" max_rounds)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
L=$(cd "$R" && REVIEW_LOOP_PROVIDER=codex bash "$S/start.sh" "t" > /dev/null && pointer "$R")
assert_contains "start.sh under codex uses the codex dir" "/codex-loops/" "$L"
(cd "$R" && REVIEW_LOOP_PROVIDER=codex bash "$S/cancel.sh" > /dev/null)
# writing: section vs provider file vs shared
rm -f "$R/.review-loop.json" "$R/.claude/review-loop.json" "$R/.codex/review-loop.json" "$HOME/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" set --provider codex backend=claude max_rounds=3)
assert_contains "set --provider reports the section" "Updated $R/.review-loop.json (providers.codex)" "$OUT"
assert_eq "set --provider writes the section" '{"backend":"claude","max_rounds":3}' "$(jq -c .providers.codex "$R/.review-loop.json")"
(cd "$R" && bash "$C" set max_rounds=7 > /dev/null)
assert_eq "set keeps the section intact" '3' "$(jq .providers.codex.max_rounds "$R/.review-loop.json")"
assert_eq "set writes top-level" '7' "$(jq .max_rounds "$R/.review-loop.json")"
OUT=$(cd "$R" && bash "$C" set --provider model=opus)
assert_contains "set --provider defaults to the running provider" "(providers.claude)" "$OUT"
assert_eq "set --provider claude section written" '"opus"' "$(jq .providers.claude.model "$R/.review-loop.json")"
OUT=$(cd "$R" && bash "$C" set --provider-file codex dir=codex-loops)
assert_contains "set --provider-file reports the file" "Updated $R/.codex/review-loop.json" "$OUT"
assert_eq "set --provider-file writes plain keys" '{"dir":"codex-loops"}' "$(jq -c . "$R/.codex/review-loop.json")"
(cd "$R" && bash "$C" set --provider-file model=sonnet > /dev/null)
assert_eq "set --provider-file defaults to the running provider" '"sonnet"' "$(jq .model "$R/.claude/review-loop.json")"
(cd "$R" && bash "$C" set --user --provider-file codex max_rounds=2 > /dev/null)
assert_eq "set --user --provider-file writes ~/.codex" '2' "$(jq .max_rounds "$HOME/.codex/review-loop.json")"
(cd "$R" && bash "$C" set --user --provider codex usage=true > /dev/null)
assert_eq "set --user --provider writes the user shared section" 'true' "$(jq .providers.codex.usage "$HOME/.config/review-loop/config.json")"
assert_eq "resolution under codex combines all of it (env backend, user section model, project section rounds, provider file dir)" '{"p":"codex","b":"fake","m":"o-reviewer","r":3,"d":"codex-loops"}' "$(cfg REVIEW_LOOP_PROVIDER=codex)"
assert_eq "project section backend shows without the env override" '"claude"' "$(cd "$R" && env -u REVIEW_LOOP_BACKEND REVIEW_LOOP_PROVIDER=codex bash "$S/config.sh" show --json | jq .effective.backend)"
OUT=$(cd "$R" && bash "$C" unset --provider codex backend max_rounds)
assert_eq "unset --provider prunes the emptied section" 'null' "$(jq -c .providers.codex "$R/.review-loop.json")"
assert_eq "unset --provider leaves other sections" '"opus"' "$(jq .providers.claude.model "$R/.review-loop.json")"
assert_contains "unset reports what each key resolves to now" "note: max_rounds now resolves to" "$OUT"
(cd "$R" && bash "$C" create --provider codex > /dev/null)
assert_contains "create --provider on an existing section" "already exists" "$(cd "$R" && bash "$C" create --provider codex)"
OUT=$(cd "$R" && bash "$C" create --provider opencode)
assert_contains "create --provider adds a new section" "Created $R/.review-loop.json (providers.opencode)" "$OUT"
assert_eq "create --provider section is empty" '{}' "$(jq -c .providers.opencode "$R/.review-loop.json")"
assert_contains "create --provider twice" "already exists" "$(cd "$R" && bash "$C" create --provider opencode)"
assert_contains "create --provider-file" "Created $R/.opencode/review-loop.json" "$(cd "$R" && bash "$C" create --provider-file opencode)"
assert_contains "provider none with no name is an error" "no provider given" "$(cd "$R" && env -u CLAUDECODE REVIEW_LOOP_PROVIDER=none bash "$C" set --provider max_rounds=1 2>&1 || true)"
assert_contains "unset --provider KEY unsets for the running provider" "(providers.claude)" "$(cd "$R" && bash "$C" unset --provider model)"
assert_eq "unset --provider KEY removed the key" 'null' "$(jq .providers.claude.model "$R/.review-loop.json")"
(cd "$R" && bash "$C" set --provider Codex usage=false > /dev/null)
assert_eq "explicit provider names are lower-cased" 'false' "$(jq .providers.codex.usage "$R/.review-loop.json")"
assert_eq "no mixed-case section is created" 'null' "$(jq '.providers.Codex' "$R/.review-loop.json")"
(cd "$R" && bash "$C" set --provider-file=CODEX dir=codex-loops > /dev/null)
assert_file "explicit provider-file names are lower-cased" "$R/.codex/review-loop.json"
assert_eq "provider dir stored lower-cased" "1" "$(ls -a "$R" | grep -c '^\.codex$')"
assert_eq "no mixed-case provider dir" "0" "$(ls -a "$R" | grep -c '^\.CODEX$')"
(cd "$R" && bash "$C" set --provider codex max_rounds=3 > /dev/null)
J=$(cd "$R" && bash "$C" show --provider codex --json)
assert_eq "show --provider reports that provider" '"codex"' "$(jq .provider <<< "$J")"
assert_eq "show --provider resolves that provider's values from a claude session" '3' "$(jq .effective.max_rounds <<< "$J")"
assert_eq "show --provider lists that provider's files" '"project codex"' "$(jq '[.files[] | select(.kind == "provider")][1].label' <<< "$J")"
assert_contains "show --provider says it was selected" "provider: codex (selected with --provider)" "$(cd "$R" && bash "$C" show --provider codex)"
OUT=$(cd "$R" && printf '








n
' | bash "$C" init --provider codex 2>&1)
assert_contains "init --provider shows that provider's current value" "[3]:" "$OUT"
assert_contains "init --provider labels the provider" "provider: codex" "$OUT"
(cd "$R" && bash "$C" unset --provider codex max_rounds > /dev/null)
assert_contains "none rejected as a section name" "'none' is not a provider" "$(cd "$R" && bash "$C" set --provider none max_rounds=1 2>&1 || true)"
assert_contains "none rejected as a provider file" "'none' is not a provider" "$(cd "$R" && bash "$C" set --provider-file=None max_rounds=1 2>&1 || true)"
assert_eq "none never creates a section" 'null' "$(jq '.providers.none' "$R/.review-loop.json")"
assert_no_file "none never creates a provider dir" "$R/.none/review-loop.json"
assert_contains "start.sh help shows the new precedence" "~/.config/review-loop/config.json" "$(bash "$S/start.sh" --help)"
J=$(cd "$R" && bash "$C" show --provider --json)
assert_eq "--provider followed by a flag: the flag is not a name" '"claude"' "$(jq .provider <<< "$J" 2>/dev/null)"
assert_eq "--provider --json still produces JSON" '"section"' "$(jq .mode <<< "$J" 2>/dev/null)"
OUT=$(cd "$R" && bash "$C" set --provider --user max_rounds=3 2>&1)
assert_contains "--provider --user writes the user shared section" "Updated $HOME/.config/review-loop/config.json (providers.claude)" "$OUT"
assert_eq "no providers.--user section" 'null' "$(jq '.providers["--user"]' "$R/.review-loop.json")"
assert_eq "user shared section holds the value" '3' "$(jq .providers.claude.max_rounds "$HOME/.config/review-loop/config.json")"
rm -f "$HOME/.config/review-loop/config.json"
J=$(cd "$R" && bash "$C" show --provider-file --json)
assert_eq "--provider-file --json: flag not taken as a name" '"file"' "$(jq .mode <<< "$J" 2>/dev/null)"
assert_contains "--provider-file --user targets the user provider file" "$HOME/.claude/review-loop.json" "$(cd "$R" && bash "$C" show --provider-file --user --json | jq -r .target)"
assert_contains "explicit name starting with - rejected" "invalid provider name '--json'" "$(cd "$R" && bash "$C" set --provider=--json max_rounds=1 2>&1 || true)"
assert_contains "explicit provider-file name starting with - rejected" "invalid provider name '-x'" "$(cd "$R" && bash "$C" set --provider-file=-x max_rounds=1 2>&1 || true)"
assert_eq "REVIEW_LOOP_PROVIDER starting with - counts as unset" '"claude"' "$(cd "$R" && REVIEW_LOOP_PROVIDER=--x bash "$S/config.sh" show --json | jq .provider)"
assert_eq "names may contain - after the first character" '"open-code"' "$(cd "$R" && REVIEW_LOOP_PROVIDER=open-code bash "$S/config.sh" show --json | jq .provider)"
NL=$'-x\nclaude'
OUT=$(cd "$R" && bash "$C" show --provider "$NL" --json 2>&1); RC=$?
assert_eq "positional multi-line value starting with - is not a name and fails" "1" "$RC"
assert_contains "it is reported as a stray argument" "unexpected argument" "$OUT"
assert_eq "no section from the multi-line positional value" 'null' "$(jq --arg k "$NL" '.providers[$k]' "$R/.review-loop.json")"
assert_contains "explicit multi-line name rejected" "invalid provider name" "$(cd "$R" && bash "$C" set "--provider=$NL" max_rounds=1 2>&1 || true)"
assert_contains "explicit multi-line provider-file name rejected" "invalid provider name" "$(cd "$R" && bash "$C" set "--provider-file=$NL" max_rounds=1 2>&1 || true)"
assert_eq "no section from a multi-line name" 'null' "$(jq --arg k "$NL" '.providers[$k]' "$R/.review-loop.json")"
assert_eq "multi-line REVIEW_LOOP_PROVIDER counts as unset" '"claude"' "$(cd "$R" && REVIEW_LOOP_PROVIDER="$NL" bash "$S/config.sh" show --json | jq .provider)"
assert_eq "multi-line valid-looking tail is still rejected" '"claude"' "$(cd "$R" && REVIEW_LOOP_PROVIDER=$'codex\nx' bash "$S/config.sh" show --json | jq .provider)"
valid() { (cd "$S" && bash -c '. ./lib.sh; rl_valid_provider_name "$1" && echo yes || echo no' _ "$1"); }
assert_eq "helper: plain name" "yes" "$(valid codex)"
assert_eq "helper: leading dash" "no" "$(valid -x)"
assert_eq "helper: newline" "no" "$(valid $'a\nb')"
assert_eq "helper: empty" "no" "$(valid '')"
assert_eq "helper: uppercase is not valid before lower-casing" "no" "$(valid Codex)"
BEFORE=$(jq -c '.providers.claude' "$R/.review-loop.json")
OUT=$(cd "$R" && bash "$C" create --provider open.code 2>&1); RC=$?
assert_eq "invalid positional name fails" "1" "$RC"
assert_contains "invalid positional name explains" "invalid provider name 'open.code'" "$OUT"
assert_eq "invalid positional name leaves providers.claude untouched" "$BEFORE" "$(jq -c '.providers.claude' "$R/.review-loop.json")"
assert_eq "invalid positional name writes no section" 'null' "$(jq '.providers["open.code"]' "$R/.review-loop.json" 2>/dev/null)"
assert_contains "invalid positional name with set fails" "invalid provider name 'Open.Code'" "$(cd "$R" && bash "$C" set --provider Open.Code max_rounds=1 2>&1 || true)"
assert_contains "invalid positional provider-file name fails" "invalid provider name 'a b'" "$(cd "$R" && bash "$C" show --provider-file 'a b' 2>&1 || true)"
assert_contains "--provider then KEY=VALUE still works" "(providers.claude)" "$(cd "$R" && bash "$C" set --provider max_rounds=2)"
assert_contains "--provider then a config key still works for unset" "(providers.claude)" "$(cd "$R" && bash "$C" unset --provider max_rounds)"
assert_contains "show rejects stray arguments" "unexpected argument 'extra'" "$(cd "$R" && bash "$C" show extra 2>&1 || true)"
assert_contains "create rejects stray arguments" "unexpected argument" "$(cd "$R" && bash "$C" create --project stray 2>&1 || true)"
assert_contains "gitignore rejects stray arguments" "unexpected argument" "$(cd "$R" && bash "$C" gitignore now 2>&1 || true)"
assert_contains "bad provider name rejected" "invalid provider name" "$(cd "$R" && bash "$C" set --provider='bad name' max_rounds=1 2>&1 || true)"
OUT=$(cd "$R" && printf '\n\n4\n\n\n\n\n\n\nn\n' | bash "$C" init --provider codex 2>&1)
assert_contains "init --provider writes into the section" "Wrote $R/.review-loop.json (providers.codex)" "$OUT"
assert_eq "init --provider value in section" '4' "$(jq .providers.codex.max_rounds "$R/.review-loop.json")"
rm -rf "$HOME/.config/review-loop" "$HOME/.claude/review-loop.json" "$HOME/.codex"
# legacy project with only .claude/review-loop.json: default writes go there, not to a masked shared file
R=$(new_repo r35); mkdir -p "$R/.claude"; echo '{"max_rounds": 2}' > "$R/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" set max_rounds=4 2>&1)
assert_contains "legacy project: writes go to the existing provider file" "Updated $R/.claude/review-loop.json" "$OUT"
assert_contains "legacy project: explains the choice" "note: using the existing $R/.claude/review-loop.json" "$OUT"
assert_eq "legacy project: the write takes effect" "4" "$(cd "$R" && bash "$C" show --json | jq .effective.max_rounds)"
assert_no_file "legacy project: no shared file created" "$R/.review-loop.json"
assert_contains "legacy project: show says where writes go" "writes go to: $R/.claude/review-loop.json" "$(cd "$R" && bash "$C" show)"
J=$(cd "$R" && bash "$C" show --json)
assert_eq "show json: mode switched to file" '"file"' "$(jq .mode <<< "$J")"
assert_contains "show json: note present" "using the existing" "$(jq -r .note <<< "$J")"
OUT=$(cd "$R" && bash "$C" set --project max_rounds=6 2>&1)
assert_contains "explicit --project writes the shared file" "Updated $R/.review-loop.json" "$OUT"
assert_contains "explicit --project warns about the mask" "warning: max_rounds=6 was written to $R/.review-loop.json but the effective value is 4, set by project claude" "$OUT"
assert_eq "masked value stays masked" "4" "$(cd "$R" && bash "$C" show --json | jq .effective.max_rounds)"
OUT=$(cd "$R" && bash "$C" set --project dir=loops 2>&1)
assert_not_contains "unmasked key gets no warning" "warning:" "$OUT"
OUT=$(cd "$R" && bash "$C" set max_rounds=7 2>&1)
assert_contains "both files present: default is the shared file" "Updated $R/.review-loop.json" "$OUT"
assert_contains "both files present: masked write warns" "effective value is 4, set by project claude" "$OUT"
OUT=$(cd "$R" && printf '\n\n8\n\n\n\n\n\n\nn\n' | bash "$C" init 2>&1)
assert_contains "init warns about masked values too" "warning: max_rounds=8" "$OUT"
rm -f "$R/.review-loop.json"
mkdir -p "$HOME/.claude"; echo '{"model": "legacy"}' > "$HOME/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" set --user model=opus 2>&1)
assert_contains "--user always writes the shared user file" "Updated $HOME/.config/review-loop/config.json" "$OUT"
assert_contains "--user write masked by ~/.claude warns" "effective value is legacy, set by user claude" "$OUT"
assert_eq "--user write landed in the shared user file" '"opus"' "$(jq .model "$HOME/.config/review-loop/config.json")"
rm -f "$HOME/.config/review-loop/config.json"
OUT=$(cd "$R" && bash "$C" create --user)
assert_file "create --user makes the shared user file even with ~/.claude present" "$HOME/.config/review-loop/config.json"
assert_contains "create --user reports the shared user file" "Created $HOME/.config/review-loop/config.json" "$OUT"
rm -f "$HOME/.config/review-loop/config.json" "$HOME/.claude/review-loop.json"
# init warns only about keys it wrote
mkdir -p "$R/.claude"; echo '{"max_rounds": 2, "model": "m"}' > "$R/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" init --project --yes 2>&1)
assert_not_contains "init --yes writes nothing, so no masking warnings" "warning:" "$OUT"
OUT=$(cd "$R" && printf '\n\n9\n\n\n\n\n\n\nn\n' | bash "$C" init --project 2>&1)
assert_contains "init warns for the key it wrote" "warning: max_rounds=9" "$OUT"
assert_eq "init warns only once" "1" "$(printf '%s\n' "$OUT" | grep -c '^warning:')"
assert_not_contains "init does not warn for keys it did not write" "warning: model=" "$OUT"
rm -f "$R/.claude/review-loop.json" "$R/.review-loop.json"
J=$(cd "$R" && bash "$C" show --provider codex --json)
assert_eq "section_exists false for a missing section" "false" "$(jq .section_exists <<< "$J")"
(cd "$R" && bash "$C" create --provider codex > /dev/null)
assert_eq "section_exists true after create" "true" "$(cd "$R" && bash "$C" show --provider codex --json | jq .section_exists)"
assert_eq "section_exists for a shared target mirrors target_exists" "true" "$(cd "$R" && bash "$C" show --project --json | jq '.section_exists == .target_exists')"
rm -f "$R/.review-loop.json"
assert_eq "section_exists false for a missing shared file" "false" "$(cd "$R" && bash "$C" show --project --json | jq .section_exists)"

section "round timings"
R=$(new_repo r27)
start "$R" --max-rounds 3 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
assert_eq "start sets round_started_epoch" "number" "$(jq -r '.round_started_epoch | type' "$L/state.json")"
assert_eq "start sets paused_s" "0" "$(jq .paused_s "$L/state.json")"
NOW=$(date +%s)
jq --argjson e "$(( NOW - 100 ))" '.round_started_epoch = $e' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
assert_contains "status shows coder time so far" "coder time:  1m 4" "$(cd "$R" && bash "$S/status.sh")"
coder "$L" 1; verdicts changes_requested approved
OUT=$(review "$R")
assert_contains "review output shows coder time" "coder worked 1m 4" "$OUT"
assert_contains "verdict line shows both durations" "coder 1m 4" "$OUT"
CD=$(jq '.rounds[0].coder_duration_s' "$L/state.json")
[ "$CD" -ge 100 ] && [ "$CD" -le 110 ] && pass "coder_duration_s recorded (~100s)" || fail "coder_duration_s recorded (~100s)" "got $CD"
assert_eq "review duration still recorded" "number" "$(jq -r '.rounds[0].duration_s | type' "$L/state.json")"
RS=$(jq .round_started_epoch "$L/state.json")
[ "$RS" -ge "$NOW" ] && pass "advance resets round start" || fail "advance resets round start" "got $RS"
assert_eq "advance resets paused_s" "0" "$(jq .paused_s "$L/state.json")"
assert_contains "status lists recorded rounds" "round 1: changes_requested, 1 blocking, coder 1m 4" "$(cd "$R" && bash "$S/status.sh")"
H=$(hook "$R" s1 "Which database? REVIEW-LOOP: PAUSE")
assert_eq "pause records paused_at_epoch" "number" "$(jq -r '.paused_at_epoch | type' "$L/state.json")"
jq --argjson e "$(( $(date +%s) - 50 ))" '.paused_at_epoch = $e' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
assert_contains "status counts pause while paused" "(paused)" "$(cd "$R" && bash "$S/status.sh")"
resume() { jq -n --arg c "$1" --arg s "$2" '{cwd: $c, session_id: $s, prompt: "go on"}' | (cd "$1" && bash "$S/resume-hook.sh"); }
OUT=$(resume "$R" other-session)
assert_eq "resume hook: foreign session ignored" "{}" "$OUT"
assert_eq "resume hook: foreign session leaves pause" "number" "$(jq -r '.paused_at_epoch | type' "$L/state.json")"
OUT=$(resume "$R" s1)
assert_eq "resume hook prints JSON" "{}" "$OUT"
PS=$(jq .paused_s "$L/state.json")
[ "$PS" -ge 50 ] && [ "$PS" -le 60 ] && pass "user reply ends the pause (~50s)" || fail "user reply ends the pause (~50s)" "got $PS"
assert_eq "user reply clears paused_at_epoch" "null" "$(jq .paused_at_epoch "$L/state.json")"
assert_eq "user reply sets phase coding" "coding" "$(st "$L" phase)"
assert_contains "resume logged as user reply" "resumed from pause (user reply)" "$(cat "$L/loop.log")"
assert_eq "resume hook idempotent" "{}" "$(resume "$R" s1)"
assert_eq "resume hook: paused_s unchanged when not paused" "$PS" "$(jq .paused_s "$L/state.json")"
H=$(hook "$R" s1 "continuing")
assert_eq "stop hook after resume just blocks" "block" "$(decision "$H")"
assert_eq "stop hook does not double count" "$PS" "$(jq .paused_s "$L/state.json")"
jq --argjson e "$(( $(date +%s) - 200 ))" '.round_started_epoch = $e' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
coder "$L" 2; review "$R" > /dev/null
CD=$(jq '.rounds[1].coder_duration_s' "$L/state.json")
[ "$CD" -ge 140 ] && [ "$CD" -le 160 ] && pass "pause excluded from coder time (~150s)" || fail "pause excluded from coder time (~150s)" "got $CD"
SUM=$(cat "$L/summary.md")
assert_contains "summary lists rounds with both durations" "- round 1: changes_requested, 1 blocking, coder 1m 4" "$SUM"
assert_contains "summary round 2" "- round 2: approved, 0 blocking, coder 2m" "$SUM"
# resumed work before the reviewer runs, with the resume hook
R=$(new_repo r29)
start "$R" --max-rounds 3 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
NOW=$(date +%s)
jq --argjson e "$(( NOW - 300 ))" '.round_started_epoch = $e' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
hook "$R" s1 "Need input. REVIEW-LOOP: PAUSE" > /dev/null
jq --argjson e "$(( NOW - 200 ))" '.paused_at_epoch = $e' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
resume "$R" s1 > /dev/null
jq '.paused_s = 100' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"   # pause lasted 100s, then 100s of work
coder "$L" 1; verdicts changes_requested approved
OUT=$(review "$R")
CD=$(jq '.rounds[0].coder_duration_s' "$L/state.json")
[ "$CD" -ge 195 ] && [ "$CD" -le 210 ] && pass "work after the reply counts as coder time (~200s)" || fail "work after the reply counts as coder time (~200s)" "got $CD"
assert_not_contains "no underestimate warning with the hook" "underestimated" "$OUT"
# same scenario, but a Stop happens after the reply and before review.sh (no resume hook):
# the fallback ends the pause late; the round must be flagged, not silently undercounted
hook "$R" s1 "Another question. REVIEW-LOOP: PAUSE" > /dev/null
NOW=$(date +%s)
jq --argjson e "$(( NOW - 300 ))" --argjson p "$(( NOW - 200 ))" '.round_started_epoch = $e | .paused_at_epoch = $p | .phase = "paused"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
H=$(hook "$R" s1 "did 100s of work after the reply")
assert_eq "stop-hook fallback resumes" "coding" "$(st "$L" phase)"
assert_eq "stop-hook fallback flags the round" "true" "$(jq .coder_time_underestimated "$L/state.json")"
assert_contains "stop-hook fallback logged as late" "late: coder time underestimated" "$(cat "$L/loop.log")"
assert_contains "status shows at least" "coder time:  at least" "$(cd "$R" && bash "$S/status.sh")"
coder "$L" 2; verdicts changes_requested approved
OUT=$(review "$R")
assert_contains "review warns after a stop-hook fallback" "coder time is underestimated" "$OUT"
assert_contains "review output marks the lower bound" "coder worked at least" "$OUT"
assert_eq "round record carries the flag" "true" "$(jq '.rounds[1].coder_time_underestimated' "$L/state.json")"
assert_eq "advance clears the flag" "null" "$(jq .coder_time_underestimated "$L/state.json")"
assert_contains "status rounds list marks it" "coder at least" "$(cd "$R" && bash "$S/status.sh")"
# with the resume hook the round is exact and unflagged
hook "$R" s1 "Third question. REVIEW-LOOP: PAUSE" > /dev/null
resume "$R" s1 > /dev/null
hook "$R" s1 "working" > /dev/null
assert_eq "resume hook keeps the round exact" "null" "$(jq .coder_time_underestimated "$L/state.json")"
coder "$L" 3; OUT=$(review "$R")
assert_not_contains "no warning with the resume hook" "underestimated" "$OUT"
assert_eq "exact round unflagged in the record" "false" "$(jq '.rounds[2].coder_time_underestimated' "$L/state.json")"
assert_contains "summary marks the late round" "- round 2: changes_requested, 2 blocking, coder at least" "$(cat "$L/summary.md")"
assert_contains "summary keeps exact rounds plain" "- round 3: approved, 0 blocking, coder " "$(cat "$L/summary.md")"
assert_not_contains "summary exact round not marked" "- round 3: approved, 0 blocking, coder at least" "$(cat "$L/summary.md")"
R=$(new_repo r33)
start "$R" --max-rounds 3 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
# same scenario without the resume hook: review.sh falls back and warns
hook "$R" s1 "More input. REVIEW-LOOP: PAUSE" > /dev/null
NOW=$(date +%s)
jq --argjson e "$(( NOW - 300 ))" --argjson p "$(( NOW - 200 ))" '.round_started_epoch = $e | .paused_at_epoch = $p | .phase = "paused"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
coder "$L" 1; verdicts approved
OUT=$(review "$R")
assert_contains "fallback warns about underestimate" "coder time is underestimated" "$OUT"
CD=$(jq '.rounds[0].coder_duration_s' "$L/state.json")
[ "$CD" -ge 95 ] && [ "$CD" -le 110 ] && pass "fallback ends the pause at review time (~100s)" || fail "fallback ends the pause at review time (~100s)" "got $CD"
assert_eq "fallback clears paused_at_epoch" "null" "$(jq .paused_at_epoch "$L/state.json")"
assert_eq "review.sh fallback flags the round too" "true" "$(jq '.rounds[0].coder_time_underestimated' "$L/state.json")"
# failed reviewer attempts are not coder time (deterministic clock, no sleep)
R=$(new_repo r31)
CLOCK="$TMP/clock"; echo 1000 > "$CLOCK"; export REVIEW_LOOP_FAKE_CLOCK="$CLOCK"
start "$R" --max-rounds 3 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
assert_eq "fake clock drives round start" "1000" "$(jq .round_started_epoch "$L/state.json")"
assert_eq "failed_review_s starts at 0" "0" "$(jq .failed_review_s "$L/state.json")"
echo 1100 > "$CLOCK"; coder "$L" 1
verdicts fail garbage approved
REVIEW_LOOP_FAKE_TAKES=60 review "$R" > /dev/null
assert_eq "failed backend run recorded" "60" "$(jq .failed_review_s "$L/state.json")"
assert_eq "clock advanced by the attempt" "1160" "$(cat "$CLOCK")"
REVIEW_LOOP_FAKE_TAKES=40 review "$R" > /dev/null
assert_eq "invalid review attempt also recorded" "100" "$(jq .failed_review_s "$L/state.json")"
echo 1300 > "$CLOCK"   # 100s more coder work fixing the cause
assert_contains "status excludes failed attempts" "coder time:  3m 20s" "$(cd "$R" && bash "$S/status.sh")"
OUT=$(REVIEW_LOOP_FAKE_TAKES=25 review "$R")
assert_eq "coder time excludes failed attempts (300-100)" "200" "$(jq '.rounds[0].coder_duration_s' "$L/state.json")"
assert_eq "review duration is the successful run" "25" "$(jq '.rounds[0].duration_s' "$L/state.json")"
assert_contains "output shows coder 3m 20s" "coder 3m 20s" "$OUT"
assert_contains "failed attempt logged" "failed attempt took 60s (excluded from coder time)" "$(cat "$L/loop.log")"
unset REVIEW_LOOP_FAKE_CLOCK
R=$(new_repo r32)
echo 5000 > "$CLOCK"; export REVIEW_LOOP_FAKE_CLOCK="$CLOCK"
start "$R" --max-rounds 3 "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
coder "$L" 1; verdicts changes_requested approved
echo 5050 > "$CLOCK"; REVIEW_LOOP_FAKE_TAKES=10 review "$R" > /dev/null
assert_eq "advance resets failed_review_s" "0" "$(jq .failed_review_s "$L/state.json")"
assert_eq "advance stamps the new round start from the clock" "5060" "$(jq .round_started_epoch "$L/state.json")"
echo 5100 > "$CLOCK"; coder "$L" 2; REVIEW_LOOP_FAKE_TAKES=5 review "$R" > /dev/null
assert_eq "round 2 coder time from its own start" "40" "$(jq '.rounds[1].coder_duration_s' "$L/state.json")"
unset REVIEW_LOOP_FAKE_CLOCK
# older loop without coder durations: nothing shifts columns
R=$(new_repo r30)
start "$R" --usage "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
coder "$L" 1; verdicts changes_requested approved; review "$R" > /dev/null
jq '.rounds |= map(del(.coder_duration_s)) | del(.round_started_epoch)' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
RD=$(jq '.rounds[0].duration_s' "$L/state.json")
assert_contains "status: old round keeps review time in its column" "round 1: changes_requested, 1 blocking, coder -, review ${RD}s" "$(cd "$R" && bash "$S/status.sh")"
assert_contains "status: unknown coder time so far" "coder time:  -" "$(cd "$R" && bash "$S/status.sh")"
coder "$L" 2; review "$R" > /dev/null
jq '.rounds |= map(del(.coder_duration_s))' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
(cd "$S" && bash -c '. ./lib.sh; rl_finalize "$1" "$2" approved done' _ "$L" "$R")
assert_contains "summary: old round columns intact" "- round 1: changes_requested, 1 blocking, coder -, review ${RD}s" "$(cat "$L/summary.md")"
assert_contains "usage.md: old reviewer row keeps its duration" "| round 1 reviewer | fake-model | 1000 | 500 | 100 | 200 | 50 | 0.01 | 3 | ${RD} |" "$(cat "$L/usage.md")"
R=$(new_repo r28)
start "$R" --usage "task" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
jq '.round_started_epoch = (.round_started_epoch - 30)' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
jq '.started_at = "2020-01-01T00:00:00Z"' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
coder "$L" 1; verdicts approved
H=$(jq -n --arg c "$R" --arg t "$TR" '{cwd: $c, session_id: "s1", transcript_path: $t}' | (cd "$R" && bash "$S/stop-hook.sh"))
review "$R" > /dev/null
assert_contains "usage.md coder row carries its duration" "| round 1 coder | claude-x,claude-y | 16 | 1500 | 20 | 175 | 30 | - | 3 | 3" "$(cat "$L/usage.md")"
OUT=$(cd "$R" && bash "$S/dashboard.sh")
J=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "dashboard data carries coder_duration_s" "number" "$(printf '%s' "$J" | jq -r '.loops[0].state.rounds[0].coder_duration_s | type')"
jq 'del(.round_started_epoch)' "$L/state.json" > "$L/s.tmp" && mv "$L/s.tmp" "$L/state.json"
assert_eq "old loops without round timing report unknown" "" "$(cd "$S" && bash -c '. ./lib.sh; rl_round_coder_seconds "$1"' _ "$L")"
assert_eq "fmt_dur seconds" "45s" "$(cd "$S" && bash -c '. ./lib.sh; rl_fmt_dur 45')"
assert_eq "fmt_dur minutes" "3m 20s" "$(cd "$S" && bash -c '. ./lib.sh; rl_fmt_dur 200')"
assert_eq "fmt_dur hours" "1h 02m" "$(cd "$S" && bash -c '. ./lib.sh; rl_fmt_dur 3725')"
assert_eq "fmt_dur empty" "-" "$(cd "$S" && bash -c '. ./lib.sh; rl_fmt_dur ""')"

section "dashboard derivation (node)"
if command -v node > /dev/null 2>&1; then
  DERIVE="$TMP/derive.js"
  sed -n '/<script id="rl-derive">/,/<\/script>/p' "$S/../templates/dashboard.html" | sed '1d;$d' > "$DERIVE"
  OUT=$(node -e '
    const RL = require(process.argv[1]);
    const mk = rounds => RL.deriveLoop({ state: { loop_id: "x", rounds, started_at: "2026-01-01T00:00:00Z" }, files: [], task: "t" });
    const all = mk([{ round: 1, coder_duration_s: 100, duration_s: 10 }, { round: 2, coder_duration_s: 50, duration_s: 20 }]);
    const mixed = mk([{ round: 1, duration_s: 10 }, { round: 2, coder_duration_s: 50, duration_s: 20 }, { round: 3, coder_duration_s: 25, duration_s: 5 }]);
    const none = mk([{ round: 1, duration_s: 10 }]);
    const empty = mk([]);
    console.log([all.coderTimeState, all.coderTime, all.reviewTime,
      mixed.coderTimeState, mixed.coderTime, mixed.coderRoundsRecorded, mixed.rounds.length, mixed.reviewTime,
      none.coderTimeState, none.coderTime, empty.coderTimeState].join(" "));
    const p90 = mk([{ round: 1, duration_s: 10 }, { round: 2, coder_duration_s: 90, duration_s: 20 }]);
    const late = mk([{ round: 1, coder_duration_s: 100, duration_s: 10 }, { round: 2, coder_duration_s: 20, coder_time_underestimated: true, duration_s: 5 }]);
    console.log([late.coderTimeState, late.coderRoundsUnderestimated, RL.fmtCoderTime(late), RL.fmtCoderTime(late, true)].join("|"));
    console.log([RL.fmtDur(59), RL.fmtDur(90), RL.fmtDur(120), RL.fmtDur(3725), RL.fmtDur(3599), RL.fmtDur(null),
      RL.fmtCoderTime(p90), RL.fmtCoderTime(p90, true), RL.fmtCoderTime(all), RL.fmtCoderTime(none)].join("|"));
    console.log([RL.minutesFloor(94), RL.minutesFloor(96), RL.minutesFloor(5), RL.minutesFloor(0), RL.minutesFloor(null)].join(","));
  ' "$DERIVE")
  assert_contains "derive: complete / partial / none / empty" "complete 150 30 partial 75 2 3 35 none 0 none" "$OUT"
  assert_contains "fmtDur never rounds up" "59s|1m 30s|2m|1h 02m|59m 59s|–|" "$OUT"
  assert_contains "partial 90s shows an honest lower bound" "|≥ 1m 30s*|at least 1m 30s (1 of 2 rounds recorded)|2m 30s|–" "$OUT"
  assert_contains "chart minutes floor (94s -> 1.5, never 1.6)" "1.5,1.6,0,0,0" "$OUT"
  assert_contains "late-resume round makes the total a lower bound" "underestimated|1|≥ 2m*|at least 2m (a pause ended late in 1 round)" "$OUT"
else
  echo "  skip node not installed"
fi

section "dashboard configuration panel"
R=$(new_repo r36); rm -rf "$HOME/.config/review-loop" "$HOME/.claude/review-loop.json"
assert_eq "keys --json lists every key" "9" "$(bash "$C" keys --json | jq '.keys | length')"
assert_eq "keys --json excludes the fake backend" '["claude","codex"]' "$(bash "$C" keys --json | jq -c .backends)"
assert_eq "keys --json marks clearable keys" "3" "$(bash "$C" keys --json | jq '[.keys[] | select(.clearable)] | length')"
(cd "$R" && bash "$C" set max_rounds=3 > /dev/null)
J=$(cd "$R" && bash "$C" show --json)
assert_eq "show --json carries sources" '"project shared"' "$(jq .sources.max_rounds <<< "$J")"
assert_eq "show --json source for env" '"env REVIEW_LOOP_BACKEND"' "$(jq .sources.backend <<< "$J")"
assert_eq "show --json source default" '"default"' "$(jq .sources.model <<< "$J")"
(cd "$R" && bash "$S/dashboard.sh" > /dev/null)
D=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "dashboard embeds the config keys" "9" "$(jq '.config.keys | length' <<< "$D")"
assert_eq "dashboard embeds effective values" "3" "$(jq .config.show.effective.max_rounds <<< "$D")"
assert_eq "dashboard embeds sources" '"project shared"' "$(jq .config.show.sources.max_rounds <<< "$D")"
CABS="$(cd "$(dirname "$C")" && pwd)/config.sh"
assert_eq "dashboard embeds the config.sh path" "$CABS" "$(jq -r .config.script <<< "$D")"
assert_eq "static page has no serve token" "null" "$(jq .serve <<< "$D")"
mkdir -p "$R/.codex" "$HOME/.opencode"; echo '{"max_rounds": 2, "model": "o"}' > "$R/.codex/review-loop.json"; echo '{"dir": "oc"}' > "$HOME/.opencode/review-loop.json"
mkdir -p "$R/.not a provider"; echo '{}' > "$R/.not a provider/review-loop.json"
(cd "$R" && bash "$S/dashboard.sh" > /dev/null)
D=$(sed -n 's|.*<script id="rl-data" type="application/json">\(.*\)</script>|\1|p' "$R/.review-loop/dashboard.html")
assert_eq "dashboard embeds other providers' project files with contents" '{"max_rounds":2,"model":"o"}' "$(jq -c '[.config.provider_files[] | select(.provider == "codex" and .scope == "project")][0].values' <<< "$D")"
assert_eq "dashboard embeds other providers' user files" '"oc"' "$(jq '[.config.provider_files[] | select(.provider == "opencode" and .scope == "user")][0].values.dir' <<< "$D")"
assert_eq "invalid provider dir names are skipped" "0" "$(jq '[.config.provider_files[] | select(.provider | test(" "))] | length' <<< "$D")"
assert_eq "dashboard embeds the user shared path" "$HOME/.config/review-loop/config.json" "$(jq -r .config.user_shared <<< "$D")"
rm -rf "$R/.codex" "$HOME/.opencode" "$R/.not a provider"
if command -v node > /dev/null 2>&1; then
  DERIVE="$TMP/derive2.js"
  sed -n '/<script id="rl-derive">/,/<\/script>/p' "$S/../templates/dashboard.html" | sed '1d;$d' > "$DERIVE"
  OUT=$(node -e '
    const RL = require(process.argv[1]);
    const keys = [{key:"backend",type:"string"},{key:"max_rounds",type:"integer"},{key:"usage",type:"boolean"},{key:"dashboard.dirs",type:"list"},{key:"model",type:"string"}];
    const eff = {backend:"codex", max_rounds:5, usage:false, model:"", dashboard:{dirs:["a","b"]}};
    const form = {backend:"codex", max_rounds:"3", usage:"true", "dashboard.dirs":"a,b", model:"o p"};
    const ch = RL.diffConfig(keys, eff, form);
    console.log(JSON.stringify(ch.set));
    console.log(RL.buildCommand("/x/config.sh", {scope:"project", mode:"shared"}, ch));
    console.log(RL.buildCommand("/x/config.sh", {scope:"user", mode:"section", provider:"codex"}, {set:{max_rounds:"2"}, unset:["model"]}));
    console.log(RL.buildCommand("/x/config.sh", {scope:"project", mode:"file", provider:"claude"}, {set:{}, unset:[]}) === "" ? "empty" : "nonempty");
    const doc = RL.applyToFile({max_rounds: 1, providers:{codex:{backend:"claude"}}}, ["providers","codex"], {set:{max_rounds:"4", usage:"yes", "dashboard.dirs":"x, y"}}, keys);
    console.log(JSON.stringify(doc));
    console.log(JSON.stringify(RL.applyToFile(null, [], {set:{model:"opus"}}, keys)));
  ' "$DERIVE")
  assert_contains "diffConfig: only changed keys, raw strings" '{"max_rounds":"3","usage":"true","model":"o p"}' "$OUT"
  assert_contains "buildCommand: set with quoting" "bash /x/config.sh set --project max_rounds=3 usage=true 'model=o p'" "$OUT"
  assert_contains "buildCommand: section scope and unset line" "bash /x/config.sh set --user --provider=codex max_rounds=2
bash /x/config.sh unset --user --provider=codex model" "$OUT"
  assert_contains "buildCommand: empty change set" "empty" "$OUT"
  assert_contains "applyToFile: typed values into the section" '{"max_rounds":1,"providers":{"codex":{"backend":"claude","max_rounds":4,"usage":true,"dashboard":{"dirs":["x","y"]}}}}' "$OUT"
  assert_contains "applyToFile: new file" '{"model":"opus"}' "$OUT"
  OUT=$(node -e '
    const RL = require(process.argv[1]);
    const keys = [{key:"backend",type:"string"},{key:"max_rounds",type:"integer"},{key:"usage",type:"boolean"},{key:"dashboard.dirs",type:"list"},{key:"model",type:"string"},{key:"dir",type:"string"}];
    const v = (k, raw) => RL.validateValue(keys.find(x => x.key === k), raw, ["claude","codex"]);
    console.log(["max_rounds:", v("max_rounds",""), "|", v("max_rounds","1.5"), "|", v("max_rounds","0"), "|", v("max_rounds","3"),
      "dir:", v("dir",""), "|", v("dir","x"), "backend:", v("backend","nope"), "|", v("backend","claude"),
      "usage:", v("usage","maybe"), "|", v("usage","yes"), "model:", v("model","")].join(""));
    // force: write the effective value to another file; remove: unset
    const eff = {backend:"codex", max_rounds:3, usage:false, model:"", dir:".review-loop", dashboard:{dirs:[]}};
    const form = {backend:"codex", max_rounds:"3", usage:"false", model:"", dir:".review-loop", "dashboard.dirs":""};
    const ch = RL.diffConfig(keys, eff, form, {force:["max_rounds"], remove:["model","dashboard.dirs"]});
    console.log(JSON.stringify(ch));
    console.log(RL.buildCommand("/x/config.sh", {scope:"user", mode:"shared"}, ch));
    const doc = RL.applyToFile({max_rounds:2, model:"old", dashboard:{dirs:["a"], auto:true}, providers:{codex:{backend:"claude"}}}, [], ch, keys);
    console.log(JSON.stringify(doc));
    const doc2 = RL.applyToFile({providers:{claude:{model:"m"}}}, ["providers","claude"], {set:{}, unset:["model"]}, keys);
    console.log(JSON.stringify(doc2));
    console.log(JSON.stringify(RL.applyToFile({max_rounds:1}, [], {set:{}, unset:["dashboard.dirs"]}, keys)));
  ' "$DERIVE")
  assert_contains "validateValue mirrors config.sh" "max_rounds:max_rounds must be a positive integer|max_rounds must be a positive integer|max_rounds must be a positive integer|dir:dir cannot be empty|backend:unknown backend 'nope'|usage:usage must be true or false|model:" "$OUT"
  assert_contains "diffConfig: forced key written although equal, removals become unsets" '{"set":{"max_rounds":"3"},"unset":["dashboard.dirs","model"]}' "$OUT"
  assert_contains "buildCommand: set and unset lines for the user file" "bash /x/config.sh set --user max_rounds=3
bash /x/config.sh unset --user dashboard.dirs model" "$OUT"
  assert_contains "applyToFile: unset removes keys and keeps the rest" '{"max_rounds":3,"dashboard":{"auto":true},"providers":{"codex":{"backend":"claude"}}}' "$OUT"
  assert_contains "applyToFile: unset in a section prunes the empty section" '{}' "$OUT"
  assert_contains "applyToFile: unset of a missing nested key is harmless" '{"max_rounds":1}' "$OUT"
  OUT=$(node -e '
    const RL = require(process.argv[1]);
    const keys = [{key:"max_rounds",type:"integer"},{key:"dashboard.dirs",type:"list"},{key:"model",type:"string"}];
    console.log(JSON.stringify(RL.applyToFile({custom:{}, providers:{other:{}}, dashboard:{dirs:[]}}, [], {set:{max_rounds:"3"}, unset:[]}, keys)));
    console.log(JSON.stringify(RL.applyToFile({custom:{}, providers:{other:{}, claude:{model:"m"}}, dashboard:{dirs:[], out:""}}, ["providers","claude"], {set:{}, unset:["model"]}, keys)));
    console.log(JSON.stringify(RL.applyToFile({custom:{}, dashboard:{dirs:["a"]}, providers:{x:{}}}, [], {set:{}, unset:["dashboard.dirs"]}, keys)));
    const v = raw => RL.validateValue(keys[0], raw, []);
    console.log([v("9007199254740991"), "|", v("9007199254740992"), "|", v("99999999999999999"), "|", v("10000000000000000")].join(""));
  ' "$DERIVE")
  assert_contains "applyToFile: set leaves unrelated empty objects alone" '{"custom":{},"providers":{"other":{}},"dashboard":{"dirs":[]},"max_rounds":3}' "$OUT"
  assert_contains "applyToFile: unset prunes only the emptied section" '{"custom":{},"providers":{"other":{}},"dashboard":{"dirs":[],"out":""}}' "$OUT"
  assert_contains "applyToFile: unset prunes only its own emptied container" '{"custom":{},"providers":{"x":{}}}' "$OUT"
  assert_contains "validateValue: safe-integer bound" "|max_rounds is too large (max 9007199254740991)|max_rounds is too large (max 9007199254740991)|max_rounds is too large (max 9007199254740991)" "$OUT"
  assert_eq "validateValue: 2^53-1 accepted" "" "$(printf '%s\n' "$OUT" | tail -1 | cut -d'|' -f1)"
  OUT=$(node -e '
    const RL = require(process.argv[1]);
    const keys = [{key:"max_rounds",type:"integer"},{key:"model",type:"string"},{key:"dashboard.dirs",type:"list"}];
    const text = `{"custom": {"id": 9007199254740993, "f": 1.50, "e": 1e5, "neg": -0, "arr": [10, 2.0]}, "s": "12 \\"x\\" 34 -5", "t": "\\u0001n:123", "u": "n:123", "max_rounds": 2, "providers": {"claude": {"model": "m"}}}`;
    const lj = RL.losslessJSON(text);
    const doc = RL.applyToFile(lj.doc, [], {set:{max_rounds:"3"}, unset:[]}, keys);
    console.log(lj.stringify(doc).replace(/\s+/g, ""));
    const lj2 = RL.losslessJSON(text);
    console.log(lj2.stringify(RL.applyToFile(lj2.doc, ["providers","claude"], {set:{}, unset:["model"]}, keys)).replace(/\s+/g, ""));
    const lj3 = RL.losslessJSON("{}"); console.log(lj3.stringify(lj3.doc) === "{}" ? "empty-ok" : "empty-bad");
    try { RL.losslessJSON("{bad"); console.log("no-throw"); } catch (e) { console.log("throws"); }
    // a string that happens to look like a marker with the nonce of a previous call must survive another call
    const fake = `{"v": "n${lj.nonce}:123", "n": 7}`;
    const lj4 = RL.losslessJSON(fake); console.log(lj4.stringify(lj4.doc).replace(/\s+/g, ""));
    console.log(lj.nonce !== lj2.nonce ? "nonce-varies" : "nonce-fixed");
    // R5-C1: a string (or key) that spells the nonce through JSON escapes must reject that nonce
    const esc = `{"v": "n\\u0061bc123:5", "n\\u0061bc123:7": "k", "x": 1}`;
    const lj5 = RL.losslessJSON(esc, ["abc123", "zzz999"]);
    console.log(lj5.nonce === "zzz999" ? "escaped-nonce-rejected" : "escaped-nonce-" + lj5.nonce);
    console.log(lj5.stringify(RL.applyToFile(lj5.doc, [], {set:{}, unset:[]}, keys)).replace(/\s+/g, ""));
    const lj6 = RL.losslessJSON(`{"plain": "nabc123:9", "y": 2}`, ["abc123", "qqq111"]);
    console.log(lj6.nonce === "qqq111" ? "plain-nonce-rejected" : "plain-nonce-" + lj6.nonce);
  ' "$DERIVE")
  assert_contains "lossless save: unrelated numbers byte-identical, edited key updated" '{"custom":{"id":9007199254740993,"f":1.50,"e":1e5,"neg":-0,"arr":[10,2.0]},"s":"12\"x\"34-5","t":"\u0001n:123","u":"n:123","max_rounds":3,"providers":{"claude":{"model":"m"}}}' "$OUT"
  assert_contains "lossless save: unset in a section keeps the rest exact" '{"custom":{"id":9007199254740993,"f":1.50,"e":1e5,"neg":-0,"arr":[10,2.0]},"s":"12\"x\"34-5","t":"\u0001n:123","u":"n:123","max_rounds":2}' "$OUT"
  assert_contains "lossless save: empty object" "empty-ok" "$OUT"
  assert_eq "lossless save: marker-shaped string is still a string" "1" "$(printf '%s\n' "$OUT" | grep -c '^{"v":"n[0-9a-f]*:123","n":7}$')"
  assert_contains "lossless save: nonce differs per call" "nonce-varies" "$OUT"
  assert_contains "lossless save: nonce spelled through escapes is rejected" "escaped-nonce-rejected" "$OUT"
  assert_contains "lossless save: escaped string and key survive unchanged" '{"v":"nabc123:5","nabc123:7":"k","x":1}' "$OUT"
  assert_contains "lossless save: nonce present in a plain string is rejected" "plain-nonce-rejected" "$OUT"
  assert_contains "lossless save: invalid JSON throws" "throws" "$OUT"
else
  echo "  skip node not installed"
fi
if command -v python3 > /dev/null 2>&1 && command -v curl > /dev/null 2>&1; then
  PORT=$(( 20000 + RANDOM % 20000 ))
  (cd "$R" && bash "$S/dashboard.sh" --serve --port "$PORT" > "$TMP/serve.log" 2>&1) &
  SPID=$!
  for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; python3 -c 'import time; time.sleep(0.2)'; done
  PAGE=$(curl -s "http://127.0.0.1:$PORT/")
  TOKEN=$(printf '%s' "$PAGE" | grep -o '"serve":{"token":"[0-9a-f]*"}' | grep -o '[0-9a-f]\{32\}')
  assert_eq "serve: page carries a 32-hex token" "32" "$(printf '%s' "$TOKEN" | wc -c | tr -d ' ')"
  post() { curl -s -w '\n%{http_code}' -X POST "http://127.0.0.1:$PORT/api/config" -H "X-RL-Token: ${2:-$TOKEN}" -H 'Content-Type: application/json' -d "$1"; }
  assert_contains "serve: bad token rejected" "403" "$(post '{"set":{"max_rounds":"4"}}' nope)"
  assert_eq "serve: bad token writes nothing" "3" "$(jq .max_rounds "$R/.review-loop.json")"
  OUT=$(post '{"scope":"project","mode":"shared","set":{"max_rounds":"4","usage":"true"}}')
  assert_contains "serve: set applied through config.sh" "Updated $R/.review-loop.json" "$OUT"
  assert_eq "serve: file updated" "4" "$(jq .max_rounds "$R/.review-loop.json")"
  assert_eq "serve: boolean coerced" "true" "$(jq .usage "$R/.review-loop.json")"
  OUT=$(post '{"scope":"project","mode":"section","provider":"codex","set":{"backend":"claude"}}')
  assert_contains "serve: section write" "(providers.codex)" "$OUT"
  assert_eq "serve: section stored" '"claude"' "$(jq .providers.codex.backend "$R/.review-loop.json")"
  OUT=$(post '{"scope":"project","mode":"shared","unset":["usage"]}')
  assert_eq "serve: unset applied" "null" "$(jq .usage "$R/.review-loop.json")"
  assert_contains "serve: validation error surfaces with 422" "positive integer (got '0')" "$(post '{"set":{"max_rounds":"0"}}')"
  assert_contains "serve: validation error status" "422" "$(post '{"set":{"max_rounds":"0"}}')"
  assert_contains "serve: unknown key rejected" "400" "$(post '{"set":{"x; rm -rf /":"1"}}')"
  assert_contains "serve: bad provider rejected" "400" "$(post '{"mode":"file","provider":"--user","set":{"max_rounds":"2"}}')"
  assert_contains "serve: provider none rejected" "400" "$(post '{"mode":"section","provider":"none","set":{"max_rounds":"2"}}')"
  assert_contains "serve: bad scope rejected" "400" "$(post '{"scope":"../x","set":{"max_rounds":"2"}}')"
  assert_contains "serve: invalid JSON rejected" "400" "$(post 'not json')"
  assert_contains "serve: unknown path is 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/etc/passwd")"
  assert_contains "serve: reload shows the new value" '"max_rounds":4' "$(curl -s "http://127.0.0.1:$PORT/" | grep -o '"effective":{[^}]*}' | head -1)"
  assert_contains "serve: page says where changes go" "applied with: bash $CABS" "$(cat "$TMP/serve.log")"
  kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
  assert_contains "serve: refuses a bad port" "invalid port" "$(cd "$R" && bash "$S/dashboard.sh" --serve --port abc 2>&1 || true)"
else
  echo "  skip python3 or curl not installed"
fi
rm -f "$R/.review-loop.json"

section "config robustness"
R=$(new_repo r37); rm -rf "$HOME/.config/review-loop" "$HOME/.claude/review-loop.json"
cfgj() { (cd "$R" && bash "$S/config.sh" show --json | jq -c '{r: .effective.max_rounds, m: .effective.model, d: .effective.dir}'); }
echo '{"providers": "oops", "max_rounds": 4}' > "$R/.review-loop.json"
assert_eq "providers that is not an object is ignored, the rest applies" '{"r":4,"m":"","d":".review-loop"}' "$(cfgj)"
echo '{"providers": {"claude": "x"}, "max_rounds": 4}' > "$R/.review-loop.json"
assert_eq "a provider section that is not an object is ignored" '{"r":4,"m":"","d":".review-loop"}' "$(cfgj)"
echo '[1, 2]' > "$R/.review-loop.json"
assert_eq "a top-level array is ignored like invalid JSON" '{"r":5,"m":"","d":".review-loop"}' "$(cfgj)"
echo '"just a string"' > "$R/.review-loop.json"
assert_eq "a top-level string is ignored" '{"r":5,"m":"","d":".review-loop"}' "$(cfgj)"
mkdir -p "$HOME/.config/review-loop"; echo '{"model": "opus", "max_rounds": 7}' > "$HOME/.config/review-loop/config.json"
echo '{"model": null, "max_rounds": null, "dir": "d"}' > "$R/.review-loop.json"
assert_eq "null values never wipe lower-precedence values" '{"r":7,"m":"opus","d":"d"}' "$(cfgj)"
echo '{"providers": {"claude": {"model": null}}, "model": "shared"}' > "$R/.review-loop.json"
assert_eq "null in a provider section is dropped too" '"shared"' "$(cd "$R" && bash "$S/config.sh" show --json | jq .effective.model)"
echo '{"providers": "oops"}' > "$R/.review-loop.json"
assert_eq "config source survives malformed providers" '"user shared"' "$(cd "$R" && bash "$S/config.sh" show --json | jq .sources.model)"
start "$R" "t" > /dev/null; L=$(pointer "$R"); echo x > "$R/f"
H=$(hook "$R" s1)
assert_eq "stop hook still blocks with a malformed config" "block" "$(decision "$H")"
assert_eq "start.sh resolves through a malformed providers value" "7" "$(st "$L" max_rounds)"
(cd "$R" && bash "$S/cancel.sh" > /dev/null)
OUT=$(cd "$R" && bash "$S/dashboard.sh" 2>&1)
assert_contains "dashboard generates with a malformed config" "1 loop(s)" "$OUT"
rm -f "$R/.review-loop.json" "$HOME/.config/review-loop/config.json"
# create with only a legacy provider file makes the shared file and says what outranks it
mkdir -p "$R/.claude"; echo '{"max_rounds": 2}' > "$R/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" create)
assert_contains "create makes the shared file despite a legacy file" "Created $R/.review-loop.json" "$OUT"
assert_contains "create notes the file that takes precedence" "note: $R/.claude/review-loop.json exists and takes precedence" "$OUT"
assert_file "shared file created" "$R/.review-loop.json"
# unset: pruning and masking note
(cd "$R" && bash "$C" set --provider codex dashboard.auto=true > /dev/null)
(cd "$R" && bash "$C" unset --provider codex dashboard.auto > /dev/null)
assert_eq "unset prunes empty dashboard, section and providers" '{}' "$(jq -c . "$R/.review-loop.json")"
(cd "$R" && bash "$C" set --project max_rounds=9 > /dev/null)
OUT=$(cd "$R" && bash "$C" unset --project max_rounds)
assert_contains "unset note names the masking source" "max_rounds now resolves to 2 (project claude)" "$OUT"
# take_name explains why a key or command word was not taken as a name
OUT=$(cd "$R" && bash "$C" show --provider backend 2>&1 || true)
assert_contains "key-shaped word after --provider is explained" "note: '--provider' took no provider name because 'backend' is a config key" "$OUT"
OUT=$(cd "$R" && bash "$C" show --provider-file keys 2>&1 || true)
assert_contains "command-shaped word after --provider-file is explained" "'keys' is a command" "$OUT"
rm -f "$R/.review-loop.json" "$R/.claude/review-loop.json"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
