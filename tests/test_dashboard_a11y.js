// Keyboard and screen-reader wiring of the dashboard: page landmarks, labelled
// form controls, focus kept across re-renders, chart tables, and robust start
// requests. The lifecycle suite invokes this when Node is available.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const moduleScope = { module: { exports: {} } };
vm.runInNewContext(html.match(/<script id="rl-derive">([\s\S]*?)<\/script>/)[1], moduleScope);
const RL = moduleScope.module.exports;
const slice = (from, to) => { const a = html.indexOf(from), b = html.indexOf(to, a); assert.ok(a >= 0 && b > a, `slice ${from}`); return html.slice(a, b); };
const esc = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Every label points at a control that exists in the same markup.
const labelsResolve = markup => {
  const fors = [...markup.matchAll(/<label for="([^"]+)"/g)].map(m => m[1]);
  for (const id of fors) assert.ok(markup.includes(`id="${id}"`), `label for="${id}" has a control`);
  assert.equal([...markup.matchAll(/<label(?![^>]*\bfor=)/g)].length, 0, 'no label without for');
  return fors;
};

// Static page structure.
assert.match(html, /<main>[\s\S]*id="view-home"[\s\S]*id="view-config"[\s\S]*<\/main>/, 'views sit in <main>');
for (const [id, name] of [['home', 'Loops'], ['loop', 'Loop'], ['start', 'Start a loop'], ['config', 'Configuration']])
  assert.match(html, new RegExp(`<section class="view" id="view-${id}" tabindex="-1" aria-label="${name}">`), `view-${id} can take focus`);
assert.match(html, /id="cfg-out" role="status"/, 'save results are announced');
assert.match(html, /id="start-out" role="status"/, 'start results are announced');
assert.match(html, /<a href="\$\{esc\(RL\.loopHref\(l\.id\)\)\}">/, 'each loop row has a real link');

// Native surfaces stay in the token system: placeholders pass 4.5:1 through
// the muted token, checkboxes are ink (blue belongs to the coder), and a
// preset checkbox never shrinks beside a long title.
assert.match(html, /::placeholder \{ color: var\(--muted\); opacity: 1; \}/, 'placeholders use the muted token');
assert.match(html, /:root \{ accent-color: var\(--action\); \}/, 'checkboxes use the ink action colour');
assert.match(html, /fieldset\.role-picks input \{ flex: none;/, 'preset checkboxes keep their size');
assert.match(html, /\.crumbs a \{ display: inline-block; padding: 4px 0;/, 'the breadcrumb is a 24px target');
// Reflow at 320px (WCAG 1.4.10): no grid column minimum may exceed its container.
const minimums = [...html.matchAll(/minmax\((min\([^)]*\)|[^,]+),/g)].map(m => m[1].trim());
assert.ok(minimums.length >= 7, 'grids found');
for (const m of minimums) assert.match(m, /^min\(\d+px, 100%\)$/, `grid minimum ${m} is capped at 100%`);
assert.match(html, /\.cfg-scope \.mono \{ min-width: 0; overflow-wrap: anywhere; \}/, 'the config target path wraps');
assert.match(html, /h1, h2, h3, h4, \.md \.md-h1, \.md \.md-h2, \.md \.md-h3, \.md \.md-h4 \{ text-wrap: balance; \}/, 'headings wrap balanced');
assert.match(html, /\.md p, \.md li \{ text-wrap: pretty; \}/, 'rendered prose avoids orphaned last words');
assert.match(html, /<span class="pick-sum">\$\{esc\(p\.summary\)\}<\/span>/, 'preset summaries are visible, not only a tooltip');

// Finish details: hints at the 12px hint size, counts and timings as plain
// text (chips are for status), usage behind a disclosure, example placeholders,
// and the time chart in seconds when every loop is under two minutes.
assert.match(html, /<div class="help" id="cfg-h-\$\{k\.key\}">/, 'field help lines use the hint style');
assert.match(html, /\.cfg-row \.help, \.catalog-status \{ color: var\(--muted\); font-size: 12px; \}/, 'hints and catalog status lines are 12px');
assert.doesNotMatch(html, /chip neutral"><i><\/i>\$\{r\.blocking\} blocking/, 'the blocking count is not a chip');
assert.match(html, /<div class="round-head"><h3>Round \$\{f\.round\} [^\n]*<\/h3>\n\s*\$\{meta && !SHARE \? `<span class="round-meta">/, 'round counts sit outside the heading (and are left out of a shared page)');
assert.match(html, /<details class="usage"><summary>Token usage/, 'per-round usage is behind a disclosure');
assert.match(html, /'dashboard\.dirs': 'e\.g\. \.review-loop,archive'/, 'list placeholders are examples');
assert.doesNotMatch(html, /placeholder="\$\{k\.type === 'list' \? 'comma-separated'/, 'no hint dressed as a placeholder');
{
  const sec = RL.timeUnit([5, 119]), min = RL.timeUnit([30, 120]), none = RL.timeUnit([]);
  assert.deepEqual([sec.name, sec.value(59.9), sec.value(null)], ['Seconds', 59, 0], 'under two minutes the chart counts whole seconds');
  assert.deepEqual([min.name, min.value(96)], ['Minutes', 1.6], 'otherwise minutes, floored to a tenth');
  assert.equal(none.name, 'Seconds');
}

// Start a loop: an active loop locks the form behind an alert that links to
// it; success stays on a confirmation panel (no timed reload); a summary line
// says what will run.
assert.match(html, /<div class="start-banner" id="start-banner" style="display:none"><\/div>/, 'the active-loop banner is plain text, not an alert announced on every visit');
assert.match(html, /const locked = !!activeLoop\(\);[\s\S]{0,200}task\.disabled = locked;/, 'the form locks while another loop runs');
assert.doesNotMatch(html, /setTimeout\(\(\) => \{ if \(j\.loop_id\)/, 'no timed reload after a start');
assert.match(html, /id="start-open">Open the loop<\/button>/, 'success offers an Open the loop button');
assert.equal(RL.startSummary({ backend: '', model: '', effort: '', max_rounds: '', usage: false }, { backend: 'codex', model: 'gpt-x', effort: 'high', max_rounds: 5 }, { reviewer: ['code-reviewer'], coder: [] }),
  'Runs the codex reviewer with gpt-x at high effort, for at most 5 rounds, usage tracking off. Role presets: reviewer code-reviewer; coder none.');
assert.equal(RL.startSummary({ backend: 'claude', model: '', effort: '', max_rounds: '1', usage: true }, { backend: 'codex', model: 'gpt-x', effort: 'high' }),
  'Runs the claude reviewer with its default model, for at most 1 round, usage tracking on.', 'a chosen backend does not inherit another backend\'s model');
assert.equal(RL.startSummary({ backend: '', model: '', effort: '', max_rounds: '', usage: false }, {}),
  'Runs the configured reviewer with its default model, for at most the configured number of rounds, usage tracking off.', 'a hidden configuration still reads as a sentence');
assert.match(html, /const problem = active \? `# a loop is already active/, 'the command names the active loop before anything else');
// Configuration: precedence detail behind a remembered switch; tools are named.
assert.match(html, /\.cfg-simple \.cfg-row \.src-note, \.cfg-simple \.cfg-row \.tools, \.cfg-simple \.scope-ctl \{ display: none; \}/, 'simple mode hides sources, tools and the file picker');
assert.match(html, /id="cfg-adv" aria-pressed="\$\{sc\.advanced \? 'true' : 'false'\}">/, 'the switch reports its state');
assert.match(html, /cfgState\.advanced = pref === '1' \|\| cfgState\.scope !== 'project' \|\| cfgState\.mode !== 'shared';/, 'a non-default target always shows the detail');
assert.doesNotMatch(html, /in target:|not in target'/, 'plain language instead of "target"');
// Reader mode (dashboard.sh --share): no Start or Configuration, a primer.
assert.match(html, /if \(SHARE && \(r\.view === 'config' \|\| r\.view === 'start'\)\) \{ location\.replace\('#\/'\); return; \}/, 'a shared page has no Start or Configuration');
assert.match(html, /\$\{SHARE \? PRIMER : ''\}/, 'a shared loop page starts with the primer');
assert.match(html, /\[hidden\] \{ display: none !important; \}/, 'hidden nav stays hidden under the touch rules');
assert.match(html, /<div class="catalog-status" id="\$\{id\}-status"/, 'catalog status lines use the hint style');

// Configuration reads as a form for people: labels first, keys beside them,
// presets folded, a switch that says and shows its state.
assert.match(html, /const KEY_LABELS = \{ backend: 'Reviewer backend'/, 'fields have human labels');
assert.match(html, /\$\{esc\(KEY_LABELS\[k\.key\] \|\| k\.key\)\}<\/label> <span class="key mono">\$\{esc\(k\.key\)\}<\/span>/, 'the key stays beside its label');
assert.match(html, /<details class="role-picks-fold"><summary>Change \$\{esc\(def\.role\)\} presets<\/summary>/, 'preset pickers are folded');
assert.match(html, /\$\{sc\.advanced \? 'Hide' : 'Show'\} where values come from/, 'the switch label follows its state');
assert.match(html, /\.cfg-scope \.adv\[aria-pressed="true"\] \{ background: var\(--action\)/, 'the switch looks pressed when on');
assert.match(html, /v === '' \? 'the configured backend \(hidden on this page\)'/, 'a hidden backend is named, not blank');
// Only the loops table looks clickable.
assert.doesNotMatch(html, /^\s*tbody tr \{ cursor: pointer; \}/m, 'no global row cursor');
assert.match(html, /#loops tbody tr\[data-id\] \{ cursor: pointer; \}/, 'loop rows keep theirs');
// The shared page leads with the reviews; the stats fold away.
assert.match(html, /fold\.className = 'stats-fold'[\s\S]{0,260}list\.parentNode\.insertBefore\(list, fold\);/, 'shared home: loop list before the folded stats');
assert.match(html, /list\.querySelector\('\.hint'\)\.insertAdjacentHTML\('afterend', PRIMER\)/, 'the primer follows the list heading');
assert.ok(html.indexOf('const PRIMER =') < html.indexOf('const SHARE = !!DATA.share;'), 'the primer exists before the shared page uses it');

// Home: the loop list leads on every page and the stats fold below it;
// shared pages hide the timing and cost columns.
assert.match(html, /fold\.className = 'stats-fold'[\s\S]{0,240}list\.parentNode\.insertBefore\(list, fold\);\n\s*if \(SHARE\) list\.querySelector/, 'every home page leads with the list');
assert.match(html, /\.reader \.share-hide \{ display: none; \}/, 'shared pages hide timing and cost columns');
assert.match(html, /const oneDay = new Set\(/, 'chart labels drop a date every loop shares');
// Configuration: a sticky save bar summarising the pending changes.
assert.match(html, /<div class="cfg-savebar" id="cfg-savebar">\s*<p class="cfg-summary" id="cfg-summary"><\/p>/, 'the save bar leads with a summary');
assert.match(html, /\.cfg-savebar \{ position: sticky; bottom: 0;/, 'the save bar stays in view');
assert.match(html, /\.cfg-row\.changed \.key::after \{ content: " · edited";/, '"edited" follows the key');
assert.match(html, /<label for="start-f-max_rounds">Round cap<\/label>/, 'one name for the round cap');

// Pure helpers.
assert.equal(RL.loopHref('a b/c'), '#/loop/a%20b%2Fc');
assert.deepEqual({ ...RL.parseRoute(RL.loopHref('a b/c')) }, { view: 'loop', id: 'a b/c' });
const table = RL.chartTable('Minutes <per> loop', [
  { label: 'Oct 1 · fix "x"', segments: [{ name: 'coder', value: 3 }, { name: 'reviewer', value: 1 }] },
  { label: 'Oct 2', segments: [{ name: 'coder', value: 0 }] }
]);
assert.match(table, /^<div class="sr-only"><table><caption>Minutes &lt;per&gt; loop<\/caption>[\s\S]*<\/table><\/div>$/);
assert.match(table, /<th scope="col">loop<\/th><th scope="col">coder<\/th><th scope="col">reviewer<\/th>/);
assert.match(table, /<th scope="row">Oct 1 · fix &quot;x&quot;<\/th><td>3<\/td><td>1<\/td>/);
assert.match(table, /<th scope="row">Oct 2<\/th><td>0<\/td><td><\/td>/, 'a missing segment is an empty cell');
assert.match(RL.chartTable('Rounds', [{ label: 'a', segments: [{ value: 2 }] }]), /<th scope="col">value<\/th>[\s\S]*<td>2<\/td>/);

// Markdown inside a round (h3) starts at h4, capped at h6; the class keeps the size.
const mdScope = { esc };
vm.createContext(mdScope);
vm.runInContext(slice('  function md(', '  // ── render'), mdScope);
const rendered = mdScope.md('# Round 1 — coder summary\n\n## What I did\n\n#### Detail\n\ntext');
assert.match(rendered, /<h4 class="md-h1">Round 1 — coder summary<\/h4>/);
assert.match(rendered, /<h5 class="md-h2">What I did<\/h5>/);
assert.match(rendered, /<h6 class="md-h4">Detail<\/h6>/);
assert.doesNotMatch(rendered, /<h[123][ >]/, 'no markdown heading outranks the round heading');
// Inline code: spans may wrap lines, use longer backtick runs, and are never formatted inside.
assert.equal(mdScope.md('see `a\nb` end'), '<p>see <code>a b</code> end</p>');
assert.equal(mdScope.md('``x `y` z``'), '<p><code>x `y` z</code></p>');
assert.equal(mdScope.md('`**a**` and **b**'), '<p><code>**a**</code> and <b>b</b></p>');
assert.equal(mdScope.md('`<b>` R1-C2'), '<p><code>&lt;b&gt;</code> <span class="cid">R1-C2</span></p>');
assert.equal(mdScope.md('a ` b'), '<p>a ` b</p>', 'an unmatched backtick stays literal');
// A list item continues on indented lines that do not start a new item.
assert.equal(mdScope.md('- one `x\n  y` two\n- three\n1. first\n   more'), '<ul><li>one <code>x y</code> two</li><li>three</li></ul><ol><li>first more</li></ol>');
// Document panes are named regions; ones that scroll get a tab stop.
for (const who of ['coder', 'reviewer']) assert.ok(html.includes(`<div class="doc ${who}" role="region" aria-label="Round \${f.round} ${who}">`), `${who} pane is a named region`);
assert.match(html, /role="region" aria-label="Loop summary"/);
assert.match(html, /querySelectorAll\('\.doc'\)\.forEach\(p => \{ if \(p\.scrollHeight > p\.clientHeight \+ 1[^\n]*p\.tabIndex = 0/);

const controls = slice('  function keepFocus(', '  function cfgInit(');
const startSource = slice('  function startRenderFields(', '  // Navigation:');
const cfgSource = slice('  function cfgRenderRows(', '  function cfgChanges(');

function setup() {
  const nodes = new Map(), focused = [];
  const node = key => ({ key, innerHTML: '', textContent: '', disabled: false, style: {}, dataset: { catalogBackend: 'codex' },
    className: '', value: '', contains: () => true, querySelectorAll: () => [], focus() { focused.push(key); } });
  const $ = key => { if (!nodes.has(key)) nodes.set(key, node(key)); return nodes.get(key); };
  const document = { activeElement: null, getElementById: id => node(id) };
  const fetches = [];
  const ctx = {
    RL, $, esc, document, focused, fetches,
    DATA: { serve: { token: 't' }, templates: {} },
    CFG: { backends: ['codex', 'claude'], models: { codex: { models: [{ id: 'm1' }], efforts: ['low'] } },
      show: { effective: { backend: 'codex' }, prompt_files: {} },
      keys: [{ key: 'backend', type: 'string', help: 'reviewer CLI' }, { key: 'model', type: 'string', help: 'model' },
        { key: 'max_rounds', type: 'integer', help: 'cap' }, { key: 'dashboard.auto', type: 'boolean', help: 'auto' },
        { key: 'prompts.reviewer', type: 'string', help: 'reviewer prompt' }] },
    cfgState: { form: { backend: 'codex', model: '', max_rounds: '5', 'dashboard.auto': 'true', 'prompts.reviewer': '' },
      initial: {}, remove: new Set(), force: new Set() },
    launchEffective: { backend: 'codex' },
    startReady: true, startState: { task: 'do it', backend: '', model: '', effort: '', max_rounds: '', usage: false },
    srcOf: () => 'default', targetHas: () => false, targetValue: () => '', cfgTargetFile: () => ({}),
    cfgUpdate() {}, activeLoop: () => null, startScript: () => '/x/start.sh',
    fetch: (url, options) => new Promise(resolve => fetches.push({ url, options, resolve })),
    setTimeout() {}, location: {}
  };
  vm.createContext(ctx);
  vm.runInContext('let startBusy = false;\n' + controls + startSource + cfgSource, ctx);
  return ctx;
}

(async () => {
  const ctx = setup();

  // Start form: every field is labelled, and focus survives the re-render
  // that a backend change triggers.
  ctx.document.activeElement = { id: 'start-f-backend' };
  ctx.startRenderFields();
  const startFields = ctx.$('#start-fields').innerHTML;
  assert.deepEqual(labelsResolve(startFields), ['start-f-backend', 'start-f-model', 'start-f-effort', 'start-f-max_rounds', 'start-f-usage']);
  assert.deepEqual(ctx.focused, ['start-f-backend'], 'focus returns to the control that had it');
  ctx.focused.length = 0;
  ctx.document.activeElement = { id: '' };
  ctx.startRenderFields();
  assert.deepEqual(ctx.focused, [], 'no focus is moved when none was inside the form');

  // Configuration rows: the label names the control; the help line describes it.
  ctx.document.activeElement = { id: 'cfg-f-dashboard.auto' };
  ctx.cfgRenderRows();
  const grid = ctx.$('#cfg-grid').innerHTML;
  const ids = labelsResolve(grid);
  assert.deepEqual(ids.sort(), ['cfg-f-backend', 'cfg-f-dashboard.auto', 'cfg-f-max_rounds', 'cfg-f-model', 'cfg-f-prompts.reviewer']);
  for (const id of ids) {
    const key = id.slice('cfg-f-'.length);
    assert.ok(grid.includes(`aria-describedby="cfg-h-${key}"`) && grid.includes(`id="cfg-h-${key}"`), `${key} is described by its help line`);
  }
  assert.doesNotMatch(grid, /<label[^>]*>[^<]*<span class="src">/, 'the source note is not part of the label');
  assert.match(grid, /<span class="src src-note">/, 'source notes carry the class simple mode hides');
  assert.deepEqual(ctx.focused, ['cfg-f-dashboard.auto']);

  // Start requests: one at a time, and a non-JSON failure names the status.
  ctx.startUpdate();
  assert.equal(ctx.$('#start-go').disabled, false);
  const first = ctx.startGo();
  ctx.startGo();
  assert.equal(ctx.fetches.length, 1, 'a second press while starting sends nothing');
  assert.equal(ctx.$('#start-go').disabled, true, 'Start is disabled while the request runs');
  ctx.fetches[0].resolve({ ok: false, status: 502, json: async () => { throw new SyntaxError('Unexpected token <'); } });
  await first;
  assert.equal(ctx.$('#start-out').textContent, 'Could not start the loop: Dashboard request failed (502).');
  assert.equal(ctx.$('#start-go').disabled, false, 'Start is enabled again after a failure');

  const ok = ctx.startGo();
  ctx.fetches[1].resolve({ ok: true, status: 200, json: async () => ({ ok: true, output: 'started', loop_id: 'L1' }) });
  await ok;
  assert.equal(ctx.$('#start-go').disabled, true, 'Start stays disabled until the page reloads');
  await assert.rejects(RL.readJson({ status: 500, json: async () => { throw new Error('bad'); } }), /Dashboard request failed \(500\)/);

  // Charts: the real barChart on a minimal DOM. One tab stop per chart,
  // arrow keys between rows, Enter opens the row's loop, keyboard focus shows
  // the tooltip, and each row's target is at least 24px (32px for touch).
  class Node {
    constructor(tag) { this.tag = tag; this.attrs = {}; this.children = []; this.style = {}; this.cls = new Set(); this.classList = { add: c => this.cls.add(c), remove: c => this.cls.delete(c) }; }
    setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    appendChild(c) { this.children.push(c); return c; }
    matches() { return true; } getBoundingClientRect() { return { left: 0, bottom: 0 }; }
    focus() { doc.activeElement = this; if (this.onfocus) this.onfocus(); }
  }
  const all = n => [n, ...n.children.flatMap(all)];
  const doc = { activeElement: null, createElementNS: (ns, tag) => new Node(tag),
    createElement: tag => { assert.equal(tag, 'template', 'link names are parsed inertly'); return { content: {}, set innerHTML(h) { this.content.textContent = h.replace(/<[^>]+>/g, ''); } }; } };
  const drawChart = coarse => {
    const tips = [], container = { innerHTML: '', clientWidth: 600, kids: [], appendChild(c) { this.kids.push(c); }, insertAdjacentHTML() {} };
    const c = { RL, document: doc, location: { hash: '' }, matchMedia: () => ({ matches: coarse }), fmtNum: String,
      showTip: (e, h) => tips.push(h), hideTip: () => tips.push(null), select: id => { c.location.hash = RL.loopHref(id); } };
    vm.createContext(c);
    vm.runInContext(slice("  const ns = 'http", '  // ── markdown') + '; this.barChart = barChart;', c);
    const rows = ['a', 'b', 'c'].map(id => ({ id, label: 'Loop ' + id, segments: [{ name: 'rounds', value: 1, color: 'var(--muted)' }], tip: () => `<b>Task ${id}</b><br>1 of 3 rounds` }));
    c.barChart(container, rows, { label: 'Rounds per loop' });
    return { c, tips, svg: container.kids[0] };
  };
  const { c, tips, svg } = drawChart(false);
  assert.equal(svg.getAttribute('role'), 'group'); assert.equal(svg.getAttribute('aria-label'), 'Rounds per loop');
  assert.equal(svg.getAttribute('aria-hidden'), null, 'the chart itself is not hidden, so its links are reachable');
  const links = svg.children.filter(n => n.tag === 'a');
  assert.deepEqual(links.map(a => a.getAttribute('tabindex')), ['0', '-1', '-1'], 'one tab stop per chart');
  assert.equal(links[0].getAttribute('aria-label'), 'Task a, 1 of 3 rounds', 'a link is named by its full tooltip text');
  assert.equal(links[0].getAttribute('href'), '#/loop/a');
  assert.ok(svg.children.filter(n => n.tag !== 'a').every(n => n.getAttribute('aria-hidden') === 'true'), 'marks are hidden from screen readers');
  const key = k => { let prevented = false; svg.onkeydown({ key: k, preventDefault: () => { prevented = true; } }); return prevented; };
  links[0].focus();
  assert.equal(tips.at(-1), '<b>Task a</b><br>1 of 3 rounds', 'keyboard focus shows the tooltip');
  assert.ok(key('ArrowDown')); assert.equal(doc.activeElement, links[1]);
  assert.deepEqual(links.map(a => a.getAttribute('tabindex')), ['-1', '0', '-1'], 'the tab stop follows the focused row');
  key('End'); assert.equal(doc.activeElement, links[2]); key('ArrowDown'); assert.equal(doc.activeElement, links[2], 'arrows stop at the last row');
  key('Home'); assert.equal(doc.activeElement, links[0]); key('ArrowUp'); assert.equal(doc.activeElement, links[0]);
  assert.equal(key('Tab'), false, 'Tab leaves the chart');
  links[0].onblur(); assert.equal(tips.at(-1), null, 'leaving a row hides its tooltip');
  key('ArrowDown'); key('Enter'); assert.equal(c.location.hash, '#/loop/b', 'Enter opens the focused row');
  const ring = a => all(a).find(n => n.tag === 'rect');
  assert.equal(ring(links[0]).getAttribute('height'), '24', 'rows are 24px targets');
  assert.equal(ring(drawChart(true).svg.children.find(n => n.tag === 'a')).getAttribute('height'), '32', 'touch rows are 32px');
})().catch(e => { console.error(e); process.exit(1); });
