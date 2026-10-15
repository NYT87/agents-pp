# AGENTS.md — conventions for agents working on this repo

## What this is

A Claude Code plugin (`plugins/review-loop`) whose single skill folder
(`plugins/review-loop/skills/review-loop`) is also usable standalone. Bash only;
runtime deps are `jq` and optionally `git`.

## Layout

- `skills/review-loop/scripts/lib.sh` — all shared helpers (config, state, verdict parsing, finalize). Source it; never duplicate its logic.
- `scripts/start.sh | status.sh | cancel.sh` — user-facing lifecycle.
- `scripts/review.sh` — runs a backend and owns every state transition (round advance, approve, cap).
- `scripts/stop-hook.sh` — Claude Code Stop hook; enforcement only, no transitions.
- `scripts/backends/*.sh` — one reviewer CLI adapter each; contract in README "Backends".
- `templates/*.md` — reviewer prompt and the file formats both agents must follow.
- `scripts/dashboard.sh` + `templates/dashboard.html` — static dashboard generator; the template gets the loop data substituted into `{{DATA}}` (with `</` escaped) and renders everything client-side with no external resources.
- `tests/test_loop.sh` — plain-bash suite driving the scripts with the `fake` backend.

## Rules

- Scripts locate siblings via `lib.sh` (`RL_SCRIPTS_DIR`), never via `${CLAUDE_PLUGIN_ROOT}`; the skill must work copied into `~/.claude/skills/`.
- The Stop hook must always print valid JSON and must never leave a loop active after an internal error.
- `review.sh` installs `round-NN-review.md` only after validation; a review file on disk is always valid.
- Usage tracking is opt-in (`state.usage`, `rl_usage_enabled`); `review.sh` exports `REVIEW_LOOP_USAGE=1` to backends only then. Backends may write `OUTPUT_FILE.usage.json` (normalized shape in `lib.sh`, `rl_normalize_usage`); `review.sh` records it per round in `state.json.rounds[]` and regenerates `usage.md`. Coder usage comes from the session transcript (`rl_transcript_usage`), deduplicated by `message.id`.
- Keep the review/coder formats machine-parseable: `### R<round>-C<n>` headings, `- blocking: yes|no`, `- R1-C2: resolved|unresolved|declined-accepted|declined-rejected`, final `VERDICT:` line.
- Any behaviour change needs a test in `tests/test_loop.sh`. Run `bash tests/run.sh` before finishing.
- Do not run `sleep` in tests; use `touch -t` to fake mtimes.
