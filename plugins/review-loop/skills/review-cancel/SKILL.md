---
name: review-cancel
description: Cancel the active review loop and release the Stop hook.
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/cancel.sh)
---

Run:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/cancel.sh
```

Report the output to the user: the loop id, the phase and round it was at,
and where the summary was written. If no loop was active, say so.
