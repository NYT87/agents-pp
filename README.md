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
claude plugin marketplace add NYT87/agents-pp
claude plugin install review-loop@agents-pp
```

Or, from a local checkout, for one session:

```bash
claude --plugin-dir ./plugins/review-loop
```

Skills are then available as `/review-loop:review-loop`, `/review-loop:review-status`, `/review-loop:review-cancel`, `/review-loop:review-dashboard` and `/review-loop:review-config`.

### As a standalone skill (no plugin)

```bash
cp -r plugins/review-loop/skills/review-loop   ~/.claude/skills/
cp -r plugins/review-loop/skills/review-status ~/.claude/skills/
cp -r plugins/review-loop/skills/review-cancel ~/.claude/skills/
cp -r plugins/review-loop/skills/review-dashboard ~/.claude/skills/
cp -r plugins/review-loop/skills/review-config ~/.claude/skills/
```

Skills are then `/review-loop`, `/review-status`, `/review-cancel`, `/review-dashboard`, `/review-config`. In this mode the loop is driven by the skill's instructions alone. To get the same Stop-hook enforcement as the plugin, add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/review-loop/scripts/stop-hook.sh", "timeout": 30 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/review-loop/scripts/resume-hook.sh", "timeout": 10 } ] }
    ]
  }
}
```

The second hook only records when a paused loop resumes (so the coder time of a round excludes exactly the time spent waiting for you); without it, the pause is ended at the next Stop or at the next `review.sh` run, the work done since your reply is lost from the count, and the round is flagged `coder_time_underestimated`: `review.sh` warns, and status, summary and the dashboard show the value as "at least".

### Requirements

- Claude Code CLI, `jq`, and `git` (optional: non-git projects work too). `python3` only for `dashboard.sh --serve`.
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
├── state.json            loop state (round, backend, base commit, session, per-round timings, ...)
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

### Round timings

Every round records two durations in `state.json` (`rounds[]`): `coder_duration_s`, the time from the start of the round (loop start, or the previous review's end) until `review.sh` is run, with time spent paused for the user and time spent in failed reviewer attempts excluded (the plugin's `UserPromptSubmit` hook marks your reply as the end of a pause); and `duration_s`, the successful reviewer run itself. Rounds recorded before this existed show `-`. They show up in `review.sh` output ("coder 12m 30s, review 1m 24s"), `/review-status` (current round so far and all recorded rounds), `summary.md`, `usage.md`, and the dashboard (per-loop coder and review columns, a time-per-loop chart, and chips on each round).

### Verdict rules

- A review ends with `VERDICT: approved` or `VERDICT: changes_requested`.
- `approved` is only valid with zero blocking items: no `blocking: yes` comment, and no earlier comment left `unresolved` or `declined-rejected`. If the reviewer says `approved` but lists a blocking item, `review.sh` downgrades the verdict to `changes_requested`.
- Non-blocking nits go under "Optional" and never hold up approval.
- A review is only installed when it has the documented structure: a `## Comments` section, a non-empty `## Assessment`, and, for `changes_requested`, at least one comment or unresolved item. Anything else (for example a bare `VERDICT:` line) is kept as `round-NN-review.invalid.md` and the reviewer is run again.

### Usage tracking (opt-in)

Off by default. Enable it per run with `--usage`, per project or user with `"usage": true` in a config file, or with `REVIEW_LOOP_USAGE=1`. When on, every round records what each agent consumed, in `usage.md` and in `state.json` (`rounds[]`), with totals in `summary.md` and in `/review-status`:

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

### Dashboard

```
/review-dashboard
bash plugins/review-loop/skills/review-loop/scripts/dashboard.sh [--dir DIR]... [--out FILE] [--open|--no-open] [--serve [--port N]]
```

Generates a self-contained `dashboard.html` (default: inside the storage dir) from every loop folder it finds and opens it in your browser. With no arguments everything comes from the config files, so a bare `/review-dashboard` is enough:

```json
{
  "dashboard": {
    "dirs": [".review-loop", "archive/loops"],
    "out": "docs/loops.html",
    "open": true,
    "auto": false
  }
}
```

`dirs` lists the folders to scan (default: the loop dir), `out` the page to write, `open` whether to launch the browser (default true), and `auto: true` regenerates the page every time a loop ends, so it is always current without running anything.

#### Editing the configuration from the dashboard

The page has a Configuration panel showing every setting with its effective value and where it comes from (the same information as `config.sh show`). Edit values, pick where to write (project or user shared file, a provider section, or a provider file), and then:

- **Static page** (the default): the panel shows the exact `config.sh` command for your changes (copy it), or saves the file through the browser. In Chromium browsers the file picker re-reads the chosen file and merges your changes into it without touching anything else (number literals included); elsewhere only a new file can be downloaded, and existing files are edited through the command. Nothing is written until you run the command or save the file.
- **Sharing**: a static page carries only project-level configuration. Your user files (`~/.config/review-loop/config.json`, `~/.<provider>/review-loop.json`) are listed without contents, and effective values from those files or environment overrides are hidden, so the page can be committed or published; pass `--with-user-config` to embed them in a page you keep private.
- **Served page**: `dashboard.sh --serve [--port 8765]` (needs `python3`) serves the dashboard on `127.0.0.1` only and adds an Apply button that writes through `config.sh`, so all validation, masking warnings and provider rules apply, and the page reloads with fresh data. Requests must carry the per-run token embedded in the page, keys and provider names are validated before anything runs, and no shell is involved. The served page (token and user configuration included) lives in a private temp file that is deleted when the server stops; the configured output file keeps the redacted, shareable page. The server runs until Ctrl-C. Flags override the config; `REVIEW_LOOP_DASHBOARD_OPEN=0` and `REVIEW_LOOP_DASHBOARD_OUT` override it from the environment. No server, no network: the loop data is embedded in the page. It shows stat tiles (loops, approval rate, average rounds, tokens and cost when usage tracking is on), a rounds-per-loop chart with the cap marked, an output-tokens-per-loop chart split by coder and reviewer, a filterable table, and, on click, the full comment trail of a loop round by round: coder summary beside the review, verdict, blocking count, usage, and the final summary. It follows the system light/dark setting and has a theme toggle.

## Configuration

The loop can be driven by different coder providers (Claude Code today; Codex or others later), so configuration is provider-neutral. Two styles work, alone or together:

- **One shared file for every provider**, with optional per-provider overrides:
  - project: `./.review-loop.json`
  - user: `~/.config/review-loop/config.json` (`XDG_CONFIG_HOME` honoured)
  ```json
  { "backend": "codex", "max_rounds": 5,
    "providers": { "claude": { "backend": "claude", "model": "opus" }, "codex": { "max_rounds": 3 } } }
  ```
- **One file per provider**, plain keys only: `./.<provider>/review-loop.json` or `~/.<provider>/review-loop.json`, for example `.claude/review-loop.json` (which is also where earlier versions kept the config, so existing files keep working) or `.codex/review-loop.json`.

The running provider is `REVIEW_LOOP_PROVIDER` when set (`none` disables provider files and sections), otherwise `claude`, so a plain shell behaves like Claude Code and keeps reading existing `.claude/review-loop.json` files; a Codex or other provider's instructions export `REVIEW_LOOP_PROVIDER=codex`. An explicit `--provider NAME` or `--provider-file NAME` also selects whose values `config.sh show` and `init` report, so you can configure Codex from a Claude session. When you give no scope flag at all and the project's shared file does not exist yet but your provider's own project file does (a project that already has `.claude/review-loop.json`), `config.sh` edits that file and says so; every explicit flag, including `--user`, targets exactly the file it names. Whenever a value you write is masked by a higher-precedence source, it warns and names the file that sets the effective value. Precedence, highest first: flags → `REVIEW_LOOP_*` env → project provider file → project shared file (its `providers.<name>` section over its top-level keys) → user provider file → user shared file → defaults. Values are frozen into `state.json` when a loop starts. A file that is not a JSON object, or a `providers` value that is not an object, is ignored rather than breaking resolution, and a key set to `null` never overrides a value from a lower-precedence file.

The quickest way to set things up is the wizard:

```
/review-config                 # project shared file ./.review-loop.json (default)
/review-config --user          # user shared file
/review-config --provider      # the providers.<current> section of the shared file
/review-config --provider-file # a separate ./.<current>/review-loop.json
```

It shows the current value of every setting and where it comes from, asks what to change, writes the file through `config.sh`, and finally offers to add the loop's paths (storage dir, pointer file, dashboard file) to `.gitignore`. Re-run it any time to update values. The same works outside Claude Code, from your project's root (the script lives in the plugin; adjust the path to where you installed it, e.g. `~/.claude/skills/review-loop/scripts/config.sh` for the standalone skill):

```bash
CFG=plugins/review-loop/skills/review-loop/scripts/config.sh   # path inside this repo
bash $CFG show                                   # effective value, source and default per key, files found
bash $CFG create                                 # empty project file, everything inherited
bash $CFG set backend=claude model=opus max_rounds=3 usage=true
bash $CFG set --provider codex max_rounds=3      # providers.codex section of ./.review-loop.json
bash $CFG set --provider-file claude model=opus  # ./.claude/review-loop.json
bash $CFG set --user dir=reviews dashboard.auto=true
bash $CFG unset model
bash $CFG init                                   # interactive wizard: Enter keeps a value, "-" clears model/dashboard.out/dashboard.dirs
bash $CFG gitignore --dry-run                    # paths that would be ignored
bash $CFG keys                                   # all keys with types
```

With `dir` set to the project root (`.`), `gitignore` writes a pattern matching loop-id folder names (`YYYYMMDD-HHMMSS-xxxxxx`) so future loops are covered too; any other folder with that exact shape would be ignored as well.

| Setting | Flag | Env | Config key | Default |
|---|---|---|---|---|
| Reviewer backend | `--backend` | `REVIEW_LOOP_BACKEND` | `backend` | `codex` |
| Reviewer model | `--model` | `REVIEW_LOOP_MODEL` | `model` | backend default |
| Max review rounds | `--max-rounds` | `REVIEW_LOOP_MAX_ROUNDS` | `max_rounds` | `5` (1 to 9007199254740991) |
| Storage dir | `--dir` | `REVIEW_LOOP_DIR` | `dir` | `.review-loop` |
| Usage tracking | `--usage` / `--no-usage` | `REVIEW_LOOP_USAGE` | `usage` | `false` |
| Dashboard | `--dir` / `--out` / `--open` | `REVIEW_LOOP_DASHBOARD_OPEN`, `REVIEW_LOOP_DASHBOARD_OUT` | `dashboard.{dirs,out,open,auto}` | loop dir, `<dir>/dashboard.html`, `true`, `false` |

Example `~/.config/review-loop/config.json`:

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
│       │   ├── scripts/                   lib.sh, start.sh, review.sh, stop-hook.sh, resume-hook.sh, status.sh, cancel.sh, dashboard.sh, config.sh
│       │   ├── scripts/backends/          codex.sh, claude.sh, fake.sh
│       │   └── templates/                 reviewer-prompt.md, coder-summary.md, review-format.md, dashboard.html
│       ├── review-status/SKILL.md
│       ├── review-cancel/SKILL.md
│       ├── review-dashboard/SKILL.md
│       └── review-config/SKILL.md
├── tests/                                 bash test suite (fake backend)
├── AGENTS.md / CLAUDE.md                  conventions for agents working on this repo
└── README.md
```

## Development

```bash
bash tests/run.sh                          # 250+ state-machine tests, plus shellcheck when installed
claude --plugin-dir ./plugins/review-loop  # try the plugin from this checkout
```

## Roadmap

- `opencode` reviewer backend.
- More pair-programming workflows under `plugins/`.

## License

MIT
