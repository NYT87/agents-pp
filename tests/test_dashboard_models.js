// Exercise the real dropdown builders and catalog button handlers without a
// browser dependency. The lifecycle suite invokes this when Node is available.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
for (const script of html.matchAll(/<script(?: id="rl-derive")?>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
const derive = html.match(/<script id="rl-derive">([\s\S]*?)<\/script>/)[1];
const moduleScope = { module: { exports: {} } };
vm.runInNewContext(derive, moduleScope);
const RL = moduleScope.module.exports;
const plain = value => JSON.parse(JSON.stringify(value));
const cat = { backend: 'codex', models: [
  { id: 'small', label: 'Small', efforts: ['low'], default: true },
  { id: 'large', label: 'Large', efforts: ['low', 'high'], default_effort: 'high' },
  { id: 'unknown', efforts: [] }
], efforts: ['low', 'high'], default_model: 'small', default_effort: 'low' };

assert.deepEqual(plain(RL.catalogChoices(cat, 'model', '', '')), [
  { value: '', label: 'backend default (small)' },
  { value: 'small', label: 'Small (default)' },
  { value: 'large', label: 'Large' },
  { value: 'unknown', label: 'unknown' }
]);
assert.deepEqual(plain(RL.catalogChoices(cat, 'effort', '', 'small')).map(x => x.value), ['', 'low']);
assert.deepEqual(plain(RL.catalogChoices(cat, 'effort', '', '')).map(x => x.value), ['', 'low']);
assert.deepEqual(plain(RL.catalogChoices(cat, 'effort', '', 'unknown')).map(x => x.value), ['']);
assert.deepEqual(plain(RL.catalogChoices(null, 'model', 'custom', '')).map(x => x.value), ['', 'custom']);
assert.deepEqual(plain(RL.catalogSelection(cat, 'small', 'high', false)), { model: 'small', effort: '' });
assert.deepEqual(plain(RL.catalogSelection(cat, 'old-backend-model', 'high', true)), { model: '', effort: '' });
assert.deepEqual(plain(RL.catalogSelection(cat, 'unknown', 'custom', false)), { model: 'unknown', effort: 'custom' });
assert.equal(RL.readCatalog({ config: { models: { codex: cat } } }, 'codex'), cat);
assert.throws(() => RL.readCatalog(cat, 'claude'), /valid model catalog/);
assert.throws(() => RL.readCatalog({ models: [{ id: 'bad', efforts: 'high' }], efforts: [] }, 'codex'), /valid model catalog/);

const controls = html.slice(html.indexOf('  function catalogSelect('), html.indexOf('  function cfgInit('));
function setup(served) {
  const nodes = new Map();
  const $ = key => { if (!nodes.has(key)) nodes.set(key, { dataset: { catalogBackend: 'codex' }, disabled: false, clicks: 0, click() { this.clicks++; } }); return nodes.get(key); };
  const calls = { cfg: 0, start: 0, fetch: 0 };
  const ctx = {
    RL, CFG: { script: '/project with spaces/config.sh', show: { effective: { backend: 'codex' } }, models: { codex: { models: [], efforts: [] } } },
    DATA: served ? { serve: { token: 'private' } } : {},
    cfgState: { scope: 'user', mode: 'file', provider: 'codex', form: { backend: 'codex', model: 'custom', effort: '' } },
    launchEffective: { backend: 'codex' },
    startReady: true, startState: { task: 'keep my task', backend: 'codex', model: 'large', effort: 'high' },
    cfgRenderRows: () => calls.cfg++, cfgUpdate() {}, startRenderFields: () => calls.start++, startUpdate() {},
    $, location: { pathname: '/dashboard.html' },
    esc: value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    navigator: { clipboard: { writeText: async text => { calls.clipboard = text; } } },
    fetch: async (url, options) => { calls.fetch++; calls.request = [url, options]; return { ok: true, json: async () => ({ ok: true, catalog: cat }) }; },
    DOMParser: class { parseFromString(text) { return { getElementById: () => ({ textContent: text }) }; } }
  };
  vm.createContext(ctx);
  vm.runInContext(controls, ctx);
  return { ctx, calls, $ };
}

(async () => {
  const { ctx, calls, $ } = setup(true);
  const options = ctx.catalogSelect('model', 'custom', cat, '', 'data-key="model"', false);
  assert.match(options, /^<select /);
  assert.match(options, /value="custom" selected>custom \(not listed\)/);
  assert.doesNotMatch(options, /<input|<datalist/);
  assert.match(ctx.catalogSelect('effort', '', {}, '', 'data-start="effort"', false), /^<select /);
  assert.match(ctx.catalogSelect('model', '<script>', {}, '', 'data-key="model"', true), /&lt;script&gt;/);
  assert.match(ctx.catalogSelect('model', '', {}, '', 'data-key="model"', true), / disabled>/);
  assert.match(ctx.catalogActions('cfg-model', 'codex'), /Refresh available options/);
  assert.match(ctx.catalogActions('cfg-model', ''), /disabled/);
  ctx.bindCatalogActions('cfg-model', 'codex');
  await $('#cfg-model-refresh').onclick();
  assert.equal(calls.fetch, 1);
  assert.equal(calls.request[0], '/api/models');
  assert.equal(calls.request[1].method, 'POST');
  assert.equal(calls.request[1].headers['X-RL-Token'], 'private');
  assert.deepEqual(JSON.parse(calls.request[1].body), { backend: 'codex', scope: 'user', mode: 'file', provider: 'codex' });
  assert.equal(calls.cfg, 1);
  assert.equal(calls.start, 1);
  assert.equal(ctx.CFG.models.codex.models.length, 3);
  assert.equal(ctx.cfgState.form.model, 'custom');
  assert.equal(ctx.startState.task, 'keep my task');
  assert.equal(ctx.startState.model, 'large');
  assert.match($('#cfg-model-status').textContent, /3 models loaded/);
  assert.equal($('#cfg-model-refresh').disabled, false);
  ctx.fetch = async () => ({ ok: false, status: 422, json: async () => ({ ok: false, output: 'cannot save catalog at selected config folder' }) });
  await $('#cfg-model-refresh').onclick();
  assert.match($('#cfg-model-status').textContent, /cannot save catalog at selected config folder/);
  ctx.fetch = async () => { throw new Error('offline'); };
  await $('#cfg-model-refresh').onclick();
  assert.match($('#cfg-model-status').textContent, /offline/);
  assert.equal(ctx.CFG.models.codex.models.length, 3);
  assert.equal($('#cfg-model-refresh').disabled, false);

  const offline = setup(false);
  assert.match(offline.ctx.catalogActions('start-model', 'codex'), /Load model catalog/);
  assert.match(offline.ctx.catalogActions('start-model', 'codex'), /Copy catalog command/);
  offline.ctx.bindCatalogActions('start-model', 'codex');
  await offline.$('#start-model-refresh').onclick();
  assert.equal(offline.$('#start-model-file').clicks, 1);
  assert.equal(offline.calls.fetch, 0);
  await offline.$('#start-model-export').onclick();
  assert.equal(offline.calls.clipboard, "bash '/project with spaces/config.sh' models --backend codex");
  const input = { files: [{ text: async () => JSON.stringify(cat) }], value: 'chosen.json' };
  await offline.$('#start-model-file').onchange({ target: input });
  assert.equal(offline.ctx.CFG.models.codex.models.length, 3);
  assert.equal(input.value, '');
  input.files[0].text = async () => '{broken';
  await offline.$('#start-model-file').onchange({ target: input });
  assert.match(offline.$('#start-model-status').textContent, /Could not load options/);
  assert.equal(offline.ctx.CFG.models.codex.models.length, 3);
  console.log('dropdown rendering, dependent choices, refresh, file loading, and recovery passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
