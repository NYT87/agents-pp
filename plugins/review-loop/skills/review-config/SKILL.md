---
name: review-config
description: Create or update the review-loop configuration file by answering a few questions (backend, model, rounds, storage dir, usage tracking, dashboard), showing the current values, and optionally adding the loop's paths to .gitignore.
argument-hint: "[--user|--project]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh *)
  - AskUserQuestion
  - Read
---

# Review loop configuration

Guide the user through the configuration without them editing JSON by hand.
All writes go through `config.sh`; never write the file yourself.

## 1. Read the current state

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh show --json $ARGUMENTS
```

The output has `effective` (what applies now), `defaults`, and the `project`
and `user` files with whether each exists and its values. `scope` and `target`
say which file will be written (`--project` → `./.claude/review-loop.json`,
the default; `--user` → `~/.claude/review-loop.json`).

## 2. Ask the questions

If the user passed neither `--user` nor `--project`, first ask which file to
write: the project file (recommended, shared with the repo) or the user file
(personal defaults for every project).

Then ask about every key, in two batches at most, **showing the current
effective value in each question** and offering it as the first option:

| Key | Ask | Options |
|---|---|---|
| `backend` | reviewer backend | `codex`, `claude` (and any other script in `scripts/backends/`) |
| `model` | reviewer model | keep current / backend default / type a model name |
| `max_rounds` | review rounds before giving up | current, 3, 5, 10, or a number |
| `dir` | where loop folders are stored | current, `.review-loop`, `reviews`, `docs/reviews`, or a path |
| `usage` | record token usage and cost per round | yes / no |
| `dashboard.open` | open the dashboard in the browser after `/review-dashboard` | yes / no |
| `dashboard.auto` | regenerate the dashboard automatically when a loop ends | yes / no |
| `dashboard.out` | dashboard output file | keep current / default (`<dir>/dashboard.html`) / a path |

Skip `dashboard.dirs` unless the user mentions several storage folders; then
ask for a comma-separated list.

## 3. Write the values

Run one `set` with only the keys whose answer differs from the current value.
If nothing changed, say so; and if the target file does not exist yet
(`exists: false` in step 1), still create it so the user ends up with a file:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh create [--user|--project]
```

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh set [--user|--project] backend=claude model=opus max_rounds=3 usage=true
```

Booleans accept `true/false`, `yes/no`. If `set` reports a validation error,
tell the user and ask that question again.

## 4. Last: .gitignore

Only now, with the paths known, show what would be ignored:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh gitignore --dry-run
```

Ask whether to add those lines (loop storage dir, the pointer file, and the
dashboard file when it is inside the project). If yes:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh gitignore
```

If it reports the paths are already covered, say so and skip the question.

## 5. Confirm

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh show
```

Report the written file, the values that changed, and the .gitignore outcome.
