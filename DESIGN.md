---
name: review-loop dashboard
description: A quiet console where two agents, a coder and a reviewer, hold a traceable conversation.
colors:
  coder-blue: "#2a78d6"
  coder-blue-dark: "#3987e5"
  reviewer-orange: "#eb6834"
  reviewer-orange-dark: "#d95926"
  stone-page: "#f9f9f7"
  stone-surface: "#fcfcfb"
  ink: "#0b0b0b"
  ink-secondary: "#52514e"
  muted: "#6b6a65"
  action: "#0b0b0b"
  on-action: "#ffffff"
  gridline: "#e1e0d9"
  axis: "#c3c2b7"
  hairline: "rgba(11,11,11,0.10)"
  hover-wash: "rgba(11,11,11,0.05)"
  night-page: "#0d0d0d"
  night-surface: "#1a1a19"
  night-ink: "#ffffff"
  night-ink-secondary: "#c3c2b7"
  night-muted: "#969490"
  night-action: "#ecebe6"
  night-on-action: "#0b0b0b"
  night-gridline: "#2c2c2a"
  night-axis: "#383835"
  night-hairline: "rgba(255,255,255,0.10)"
  night-hover-wash: "rgba(255,255,255,0.06)"
  status-good: "#0ca30c"
  status-warning: "#fab219"
  status-serious: "#ec835a"
  status-critical: "#d03b3b"
  status-good-text: "#0a7d0a"
  status-critical-text: "#c22f2f"
  night-status-good-text: "#3cc23c"
  night-status-critical-text: "#ef6b6b"
typography:
  page-title:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.5
  metric:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "26px"
    fontWeight: 600
    lineHeight: 1.5
  headline:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.5
  title:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 700
    lineHeight: 1.5
  body:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  body-dense:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.5
  eyebrow:
    fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    letterSpacing: "0.04em"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
rounded:
  swatch: "3px"
  code: "4px"
  control: "6px"
  pane: "8px"
  card: "10px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
components:
  button:
    backgroundColor: "{colors.stone-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "4px 10px"
  button-hover:
    backgroundColor: "{colors.hover-wash}"
  button-primary:
    backgroundColor: "{colors.action}"
    textColor: "{colors.on-action}"
    rounded: "{rounded.control}"
    padding: "4px 10px"
  nav-button-active:
    backgroundColor: "{colors.action}"
    textColor: "{colors.on-action}"
    rounded: "{rounded.control}"
    padding: "4px 10px"
  input:
    backgroundColor: "{colors.stone-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "5px 8px"
  card:
    backgroundColor: "{colors.stone-surface}"
    rounded: "{rounded.card}"
    padding: "14px 16px"
  tile:
    backgroundColor: "{colors.stone-surface}"
    rounded: "{rounded.card}"
    padding: "12px 14px"
  doc-pane:
    backgroundColor: "{colors.stone-page}"
    rounded: "{rounded.pane}"
    padding: "10px 14px"
  chip:
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "1px 8px"
---

# Design System: review-loop dashboard

## Overview

**Creative North Star: "The Two-Voice Console"**

The dashboard records a conversation between two agents. Everything is built around those two voices: the coder speaks in blue, the reviewer in orange, and both appear on quiet stone-grey paper that adds nothing of its own. Charts, legends, round timelines and side-by-side document panes all keep the same voice-to-colour mapping, so a reader can follow who said what without reading a label.

The console is quiet and utilitarian. Surfaces are flat, separated by hairline borders rather than shadows. Type is the system font at small, dense sizes. Apart from the two voices, colour appears only as state: a status dot on a chip, a red error, a green success. The page is one self-contained file with no web fonts, images or icon sets. Its character comes from restraint and consistency, not ornament.

Light and dark themes are first-class. Dark mode is not an inversion: it is a separately tuned set of near-black stone surfaces in which both voices are re-tuned (a brighter blue, a deeper orange) to keep their contrast and balance.

**Key Characteristics:**
- Two voice colours (coder blue, reviewer orange) on warm neutral stone.
- Flat surfaces, 1px translucent hairlines, no resting shadows.
- System font only, 11–26px, with tabular numerals for data.
- Colour as state: dot-chips carry status, the text stays ink.
- Dense, scannable, desktop-first, collapsing gracefully at 640px.

## Colors

Warm, low-chroma stone neutrals carry the whole page. The only saturated colours are the two agent voices and four status signals.

### Primary
- **Coder Blue** (light `coder-blue`, dark `coder-blue-dark`): the coder's voice. The coder series in every chart and legend, and the coder's side of each round. Used for nothing else.

### Secondary
- **Reviewer Orange** (light `reviewer-orange`, dark `reviewer-orange-dark`): the reviewer's voice. The reviewer series in charts and legends. Used for nothing else.

### Action
- **Ink Action** (`action` / `night-action`, with `on-action` / `night-on-action` text): links, the current nav button, primary buttons and the focus ring. Actions are ink rather than a hue, so neither voice colour is spent on them. Links are underlined; edited config labels are ink, semibold and suffixed "· edited".

### Tertiary (status signals)
- **Approval Green** (`status-good`): approved verdicts, successful saves.
- **Pause Amber** (`status-warning`): paused loops.
- **Cap Coral** (`status-serious`): `changes_requested` verdicts, loops that hit the round cap.
- **Failure Red** (`status-critical`): failures, hook errors, validation errors, missing prompt files, removed config keys.

These four colours appear as 8px dots inside chips. Text in a status colour uses the stronger text tokens (`status-good-text`, `status-critical-text` and their night pairs), which pass 4.5:1 on every surface. They never fill large areas. The "Active" chip dot is Ink Secondary, not coder blue.

### Neutral
- **Stone Page** (`stone-page` / `night-page`): page background, and the inset background of document panes and command blocks.
- **Stone Surface** (`stone-surface` / `night-surface`): cards, tiles, controls, inline code.
- **Ink** (`ink` / `night-ink`): primary text.
- **Ink Secondary** (`ink-secondary` / `night-ink-secondary`): supporting text, legends, breadcrumbs, key-value rows.
- **Muted** (`muted` / `night-muted`): labels, hints, table headers, axis ticks, timestamps, rounds-per-loop bars and their dashed cap marker. At least 4.5:1 on page, surface and hover backgrounds in both themes.
- **Gridline** and **Axis** (`gridline`, `axis` and their night pairs): chart gridlines and baselines, table row rules, round dividers, blockquote bars.
- **Hairline** (`hairline` / `night-hairline`): every component border.
- **Hover Wash** (`hover-wash` / `night-hover-wash`): hover and selected-row backgrounds.

### Named Rules
**The Voice Ownership Rule.** Blue means the coder and orange means the reviewer, and nothing else. Actions use the ink `--action` token; data that belongs to neither agent (such as rounds per loop) is drawn in Muted.

**The Dot, Not the Fill Rule.** Status colour is carried by a small dot or a short run of text, never by a filled background. Chip text stays ink.

## Typography

**Body Font:** system-ui (with -apple-system, Segoe UI, sans-serif)
**Label/Mono Font:** ui-monospace (with SFMono-Regular, Menlo, monospace)

**Character:** The platform's own UI font, set small and dense like a native tool. Monospace marks anything that is literally from the files: comment IDs, paths, commands and code.

### Hierarchy
- **Page title** (700, 20px): the dashboard name in the header. Used once.
- **Metric** (600, 26px): the value in each stat tile. The largest type on the page, because the numbers matter most.
- **Headline** (700, 16px): the loop name in the loop detail view.
- **Title** (700, 14px): card and round headings, role card names.
- **Body** (400, 14px/1.5): the base size for controls and running text.
- **Body dense** (400, 13px): tables, filters, breadcrumbs, key-value rows, config labels.
- **Label** (400, 12px): tile labels, hints, legends, chips, table headers (500 weight), rendered markdown inside document panes.
- **Eyebrow** (400, 11px, 0.04em tracking, uppercase): "CODER" / "REVIEWER" above document panes, config group headers (12px there).
- **Mono** (12px): comment IDs, paths, commands, code blocks (11px in template previews).

### Named Rules
**The Tabular Numbers Rule.** Every numeric column and chart tick uses `font-variant-numeric: tabular-nums` and is right-aligned in tables.

**The No Web Fonts Rule.** The file is self-contained and must work from `file://`. Never load a font; use system stacks only.

## Layout

- A single centred column, at most 1200px wide, with 24px top, 16px sides and 64px bottom padding.
- The header is a flex row: title, spacer, nav buttons. Metadata wraps onto its own full-width line beneath.
- Views are hash-routed and swapped in place. Only one `.view` is visible at a time.
- Grids are fluid `auto-fit` columns with minimum widths: stat tiles 150px, chart cards 420px, the coder/reviewer document pair 320px, config fields and role cards 300px, start-form fields 160px. There are no fixed breakpoint grids. Columns reflow on their own.
- Gaps are 12px between cards and tiles, 8px inside control rows, and 20px below a tile row or card grid.
- Every `auto-fit` minimum is written `min(<width>, 100%)`, so no grid forces sideways scrolling on a phone. The header nav wraps.
- At ≤640px tables hide optional columns (`.opt`) and truncate the task cell to 200px. The loop list's Started column is optional; its date moves under the task in 12px muted text, so Outcome always stays visible.
- Only the loop list's rows look and act clickable (pointer and hover wash). Other tables (the ledger, usage, Markdown) don't. Wide tables (loops, per-round usage) scroll inside their own container.
- Charts are drawn at the card's real width (label column 40% of it, at most 240px) and redrawn on resize, so chart text stays 12px; labels that do not fit are shortened with an ellipsis.
- On touch (`pointer: coarse`) controls are at least 44px tall (mini buttons 36px), inputs use 16px text and checkboxes are 24px, and the breadcrumb, header title link and disclosure summaries grow to 44px. Mini buttons, the breadcrumb, summaries and chart rows are at least 24px tall everywhere (chart rows 32px on touch).

## Elevation & Depth

The dashboard is flat. Depth comes from tonal layering: stone surface cards on a stone page, with document panes and command blocks inset back to the page tone, all outlined by 1px hairlines. The only shadow belongs to the floating chart tooltip, which has to lift above the content.

### Shadow Vocabulary
- **Tooltip lift** (`box-shadow: 0 4px 16px rgba(0,0,0,0.15)`): the fixed-position chart tooltip only.

### Named Rules
**The Hairline, Not Shadow Rule.** Separate surfaces with a 1px translucent border and a change in tone. Do not add shadows to cards, tiles or controls.

## Shapes

Small, gently rounded corners that step up with container size: 3px swatches, 4px inline code, 6px controls and inputs, 8px document panes and role cards, 10px cards and tiles. Chips and status dots are fully round. Every border is a 1px hairline. The only thicker stroke is the 3px axis-tone bar on blockquotes.

## Components

### Buttons
Plain and low-key; a button looks like a control, not a call to action.
- **Shape:** 6px corners, 1px hairline border.
- **Default:** stone surface, ink text, 4px 10px padding, inherits the body font.
- **Hover:** hover-wash background. No movement, no transition.
- **Primary (save/start):** filled ink action with on-action text, no border, 0.9 opacity on hover, 0.5 opacity when disabled.
- **Focus:** a 2px ink action outline, offset 2px, on `:focus-visible`.
- **Mini:** 11px text, 0 6px padding, for per-field tools (reset, remove).

### Navigation
- A row of the same buttons in the header, wrapping on narrow screens. The current route is filled with the ink action and marked `aria-current="page"`.
- Breadcrumbs: 13px secondary-ink links with no underline. They turn ink and underline on hover.

### Chips
- **Style:** pill (999px), hairline border, 12px ink text, 1px 8px padding, with an 8px leading dot.
- **State:** the dot colour carries the status (good, warning, serious, critical, active, neutral).

### Cards / Containers
- **Card:** stone surface, 10px corners, hairline border, 14px 16px padding. 14px title and a muted 12px hint.
- **Stat tile:** the same surface, 12px 14px padding, muted 12px label, 26px metric, 12px secondary sub-line.
- **Role card:** no fill, 8px corners, hairline, 10px 12px padding.

### Home
- **Order:** on every page the loop list leads, and the stat tiles and charts fold into a closed "Stats across these loops" disclosure below it.
- **Dates:** chart labels drop the date when every loop shares it, and loop-list dates are in the body font, not mono.

### Configuration: simple and detailed
- **Save bar:** sticky at the bottom of the card, with a 13px summary of what will change ("1 change: Round cap 5 → 7"), the actions and the command. The main action (Copy command on a static page, Save now on a served one) turns ink once there is a change.
- **Edited fields:** an edited field's key gains "· edited".
- **Labels:** each field is labelled for people ("Reviewer backend", "Round cap", "Extra coder instructions"), with its key beside the label in 12px muted mono for the CLI and the file.
- **Hidden values:** a select whose value is hidden on this page names it ("the configured backend (hidden on this page)") instead of showing a blank option.
- **Presets and intro:** the preset pickers fold behind "Change reviewer presets" and "Change coder presets". The intro is one sentence plus a "How saving works here" disclosure, underlined so it reads as clickable.
- **The switch:** reads "Show where values come from", or "Hide…" when on, and fills ink when pressed.
- **Simple by default:** the page shows each field, its 12px help line and the role presets.
- **The switch:** **Show where values come from** is a mini button with `aria-pressed`, at the right of the save row. It reveals:
  - each value's source note,
  - "saved in this file" / "not in this file",
  - the per-field write and unset tools, whose accessible names are "Write backend to this file" and "Remove backend from this file",
  - the **Save to** file picker.
- **When it's on:** it's remembered per browser, and forced on whenever the target isn't the project shared file.
- **Plain words:** "this file", not "target".

### Start a loop: protection and confirmation
- **Active-loop banner:** when a loop is already running in the project, it's the first thing in the card, a plain box in the page tone with a 1px ink border. It isn't an alert, because it describes a standing state. It names and links the running loop with its round, and gives the cancel command. The whole form is disabled, and the command block names the active loop.
- **Summary line:** above the actions, a 13px Ink Secondary sentence says what Start will run: backend, model, effort, round cap, usage and role presets.
- **Confirmation:** after a successful start the page does not reload. A "Loop started" panel takes focus, gives the next step (open Claude Code in the project), and offers **Open the loop**. Start stays disabled until then.
- **Disabled controls:** every disabled control is drawn at 0.5 opacity.

### Reader mode (`dashboard.sh --share`)
- **Home:** the primer follows the loop list's hint, and the Backend, Coder, Review and Cost columns are hidden.
- **Loop pages:** leave out the per-round timings, token usage and cost.
- **For the recipient:** a shared page is for someone who reads the record and can neither start nor configure loops.
- **Hidden:** the Start and Configuration nav buttons. Their routes return to the loop list.
- **Header:** names the project ("repo · shared <date>"), not a path.
- **Primer:** each loop page opens with a short primer (13px Ink Secondary, 62ch, inset in the page tone) explaining IDs, fixed or declined answers, the reviewer's grades and blocking.

### Inputs / Fields
- **Style:** stone surface, hairline border, 6px corners, 5px 8px padding, full width in config rows. The task textarea is at least 72px tall and resizes vertically.
- **Changed:** the field label turns semibold ink and gains a muted "· edited" suffix.
- **Removed / Error:** the label turns to the critical text colour (struck through when removed). Error text uses the same colour.
- **Source note:** a muted 11px line under each field names the config file it came from.
- **Placeholder:** Muted, which keeps examples at 4.5:1. Placeholders are examples, never labels.
- **Checkbox:** native, tinted with the ink action through `accent-color`, never the browser's blue.
- **Preset picker:** a fieldset of checkboxes under a role's presets field, in fluid 220px columns. Each option shows its title, its monospace name (with "· default" for the role's defaults) and a one-line summary in Ink Secondary. The checkboxes and the comma-separated field edit the same value.

### Tables
- Full width, 13px. Cells have 8px 10px padding and a gridline rule beneath.
- Headers are muted, 12px, weight 500. Number columns are right-aligned with tabular numerals.
- Rows are clickable. They show the hover wash, and the selected row adds a hairline outline.

### Signature: Round Pair
The two voices side by side. Each round opens with a 14px heading holding its verdict chip, the round's status; beside it, outside the heading, a 12px Ink Secondary line gives the blocking count and the coder and review times as plain text, since chips are for status, not data. The round then shows the coder's and reviewer's documents in two fluid columns. Each document pane is inset to the page tone with 8px corners, a 520px scroll limit and rendered markdown, and carries its author's voice: its 1px hairline is drawn in that voice colour at 55% strength, and its uppercase eyebrow is led by an 8px dot in the full voice colour. The voice is never a thick stripe: a heavier coloured edge on a rounded pane is the accent-stripe cliché the Hairline rule rules out. Comment IDs (`R1-C2`) appear as small monospace badges with a hairline border. Every mention links to the heading where the comment was raised, and pointing at or focusing one outlines every mention of the same ID in ink. Links never change the hash, because the page is hash-routed; they scroll to the comment and move focus there. Per-round token usage sits below the pair in a closed disclosure ("Token usage · $0.0100"), so the table never breaks the reading rhythm of the exchange.

### Signature: Verdict Line
- **Placement:** directly under a loop's title, before anything else. It holds the outcome chip and one 14px sentence that adds what the chip doesn't say, such as "In round 3 (round cap 5)." or "Changes were still requested after 2 rounds (round cap 2)." It never repeats the outcome.
- **Terms:** the round cap is always called that, including the outcome chip ("Round cap reached").
- **Order below it:** the primer on a shared page, the comment ledger (its lead sentence carries the comment counts), a closed **Run details** disclosure (id, reviewer, rounds, times, cost, folder, prompts, presets), then the rounds.
- **The end:** the page closes on the same line with the comment counts added, then the raw `summary.md` in a closed disclosure.
- **Files are the truth:**
  - When `state.json` records fewer rounds than there are review files, a 13px Ink Secondary note says so, with both counts.
  - A round without a record takes its chip from its review file (front matter or final `VERDICT:` line) and says "verdict read from the review file".
- **Round progress:** one wording everywhere: "round 1 in progress (round cap 5)" for an active loop, "3 rounds (round cap 5)" for a finished one.
- **Markdown headings:** a document's headings start at h4 under the round's h3, counted from the document's own top level, so the outline never skips a level.

### Signature: Round Panes as an Exchange
- **Labels:** each pane is named by an h4 ("CODER" / "REVIEWER", the eyebrow style with its voice dot), so heading navigation says where each voice starts.
- **The reviewer pane** renders a structured review as its parts, under 13px h5 headings:
  - "Earlier comments": each ID with the grade chip and the reason.
  - "New comments" and "Optional": each comment laid out like its ledger row, with ID badge · severity · blocking / non-blocking / optional · `file:line`, then the description and "Suggested fix:". Each block is the target of every link to its ID.
  - "Assessment".
  - Any other section, as it was written.
- **What the panes drop:** the front matter and the final `VERDICT:` line, which the round heading already carries.
- **Free-form reviews:** a review in that format (older loops) stays plain markdown.
- **The coder pane** drops a leading "# Round N …" title (the round heading says it), and lists "Answers to the previous review" with each answer (fixed / declined: note) beside the grade the same round's review gave it.
- **Raw files:** both panes end with the raw file in a closed disclosure ("Coder summary file", "Review file"). Panes align to the top instead of stretching to the taller one.

### Next Steps
- **Where:** beside the verdict line, at the top and in the closing recap, a 13px line gives the command to run next, in a code chip with a **Copy** mini button.
- **Which command:**
  - `/review-continue` for a loop that hit its round cap ("add a number for more rounds").
  - `/review-cancel` for an active or paused one.
- **Never shown** on a shared page.

### Signature: Comment Ledger
The top of a loop page, before the rounds. A 14px "Comments" title, then one plain sentence that answers the reader's first question ("4 comments, 2 blocking. All blocking comments were resolved.", or which blocking IDs are still open or unresolved). Below it is a table with one row per comment, in the order raised:
- **Comment:** the ID badge, severity · blocking / non-blocking / optional · `file:line` in Ink Secondary, the description, and "Suggested fix:" in 12px Ink Secondary.
- **Raised:** the round.
- **What happened:** each later round in which something changed. That is the coder's answer (fixed / declined: note) and the reviewer's grade, with grades that only repeat the previous one dropped.
- **Status:** a chip.
  - Resolved is good; declined, accepted is neutral; unresolved and declined, rejected are serious.
  - A comment nobody graded reads "awaiting the next round" (active) while the loop runs. Once the loop is finished it reads "still open" (serious) if blocking, or "not addressed · optional" / "not addressed · non-blocking" (neutral).

Notes render as inline markdown. Below 640px each row stacks: comment, status, then what happened. The Raised column hides, and explicit table roles keep the semantics.

### Signature: Voice Charts
Inline SVG bar charts with gridline-tone grids and axis-tone baselines, muted 11px tabular ticks, and series in the two voice colours with a matching square-swatch legend (10px, 3px corners). Bars dim to 0.85 opacity on hover and show the lifted tooltip. The time chart counts whole seconds when every loop took under two minutes (minutes would floor those bars to 0), and minutes otherwise; its hint and hidden table name the unit. Each row label is a link to its loop: a chart is one tab stop, arrow keys (and Home/End) move between rows, Enter opens the loop, and keyboard focus draws a 2px ink ring around the row, dims its bars and shows the same tooltip. The marks are hidden from screen readers; a visually hidden table carries the numbers.

## Do's and Don'ts

### Do:
- **Do** keep blue for the coder and orange for the reviewer in every chart, legend and paired view.
- **Do** use the ink `--action` token for links, current navigation, primary buttons and focus.
- **Do** define every colour as a token on `:root`, with dark values under `prefers-color-scheme: dark` (guarded by `:not([data-theme="light"])`) and again under `[data-theme="dark"]`.
- **Do** separate surfaces with 1px hairlines and a change in tone.
- **Do** carry status as a dot in a pill chip, with the text left in ink.
- **Do** set file-sourced strings (IDs, paths, commands) in the monospace stack.
- **Do** use tabular numerals for every number.

### Don't:
- **Don't** use coder blue or reviewer orange for actions, statuses or data that belongs to neither agent.
- **Don't** load web fonts, icon fonts, images or any external resource.
- **Don't** add shadows to cards, tiles or controls; the tooltip is the only lifted element.
- **Don't** fill large areas with status colours, or set text in the dot-strength status colours.
- **Don't** introduce new saturated hues beyond the two voices and four statuses.
