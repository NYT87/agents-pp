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

Skills are then available as `/review-loop:review-loop`, `/review-loop:review-status`, `/review-loop:review-cancel`, `/review-loop:review-continue`, `/review-loop:review-dashboard` and `/review-loop:review-config`.

### As a standalone skill (no plugin)

```bash
cp -r plugins/review-loop/skills/review-loop   ~/.claude/skills/
cp -r plugins/review-loop/skills/review-status ~/.claude/skills/
cp -r plugins/review-loop/skills/review-cancel ~/.claude/skills/
cp -r plugins/review-loop/skills/review-continue ~/.claude/skills/
cp -r plugins/review-loop/skills/review-dashboard ~/.claude/skills/
cp -r plugins/review-loop/skills/review-config ~/.claude/skills/
```

Skills are then `/review-loop`, `/review-status`, `/review-cancel`, `/review-continue`, `/review-dashboard`, `/review-config`. In this mode the loop is driven by the skill's instructions alone. To get the same Stop-hook enforcement as the plugin, add to `~/.claude/settings.json`:

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
/review-loop Refactor the auth middleware --backend claude --model opus --effort high --max-rounds 3 --usage
/review-status
/review-cancel
/review-continue 2          # the loop hit its cap: allow 2 more rounds and carry on
```

What happens:

1. `start.sh` creates `.review-loop/<loop-id>/` with `task.md` and `state.json`, and a pointer at `.claude/review-loop.active`.
2. Claude implements the task, writes `round-01-coder.md` and runs `review.sh`.
3. `review.sh` renders the reviewer prompt, runs the backend, validates the verdict and installs `round-01-review.md`. On `changes_requested` it advances to the next round and tells Claude what to do; on `approved`, or at the cap, it writes `summary.md` and ends the loop.
4. If Claude tries to stop while the loop is active, the Stop hook blocks and repeats the instructions. Claude can pause for a genuine question by ending its message with `REVIEW-LOOP: PAUSE`.
5. If the cap is reached without approval, `/review-continue [N]` (`continue.sh [N | --rounds N] [--loop ID]`) re-opens the loop where it stopped with N more rounds (default 1): the pointer comes back, `max_rounds` grows, the summary written at the cap is kept as `summary.before-extension-K.md`, and `review.sh` resumes from the last review — the reviewer is not run again — so the next round starts with that review's comments to address. The extension is recorded in `state.json` (`extensions[]`), shown by `/review-status`, the loop page and the final summary. Continuing from a different Claude Code session (the skill passes `--session`) keeps the coder usage right per session: each session's total so far is stored (`state.sessions[]`), the new rounds are measured on the new session's transcript, and returning to an earlier session counts only what it did since — so per-round numbers and the coder total never double count. Only a loop that ran out of rounds can be continued, only from the project it was started in (a storage dir can be shared by several projects), and not while another loop is active; if the pointer or the state cannot be written, the loop is left at its cap for a retry.

### The comment trail

```
.review-loop/20261015-143000-a1b2c3/
├── task.md               the task
├── coder-brief.md        the coder's instructions (template + configured extras)
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

### Role prompts: extend or replace what each agent is told

Each round's reviewer prompt is rendered from `templates/reviewer-prompt.md` (saved as `round-NN-prompt.md`), and the coder gets a brief rendered from `templates/coder-brief.md` (saved as `coder-brief.md` in the loop folder and printed by `start.sh`). Both can be extended with project instructions or replaced entirely, per project or per user, through four config keys holding file paths (absolute, `~/...`, or relative to the project root):

| Key | Effect |
|---|---|
| `prompts.reviewer_extra` | file appended to the reviewer prompt under "Additional instructions for the reviewer" |
| `prompts.coder_extra` | file appended to the coder brief under "Additional instructions for the coder" |
| `prompts.reviewer` | file that replaces the reviewer template; same `{{placeholders}}`: `TASK`, `ROUND`, `MAX_ROUNDS`, `CODER_SUMMARY`, `PREVIOUS_REVIEWS`, `DIFF_INSTRUCTIONS`, `REVIEW_FORMAT`, `LOOP_DIR`, `ROOT`, `BACKEND`, `EXTRA` |
| `prompts.coder` | file that replaces the coder brief template; placeholders `TASK`, `LOOP_ID`, `LOOP_DIR`, `SCRIPTS`, `TEMPLATES`, `BACKEND`, `MAX_ROUNDS`, `ROOT`, `EXTRA` |

```bash
bash $CFG set prompts.reviewer_extra=docs/review-guidelines.md prompts.coder_extra=docs/coding-conventions.md
/review-loop add the export endpoint --reviewer-extra docs/security-checklist.md   # per run
```

A replacement reviewer template must still end with the required output format (`{{REVIEW_FORMAT}}`) so verdicts stay machine-parseable; if a replacement template has no `{{EXTRA}}`, configured extras are appended at the end anyway. Paths are frozen into `state.json` when the loop starts and the files are read at each use, so edits apply to the next round: the reviewer prompt is built each round, and `coder-brief.md` is re-rendered whenever `review.sh` advances to a new round (its output tells the coder to re-read it). A missing or unreadable file stops `start.sh` (before it creates or cancels anything) or `review.sh` with a message naming the key. For the reviewer's files that happens before the reviewer runs; the coder's files are only needed when a new round starts, so a missing one never blocks an approval or the final round: `review.sh` keeps the review on disk and leaves the round where it is; the coder fixes the file and runs it again, and that run resumes from the installed review (verdict and comments unchanged) without calling the reviewer a second time.

### Role presets: focus an agent on a speciality

`templates/roles/` ships ready-made role presets, short focus instructions
adapted (MIT) from the Core Engineering and Development Tools skills of
[alirezarezvani/claude-skills](https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team):

| Group | Presets |
|---|---|
| Core Engineering | `senior-architect`, `senior-frontend`, `senior-backend`, `senior-fullstack`, `senior-qa`, `senior-devops`, `senior-secops`, `code-reviewer`, `senior-security` |
| Development Tools | `tdd-guide`, `tech-stack-evaluator` |

Each one works for either agent: the coder builds to the standards and the
reviewer checks them. Pick any number per role with `roles.reviewer` and
`roles.coder` (comma-separated names), or per run with `--reviewer-roles` /
`--coder-roles` (an empty value means none, even when the config sets some).

By default the reviewer runs with `code-reviewer`, `senior-qa` and
`senior-security` (a general review checklist, test coverage of the risky paths,
and a quick threat model of the change), and the coder with `senior-architect`,
`tech-stack-evaluator`, `senior-security`, `senior-backend` and `senior-secops`
(design trade-offs, justified dependencies, secure backend code). Set a key to an empty list
(`roles.coder=`) to turn its defaults off, or `unset` it to get them back.

```bash
bash $CFG roles                                   # list the presets
bash $CFG set roles.reviewer=code-reviewer,senior-security roles.coder=senior-backend,tdd-guide
/review-loop add the export endpoint --reviewer-roles senior-secops   # per run
```

Each preset is rendered into `{{EXTRA}}` as a "Role focus: <title>" section,
before any `prompts.*_extra` file, so it also reaches a replacement template
(appended when the template has no `{{EXTRA}}`). The names are validated by
`config.sh` and `start.sh` and frozen into `state.json` (`roles`) when the loop
starts; the dashboard's configuration page offers them as checkboxes on each
role card, saved automatically on every change like the other settings (on a
`--serve` page right away; on a static page once auto-save is enabled for the
config file). To add your own preset, drop a `<name>.md` file with `title`,
`summary`, `group` and `source` front matter into `templates/roles/`.

### Verdict rules

New loops freeze `protocol_version: 2` in state. They validate unique consecutive
finding IDs, required finding fields, and exactly one disposition for every
earlier finding, including Optional items. Missing, unknown or duplicate IDs and
invalid statuses cannot silently clear a blocker. `changes_requested` needs a
blocking finding or unresolved earlier ID, and the review must finish with its
`VERDICT:` line. Fenced examples do not count as findings or blocking items.

Before spending a reviewer call, the loop also validates the coder's response
table: one `fixed` or `declined` row, with an explanation, for every finding
introduced in the preceding review and every older unresolved or
declined-rejected ID. Fix invalid summaries and rerun the same round; invalid
reviewer output is retained as `.invalid.md` without installing a review or
advancing. These checks enforce accountability and structure; the reviewer still
judges whether a fix or decline is correct.

Existing loops without a protocol version (or with version 1) retain legacy
validation, including when continued. Pending installed reviews resume their
transition without requiring a coder summary or invoking the reviewer again.
Replacement prompts for new loops must follow the same strict format.

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
bash plugins/review-loop/skills/review-loop/scripts/dashboard.sh [--dir DIR]... [--out FILE] [--open|--no-open] [--serve [--port N]] [--share]
```

Generates a self-contained `dashboard.html` (default: inside the storage dir) from every loop folder it finds and opens it in your browser. The page has four views, each with its own link: the main page (`#/`) with the stat tiles, the charts and the list of loops; a "Start a loop" page (`#/start`, header button); a loop page (`#/loop/<loop-id>`) opened by clicking a row, showing only that loop's rounds, comments and summary; and the configuration page (`#/config`), reached from the header button. With no arguments everything comes from the config files, so a bare `/review-dashboard` is enough:

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

Model and effort are dropdowns on both Configuration and Start a loop. Effort
choices follow the selected model; an existing unlisted value stays visible as
"not listed". On a served page, **Refresh available options** re-reads the
backend catalogs, saves them beside the selected config, and updates both forms without clearing pending edits. Codex
options come from its CLI model cache: if that cache is missing, run Codex once
and refresh. The button does not launch or authenticate a CLI.

On a static page, **Copy catalog command** provides the command to export the
selected backend's options beside the configuration file as
`review-loop-models.<backend>.json`. Regenerating the page reads saved catalogs
automatically; **Load model catalog…** can also load the saved JSON or an updated
dashboard HTML file immediately. A static browser page cannot execute local CLI commands. When no
catalog is available, the dropdowns retain the backend default and any current
value. Custom names can still be set through `config.sh` or CLI flags.

The Configuration page (header button, or `#/config`) shows every setting with its effective value and where it comes from (the same information as `config.sh show`), in three groups: **Loop**, **Dashboard** and **Agent roles**. The roles group has one card per agent (reviewer, coder) saying what it runs with — the default template or the configured replacement, plus the extra file appended to it — and flags a configured file that is missing or unreadable (the loop would not start). Each card unfolds the default template with the `{{placeholders}}` a replacement may use. A loop's page shows which prompts that loop ran with (they are frozen in its `state.json`). Edit values, pick where to write (project or user shared file, a provider section, or a provider file), and then:

- **Static page** (the default): the panel shows the exact `config.sh` command for your changes (copy it), or saves the file through the browser. In Chromium browsers the file picker re-reads the chosen file and merges your changes into it without touching anything else (number literals included); elsewhere only a new file can be downloaded, and existing files are edited through the command. Use **Enable auto-save…** to choose the configuration file once; subsequent valid edits save automatically, merging into its current contents each time. Browsers without file access retain the download and command options.
- **Sharing**: a static page carries only project-level configuration. Your user files (`~/.config/review-loop/config.json`, `~/.<provider>/review-loop.json`) are listed without contents, effective values from those files or environment overrides are hidden, and so are the backends' default model and effort (they come from your own tool configuration, e.g. `~/.codex/config.toml`; the model lists themselves stay), so the page can be committed or published; pass `--with-user-config` to embed them in a page you keep private.
- **Sending a review to someone else**: `dashboard.sh --share --out review.html` writes a read-only page for a teammate.
  - **Removed:** the Start and Configuration pages, the configuration itself, absolute paths (the project is named by its folder, and loop folders are project-relative), session ids and transcript paths.
  - **Kept:** the record: tasks, rounds, comments, verdicts and usage.
  - **Added:** each loop page opens with a short primer on how to read the exchange.
  - **Not allowed:** `--share` cannot be combined with `--serve` or `--with-user-config`.
  - **Paths in the agents' text:** in the round files and the summary, the project root becomes relative and your home directory `~`; everything else is embedded as written.
- **Where values come from**: the Configuration page starts simple, showing each value, its help line and the role presets. **Show where values come from** reveals the precedence detail: the source of each value, what this file holds, the per-field write and unset buttons, and the **Save to** file picker. The choice is remembered in that browser, and the detail always shows when the page targets a file other than the project shared one. Masking warnings appear after every save either way.
- **Starting a loop from the page**: the "Start a loop" page (header button, or `#/start`) takes the task and the backend, model, effort, max rounds and usage (prefilled from the configuration; model and effort offered from the backend's catalog). Only what differs from the configuration is passed to `start.sh` (choosing "backend default" for a configured model or effort is passed as an explicit empty flag, which overrides the configuration). On a served page the Start button creates the loop through `start.sh` (`/api/start`, validated fields, the task passed after `--`, no shell) and then says what comes next — open Claude Code in the project and send any message; the Stop hook holds that session to the task until the reviewer approves — before opening the new loop's page. A static page gives the same request as a `/review-loop …` line to paste into Claude Code in the project (its main action, **Copy for Claude Code**), with the equivalent `start.sh` command under "Or run it in a terminal". An active loop of this project must be cancelled first, as on the command line (another project's loop in a shared storage dir does not block it).
- **Served page**: `dashboard.sh --serve [--port 8765]` (needs `python3`) serves the dashboard on `127.0.0.1` only and automatically saves valid configuration edits through `config.sh`, so validation, masking warnings and provider rules apply. Saves are debounced and serialized, show saving/saved/error status, and preserve newer edits without reloading the page; **Save now / retry** retries a failed save. Requests (`/api/config`, `/api/start`, `/api/models`) must carry the per-run token embedded in the page, keys, provider and backend names are validated before anything runs, and no shell is involved. The served page (token and user configuration included) lives in a private temp file that is deleted when the server stops; the configured output file keeps the redacted, shareable page. The server runs until Ctrl-C. Flags override the config; `REVIEW_LOOP_DASHBOARD_OPEN=0` and `REVIEW_LOOP_DASHBOARD_OUT` override it from the environment. No server, no network: the loop data is embedded in the page. The main page shows stat tiles (loops, approval rate, average rounds, tokens and cost when usage tracking is on), a rounds-per-loop chart with the cap marked, time and output-token charts split by coder and reviewer, and a filterable table. A loop's page shows its full comment trail round by round: coder summary beside the review, verdict, blocking count, usage, and the final summary. It follows the system light/dark setting and has a theme toggle.

The local request and response contract is documented in [Dashboard API](docs/dashboard-api.md).

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
bash $CFG set backend=claude model=opus effort=high max_rounds=3 usage=true
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
| Reviewer model | `--model` | `REVIEW_LOOP_MODEL` | `model` | backend default (list: `config.sh models`; `--model ""` forces the backend default over a configured one) |
| Reviewer effort | `--effort` | `REVIEW_LOOP_EFFORT` | `effort` | backend default (one of the chosen model's listed levels) |
| Max review rounds | `--max-rounds` | `REVIEW_LOOP_MAX_ROUNDS` | `max_rounds` | `5` (1 to 9007199254740991) |
| Storage dir | `--dir` | `REVIEW_LOOP_DIR` | `dir` | `.review-loop` |
| Usage tracking | `--usage` / `--no-usage` | `REVIEW_LOOP_USAGE` | `usage` | `false` |
| Role prompts | `--reviewer-prompt` / `--reviewer-extra` / `--coder-prompt` / `--coder-extra` | | `prompts.{reviewer,reviewer_extra,coder,coder_extra}` | templates in `templates/` |
| Role presets | `--reviewer-roles` / `--coder-roles` | | `roles.{reviewer,coder}` | reviewer `code-reviewer,senior-qa,senior-security`, coder `senior-architect,tech-stack-evaluator,senior-security,senior-backend,senior-secops` (list: `config.sh roles`) |
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

Environment available to backends: `REVIEW_LOOP_MODEL`, `REVIEW_LOOP_EFFORT`, `REVIEW_LOOP_ROUND`, `REVIEW_LOOP_LOOP_DIR`, `REVIEW_LOOP_ROOT`, and `REVIEW_LOOP_NESTED=1` (so a nested Claude session does not trigger the Stop hook).

5. optionally answers `<name>.sh --models` with its catalog as JSON: `{models: [{id, label, efforts, default_effort, default}], efforts, default_model, default_effort, source, note}`. `config.sh models [--backend NAME]`, the `/review-config` wizard and the dashboard's configuration page use it to offer models and efforts; an `effort` is validated against the chosen model's `efforts` when that model is listed (its list taken as is: an empty one means that model's capabilities are unknown and any value is accepted), else against the backend-wide `efforts` (an empty one likewise accepts anything), `model` values outside `models` only get a note. A backend without `--models` simply offers no list.

### Models and effort

```
bash $CFG models                    # refresh and save beside the active configuration
bash $CFG models --backend claude   # refresh another backend
bash $CFG models --user            # save beside the user shared config
bash $CFG models --json --no-save  # read-only JSON, no catalog file written
bash $CFG set model=gpt-6.1-sol effort=high
/review-loop ... --model opus --effort xhigh
```

`codex` reads the model list Codex itself fetched (`~/.codex/models_cache.json`: listed models in Codex's order, their reasoning levels, and the `model` / `model_reasoning_effort` defaults from `~/.codex/config.toml`); the effort is passed as `-c model_reasoning_effort="…"`. `claude` offers the aliases Claude Code documents (`fable`, `opus`, `sonnet`, `haiku`) and the current full names, with efforts `low`…`max`, passed as `--effort`. The chosen model and effort are frozen in the loop's `state.json` and shown by `/review-status`, the review files' front matter and the dashboard.

Shipped backends:

| Backend | Command | Notes |
|---|---|---|
| `codex` (default) | `codex exec -s read-only --ephemeral --skip-git-repo-check [-m MODEL] [-c model_reasoning_effort="LEVEL"] -o <out> -` | Verified with codex-cli 0.162. With usage tracking on it adds `--json` and turns the events into progress lines and token usage. |
| `claude` | `claude -p --output-format json --setting-sources user --disable-slash-commands --no-session-persistence --permission-mode dontAsk [--model MODEL] [--effort LEVEL] --allowedTools "Read,Glob,Grep,Bash(git diff*),..."` | Verified with Claude Code 2.1.292. Pick a stronger reviewer with `--model`, more thinking with `--effort`. |
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
│       │   ├── scripts/                   lib.sh, start.sh, review.sh, stop-hook.sh, resume-hook.sh, status.sh, cancel.sh, continue.sh, dashboard.sh, config.sh
│       │   ├── scripts/backends/          codex.sh, claude.sh, fake.sh
│       │   └── templates/                 reviewer-prompt.md, coder-brief.md, coder-summary.md, review-format.md, dashboard.html
│       ├── review-status/SKILL.md
│       ├── review-cancel/SKILL.md
│       ├── review-continue/SKILL.md
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
