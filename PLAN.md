# Plan (v2): role-based agents + stricter approval gate

## Context
Re-checked against the current working tree. Since the first plan, uncommitted work already landed the first half of the role idea (TODO.md item "configure agents for each role"):
- `prompts.{reviewer,coder}` (replace template) and `prompts.{reviewer,coder}_extra` (appended as `{{EXTRA}}`), resolved by `rl_role_prompt` / `rl_render` in `lib.sh:277-340`, stored in `state.json.prompts` by `start.sh:98-109`.
- Coder is now a real template: `templates/coder-brief.md`, rendered by `rl_coder_brief` into `<loop>/coder-brief.md` at start and at each round advance (`review.sh:82-97`); `stop-hook.sh:135` points the coder at it.
- `review.sh` has resume logic: an installed `round-NN-review.md` means the transition failed, and the next run re-applies it without calling the reviewer. The round is recorded in `state.rounds[]` before install.

So the plan now generalizes those pieces instead of adding new mechanisms. Remaining goals:
1. More roles (security, qa, architect, verifier), each with its own prompt and optionally backend/model/reasoning (also covers TODO "select different models and reasoning for an agent").
2. "Reviewer approved but a direct Codex review still finds issues". Causes (unchanged, still present in `reviewer-prompt.md`): "Do not block on style... say so briefly and approve; do not invent findings"; coder summary shown before the reviewer forms its own view; codex backend defaults to `-s read-only` so tests can't run (`backends/codex.sh:30`) and uses generic `codex exec`, not `codex review`; `review-format.md` allows `approved` with medium/low `blocking: no` items that are never fed back; single pass.

The external repo (engineering-team skills) shape we borrow: one role = persona + checklist + severity thresholds + verdict rule. Not its Python tooling.

## Design
### Role templates (reuse `rl_role_prompt`)
- Add `templates/roles/{security,qa,architect,verifier}.md` (focus section only). Keep `reviewer-prompt.md` as the shared wrapper (task, diff, previous reviews, format) and add `{{ROLE_FOCUS}}`; the default `reviewer` focus is the current "What to check" list. Coder stays `coder-brief.md`.
- Generalize prompt keys from a fixed set to `prompts.<role>` and `prompts.<role>_extra` for any role in the known list. Change `rl_role_prompt` callers, the `defaults` JSON (`lib.sh:236`), `start.sh:109` (build PROMPTS map from the role list instead of 4 hardcoded fields), `config.sh` KEYS/type/help (`config.sh:46-73`). Existing 4 keys keep working unchanged.
- Order change in the wrapper: task + diff instructions first, coder summary last, labelled "claims, unverified".

### Reviewer pipeline
- New config: `reviewers` (list, default `["reviewer"]`; roles run in order, `verifier` always last) and per-role `roles.<role>.{backend,model,reasoning}` overriding the global values (state.json gets a resolved copy at start like `prompts`). `reasoning` is passed to codex as `-c model_reasoning_effort=<v>` and to claude as its effort flag; empty = backend default.
- `review.sh`: loop over roles; each run builds its prompt, calls the backend, validates (`rl_parse_verdict`, `rl_validate_review`) and keeps `round-NN-review.<role>.md` as an intermediate. On a re-run, an existing validated per-role file is reused (no repeat reviewer cost after a mid-pipeline failure). Then `rl_merge_reviews` produces one review: comments renumbered `R<round>-C<n>` with a `role:` field, `blocking` count = sum, verdict `approved` only if all roles approved. Only the merged file is installed as `round-NN-review.md`, preserving the invariants in CLAUDE.md (valid-on-disk, record-before-install, resume-from-installed). Per-role duration/usage go in `rounds[].reviewers[]` (keep `duration_s`/`reviewer` as totals so the dashboard/status keep working).
- `verifier` runs only if every earlier role approved; failed/invalid role attempts count toward `failed_review_s` as today.

### Native Codex gate
- Key `native_gate` (bool, default false). When on and the backend is codex, before the verifier `review.sh` runs `codex review --base $BASE_REF` (read-only), captures the raw output, and injects it as `{{NATIVE_REVIEW}}` into the verifier prompt; the verifier must triage each native finding into formatted comments (blocking when real). Free-form output never touches the parsers. Fail-soft: log and continue if `codex review` errors. Step 0 of implementation: check `codex review --help` for the real flags.

### Prompt/sandbox fixes (default reviewer behaviour)
- Replace "do not invent findings" with "every finding needs file:line + evidence; speculation goes under Optional". Rule: correctness/security/missing-test/regression findings of severity medium+ are `blocking: yes`; only low/style is non-blocking.
- Require a non-empty `## Checked` section (commands run, files read) before `approved`; enforce in `rl_validate_review`; add to `review-format.md`.
- `qa` and `verifier` roles get `-s workspace-write` for codex (per-role flag env into the backend) and a test-runner Bash allowlist for claude (`backends/claude.sh:26-32`), so tests actually run; other roles stay read-only.

## Files
Under `plugins/review-loop/skills/review-loop/`: `templates/roles/*.md` (new), `templates/reviewer-prompt.md`, `templates/review-format.md`, `scripts/review.sh` (pipeline, native gate), `scripts/lib.sh` (`rl_role_prompt` generalization, `rl_merge_reviews`, validator, config defaults/env, `rl_config_source`), `scripts/config.sh` (new keys + usage block), `scripts/start.sh` (resolve roles/prompts into state; banner), `scripts/backends/{codex,claude}.sh` (reasoning + per-role flags), `scripts/status.sh`, `scripts/dashboard.sh` + `templates/dashboard.html` (role tag per comment, per-role timings; config page lists new keys), `SKILL.md`, `skills/review-config/SKILL.md` (ask about reviewers), `README.md`, `CLAUDE.md`/`AGENTS.md` (layout + rules: pipeline invariants), `TODO.md` (tick items).
Caveat: the tree has many uncommitted changes in these same files (prompts feature, status/stop-hook edits). Build on them as-is; suggest committing the prompts work first so this lands as a clean diff.

## Verification
- New cases in `tests/test_loop.sh` (fake backend; no `sleep`; a fake `codex` shim on PATH for the gate): role prompt rendering incl. `prompts.<role>`/`_extra` for new roles in `round-NN-prompt.md`; multi-role pipeline writes per-role intermediates and one merged review with renumbered IDs and role tags; any role `changes_requested` => merged `changes_requested`, blocking summed; verifier skipped when an earlier role requests changes; mid-pipeline failure then re-run reuses completed roles (backend call count) and resume-from-installed still works; per-role backend/model/reasoning reach the backend env; `approved` without `## Checked` is rejected; native gate injects `{{NATIVE_REVIEW}}` and fails soft; new config keys (update hardcoded key counts and clearable counts in the existing key tests; dashboard config test).
- `bash tests/run.sh` passes.
- Manual: loop on a small change with `reviewers=["reviewer","security","verifier"]`, `native_gate=true` on codex; compare findings with a direct `codex review`.
