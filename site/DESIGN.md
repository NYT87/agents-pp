---
name: review-loop homepage
description: A laminated normal-procedures card held over a dark flight-deck ground; the review loop read as challenge and response.
colors:
  amber: "#e8a500"
  amber-soft: "#fbe7b0"
  green: "#1b6b3f"
  ground: "#1d2327"
  ground-ink: "#e4e8ea"
  ground-muted: "#aeb6bb"
  card: "#f6f6f1"
  card-2: "#ecece5"
  well: "#ffffff"
  ink: "#111417"
  ink-hover: "#2a3035"
  ink-2: "#3f464c"
  muted: "#5c6369"
  rule: "#9aa0a3"
  rule-soft: "#d4d6d1"
typography:
  display:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "clamp(40px, 6.2vw, 76px)"
    fontWeight: 700
    lineHeight: 1.02
    letterSpacing: "-0.01em"
  headline:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "clamp(24px, 3vw, 34px)"
    fontWeight: 700
    lineHeight: 1.15
  lede:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "clamp(17px, 1.6vw, 19px)"
    fontWeight: 400
    lineHeight: 1.55
  body:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  item-label:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    letterSpacing: "0.06em"
  label:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.16em"
  grade:
    fontFamily: "B612, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.1em"
  mono:
    fontFamily: "B612 Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.6
  mono-id:
    fontFamily: "B612 Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1
rounded:
  mark: "3px"
  tab: "4px"
  control: "6px"
  well: "8px"
  card: "14px"
spacing:
  pad: "clamp(16px, 4vw, 48px)"
  row: "12px"
  section-top: "28px"
  section-body: "20px"
  section-bottom: "36px"
  card-max: "1180px"
components:
  section-tab:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "0 4px 4px 0"
    padding: "8px 16px 7px var(--pad)"
  copy-button:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.card}"
    typography: "{typography.label}"
    height: "44px"
    padding: "0 16px"
  copy-button-hover:
    backgroundColor: "{colors.ink-hover}"
  copy-button-done:
    backgroundColor: "{colors.green}"
  link-button:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.card}"
    rounded: "{rounded.control}"
    height: "48px"
    padding: "0 18px"
  link-button-hover:
    backgroundColor: "{colors.ink-hover}"
  ghost-button:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    height: "44px"
    padding: "0 14px"
  ghost-button-hover:
    backgroundColor: "{colors.card}"
  command-well:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "{typography.mono}"
    rounded: "{rounded.well}"
    padding: "12px 14px"
  comment-id:
    textColor: "{colors.ink}"
    typography: "{typography.mono-id}"
    rounded: "{rounded.mark}"
    padding: "3px 6px"
  grade-raised:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.ink}"
    typography: "{typography.grade}"
    rounded: "{rounded.mark}"
    padding: "4px 7px"
  grade-unresolved:
    backgroundColor: "{colors.amber-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.grade}"
    rounded: "{rounded.mark}"
    padding: "4px 7px"
  grade-fixed:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.grade}"
    rounded: "{rounded.mark}"
    padding: "4px 7px"
  grade-resolved:
    backgroundColor: "{colors.green}"
    textColor: "{colors.well}"
    typography: "{typography.grade}"
    rounded: "{rounded.mark}"
    padding: "4px 7px"
  complete-strip:
    backgroundColor: "{colors.green}"
    textColor: "{colors.well}"
    rounded: "{rounded.control}"
    padding: "14px 16px"
---

# Design System: review-loop homepage

Scope: `site/` (the public homepage). The review-loop dashboard has its own world, recorded in the repository-root `DESIGN.md`; nothing here applies to it.

## Overview

**Creative North Star: "Challenge and Response"**

The page is one laminated normal-procedures card held over a dark flight-deck ground. Everything a visitor reads sits on that card: a black header strip naming the procedure, amber index tabs on the card's left edge that open each section, and checklist rows with a gutter number, a caps label, a dotted leader and the response at the right end. The review loop is shown as the two-person checklist it is: the reviewer reads a challenge (amber), the coder answers it, and the procedure is complete only when a green strip says so.

Density is that of a printed checklist: ruled rows, tight labels, generous outer padding. The ground is only a holder: a thin bar carries the mark and site nav above the card, and a single colophon line sits below it. There is one motion moment (the leaders drawing in the challenge-and-response panel); everything else is still.

**Key Characteristics:**
- One card, seen once, capped at the content width and rounded only at its outer corners.
- Amber is the reviewer and the section tab; green is a confirmed procedure; ink is every action.
- B612 for all type, B612 Mono for commands, file names and comment IDs.
- Dotted leaders join a challenge to its response in every checklist row.
- Ruled, flat surfaces on the card; the card alone carries a shadow.

## Colors

A cockpit palette: near-black ground, off-white card stock, black ink, and two signal colors used only for what they mean.

### Primary
- **Caution Amber** (`amber`): the section tabs, the reviewer's challenge marks (square bullet before a reviewer step, the BLOCKING grade), text selection, and the focus ring on the dark ground. Also the outline color of the mark's frame and check strokes.
- **Pale Amber** (`amber-soft`): the UNRESOLVED grade and the wash that marks the step currently playing in the run.

### Secondary
- **Confirmation Green** (`green`): only for a confirmed state: the RESOLVED grade, the COMPLETE strip, and the copy button after a successful copy. White text on it.

### Neutral
- **Flight-Deck Ground** (`ground`): page background behind the card. Text on it is **Panel Light** (`ground-ink`) and **Panel Grey** (`ground-muted`, nav links and the colophon).
- **Card Stock** (`card`): the card surface; also the text color on ink surfaces.
- **Card Stock Shade** (`card-2`): the challenge-and-response panel, the card footer, and file captions; a second plane on the same card.
- **Paper White** (`well`): command wells and the quoted file, which read as inserts on the card; text on green.
- **Ink** (`ink`): body text on the card, the header strip, every filled action, and all 1.5px marks and borders. **Ink Lift** (`ink-hover`) is its hover state.
- **Ink 2** (`ink-2`) for ledes and item details; **Muted** (`muted`) for gutter numbers, speaker labels and captions.
- **Rule** (`rule`) for dotted leaders and dashed borders; **Soft Rule** (`rule-soft`) for row and section dividers.
- Inline code chips use ink at 7% (`rgba(17,20,23,.07)`).

**The Signal Rule.** Amber means "challenge" or "section", green means "confirmed". Neither appears as decoration, and green never appears before something is actually resolved or completed.

## Typography

**Display Font:** B612 (with system-ui, sans-serif)
**Body Font:** B612
**Label/Mono Font:** B612 Mono (with ui-monospace, SFMono-Regular, Menlo, monospace)

**Character:** Airbus's open cockpit-display face: legible at small sizes, slightly technical, never decorative. All four weights are self-hosted (`site/fonts/`, 400 and 700 for each family); no other faces.

### Hierarchy
- **Display** (700, clamp 40–76px, 1.02, -0.01em, balanced wrap): the page title only.
- **Headline** (700, clamp 24–34px, 1.15, max 30ch): section titles inside the card.
- **Lede** (400, clamp 17–19px, max 46ch, `ink-2`): the line under the title. Section ledes use body size at max 64ch.
- **Body** (400, 16px, 1.55): running text; item details at 15px, max 64ch.
- **Item label** (700, 15px, 0.06em, uppercase): the challenge word of a checklist row.
- **Label** (700, 13px, 0.12–0.16em, uppercase): tabs, the header strip, button labels, the panel title; 12px at 0.1em for grades and speaker labels.
- **Mono** (400, 13–14px, 1.55–1.6): commands, file names, the quoted file. **Mono ID** (700, 13px): comment IDs, round indicator, gutter numbers (14px).

**The Placard Rule.** Uppercase with wide tracking is reserved for things printed on a procedures card: the header strip, tabs, checklist labels, grades, the COMPLETE strip and button labels. Sentences are never set in caps.

**The Machine Text Rule.** Anything a user types or a script writes (commands, paths, file names, `R<n>-C<n>` IDs) is B612 Mono; everything else is B612.

## Layout

A single centered column: the deck bar, the card and the colophon all cap at 1180px and share the horizontal padding `pad` (clamp 16–48px), so the card's content line, the tab text and the deck mark align.

- **Sections** stack inside the card, divided by a soft 1px rule. Each opens with its tab (28px above), then a body padded 20px top and 36px bottom.
- **First viewport** is a two-column grid (1.05fr / 1fr): title, lede and BEFORE START on the left; the challenge-and-response panel on a shaded right plane, separated by a soft rule. Below 900px it stacks, panel second.
- **Checklist rows** are a four-column grid: gutter number (2.4em), label, leader (min 24px, fills), response (max-content); details span from the label column. Below 700px the leader drops and the response moves under the label.
- **The record block** (file list beside a quoted file) is 1fr / 1.15fr and stacks below 820px.
- Rows breathe at 12px vertical padding with a soft rule between them; measure is capped at 46–70ch for prose.

**The Content Line Rule.** Tab words, checklist labels and the card header all start on the same left content line set by `pad`; the tab's amber block reaches out to the card's edge rather than shifting the text.

## Elevation & Depth

Flat by construction. The card is the only lifted object: a faint inset highlight plus a deep ambient drop (`0 1px 0 rgba(255,255,255,.06) inset, 0 18px 40px rgba(0,0,0,.35)`) that separates the laminate from the ground. Inside the card, depth is tonal (card, card shade, paper-white wells) and ruled (1px soft rules, 1.5px ink borders). No shadow appears on any element inside the card.

**The One Lamination Rule.** Only the card casts a shadow. Inside it, separate planes with tone and rules, never with elevation.

## Shapes

- The card has gently rounded outer corners (14px) and clips its contents; the header strip and footer run edge to edge.
- Index tabs are square on the card's edge and rounded (4px) on the free end only.
- Wells and the quoted file use 8px; buttons and the COMPLETE strip 6px; comment IDs, grades and inline code 3px; the round indicator 4px.
- Marks are drawn with 1.5px ink borders (IDs, grades, wells, ghost buttons); the COMPLETE strip uses 2px. The optional-input line (the RUN example) is a 1.5px dashed `rule` border.
- Speaker marks are geometric: a 9px amber square for the reviewer, a 9px card-colored circle for the coder, both outlined in ink.
- Leaders are a 2px dotted `rule` line.

## Components

### Section Tab
Amber index tab flush with the card's left edge (square there, 4px on the right), ink label text on the content line. Opens every card section and the BEFORE START block; it is the section heading (an `h2`), not a decoration.

### Checklist Row
Gutter number (mono, muted), uppercase label, dotted leader, response at the right end; optional detail paragraph or command well beneath. Rows divided by soft rules, the last row unruled.

### Command Well and Copy Button
Paper-white well with a 1.5px ink border and 8px radius holding mono commands that wrap only at spaces. The copy action is the well's bottom bar: full-width ink bar, 44px min height, uppercase label with a 16px stroke icon. Hover lifts to `ink-hover`; success turns it green and reads "Copied", with the result announced in a polite live region. Focus inside the card uses a 3px amber ring inset by 6px.

### Challenge-and-Response Panel (signature)
On the card's shaded plane: an uppercase panel title with a mono round indicator boxed in ink, a muted note, then one step per round-and-speaker. Each step has a speaker label with its mark (amber square for reviewer, circle for coder) and rows of comment ID, quoted words, dotted leader and a grade chip:
- **Blocking** amber, **Unresolved** pale amber, **Fixed** outline only, **Resolved** green with white text; all with a 1.5px border and 3px radius.

The run is the page's one motion moment: when the panel is 40% in view it plays once; unplayed steps sit at 18% opacity, each step's leaders scale in from the left (0.55s, `cubic-bezier(.16,1,.3,1)`), then its grades fade in (0.25s after 0.45s); the current step carries a pale-amber wash fading right. A step holds 850ms (1150ms for a reviewer check). Without script or with reduced motion, the finished record shows and the replay button is hidden.

### COMPLETE Strip
A 2px ink-outlined bar that turns solid green with white text when the procedure is complete: uppercase status on the left, mono "round N of M · 0 blocking" on the right.

### Buttons and Links
- **Filled link** (open the full loop): ink, 48px min height, 6px radius, uppercase label with trailing arrow; hover `ink-hover`.
- **Ghost** (replay): transparent with 1.5px ink border, 44px; hover fills with card stock.
- **Text links** inherit color, underline offset 3px. Deck nav links are `ground-muted`, 10px vertical padding for the tap target, underlined and brightened on hover.
- **Focus:** 2px amber outline at 3px offset on the ground; ink outline inside the card.

### Card Header Strip and Footer
Ink strip across the card top: uppercase procedure name on the left, a mono document number and version on the right in a lighter grey. The footer is a card-shade band with author, licence and repository.

## Do's and Don'ts

### Do:
- **Do** put new content on the card as a tabbed section with checklist rows before reaching for any other layout.
- **Do** keep amber for challenges and section tabs and green for confirmed states (The Signal Rule).
- **Do** set commands, file names and comment IDs in B612 Mono, and quote real loop files rather than paraphrasing them.
- **Do** keep every action at least 44px tall and keep the ink focus ring inside the card, amber outside it.
- **Do** give any new motion a finished, still state for reduced motion and no-script, as the run does.

### Don't:
- **Don't** add a second motion moment; the leaders drawing in the panel is the page's only one.
- **Don't** add shadows inside the card (The One Lamination Rule).
- **Don't** set sentences in uppercase or introduce a face other than B612 and B612 Mono.
- **Don't** add a dark hero with a terminal window or a grid of feature cards; the procedures card is the page.
