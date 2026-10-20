---
name: review-loop
description: Start a coder/reviewer loop for a task. Claude implements the task, an independent CLI reviewer (Codex, Claude, ...) reviews it, and the loop repeats until the reviewer approves. Every round's summary and review comments are stored in the project.
argument-hint: "<task description> [--backend codex|claude] [--model MODEL] [--max-rounds N] [--dir DIR] [--usage] [--reviewer-extra FILE] [--coder-extra FILE] [--force] [--git-exclude]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# Review loop

You are the **coder** in a coder/reviewer loop. An independent reviewer agent
(a separate CLI process, not you) will review your work and either approve it
or request changes. The loop ends only when the reviewer approves, the maximum
number of rounds is reached, or the user cancels it.

## 1. Start the loop

Run exactly this command (the arguments after `start.sh` are the user's
arguments, pass them through unchanged):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/start.sh --session ${CLAUDE_SESSION_ID} $ARGUMENTS
```

(The user's arguments may include `--backend`, `--model`, `--effort`,
`--max-rounds`, `--usage` and the prompt flags; `config.sh models` lists the
models and efforts a backend offers. `--session` identifies your session as the loop owner and, when the user
enables `--usage`, lets the loop record your token usage; keep it as is.)

It prints the loop id, the loop directory, the task file and **your brief**
(also saved as `<loop dir>/coder-brief.md`). The brief is the protocol below
plus any project-specific instructions the user configured for the coder
role (`prompts.coder_extra`, or a replacement brief via `prompts.coder`);
follow it. If start.sh reports that a loop is already active, tell the user
and stop; they can run `/review-cancel` or pass `--force`.

## 2. Implement the task

Do the task completely and carefully: clean, well-structured, tested code.
Do not stop early and do not narrow the task. Do not ask the user questions
unless you are truly blocked (see "Pausing" below).

## 3. Submit for review

When the implementation is complete:

1. Write `<loop dir>/round-NN-coder.md` following
   `${CLAUDE_SKILL_DIR}/templates/coder-summary.md`: what you did, files changed,
   how you verified it. From round 2 on, include the "Responses to the previous
   review" table with one row per comment ID (`fixed`, or `declined` with a reason).
2. Run the reviewer (give the Bash tool a 600000 ms timeout; reviews take minutes):

   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/review.sh
   ```

3. Read what it prints and do exactly that:
   - **APPROVED**: the loop is finished. Report the outcome to the user,
     including any optional nits you chose not to apply and, if usage tracking
     is on, the totals from `<loop dir>/usage.md`, and stop.
   - **CHANGES REQUESTED**: read the review file it names. Address **every**
     comment by ID: fix it, or decline it with a clear technical reason. Do not
     ignore comments, and do not blindly accept wrong ones. Then write the next
     `round-NN-coder.md` and run `review.sh` again.
   - **Maximum rounds reached**: read the summary, report the unresolved
     comments to the user, and stop. The user can give the loop more rounds
     with `/review-continue [N]`.
   - If `review.sh` fails (missing coder summary, backend error), fix the cause
     it names and run it again.

## Rules

- Never stop while the loop is active and the reviewer has not approved. If the
  review-loop plugin is installed, a Stop hook will send you back with the same
  instructions; if not, these instructions alone are the loop.
- Do not edit anything under the loop directory other than the coder summary.
- Do not run the reviewer before the implementation is complete.
- The reviewer sees the diff since the loop started (or since its base commit);
  committing during the loop is fine.

## Pausing

If you genuinely need the user's input (a decision only they can make), end
your message with a line containing exactly `REVIEW-LOOP: PAUSE`. The loop
resumes on your next turn. To abort, run `/review-cancel`.

## Useful commands

- `bash ${CLAUDE_SKILL_DIR}/scripts/status.sh` — current round, phase, files.
- `bash ${CLAUDE_SKILL_DIR}/scripts/cancel.sh` — abort the loop.
