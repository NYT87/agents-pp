---
name: review-dashboard
description: Generate and open an HTML dashboard of all review loops in this project (outcomes, rounds, usage, and the full comment trail per loop).
argument-hint: "[--dir DIR] [--out FILE] [--no-open] [--serve [--port N]] [--share]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/dashboard.sh *)
---

Run:

```bash
bash ${CLAUDE_SKILL_DIR}/../review-loop/scripts/dashboard.sh $ARGUMENTS
```

With no arguments it reads everything from the config file (`dashboard.dirs`,
`dashboard.out`, `dashboard.open`, falling back to the loop dir) and opens the
page in the browser. Report where the page was written and how many loops it
contains. The page is self-contained (no network needed) and can be
regenerated at any time; with `"dashboard": {"auto": true}` in the config it is
regenerated automatically whenever a loop ends. The page has three views: the
main page (stats and loop list), one page per loop (`#/loop/<id>`), and the
configuration page (`#/config`, header button), which lets the user edit the config: on the static page it shows the
`config.sh` command to run (or saves the file via the browser); with `--serve`
changes apply directly. `--serve` keeps running until Ctrl-C, so only use it
when the user asks for it, and run it in the background.

When the user wants to send a review to someone else, use `--share` with an
`--out` file (for example `--share --out review.html`). It writes a read-only
page with no Start or Configuration pages, no configuration, local paths or
session data, and a short primer on each loop page. It cannot be combined with
`--serve` or `--with-user-config`. Tell the user that the round files are
embedded as written, so anything they wrote in a summary stays.
