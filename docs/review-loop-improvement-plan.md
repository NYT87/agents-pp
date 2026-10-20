# Implementation plan: reliable, convergent review loops

Status: Phase 1 is implemented for new loops (`protocol_version: 2`). Phases
2–5 remain proposed. Existing unversioned/version-1 loops keep legacy behavior.

Phase 1 uses `rl_review_data`, `rl_review_history`, `rl_validate_coder`, and
strict review validation in `scripts/lib.sh`, with lifecycle integration in
`review.sh` and version freezing in `start.sh`. Run `bash tests/test_protocol.sh`
for focused regression coverage, or `bash tests/run.sh` for the full suite.

## Goal and scope

Improve the existing coder/reviewer loop so that approval accounts for every
finding, repeated reviews focus on relevant changes, and required verification
has executable evidence. Keep the standalone skill, Bash implementation, backend
contract, and recoverable state transitions.

This proposal follows the analysis of [How the Claude Code team does code
review](https://claude.dev/blog/solving-code-review-at-anthropic/), published
October 15, 2026. The article describes layered verification, filtering review
noise, convergence controls, and evaluations built from past failures. Those are
useful directions; the implementation choices below are specific to this repo.

Start with protocol enforcement and prompt improvements. Introduce snapshotting
before incremental review or executable approval gates. Evaluate the resulting
reviewer before investing in additional reviewer agents.

This document complements [the existing role-based plan](../PLAN.md), without
replacing it. That plan proposes additional roles, a native Codex review gate,
and broader reviewer permissions. Here, additional roles and native review are
deferred. Any required gate introduced later must fail closed on execution
errors; optional advisory tools may report an error without blocking. Use the
existing `effort` terminology rather than adding a parallel `reasoning` setting.

PR approvals, branch protection, merge queues, deployment controls, and incident
response belong to consuming repositories. A loop approval is a local review
result, not permission to merge or deploy.

## Current implementation

Paths below are relative to
`plugins/review-loop/skills/review-loop/`, unless stated otherwise.

| Capability | Existing implementation | Gap |
| --- | --- | --- |
| Independent reviewer | `scripts/review.sh`, `scripts/backends/*.sh` | Keep the single-reviewer contract initially |
| Comment accountability | `templates/review-format.md`, coder response table | Validation does not enforce complete historical ID coverage |
| Review scope | Full diff against `state.base_ref`, plus untracked files | No saved previous-round input for incremental review |
| Convergence | Cap defaults to five; explicit continuation | Full historical reviews and full task diff are included each round |
| Verification | Commands and results in coder summary | No runner-owned required check results |
| Guidance | `rl_role_prompt`, `prompts.*` configuration | Improve defaults and document project review policy |
| Metrics | Round counts, durations, optional usage, dashboard | No normalized finding outcomes or reviewer quality evaluation |

The reviewer is told to inspect tests, but execution depends on backend
permissions. Codex defaults to a read-only sandbox; Claude's explicit Bash
allowlist covers Git inspection. A reviewer-written statement that tests passed
does not establish that the loop executed them.

## Invariants to preserve

1. Shared helpers live in `scripts/lib.sh`; scripts find siblings through it.
2. `review.sh` owns advance, approval, and cap transitions. Hooks enforce the
   protocol and record pauses; they do not run checks or advance rounds.
3. An installed `round-NN-review.md` is complete and valid. Record its round in
   state before atomic installation, then apply the transition.
4. An installed review for the current round means a pending transition. Retry
   reuses that review rather than calling the backend again.
5. Write and check the next coder brief before advancing the round.
6. Configuration reads use `rl_resolve_config`; only `config.sh` writes config.
7. Usage collection remains opt-in. New timing fields must not change historical
   usage totals or count machine verification as coder work.
8. The Stop hook always emits valid JSON and aborts safely on internal errors.

## Phase 1: enforce comment accountability

### Parse once, validate consistently

Add shared helpers that extract finding headings and previous-comment status
lines into a normalized representation. Reuse them for validation, blocking
counts, unresolved-ID reporting, and eventually metrics. Preserve the documented
Markdown format and final `VERDICT:` line.

For each fresh review, `review.sh` supplies the current round and expected
historical finding IDs to the validator. Derive these IDs from finding headings
in installed earlier reviews, including Optional findings; status references do
not create new findings.

Require:

- Each historical finding has exactly one disposition in `## Previous comments`.
- Dispositions use the four documented statuses and reference existing IDs.
- New finding IDs belong to the current round, are unique, and start at C1 with
  consecutive numbering across Comments and Optional.
- Each new finding has a valid severity, explicit blocking flag, non-empty file,
  positive line number, description, and suggested fix.
- Optional findings have `blocking: no`.
- Existing section and assessment requirements still hold.

Keep the existing protection that downgrades `approved` when blocking findings
or blocking dispositions are present. Missing historical IDs are invalid output,
not implicit resolutions. A reviewer claiming `changes_requested` with only
non-blocking findings should be rejected as inconsistent output.

Validate the coder's response table before invoking the backend: every finding
introduced by the immediately preceding review needs one `fixed` or `declined`
response with a reason. Also require responses to older findings that remain
open. Continue requiring the reviewer to report every historical ID, even when
the coder did not need to answer a closed finding again.

### Failure and compatibility behavior

Invalid coder input leaves the round unchanged and names the missing or invalid
IDs. Invalid backend output follows the existing `.invalid.md` path, records a
failed reviewer attempt, and installs no final review. Do not auto-run unbounded
repair attempts.

Freeze a `protocol_version` for new loops. Missing version means legacy behavior
for already-started loops and their custom prompts. Apply strict validation to
new loops, including replacement templates, and document the requirements.
Do not retroactively invalidate installed legacy reviews on resume.

### Acceptance tests

Cover missing, duplicate, unknown, and malformed dispositions; wrong-round and
duplicate findings; missing finding fields; unresolved older blockers omitted
from a later review; Optional findings; malformed coder tables; and clean
approval with complete history. Confirm invalid output neither advances nor
installs a review, and legacy pending transitions still resume without a backend
call.

## Phase 2: improve review guidance

Revise `templates/reviewer-prompt.md` to prioritize demonstrated correctness,
security, missing required behavior, and regressions. Every blocking finding
should identify a triggering condition, explain the consequence, and cite the
code that supports it. File names or speculation alone are insufficient.

Ask the reviewer to distinguish newly introduced bugs from existing problems.
An existing problem may block when the task requires fixing it or the change
makes it reachable; explain that connection. Otherwise report it as optional
context. Group repeated instances of one bug pattern into a single actionable
finding, using the existing file/line fields for the primary example.

On later rounds, verify fixes and investigate regressions. Require an explanation
when introducing a late blocker in code unchanged since the prior review.
Do not hide a demonstrated serious bug merely to reduce the round count.

Keep the coder summary available, but label its statements as claims to verify.
Place task and inspection instructions before it in the default wrapper.
Strengthen `coder-summary.md` to request actual command results, verification
limitations, and an explicit reason for each declined finding. Clearly separate
commands executed from checks merely recommended.

Use existing configuration for a concise project-owned policy:

```bash
bash plugins/review-loop/skills/review-loop/scripts/config.sh set \
  prompts.reviewer_extra=REVIEW.md
```

The policy should list local failure modes, sensitive areas, useful checks, and
what deserves a blocking finding. Do not add automatic `REVIEW.md` discovery in
this phase or require a new output field to express every policy rule.

Keep the default cap at five during the pilot; projects can already choose
three. At the cap, recommend reconsidering the approach and summarize unresolved
IDs. Continuation stays an explicit action through `continue.sh`; it must retain
its project ownership, rollback, and session-usage guarantees.

Tests should assert rendered prompt requirements, extra-file configuration,
custom-template compatibility, and cap output. Prompt text assertions establish
delivery of instructions, not that a real model follows them.

## Phase 3: capture review inputs and focus re-review

### Snapshot contract

Introduce immutable, attempt-scoped snapshots inside the loop directory. A
snapshot identifies the actual project content submitted for review, including
uncommitted and untracked work. HEAD alone is insufficient.

Use a shared helper to enumerate tracked files and non-ignored untracked files
for Git projects. Apply the existing loop artifact exclusions. Include tracked
files even when ignore rules match them; exclude untracked ignored files.
Record relative paths, file type, executable mode, content, and symlink target.
Represent deletions through the difference between manifests.

Handle spaces, newlines, leading dashes, and Unicode in file names using
NUL-delimited enumeration and JSON encoding. Do not dereference symlinks or
modify the user's index, worktree, branches, or commits. Use private copied
content and a deterministic manifest for the initial implementation; avoid new
runtime dependencies beyond existing Bash, jq, optional Git, and standard
utilities. Compare actual content and metadata, not only size or mtime.

Capture into a temporary directory and publish it atomically only after a second
enumeration/content comparison confirms the live input still matches. Detect
another change after the reviewer returns. If it changed, reject that attempt
as stale without installing its review. This detects ordinary concurrent edits;
it does not make a live-worktree reviewer isolated from concurrent writers.
Document that limitation and require the coder to remain idle during review.

Unsupported submodule content, unreadable files, or snapshot limits must be
reported explicitly. Incremental review can fall back to the existing full
review with a recorded reason. A required verification gate cannot silently
fall back to a mode that cannot establish what it checked.

### Scope and artifacts

Proposed artifacts:

```text
snapshots/<snapshot-id>/manifest.json
snapshots/<snapshot-id>/files/...
round-02-attempt-01.json
round-02-incremental.diff
round-02-context.md
```

Round one continues to use the full task diff from the loop base. Later focused
reviews get the difference between the last installed review's snapshot and the
current snapshot, outstanding findings with original descriptions, the coder's
responses, and a compact ledger of closed IDs. Retain the full review files as
the audit trail. Keep full task-diff instructions available for context.

Git can render differences between private file trees; a normal nonzero
`git diff --no-index` result indicating differences is not a tool failure.
Snapshot differences must capture additions, deletions, modes, and symlinks;
display renames as delete/add initially. Do not rely on a textual patch as the
only representation of binary content or metadata.

Add `review.scope=full|incremental`, initially defaulting to `full`. Non-git
projects retain full-review behavior and record a fallback reason. Missing or
unreadable previous snapshots also cause a visible full-review fallback. A
failed attempt never becomes the next round's comparison baseline.

The reviewer currently cannot read loop artifacts outside quoted prompt
content. Embed focused patches/context in the prompt or explicitly allow only
the named input artifacts. Do not broadly open the loop directory to reviewers.

### Resume and retention

Store the snapshot reference, scope, and fallback reason in the round record
before installing its review. Include enough metadata in review front matter to
restore the association if a round record is missing. Never overwrite a
snapshot referenced by an installed review; retain it through continuation.

A pending installed review resumes its original transition without rerunning
the backend. Before final approval, check that the live project still matches
its reviewed snapshot. If it differs, leave the pending transition unchanged and
report the mismatch. A recovery command should archive the stale review and
round evidence, clear that round's record, and reopen the same round for fresh
review atomically; it must retain usage baselines and exclude prior machine time
from coder time. Implement and test that recovery before enabling snapshot-bound
approval. Never silently discard installed evidence or approve changed content.

### Acceptance tests

Cover edits without commits, additions, deletions, modes, symlinks, binary files,
unusual paths, ignored files, excluded loop files, failed snapshots, unsupported
submodules, stale attempts, missing baselines, and non-git fallback. Confirm the
user's index and HEAD are unchanged. Exercise write failures, resume, cap and
continue, stale-review recovery, and baseline selection after failed attempts.

## Phase 4: add optional executable verification

### Configuration and execution

Introduce these proposed keys through `config.sh` and `rl_resolve_config`:

| Key | Default | Meaning |
| --- | --- | --- |
| `verification.argv` | `[]` | One project check command as an argv array; empty disables it |
| `verification.required` | `false` | Require a successful matching check before approval |

Reject `required=true` with empty argv. Freeze the effective configuration in
state at loop start. Execute directly from the project root without `eval` or
`bash -c`. Projects needing several commands should provide a checked-in wrapper.
For this repository the argv would be `["bash", "tests/run.sh"]`.

Configured checks execute project code and have the invoking user's ordinary
permissions. Make the command visible at loop start. This is not a new sandbox
and must not broaden the reviewer backend's permissions.

Run checks before the reviewer. Capture stdout/stderr in a bounded attempt log,
and record argv, exit code, start/end times, duration, and snapshot reference in
attempt metadata. Store full local logs separately from the bounded excerpt
included in the prompt. Do not embed raw check logs in a shareable dashboard by
default; they may contain local environment details.

Compare project input before and after checks, then after review. Generated
ignored output does not invalidate the snapshot; tracked or review-visible
changes do. A mutating formatter requires a fresh snapshot and check attempt.
Do not automatically loop until the formatter stabilizes.

### Failure and caching rules

- Required check failure or execution error: keep the same round, record the
  failed attempt, and do not invoke the reviewer or install a review.
- Advisory check failure: include the result in the reviewer prompt; it is not
  a hard gate. The reviewer can still identify a blocking defect.
- Backend failure after a successful check: initially rerun checks on retry.
  Content alone cannot capture external services or environment changes, so do
  not introduce success caching in the first version.
- An installed review records the evidence it used. Resume reuses that evidence
  after checking snapshot equality, without rerunning the backend or checks.

Required verification is part of fresh review validation, before record and
install. Do not install `approved` and then attempt a check in `apply_verdict`.
Missing required evidence cannot turn into approval after a restart.

Track successful `verification_duration_s` separately from reviewer duration;
exclude all check attempts from coder time. Maintain a current-round accumulator
for failed verification and stale attempts until transition. Reset it when a
new round starts, preserve it on retry/continue as appropriate, and use the fake
clock for tests. Legacy rounds show unknown verification duration rather than
an invented zero. Preserve existing coder usage/session arithmetic.

Tests should cover pass, fail, executable missing, interruption, advisory mode,
literal argv containing shell metacharacters, changed input, failure followed by
retry, no backend call on required failure, record/install failure, resume,
duration accounting, and legacy loops with verification disabled.

## Phase 5: measure quality and add reviewer evaluations

Derive normalized findings and dispositions from the same parser used for
validation. Keep Markdown reviews as the audit source; any JSON ledger is a
rebuildable index, not a competing source of truth.

Initial metrics: rounds to approval, cap and extension rates, reviewer and check
time, optional usage, fixed findings, accepted declines, rejected declines, and
late findings on unchanged content. Use these outcomes as signals for manual
inspection. An accepted decline is not automatically a false positive, and a
coder fix is not proof that the original finding was correct.

Create an opt-in evaluation harness under `tests/evals/`. Each fixture contains
a reproducible code change, task, confirmed expected bugs or clean status, and
human rationale. Include project history where expected behavior is established
by a regression test or independently reviewed failure. Add clean examples to
detect unnecessary or harmful requested changes.

Compare baseline and candidate prompts/models using bug detection and false
positives first, then rounds, time, and cost. Record backend/model/effort,
rendered prompt, fixture revision, and available tool permissions so results can
be interpreted. Real-model evaluations require credentials and incur cost; keep
them separate from deterministic `bash tests/run.sh`. Do not make ordinary CI
call paid reviewers.

Only revisit role pipelines, finding verification agents, or risk-based model
selection when evaluated missed bugs justify their additional complexity. Such
work must still produce one validated final review per round and preserve
usage, snapshot, and resume guarantees.

## Implementation sequence and files

| Change | Main files | Completion criterion |
| --- | --- | --- |
| 1. Protocol enforcement | `scripts/lib.sh`, `scripts/review.sh`, `scripts/start.sh`, format templates, fake backend | Omitted findings cannot silently disappear; legacy resume works |
| 2. Default guidance | Reviewer/coder templates, README, optional project `REVIEW.md` | Evidence and scope expectations appear in rendered prompts |
| 3. Snapshots and focused review | `lib.sh`, `review.sh`, `start.sh`, config, status | Correct previous-round delta; stale evidence cannot approve changed code |
| 4. Verification runner | Shared helpers, lifecycle scripts, config, summaries/status | Required check must pass for the reviewed input; retries retain accounting |
| 5. Reporting and evaluation | Dashboard generator/template, summaries, `tests/evals/` | Metrics are traceable; baseline and candidate can be compared |

For new config keys, update key types, defaults, validation, provider resolution,
configuration wizard, dashboard configuration controls, README, and the
`review-config` skill together. Keep all existing flags and keys valid. New
fields in state and review front matter are additive; absent fields receive
explicit legacy behavior. Update project instructions when the invariants or
artifact layout change.

Every behavior change needs regression coverage in `tests/test_loop.sh`. Use
the fake backend and shell fixtures for ordinary tests; Node and Python sections
must retain their existing skip behavior. Never use sleep in tests: use
`touch -t`, `REVIEW_LOOP_FAKE_CLOCK`, and `REVIEW_LOOP_FAKE_TAKES`.

Run `bash tests/run.sh` before finishing each implementation change. Failure
injection should cover filesystem writes and retries, not only happy paths.

## Rollout and success criteria

Land protocol enforcement and guidance first. Enable incremental scope on this
repository as a pilot, then required verification using `bash tests/run.sh`.
Keep incremental scope and verification opt-in until their failure and recovery
paths are covered. Existing loops continue using the policy frozen at start.

Accept the implementation when:

- A historical blocker cannot disappear through omission.
- Approval refers to the input reviewed and any required checks cover that input.
- Interrupted attempts and transitions can be retried without duplicate installed
  reviews, lost findings, inflated usage, or accidental round advancement.
- Focused review includes every intervening review-visible change or explicitly
  falls back to full review.
- Evaluation shows no regression in confirmed bug detection or clean-change
  behavior before reduced review time is treated as an improvement.

Report sample sizes and individual failures during the pilot. Set numerical
quality and performance targets after collecting a baseline rather than
claiming that fewer rounds alone means better review.
