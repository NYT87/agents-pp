---
version: 1
slug: "site-index-html"
primary_target: "site/index.html"
related_targets: []
---

# Homepage (site/index.html)

Scope: the public homepage for agents-pp / review-loop, deployed to GitHub Pages from `site/`, plus one shared loop page (`site/loop/`) generated with `dashboard.sh --share`. Visitor mode: Persuade.

Audience and job: developers who use coding agents (Claude Code first) and want an independent second agent to review the work. They should understand the loop in one viewport, believe it through one real exchange, and install the plugin.

Action: install the plugin (`claude plugin marketplace add NYT87/agents-pp` then `claude plugin install review-loop@agents-pp`), copyable in the first viewport.

Proof: the real loop `20261020-080121-419ce6` (model and effort selection): R1-C1 and R1-C2 blocking; round 2 the coder answers both "fixed", the reviewer resolves R1-C2 but grades R1-C1 unresolved (disputed); round 3 R1-C1 resolved; approved in round 3 of 5. Quotes are excerpts of the real files. No invented users, numbers or claims.

Constraints: static HTML/CSS/JS, no build step, no external requests at runtime (fonts self-hosted), works on phones, AA contrast, keyboard operable, reduced motion respected.

## Direction contract

THESIS: The loop is a two-person checklist: the reviewer reads each challenge, the coder answers it, and the procedure is complete only when every item is confirmed. Refuses the dark hero with a terminal window and a feature-card grid.

OWN-WORLD: A laminated normal-procedures card held over a dark flight-deck ground (#1d2327). Card stock white, black ink, amber section tabs and challenge marks (the reviewer), a green COMPLETE strip; dotted leaders join challenge to response. B612 (the open cockpit-display face) for all type, B612 Mono for commands and comment IDs. Item numbers in a left gutter, section tabs on the card's edge.

STORY: The visitor sees the procedure card, copies the install line as item 1, watches one real loop run as challenge and response (a dispute included) until COMPLETE, reads how the procedure works, and opens the full shared loop.

FIRST VIEWPORT: The card fills the width on the dark ground. Header strip: AGENTS-PP · REVIEW-LOOP · NORMAL PROCEDURES. Title "Two agents, one task." with one line under it. Section tab BEFORE START: item 1 INSTALL with the two commands and a Copy button (the primary action), item 2 RUN with `/review-loop <task>`. The right half of the card holds the first real challenge (R1-C1) with its dotted leader running to the coder's response.

FORM: candidate 4 of my ordered list (Challenge and Response), chosen from the safer register on re-roll 2. seed:72360b53cfbca15a

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
