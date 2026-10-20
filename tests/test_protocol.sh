#!/usr/bin/env bash
# Standalone strict-protocol regression tests; also run by test_loop.sh.
set -uo pipefail
PROTO_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/review-loop/skills/review-loop/scripts" && pwd)
. "$PROTO_SCRIPTS/lib.sh"
PROTO_TMP=$(mktemp -d)
trap 'rm -rf "$PROTO_TMP"' EXIT
PROTO_PASS=0 PROTO_FAIL=0
proto_eq() {
  if [ "$2" = "$3" ]; then PROTO_PASS=$((PROTO_PASS + 1)); else
    PROTO_FAIL=$((PROTO_FAIL + 1)); printf 'FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3"
  fi
}
proto_bad() {
  local label="$1" expected="$2" result rc
  shift 2
  result=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [[ "$result" == *"$expected"* ]]; then PROTO_PASS=$((PROTO_PASS + 1)); else
    PROTO_FAIL=$((PROTO_FAIL + 1)); printf 'FAIL %s: expected failure containing <%s>, got exit %s: %s\n' "$label" "$expected" "$rc" "$result"
  fi
}
proto_finding() {
  printf '### %s\n- severity: high\n- blocking: %s\n- file: src/app.sh\n- line: 10\n- description: Fails on empty input.\n- suggested fix: Validate the input.\n\n' "$1" "${2:-yes}"
}
proto_document() {
  printf '## Comments\n\n'; proto_finding "$1" "${2:-yes}"
  printf '## Assessment\n\nVerified the failure.\n\nVERDICT: %s\n' "${3:-changes_requested}"
}
PROTO_EMPTY='{"ids":[],"required_coder_ids":[]}'
PROTO_HIST='{"ids":["R1-C1","R1-C2"],"required_coder_ids":["R1-C1","R1-C2"]}'
proto_document R1-C1 > "$PROTO_TMP/base"
proto_eq 'valid new finding' '' "$(rl_validate_review "$PROTO_TMP/base" changes_requested 1 "$PROTO_EMPTY")"
proto_eq 'strict blocking count' 1 "$(rl_count_blocking "$PROTO_TMP/base" 2)"
for pair in 'severity:unknown' 'blocking:maybe' 'file:' 'line:0' 'line:-1' 'line:ten' 'description:' 'suggested fix:'; do
  key=${pair%%:*}; value=${pair#*:}
  awk -v key="$key" -v value="$value" 'index($0,"- " key ":") == 1 {$0="- " key ": " value} {print}' "$PROTO_TMP/base" > "$PROTO_TMP/bad"
  proto_bad "invalid $pair" "$key" rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
done
sed '/- blocking: yes/a\
- blocking: no
' "$PROTO_TMP/base" > "$PROTO_TMP/bad"
proto_bad 'duplicate field' 'duplicate field blocking' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
{ printf '## Comments\n\n'; proto_finding R1-C1; proto_finding R1-C1; printf '## Assessment\n\nBad.\nVERDICT: changes_requested\n'; } > "$PROTO_TMP/bad"
proto_bad 'duplicate finding' 'duplicate finding ID' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
proto_document R1-C2 > "$PROTO_TMP/bad"
proto_bad 'nonconsecutive finding' 'expected finding R1-C1' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
proto_document R2-C1 > "$PROTO_TMP/bad"
proto_bad 'wrong round' 'expected finding R1-C1' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
proto_document R0-C1 > "$PROTO_TMP/bad"
proto_bad 'malformed finding ID' 'malformed finding heading' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
sed 's/## Comments/## Comments\n\n## Optional/' "$PROTO_TMP/base" > "$PROTO_TMP/bad"
proto_bad 'blocking Optional' 'must have blocking: no' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
proto_document R1-C1 no > "$PROTO_TMP/bad"
proto_bad 'optional-only changes requested' 'requires a blocking finding' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
printf '## Comments\n\n## Assessment\n\nFine.\n\n```md\n### R1-C1\n- blocking: yes\n- R0-C1: unresolved\n```\nVERDICT: approved\n' > "$PROTO_TMP/clean"
proto_eq 'fenced examples ignored' '' "$(rl_validate_review "$PROTO_TMP/clean" approved 1 "$PROTO_EMPTY")"
proto_eq 'examples do not block' 0 "$(rl_count_blocking "$PROTO_TMP/clean" 2)"
proto_eq 'examples have no blocking IDs' '' "$(rl_blocking_ids "$PROTO_TMP/clean" 2)"
cp "$PROTO_TMP/clean" "$PROTO_TMP/bad"; printf 'Extra prose after the verdict.\n' >> "$PROTO_TMP/bad"
proto_bad 'verdict must finish the review' 'last non-empty line must be VERDICT' rl_validate_review "$PROTO_TMP/bad" approved 1 "$PROTO_EMPTY"
printf '```\n' >> "$PROTO_TMP/clean"
proto_bad 'unclosed fence' 'unclosed code fence' rl_validate_review "$PROTO_TMP/clean" approved 1 "$PROTO_EMPTY"
{ printf '## Comments\n\n## Assessment\n\nChecked.\n\n'; proto_finding R1-C1; printf 'VERDICT: changes_requested\n'; } > "$PROTO_TMP/bad"
proto_bad 'finding in wrong section' 'must be in Comments or Optional' rl_validate_review "$PROTO_TMP/bad" changes_requested 1 "$PROTO_EMPTY"
printf '## Comments\n\n- blocking: yes\n\n## Assessment\n\nChecked.\nVERDICT: approved\n' > "$PROTO_TMP/bad"
proto_bad 'orphan finding field' 'finding field without a finding heading' rl_validate_review "$PROTO_TMP/bad" approved 1 "$PROTO_EMPTY"
proto_previous() {
  printf '## Previous comments\n\n%s\n\n## Comments\n\n## Assessment\n\nChecked the fixes.\n\nVERDICT: approved\n' "$1"
}
proto_previous '- R1-C1: resolved' > "$PROTO_TMP/bad"
proto_bad 'omitted historical ID' 'missing previous-comment ID: R1-C2' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
proto_previous $'- R1-C1: resolved\n- R1-C1: unresolved\n- R1-C2: declined-accepted' > "$PROTO_TMP/bad"
proto_bad 'duplicate disposition' 'duplicate previous-comment ID' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
proto_previous $'- R1-C1: fixed\n- R1-C2: declined-accepted' > "$PROTO_TMP/bad"
proto_bad 'invalid disposition' 'invalid status for R1-C1' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
proto_previous $'- R1-C1: resolved\n- R1-C2: declined-accepted\n- R9-C1: resolved' > "$PROTO_TMP/bad"
proto_bad 'unknown disposition' 'unknown previous-comment ID' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
proto_previous $'- R1-C1: resolved\n- R1-C2: declined-accepted' | sed 's/## Previous comments/## Optional/' > "$PROTO_TMP/bad"
proto_bad 'disposition outside previous section' 'outside Previous comments' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
{ printf '## Optional\n\n'; proto_previous $'- R1-C1: resolved\n- R1-C2: declined-accepted'; printf '\n## Optional\n\nVERDICT: approved\n'; } > "$PROTO_TMP/bad"
proto_bad 'duplicate Optional section' 'duplicate ## optional section' rl_validate_review "$PROTO_TMP/bad" approved 2 "$PROTO_HIST"
proto_previous $'- R1-C1: unresolved\n- R1-C2: declined-rejected' > "$PROTO_TMP/open"
proto_eq 'all historical statuses valid' '' "$(rl_validate_review "$PROTO_TMP/open" approved 2 "$PROTO_HIST")"
proto_eq 'unresolved statuses block' 2 "$(rl_count_blocking "$PROTO_TMP/open" 2)"
proto_eq 'unresolved IDs reported' $'R1-C1\nR1-C2' "$(rl_blocking_ids "$PROTO_TMP/open" 2)"
mkdir "$PROTO_TMP/history"
{ printf '## Comments\n\n'; proto_finding R1-C1; printf '## Optional\n\n'; proto_finding R1-C2 no; printf '## Assessment\n\nChecked.\nVERDICT: changes_requested\n'; } > "$PROTO_TMP/history/round-01-review.md"
{ printf '## Previous comments\n\n- R1-C1: unresolved\n- R1-C2: declined-accepted\n\n'; proto_document R2-C1; } > "$PROTO_TMP/history/round-02-review.md"
PROTO_HISTORY=$(rl_review_history "$PROTO_TMP/history" 3)
proto_eq 'older open IDs remain required' '["R1-C1","R2-C1"]' "$(jq -c .required_coder_ids <<< "$PROTO_HISTORY")"
proto_bad 'missing history cannot drop blockers' 'missing historical review' rl_review_history "$PROTO_TMP/history" 4
proto_responses() { printf '## Responses to the previous review\n\n| ID | Status | Note |\n|----|--------|------|\n%s\n' "$1"; }
proto_responses '| R2-C1 | fixed | Tested. |' > "$PROTO_TMP/coder"
proto_bad 'older blocker needs coder answer' 'missing coder response: R1-C1' rl_validate_coder "$PROTO_TMP/coder" "$PROTO_HISTORY"
proto_responses $'| R1-C1 | fixed | Tested. |\n| R2-C1 | declined | Intentional behavior. |' > "$PROTO_TMP/coder"
proto_eq 'fixed and declined responses' '' "$(rl_validate_coder "$PROTO_TMP/coder" "$PROTO_HISTORY")"
for extra in '| R2-C1 | fixed | Duplicate. |' '| R9-C1 | fixed | Unknown. |'; do
  cp "$PROTO_TMP/coder" "$PROTO_TMP/bad"; printf '%s\n' "$extra" >> "$PROTO_TMP/bad"
  proto_bad 'duplicate or unknown coder ID' 'coder response' rl_validate_coder "$PROTO_TMP/bad" "$PROTO_HISTORY"
done
sed 's/Intentional behavior\.//' "$PROTO_TMP/coder" > "$PROTO_TMP/bad"
proto_bad 'declines need a reason' 'non-empty explanation' rl_validate_coder "$PROTO_TMP/bad" "$PROTO_HISTORY"
sed 's/declined/resolved/' "$PROTO_TMP/coder" > "$PROTO_TMP/bad"
proto_bad 'invalid coder status' 'invalid coder response status' rl_validate_coder "$PROTO_TMP/bad" "$PROTO_HISTORY"

# End to end: invalid coder input must not spend a backend call; omission of an
# earlier blocker must not install a review or advance; retries must converge.
mkdir "$PROTO_TMP/project"
printf '{"model":"","effort":"","prompts":{"reviewer":"","reviewer_extra":"","coder":"","coder_extra":""},"dashboard":{"auto":false}}\n' > "$PROTO_TMP/project/.review-loop.json"
cd "$PROTO_TMP/project" || exit 1
export REVIEW_LOOP_PROVIDER=none REVIEW_LOOP_BACKEND=fake REVIEW_LOOP_MODEL= REVIEW_LOOP_EFFORT=
export REVIEW_LOOP_DIR=.review-loop REVIEW_LOOP_MAX_ROUNDS=3 REVIEW_LOOP_USAGE=0 REVIEW_LOOP_DASHBOARD_OPEN=0
export REVIEW_LOOP_FAKE_FILE="$PROTO_TMP/queue" REVIEW_LOOP_FAKE_REVIEW_FILE="$PROTO_TMP/review"
export REVIEW_LOOP_FAKE_ENV_FILE="$PROTO_TMP/env" REVIEW_LOOP_FAKE_LAST_PROMPT="$PROTO_TMP/prompt"
export REVIEW_LOOP_FAKE_CLOCK="$PROTO_TMP/clock" REVIEW_LOOP_FAKE_TAKES=10
printf '1000\n' > "$PROTO_TMP/clock"
bash "$PROTO_SCRIPTS/start.sh" 'Fix the bug' > "$PROTO_TMP/start-output" 2>&1
PROTO_LOOP=$(cat .claude/review-loop.active)
proto_eq 'new loops freeze protocol 2' 2 "$(jq .protocol_version "$PROTO_LOOP/state.json")"
printf '# Coder summary\n' > "$PROTO_LOOP/round-01-coder.md"
cp "$PROTO_TMP/history/round-01-review.md" "$PROTO_TMP/review"
printf 'custom\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
proto_eq 'valid round advances' 2 "$(jq .round "$PROTO_LOOP/state.json")"
proto_responses '| R1-C1 | fixed | Fixed. |' > "$PROTO_LOOP/round-02-coder.md"
printf 'custom\n' > "$PROTO_TMP/queue"
proto_bad 'missing coder response rejected before backend' 'missing coder response: R1-C2' bash "$PROTO_SCRIPTS/review.sh"
proto_eq 'coder failure keeps backend queue' custom "$(cat "$PROTO_TMP/queue")"
proto_eq 'coder failure does not consume reviewer time' 1010 "$(cat "$PROTO_TMP/clock")"
proto_responses $'| R1-C1 | fixed | Fixed. |\n| R1-C2 | declined | Style preference. |' > "$PROTO_LOOP/round-02-coder.md"
proto_previous '- R1-C2: declined-accepted' > "$PROTO_TMP/review"
proto_bad 'omitted blocker cannot approve' 'missing previous-comment ID: R1-C1' bash "$PROTO_SCRIPTS/review.sh"
proto_eq 'invalid review leaves round unchanged' 2 "$(jq .round "$PROTO_LOOP/state.json")"
proto_eq 'invalid review not installed' no "$([ -f "$PROTO_LOOP/round-02-review.md" ] && echo yes || echo no)"
proto_eq 'invalid review retained for inspection' yes "$([ -f "$PROTO_LOOP/round-02-review.invalid.md" ] && echo yes || echo no)"
proto_eq 'invalid reviewer time recorded' 10 "$(jq .failed_review_s "$PROTO_LOOP/state.json")"
proto_eq 'invalid review has no round record' 1 "$(jq '.rounds | length' "$PROTO_LOOP/state.json")"
{ proto_previous $'- R1-C1: unresolved\n- R1-C2: declined-accepted'; } > "$PROTO_TMP/review"
printf 'custom\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
proto_eq 'approval with old blocker downgraded' changes_requested "$(rl_review_meta "$PROTO_LOOP/round-02-review.md" verdict)"
proto_eq 'retry advances exactly once' 3 "$(jq .round "$PROTO_LOOP/state.json")"
proto_eq 'failed review time excluded from coder duration' 0 "$(jq '.rounds[-1].coder_duration_s' "$PROTO_LOOP/state.json")"
proto_responses '| R1-C1 | fixed | Verified again. |' > "$PROTO_LOOP/round-03-coder.md"
proto_previous $'- R1-C1: resolved\n- R1-C2: declined-accepted' > "$PROTO_TMP/review"
printf 'custom\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
proto_eq 'complete history approves' approved "$(jq -r .outcome "$PROTO_LOOP/state.json")"
proto_eq 'strict protocol recorded in review' 2 "$(rl_review_meta "$PROTO_LOOP/round-03-review.md" protocol_version)"

# An installed strict review resumes before coder validation and never spends
# another backend call, even when its next-brief installation failed.
bash "$PROTO_SCRIPTS/start.sh" 'Resume a pending transition' > "$PROTO_TMP/start-output" 2>&1
PROTO_LOOP=$(cat .claude/review-loop.active)
printf '# Summary\n' > "$PROTO_LOOP/round-01-coder.md"
proto_document R1-C1 > "$PROTO_TMP/review"
printf 'custom\n' > "$PROTO_TMP/queue"
mkdir "$PROTO_LOOP/coder-brief.md.tmp"
proto_bad 'brief failure leaves pending strict review' 'round 1 not advanced' bash "$PROTO_SCRIPTS/review.sh"
proto_eq 'pending strict review installed' yes "$([ -f "$PROTO_LOOP/round-01-review.md" ] && echo yes || echo no)"
rm "$PROTO_LOOP/round-01-coder.md"; rmdir "$PROTO_LOOP/coder-brief.md.tmp"
printf 'garbage\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
proto_eq 'pending transition needs no coder file' 2 "$(jq .round "$PROTO_LOOP/state.json")"
proto_eq 'pending transition does not rerun backend' garbage "$(cat "$PROTO_TMP/queue")"
bash "$PROTO_SCRIPTS/cancel.sh" > /dev/null

# Existing loops do not acquire strict validation during an upgrade.
bash "$PROTO_SCRIPTS/start.sh" 'Legacy loop' > "$PROTO_TMP/start-output" 2>&1
PROTO_LOOP=$(cat .claude/review-loop.active)
jq 'del(.protocol_version)' "$PROTO_LOOP/state.json" > "$PROTO_LOOP/state.tmp"; mv "$PROTO_LOOP/state.tmp" "$PROTO_LOOP/state.json"
printf '# Old summary\n' > "$PROTO_LOOP/round-01-coder.md"
proto_document R1-C1 > "$PROTO_TMP/review"; printf 'custom\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
printf '# Old unstructured round-two summary\n' > "$PROTO_LOOP/round-02-coder.md"
proto_previous '' > "$PROTO_TMP/review"; printf 'custom\n' > "$PROTO_TMP/queue"
bash "$PROTO_SCRIPTS/review.sh" > "$PROTO_TMP/output" 2>&1
proto_eq 'unversioned loops retain legacy validation' approved "$(jq -r .outcome "$PROTO_LOOP/state.json")"
proto_eq 'legacy version does not change during review' null "$(jq .protocol_version "$PROTO_LOOP/state.json")"
printf 'strict protocol: %s passed, %s failed\n' "$PROTO_PASS" "$PROTO_FAIL"
[ "$PROTO_FAIL" -eq 0 ]
