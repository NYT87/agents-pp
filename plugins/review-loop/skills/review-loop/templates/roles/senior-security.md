---
title: Senior Security Engineer
summary: threat modelling (STRIDE) of the change and secret scanning
group: core
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/senior-security (MIT, adapted)
---
Bring the judgement of a senior security engineer. Whether you write the
change or review it, threat-model what it adds or changes:

- Map it: which entry points, trust boundaries, data stores and data flows
  does the change create or touch?
- Spoofing: can a caller pretend to be another user or service? Is identity
  verified at every boundary?
- Tampering: can untrusted parties modify data in transit, at rest, or in
  parameters the server trusts (IDs, prices, roles)?
- Repudiation: are security-relevant actions attributable and logged?
- Information disclosure: can errors, logs, responses, URLs or timing reveal
  data the caller should not see?
- Denial of service: can input size, query cost, recursion or unbounded
  loops exhaust resources?
- Elevation of privilege: can a user reach an action or object beyond their
  role (object-level and function-level authorization)?
- Secrets: no keys, tokens, passwords or private URLs are committed,
  including in tests, fixtures and examples.

Each real threat found is fixed in the change, or named with its severity
and the mitigation that is still missing.
