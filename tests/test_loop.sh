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
assert_eq "show json: target is project file" "$R/.claude/review-loop.json" "$(jq -r .target <<< "$J")"
assert_eq "show json: project missing" "false" "$(jq .project.exists <<< "$J")"
assert_eq "show json: effective default rounds" "5" "$(jq .effective.max_rounds <<< "$J")"
OUT=$(cd "$R" && bash "$C" set backend=claude model=opus max_rounds=3 usage=yes dashboard.dirs=".review-loop, archive" dashboard.auto=1)
assert_contains "set reports file" "Updated $R/.claude/review-loop.json" "$OUT"
F="$R/.claude/review-loop.json"
assert_eq "set: string" "claude" "$(jq -r .backend "$F")"
assert_eq "set: integer typed" "3" "$(jq .max_rounds "$F")"
assert_eq "set: boolean from yes" "true" "$(jq .usage "$F")"
assert_eq "set: list split and trimmed" '[".review-loop","archive"]' "$(jq -c .dashboard.dirs "$F")"
assert_eq "set: nested boolean from 1" "true" "$(jq .dashboard.auto "$F")"
(cd "$R" && bash "$C" set --user max_rounds=7 dir=reviews > /dev/null)
assert_eq "set --user writes user file" "7" "$(jq .max_rounds "$HOME/.claude/review-loop.json")"
J=$(cd "$R" && bash "$C" show --json)
assert_eq "effective: project beats user" "3" "$(jq .effective.max_rounds <<< "$J")"
assert_eq "effective: user fills gaps" "reviews" "$(jq -r .effective.dir <<< "$J")"
assert_contains "show prints current values per file" "max_rounds       3                      3                      7" "$(cd "$R" && bash "$C" show)"
BEFORE=$(cat "$F")
for bad in backend=nope max_rounds=0 max_rounds=x usage=maybe nokey=1 dir= ; do
  OUT=$(cd "$R" && bash "$C" set "$bad" 2>&1); RC=$?
  assert_eq "set rejects $bad" "1" "$RC"
done
assert_contains "backend error lists real backends only" "(available: claude codex)" "$(cd "$R" && bash "$C" set backend=nope 2>&1)"
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
mkdir -p "$R/archive"; cp -R "$L" "$R/archive/"; echo unrelated > "$R/archive/README.md"
OUT=$(cd "$R" && bash "$C" gitignore --dry-run)
assert_contains "gitignore: extra dashboard dir offers its loop folder" "/archive/$(basename "$L")/" "$OUT"
assert_eq "gitignore: extra dashboard dir itself never ignored" "0" "$(printf '%s\n' "$OUT" | grep -cxF '  /archive/')"

R=$(new_repo r26); rm -f "$HOME/.claude/review-loop.json"
OUT=$(cd "$R" && bash "$C" create)
assert_contains "create: makes the file" "Created $R/.claude/review-loop.json" "$OUT"
assert_eq "create: empty object" "{}" "$(jq -c . "$R/.claude/review-loop.json")"
(cd "$R" && bash "$C" set max_rounds=2 > /dev/null)
assert_contains "create: existing file untouched" "already exists" "$(cd "$R" && bash "$C" create)"
assert_eq "create: values preserved" "2" "$(jq .max_rounds "$R/.claude/review-loop.json")"
OUT=$(cd "$R" && bash "$C" create --user)
assert_file "create --user" "$HOME/.claude/review-loop.json"; rm -f "$HOME/.claude/review-loop.json"
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
F="$R/.claude/review-loop.json"
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
assert_contains "init --yes: no prompts" "Wrote $HOME/.claude/review-loop.json" "$OUT"
assert_eq "init --yes: keeps existing user value" "opus" "$(jq -r .model "$HOME/.claude/review-loop.json")"
assert_eq "init --yes: existing file untouched for other keys" "null" "$(jq .max_rounds "$HOME/.claude/review-loop.json")"
rm -f "$HOME/.claude/review-loop.json"
assert_contains "unknown command" "unknown command" "$(cd "$R" && bash "$C" bogus 2>&1)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
