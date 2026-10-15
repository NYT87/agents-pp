---
name: review-status
description: Show the state of the active review loop (round, phase, backend, files written so far).
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/status.sh)
  - Read
---

Run:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/status.sh
```

Report the output to the user as is. If a round review file exists and the
user asks, read it and summarise the comments by ID.
