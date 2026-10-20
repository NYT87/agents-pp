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
for (const who of ['coder', 'reviewer']) assert.ok(html.includes(`<div class="doc" role="region" aria-label="Round \${f.round} ${who}">`), `${who} pane is a named region`);
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
})().catch(e => { console.error(e); process.exit(1); });
