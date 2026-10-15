Your final message is the review. It must follow this format exactly (Markdown):

## Previous comments

Only from round 2 on. One line per comment ID from EVERY earlier review, with one
of these statuses: `resolved`, `unresolved`, `declined-accepted` (the coder
declined it and you agree), `declined-rejected` (the coder declined it and you
do not agree). `unresolved` and `declined-rejected` are blocking.

- R1-C1: resolved
- R1-C2: declined-accepted — the coder's reason is valid
- R1-C3: unresolved — still fails on empty input

## Comments

One section per new finding. IDs are `R<round>-C<n>` with n starting at 1 for
this round. Never re-raise a resolved ID under a new ID.

### R{{ROUND}}-C1
- severity: critical | high | medium | low
- blocking: yes | no
- file: path/to/file
- line: 42
- description: what is wrong and why it matters
- suggested fix: concrete, actionable change

## Optional

Non-blocking nits, in the same `### R{{ROUND}}-Cn` format with `blocking: no`.
This section may be empty.

## Assessment

One short paragraph: overall quality, whether the task is actually done, what
was verified.

VERDICT: approved

The last line must be exactly `VERDICT: approved` or `VERDICT: changes_requested`.
Write `approved` ONLY when there is no blocking comment at all (no `blocking: yes`,
no `unresolved`, no `declined-rejected`). Otherwise write `changes_requested`.
