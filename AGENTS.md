# AGENTS.md — conventions for agents working on this repo

## What this is

A Claude Code plugin (`plugins/review-loop`) whose single skill folder
(`plugins/review-loop/skills/review-loop`) is also usable standalone. Bash only;
runtime deps are `jq` and optionally `git`.

## Layout

- `skills/review-loop/scripts/lib.sh` — all shared helpers (config, state, verdict parsing, finalize). Source it; never duplicate its logic.
- `scripts/start.sh | status.sh | cancel.sh` — user-facing lifecycle.
- `scripts/config.sh` — the only writer of the config files (show/create/set/unset/init/gitignore/keys); key list, types and validation live there. The `/review-config` skill asks the questions and calls it.
- Config files are provider-neutral (`rl_config_files`, `rl_provider`, `rl_resolve_config` in `lib.sh`): shared `./.review-loop.json` and `~/.config/review-loop/config.json` (top-level keys plus `providers.<name>` sections) and per-provider `./.<provider>/review-loop.json`. Never read a config path directly; always go through `rl_resolve_config`.
- `scripts/review.sh` — runs a backend and owns every state transition (round advance, approve, cap).
- `scripts/stop-hook.sh` — Claude Code Stop hook; enforcement only, no transitions.
- `scripts/resume-hook.sh` — UserPromptSubmit hook; only ends a pause (`rl_resume_pause`), never blocks.
- `scripts/backends/*.sh` — one reviewer CLI adapter each; contract in README "Backends".
- `templates/*.md` — reviewer prompt, coder brief, and the file formats both agents must follow. Both role prompts are resolved by `rl_role_prompt` (`lib.sh`): config `prompts.<role>` replaces the template, `prompts.<role>_extra` is appended as `{{EXTRA}}`; `start.sh` renders the coder brief into the loop dir, `review.sh` renders the reviewer prompt each round.
- `scripts/dashboard.sh` + `templates/dashboard.html` — static dashboard generator (defaults from config `dashboard.{dirs,out,open,auto}`; `rl_finalize` regenerates it when `auto` is on); the template gets the loop data substituted into `{{DATA}}` (with `</` escaped) and renders everything client-side with no external resources. The page is hash-routed (`RL.parseRoute`): `#/` stats and loop list, `#/loop/<id>` one loop, `#/config` the configuration page. `DATA.config` embeds `config.sh show --json` and `keys --json` for the configuration page; `--serve` runs an embedded python3 loopback server whose only write path is `config.sh set/unset` with a validated argv (no shell) and a per-run token.
- `tests/test_loop.sh` — plain-bash suite driving the scripts with the `fake` backend; the Node and serve-mode sections skip when `node` / `python3` are missing.

## Rules

- Scripts locate siblings via `lib.sh` (`RL_SCRIPTS_DIR`), never via `${CLAUDE_PLUGIN_ROOT}`; the skill must work copied into `~/.claude/skills/`.
- The Stop hook must always print valid JSON and must never leave a loop active after an internal error.
- `review.sh` installs `round-NN-review.md` only after validation and atomically (`round-NN-review.md.tmp` + rename); a review file on disk is always valid and complete (a resume still checks the body ends in a `VERDICT:` line and moves a truncated file aside). The transition (advance, approve, cap) runs after the install; a review for the *current* round therefore means a transition that failed, and the next `review.sh` run resumes it from the file instead of running the backend again. The round is recorded in `state.rounds[]` before the review is installed, so an installed review always has its record (a resume restores a missing one from the review's front matter). The next round's `coder-brief.md` is written (and checked) before the round advances.
- Usage tracking is opt-in (`state.usage`, `rl_usage_enabled`); `review.sh` exports `REVIEW_LOOP_USAGE=1` to backends only then. Backends may write `OUTPUT_FILE.usage.json` (normalized shape in `lib.sh`, `rl_normalize_usage`); `review.sh` records it per round in `state.json.rounds[]` and regenerates `usage.md`. Coder usage comes from the session transcript (`rl_transcript_usage`), deduplicated by `message.id`.
- Round timing: `start.sh` and `review.sh` (on advance) set `round_started_at/epoch` and reset `paused_s`; the Stop hook starts a pause and the UserPromptSubmit hook ends it (`rl_resume_pause`; Stop hook and `review.sh` are fallbacks); failed reviewer attempts add to `failed_review_s`; `review.sh` stores `coder_duration_s` (via `rl_round_coder_seconds`, which subtracts pauses and failed attempts) next to the reviewer's `duration_s` in `rounds[]`.
- Keep the review/coder formats machine-parseable: `### R<round>-C<n>` headings, `- blocking: yes|no`, `- R1-C2: resolved|unresolved|declined-accepted|declined-rejected`, final `VERDICT:` line.
- Any behaviour change needs a test in `tests/test_loop.sh`. Run `bash tests/run.sh` before finishing.
- Do not run `sleep` in tests; use `touch -t` to fake mtimes and `REVIEW_LOOP_FAKE_CLOCK` (a file with epoch seconds read by `rl_epoch`; the fake backend advances it by `REVIEW_LOOP_FAKE_TAKES`) to fake time.
