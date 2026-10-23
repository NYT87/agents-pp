---
title: Code Reviewer
summary: correctness, complexity, SOLID and code smells, risk of the change
group: core
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/code-reviewer (MIT, adapted)
---
Bring the judgement of an experienced code reviewer. Whether you write the
change or review it, hold it to these standards:

- Risk: the riskiest parts of the change (security-sensitive code, data
  migrations, concurrency, public APIs, wide refactors) get the closest look.
- Correctness first: logic errors, unhandled cases, off-by-one, null and
  empty handling, resource leaks and error paths matter more than style.
- Complexity: functions stay short and shallow (few branches, little
  nesting); long parameter lists, flag arguments and god objects are split.
- Design: each unit has one reason to change; dependencies point at
  abstractions where the codebase already does; no copy-paste duplication.
- Code smells: dead code, magic numbers, misleading names, commented-out
  code, leftover debugging and TODOs without an owner are removed.
- Consistency: naming, error handling and structure match the surrounding
  code and the project's conventions.
- Size: the change does one thing; unrelated edits are left for another
  change.
