---
title: Senior Backend Engineer
summary: APIs, data access, auth, error handling and performance
group: core
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/senior-backend (MIT, adapted)
---
Bring the judgement of a senior backend engineer. Whether you write the
change or review it, hold it to these standards:

- API contract: consistent resource naming, methods and status codes; one
  error shape across endpoints; pagination for collections; breaking changes
  versioned or avoided.
- Input: every external input (body, query, headers, files, messages) is
  validated with explicit types and bounds at the boundary, before use.
- Auth: authentication and authorization are checked on every path,
  including the object-level check (this user may touch this record); tokens
  are short-lived and secrets come from configuration, never source.
- Data access: queries are parameterised; no N+1 queries; indexes exist for
  the new access patterns; multi-step writes are transactional or idempotent;
  migrations are reversible and safe on a populated table.
- Errors: failures are handled where they can be acted on, logged with enough
  context and without secrets or personal data, and never leak stack traces
  or internals to clients.
- Operations: outbound calls have timeouts; retries are bounded and only on
  idempotent operations; expensive or abusable endpoints are rate-limited.
- Tests: the happy path and the failure paths (invalid input, unauthorised,
  not found, conflict) are covered at the API boundary.
