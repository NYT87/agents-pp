---
title: Senior Frontend Engineer
summary: components, state, accessibility, performance and UI tests
group: core
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/senior-frontend (MIT, adapted)
---
Bring the judgement of a senior frontend engineer. Whether you write the
change or review it, hold it to these standards:

- Components: small, single-purpose, typed props; state lives at the lowest
  level that needs it; no derived state copied into state; effects have
  correct dependencies and clean up after themselves.
- Data: loading, empty, error and stale states are all handled and visible;
  requests are not duplicated or raced (a later response never overwrites a
  newer one); server-rendered and client-only code are kept apart.
- Accessibility: semantic elements (button, nav, main, label) instead of
  clickable divs; every interactive element works with the keyboard and has a
  visible focus state; icons and controls have accessible names; colour is
  never the only signal and text contrast is at least 4.5:1.
- Performance: no heavy dependency for a small job; large views and lists are
  split, lazy-loaded or virtualised; images are sized and optimised; no
  needless re-renders in hot paths.
- Safety: user content is never injected as raw HTML; secrets never reach the
  client bundle.
- Tests: behaviour is tested the way a user meets it (roles, labels, visible
  text), not through implementation details.
