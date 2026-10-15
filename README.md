# agents-pp — Agents Pair Programming

**Two agents, one task: one codes, the other reviews, until the reviewer has no comments left.**

`agents-pp` is a collection of pair-programming workflows for coding agents. The first one, **review-loop**, is a Claude Code **skill + plugin** that turns any task into a coder/reviewer loop:

1. Claude (the **coder**) implements the task.
2. An independent **reviewer**, a separate CLI agent (Codex, Claude, ...), reads the diff and writes comments with a verdict.
3. The coder answers every comment, by ID: fixes it or declines it with a reason, then resubmits.
4. Repeat until the reviewer **approves** with no blocking comments, the round cap is reached, or you cancel.

Every round is written to disk, so each agent reads the other's output from a file and you can audit the whole conversation afterwards. Inspired by [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop); this version is multi-round, backend-agnostic, and keeps the comments.

```
 coder (Claude)                 reviewer (Codex / Claude / ...)
 ──────────────                 ───────────────────────────────
 implement task
 write round-01-coder.md  ───▶  read diff + summary
                          ◀───  round-01-review.md  (R1-C1, R1-C2, ... VERDICT: changes_requested)
 fix / decline each ID
 write round-02-coder.md  ───▶  verify each R1-Cn, add R2-Cn
                          ◀───  round-02-review.md  (VERDICT: approved)
 report to the user
```

## Installation

### As a plugin (recommended: adds Stop-hook enforcement)

```bash
claude plugin marketplace add nyt87/agents-pp
claude plugin install review-loop@agents-pp
```

Or, from a local checkout, for one session:

```bash
claude --plugin-dir ./plugins/review-loop
```

Skills are then available as `/review-loop:review-loop`, `/review-loop:review-status` and `/review-loop:review-cancel`.

### As a standalone skill (no plugin)

```bash
cp -r plugins/review-loop/skills/review-loop   ~/.claude/skills/
cp -r plugins/review-loop/skills/review-status ~/.claude/skills/
cp -r plugins/review-loop/skills/review-cancel ~/.claude/skills/
```

Skills are then `/review-loop`, `/review-status`, `/review-cancel`. In this mode the loop is driven by the skill's instructions alone. To get the same Stop-hook enforcement as the plugin, add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/review-loop/scripts/stop-hook.sh", "timeout": 30 } ] }
    ]
  }
}
```

### Requirements

- Claude Code CLI, `jq`, and `git` (optional: non-git projects work too).
- A reviewer CLI: [Codex](https://github.com/openai/codex) (`npm install -g @openai/codex`) for the default backend, or Claude Code itself for `--backend claude`.

## Usage

```
/review-loop Add a divide() function with ValueError on zero, plus tests
/review-loop Refactor the auth middleware --backend claude --model opus --max-rounds 3 --usage
/review-status
/review-cancel
```

What happens:

1. `start.sh` creates `.review-loop/<loop-id>/` with `task.md` and `state.json`, and a pointer at `.claude/review-loop.active`.
2. Claude implements the task, writes `round-01-coder.md` and runs `review.sh`.
3. `review.sh` renders the reviewer prompt, runs the backend, validates the verdict and installs `round-01-review.md`. On `changes_requested` it advances to the next round and tells Claude what to do; on `approved`, or at the cap, it writes `summary.md` and ends the loop.
4. If Claude tries to stop while the loop is active, the Stop hook blocks and repeats the instructions. Claude can pause for a genuine question by ending its message with `REVIEW-LOOP: PAUSE`.

### The comment trail

```
.review-loop/20261015-143000-a1b2c3/
├── task.md               the task
├── state.json            loop state (round, backend, base commit, session, ...)
├── round-01-coder.md     coder: what changed, files, how it was verified
├── round-01-prompt.md    the exact prompt the reviewer received
├── round-01-review.md    reviewer: comments R1-C1.. (severity, blocking, file, line, fix) + verdict
├── round-02-coder.md     coder: fixes, plus a table answering every R1-Cn (fixed / declined: reason)
├── round-02-review.md    reviewer: status of every R1-Cn, new R2-Cn comments, verdict
├── summary.md            outcome, rounds, unresolved comment IDs (+ usage totals when enabled)
├── usage.md              tokens, cost and duration per round and agent (only with --usage)
└── loop.log
```

Add `.review-loop/` and `.claude/review-loop.active` to `.gitignore` if you do not want to commit the trail, or pass `--git-exclude` to exclude them locally. The loop's own files are always hidden from the diff the reviewer and the Stop hook look at; with `--dir .` only the loop folders stored at the root are hidden, never the project.

### Verdict rules

- A review ends with `VERDICT: approved` or `VERDICT: changes_requested`.
- `approved` is only valid with zero blocking items: no `blocking: yes` comment, and no earlier comment left `unresolved` or `declined-rejected`. If the reviewer says `approved` but lists a blocking item, `review.sh` downgrades the verdict to `changes_requested`.
- Non-blocking nits go under "Optional" and never hold up approval.
- A review is only installed when it has the documented structure: a `## Comments` section, a non-empty `## Assessment`, and, for `changes_requested`, at least one comment or unresolved item. Anything else (for example a bare `VERDICT:` line) is kept as `round-NN-review.invalid.md` and the reviewer is run again.

### Usage tracking (opt-in)

Off by default. Enable it per run with `--usage`, per project or user with `"usage": true` in the config file, or with `REVIEW_LOOP_USAGE=1`. When on, every round records what each agent consumed, in `usage.md` and in `state.json` (`rounds[]`), with totals in `summary.md` and in `/review-status`:

| Round / agent | Model | Input (uncached) | Cached input | Cache write | Output | Reasoning | Cost USD | Turns | Duration s |
|---|---|---|---|---|---|---|---|---|---|
| round 1 reviewer | gpt-6-sol | 10612 | 96896 | 0 | 1396 | 262 | - | 1 | 26 |
| round 1 coder | claude-fable-5-1 | 145 | 499973 | 33672 | 4822 | 895 | - | 19 | - |
| TOTAL reviewer | ... | | | | | | | | |

Where the numbers come from:

- **Codex reviewer**: the `turn.completed` events of `codex exec --json` (tokens only; Codex does not report cost).
- **Claude reviewer**: the result envelope of `claude -p --output-format json` (tokens and `total_cost_usd`).
- **Coder** (your Claude Code session): the session transcript (`~/.claude/projects/<project>/<session>.jsonl`), summing assistant messages since the loop started, deduplicated by message id. The Stop hook passes the transcript path; without the hook the skill passes `${CLAUDE_SESSION_ID}` to `start.sh` so the transcript is found by session id. The coder numbers cover everything the session did during the loop, not only this task.

Backends report usage through an optional sidecar file (see "Reviewer backends"), only when `REVIEW_LOOP_USAGE=1` is set by `review.sh`. A backend without one records zeros. When tracking is off, nothing reads transcripts or sidecars and the Codex backend runs in its plain streaming mode.

## Configuration

| Setting | Flag | Env | Config key | Default |
|---|---|---|---|---|
| Reviewer backend | `--backend` | `REVIEW_LOOP_BACKEND` | `backend` | `codex` |
| Reviewer model | `--model` | `REVIEW_LOOP_MODEL` | `model` | backend default |
| Max review rounds | `--max-rounds` | `REVIEW_LOOP_MAX_ROUNDS` | `max_rounds` | `5` |
| Storage dir | `--dir` | `REVIEW_LOOP_DIR` | `dir` | `.review-loop` |
| Usage tracking | `--usage` / `--no-usage` | `REVIEW_LOOP_USAGE` | `usage` | `false` |

Precedence (highest first): flags → env → `./.claude/review-loop.json` → `~/.claude/review-loop.json` → defaults. Values are frozen into `state.json` when a loop starts.

Example `~/.claude/review-loop.json`:

```json
{ "backend": "claude", "model": "opus", "max_rounds": 3, "dir": "docs/reviews", "usage": true }
```

Backend-specific flags:

| Env | Default | Notes |
|---|---|---|
| `REVIEW_LOOP_CODEX_FLAGS` | `-s read-only --ephemeral` | Replaces the default, so include a sandbox flag. `-s workspace-write` lets the reviewer run tests. |
| `REVIEW_LOOP_CLAUDE_FLAGS` | (empty) | Appended to the `claude -p` command line. |

## Reviewer backends

A backend is a script `scripts/backends/<name>.sh PROMPT_FILE OUTPUT_FILE` that:

1. runs a reviewer CLI in the current directory (the project root), feeding it the prompt from `PROMPT_FILE` via stdin or file, never argv;
2. writes the agent's **final message** to `OUTPUT_FILE`, using a temp file and `mv` so partial output is never installed;
3. exits non-zero on failure, in which case nothing is installed and `review.sh` asks for a rerun;
4. when `REVIEW_LOOP_USAGE=1`, optionally writes `OUTPUT_FILE.usage.json` with `{model, input_tokens (uncached), cached_input_tokens, cache_write_tokens, output_tokens, reasoning_tokens, cost_usd|null, num_turns|null}`; missing fields default to zero.

Environment available to backends: `REVIEW_LOOP_MODEL`, `REVIEW_LOOP_ROUND`, `REVIEW_LOOP_LOOP_DIR`, `REVIEW_LOOP_ROOT`, and `REVIEW_LOOP_NESTED=1` (so a nested Claude session does not trigger the Stop hook).

Shipped backends:

| Backend | Command | Notes |
|---|---|---|
| `codex` (default) | `codex exec -s read-only --ephemeral --skip-git-repo-check -o <out> -` | Verified with codex-cli 0.162. With usage tracking on it adds `--json` and turns the events into progress lines and token usage. |
| `claude` | `claude -p --output-format json --setting-sources user --disable-slash-commands --no-session-persistence --permission-mode dontAsk --allowedTools "Read,Glob,Grep,Bash(git diff*),..."` | Verified with Claude Code 2.1.292. Pick a stronger reviewer with `--model`. |
| `fake` | deterministic verdicts | Used by the test suite. |

To add one (OpenCode, for example), copy `claude.sh`, adapt the command, and select it with `--backend opencode`.

## Permissions

The skill pre-approves `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)`. If Claude Code still prompts for `review.sh` each round, add to your project's `.claude/settings.json`:

```json
{ "permissions": { "allow": [ "Bash(bash */review-loop/scripts/*)" ] } }
```

## How the Stop hook works

`scripts/stop-hook.sh` runs every time Claude wants to stop:

- No pointer file, inactive loop, a different session, or `REVIEW_LOOP_NESTED=1` → allow.
- Active loop with no changes in the project → block: "implement the task first".
- Active loop with changes → block: "write the coder summary, run `review.sh`, follow its output".
- `REVIEW-LOOP: PAUSE` in Claude's last message → allow once, resume on the next turn.
- Four consecutive stops without a successful review → abort the loop visibly (`summary.md` plus a system message).
- Any internal error → abort the loop and say so. It never traps you.

State transitions (round advance, approval, cap) live in `review.sh`, so the loop behaves the same with or without the hook. The hook never runs the reviewer itself; Claude runs `review.sh` through its Bash tool so the backend's output is visible.

## Repository layout

```
agents-pp/
├── .claude-plugin/marketplace.json        marketplace "agents-pp"
├── plugins/review-loop/
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json                   Stop hook registration
│   └── skills/
│       ├── review-loop/                   self-contained skill (copy this dir for standalone use)
│       │   ├── SKILL.md
│       │   ├── scripts/                   lib.sh, start.sh, review.sh, stop-hook.sh, status.sh, cancel.sh
│       │   ├── scripts/backends/          codex.sh, claude.sh, fake.sh
│       │   └── templates/                 reviewer-prompt.md, coder-summary.md, review-format.md
│       ├── review-status/SKILL.md
│       └── review-cancel/SKILL.md
├── tests/                                 bash test suite (fake backend)
├── AGENTS.md / CLAUDE.md                  conventions for agents working on this repo
└── README.md
```

## Development

```bash
bash tests/run.sh                          # 150+ state-machine tests, plus shellcheck when installed
claude --plugin-dir ./plugins/review-loop  # try the plugin from this checkout
```

## Roadmap

- `opencode` reviewer backend.
- More pair-programming workflows under `plugins/`.

## License

MIT
