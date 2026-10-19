---
name: review-continue
description: Continue the last review loop that stopped at its round cap with extra rounds (default 1), then keep coding until the reviewer approves.
argument-hint: "[N] [--loop ID]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/*)
---

# Continue a review loop

The loop stopped because it reached its maximum number of rounds without an
approval. You are the **coder** again: the loop is re-opened where it stopped,
with more rounds, and the same independent reviewer judges the next round.

## 1. Continue the loop

Run exactly this command (the arguments are the user's: a number is the extra
rounds to allow, default 1; `--loop ID` picks a loop other than the latest):

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/continue.sh --session ${CLAUDE_SESSION_ID} $ARGUMENTS
```

It prints the new cap, then the last review's verdict and what to do next
(`review.sh` resumes from that review without running the reviewer again).
If it reports that a loop is still active, or that no loop stopped at its
cap, tell the user and stop.

## 2. Address the last review, then submit

Follow the printed instructions exactly, as in `/review-loop`:

1. Read the last review it names and address **every** comment by ID: fix it,
   or decline it with a clear technical reason.
2. Write `<loop dir>/round-NN-coder.md` for the new round, following
   `${CLAUDE_SKILL_DIR}/../review-loop/templates/coder-summary.md`, including
   the "Responses to the previous review" table with one row per comment ID.
3. Run the reviewer (give the Bash tool a 600000 ms timeout):

   ```bash
   bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/review.sh
   ```

4. Do what it prints: on **APPROVED** report the outcome to the user and stop;
   on **CHANGES REQUESTED** repeat from step 1; when the new maximum is
   reached, report the unresolved comments and stop (the user can continue
   again).

## Rules

- Never stop while the loop is active and the reviewer has not approved; the
  Stop hook sends you back otherwise.
- Do not edit anything under the loop directory other than the coder summary.
- To pause for a genuine question, end your message with `REVIEW-LOOP: PAUSE`.
  To abort, run `/review-cancel`.
