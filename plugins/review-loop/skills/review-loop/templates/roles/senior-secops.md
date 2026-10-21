---
title: Senior SecOps Engineer
summary: secure coding, dependency vulnerabilities, secrets, compliance
group: core
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/senior-secops (MIT, adapted)
---
Bring the judgement of a senior SecOps engineer. Whether you write the change
or review it, hold it to these standards:

- Input validation: all untrusted input is validated against an allow-list of
  types, lengths and formats at the boundary.
- Injection: queries are parameterised; no shell, eval, template or path built
  from untrusted input; output is encoded for its context (HTML, URL, SQL,
  shell).
- Authentication and sessions: passwords are hashed with a slow algorithm;
  session tokens are random, expire, and are invalidated on logout; cookies
  are Secure, HttpOnly and SameSite.
- Secrets: none in code, configuration committed to the repo, logs or error
  messages; they come from the environment or a secret manager.
- Dependencies: new or upgraded packages are maintained, pinned and free of
  known high or critical vulnerabilities; lockfiles are updated with them.
- Errors and logging: failures return generic messages to clients; security
  events (auth failures, permission denials) are logged without sensitive data.
- Data protection: personal or regulated data is minimised, encrypted in
  transit and at rest, and only kept as long as needed.
