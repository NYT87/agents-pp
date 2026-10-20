---
name: review-config
description: Create or update the review-loop configuration file by answering a few questions (backend, model, rounds, storage dir, usage tracking, dashboard), showing the current values, and optionally adding the loop's paths to .gitignore.
argument-hint: "[--user|--project] [--provider [NAME] | --provider-file [NAME]]"
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

The output has `effective` (what applies for the selected provider: the one
named with `--provider`/`--provider-file`, else the running one), `defaults`,
`provider`, `target_exists` / `section_exists` (whether the place writes go to
already exists), an optional `note` (when no scope flag was given and an existing
project provider file was chosen because the project shared file does not
exist yet; `--user` and the other flags always target what they name), and
`files`: every config
file that is consulted, lowest precedence first, with whether it exists and
its values. `target`, `mode` and `section` say where writes go:

- `--project` (default): `./.review-loop.json`, shared by every provider
- `--user`: `~/.config/review-loop/config.json`, shared, every project
- `--provider [NAME]`: the `providers.NAME` section of that shared file
- `--provider-file [NAME]`: a separate `./.NAME/review-loop.json`
  (e.g. `.claude/review-loop.json`, `.codex/review-loop.json`)

## 2. Ask the questions

If the user passed no scope flag, first ask where to write: the project shared
file (recommended, committed with the repo, applies to every provider), the
user shared file (personal defaults for every project), or a provider-specific
place (the `providers.<name>` section, or a separate `.<name>/review-loop.json`)
when the values should apply only to one coder provider such as Claude or Codex.
Pass the matching flags to every `config.sh` call below.

Then ask about every key, in two batches at most, **showing the current
effective value in each question** and offering it as the first option:

| Key | Ask | Options |
|---|---|---|
| `backend` | reviewer backend | `codex`, `claude` (and any other script in `scripts/backends/`) |
| `model` | reviewer model | keep current / backend default / one of the backend's listed models (see below) / type a model name |
| `effort` | reasoning effort for the reviewer | keep current / backend default / one of the backend's listed efforts |
| `max_rounds` | review rounds before giving up | current, 3, 5, 10, or a number |
| `dir` | where loop folders are stored | current, `.review-loop`, `reviews`, `docs/reviews`, or a path |
| `usage` | record token usage and cost per round | yes / no |
| `dashboard.open` | open the dashboard in the browser after `/review-dashboard` | yes / no |
| `dashboard.auto` | regenerate the dashboard automatically when a loop ends | yes / no |
| `dashboard.out` | dashboard output file | keep current / default (`<dir>/dashboard.html`) / a path |

Skip `dashboard.dirs` unless the user mentions several storage folders; then
ask for a comma-separated list.

For `model` and `effort`, list what the chosen backend offers (the one the
user picked for `backend`, or the effective one) and let the user pick from
it:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh models --backend <backend> --json
```

`models[]` has `id`, `label`, `efforts` and `default`; `efforts` is the list
of levels the backend accepts and `default_model`/`default_effort` what it
uses when the keys are empty. Offer the models by label (id in parentheses)
with "backend default" first; a name that is not listed is accepted for
`model` (new models appear before lists do) but `effort` must be one of the
levels listed for the chosen model (`models[].efforts`; for an unlisted model,
the backend-wide `efforts`). When the lists are empty (Codex before its first
run, say), say so and accept typed values.

## 3. Write the values

Run one `set` with only the keys whose answer differs from the current value.
If nothing changed, say so; and if the place writes go to does not exist yet
(`section_exists: false` in step 1), still create it so the user ends up with a
file (or section):

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh create [scope flags]
```

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/config.sh set [scope flags] backend=claude model=opus max_rounds=3 usage=true
```

Booleans accept `true/false`, `yes/no`. If `set` reports a validation error,
tell the user and ask that question again. If it prints a `warning:` that a
value is masked by a higher-precedence source (for example an existing
`.claude/review-loop.json` when writing the shared file), tell the user which
file sets the effective value and offer to write there instead
(`--provider-file`).

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
