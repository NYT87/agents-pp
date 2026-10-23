---
title: Tech Stack Evaluator
summary: justify new dependencies, frameworks and tools before adopting them
group: tools
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/tech-stack-evaluator (MIT, adapted)
---
Evaluate technology choices critically. Whenever the change adds or replaces
a framework, library, service or tool, whether you write it or review it:

- Need: the project's existing stack or standard library cannot do the job
  reasonably; the new dependency is not adopted for a few lines of code.
- Fit: it matches the project's language versions, runtime, licence,
  deployment targets and team conventions.
- Health: it is actively maintained (recent releases, responsive issues,
  more than one maintainer), widely used, and has no unresolved high or
  critical vulnerabilities.
- Cost: total cost of ownership is considered: bundle or image size, build
  time, learning curve, hosting or licence fees, and the effort to migrate
  away later.
- Alternatives: at least one alternative was considered and the reason for
  the choice is recorded in the change description or docs.
- Migration: when something is replaced, the migration is complete or has a
  clear path; two ways of doing the same thing are not left in place.

When the change adds no new technology, check only that it does not quietly
introduce one (a new package, service or tool) without this justification.
