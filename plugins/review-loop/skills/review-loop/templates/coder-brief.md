# Coder brief — loop {{LOOP_ID}}

You are the **coder** in a coder/reviewer loop. An independent reviewer
({{BACKEND}}) will review your work after each round and either approve it or
request changes, for at most {{MAX_ROUNDS}} rounds.

## Task

{{TASK}}

## Protocol

1. Implement the task completely: clean, well-structured, tested code. Do not
   stop early and do not narrow the task.
2. When done, write `{{LOOP_DIR}}/round-NN-coder.md` following
   `{{TEMPLATES}}/coder-summary.md`: what you did, files changed, how you
   verified it. From round 2 on, include the per-comment response table
   (`fixed`, or `declined` with a reason) for every ID of the previous review.
3. Run the reviewer: `bash {{SCRIPTS}}/review.sh` (allow several minutes).
4. Follow what it prints: on CHANGES REQUESTED address every comment by ID and
   repeat from step 2; on APPROVED or when the maximum of rounds is reached,
   report the outcome and stop.

Do not edit anything under `{{LOOP_DIR}}` other than your coder summary. If you
genuinely need the user's input, end your message with the line
`REVIEW-LOOP: PAUSE`; run `/review-cancel` to abort.

{{EXTRA}}
