---
name: review-dashboard
description: Generate and open an HTML dashboard of all review loops in this project (outcomes, rounds, usage, and the full comment trail per loop).
argument-hint: "[--dir DIR] [--out FILE]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/dashboard.sh *)
---

Run:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/dashboard.sh --open $ARGUMENTS
```

Report where the page was written and how many loops it contains. The page is
self-contained (no network needed) and can be regenerated at any time.
