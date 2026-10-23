const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const moduleScope = { module: { exports: {} } };
vm.runInNewContext(html.match(/<script id="rl-derive">([\s\S]*?)<\/script>/)[1], moduleScope);
const RL = moduleScope.module.exports;
const source = html.slice(html.indexOf('  function cfgChanges('), html.indexOf('  // Save file:'));
function setup(served) {
  const nodes = new Map(), timers = new Map();
  let timerId = 0;
  const $ = key => {
    if (!nodes.has(key)) nodes.set(key, { textContent: '', disabled: false, style: {}, classList: { toggle() {} }, querySelectorAll: () => [] });
    return nodes.get(key);
  };
  const ctx = {
    RL, DATA: served ? { serve: { token: 'token' } } : {},
    CFG: { keys: [{ key: 'model', type: 'string' }], backends: ['codex'], script: '/config.sh', models: {},
      show: { effective: { model: '' }, files: [{ path: '/project/.review-loop.json', label: 'project shared', exists: true, values: {} }] } },
    cfgState: { scope: 'project', mode: 'shared', provider: 'claude', form: { model: 'first' }, initial: { model: '' }, force: new Set(), remove: new Set() },
    cfgTargetFile: () => ({ path: '/project/.review-loop.json', exists: true }),
    sectionOf: () => [], cfgRenderRows() {}, canPick: () => !served, $,
    launchProvider: 'claude', launchEffective: { model: '' }, startReady: false,
    setTimeout: fn => { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout: id => timers.delete(id)
  };
  vm.createContext(ctx);
  vm.runInContext('let cfgSaveTimer = null, cfgSaving = false, cfgFileHandle = null, cfgFileTarget = "";', ctx);
  vm.runInContext(source, ctx);
  const runTimer = () => { const [id, fn] = timers.entries().next().value; timers.delete(id); return fn(); };
  return { ctx, timers, $, runTimer };
}

(async () => {
  const { ctx, timers, $, runTimer } = setup(true);
  let resolve;
  const requests = [];
  ctx.fetch = async (url, options) => {
    requests.push({ url, options });
    return new Promise(done => { resolve = model => done({ ok: true, json: async () => ({ ok: true, output: '', show: { effective: { model }, files: [] }, launch_effective: { model } }) }); });
  };
  ctx.cfgUpdate();
  ctx.cfgUpdate();
  assert.equal(timers.size, 1, 'edits debounce into one save');
  assert.equal($('#cfg-scope-sel').disabled, true, 'destination locked while saving is pending');
  const first = runTimer();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/api/config');
  assert.equal(requests[0].options.headers['X-RL-Token'], 'token');
  assert.equal(JSON.parse(requests[0].options.body).set.model, 'first');
  ctx.cfgState.form.model = ''; // Revert while the earlier request is in flight.
  ctx.cfgUpdate();
  assert.equal(requests.length, 1, 'never sends overlapping writes');
  resolve('first'); await first;
  assert.equal(ctx.cfgState.form.model, '', 'old response cannot overwrite a newer edit');
  assert.equal(timers.size, 1, 'reverting to the old value still persists after the first write');
  const second = runTimer();
  assert.equal(JSON.parse(requests[1].options.body).set.model, '');
  resolve(''); await second;
  assert.equal(timers.size, 0);
  assert.match($('#cfg-out').textContent, /Saved automatically/);
  assert.equal($('#cfg-scope-sel').disabled, false);

  ctx.fetch = async () => { throw new Error('offline'); };
  ctx.cfgState.form.model = 'retry-me'; ctx.cfgUpdate(); await runTimer();
  assert.equal(timers.size, 0, 'failed saves do not retry forever');
  assert.equal(ctx.cfgState.form.model, 'retry-me');
  assert.match($('#cfg-out').textContent, /Not saved: offline/);
  assert.equal($('#cfg-apply').disabled, false);
  ctx.fetch = async () => ({ ok: true, json: async () => ({ ok: true, output: '', show: { effective: { model: 'retry-me' }, files: [] }, launch_effective: { model: 'retry-me' } }) });
  await ctx.cfgApply();
  assert.match($('#cfg-out').textContent, /Saved automatically/);
  ctx.CFG.keys.push({ key: 'max_rounds', type: 'integer' });
  ctx.CFG.show.effective.max_rounds = 5;
  ctx.cfgState.form.max_rounds = 'invalid'; ctx.cfgUpdate();
  assert.equal(timers.size, 0, 'invalid values are not auto-saved');
  assert.equal($('#cfg-apply').disabled, true);

  // Role preset checkboxes save on change like any other edit; unchecking
  // every box writes an empty list (defaults off), never an unset.
  const roles = setup(true), rc = roles.ctx;
  rc.CFG.keys = [{ key: 'roles.coder', type: 'list' }];
  rc.CFG.roles = [{ name: 'senior-qa' }, { name: 'tdd-guide' }];
  rc.CFG.show.effective = { roles: { coder: ['senior-qa'] } };
  rc.cfgState.form = { 'roles.coder': 'senior-qa' }; rc.cfgState.initial = { 'roles.coder': 'senior-qa' };
  const roleBodies = [];
  rc.fetch = async (url, options) => {
    const body = JSON.parse(options.body); roleBodies.push(body);
    const coder = String(body.set['roles.coder']).split(',').filter(Boolean);
    return { ok: true, json: async () => ({ ok: true, output: '', show: { effective: { roles: { coder } }, files: [] }, launch_effective: {} }) };
  };
  rc.cfgPickPreset('roles.coder', 'tdd-guide', true);
  assert.equal(roles.$('[data-key="roles.coder"]').value, 'senior-qa,tdd-guide', 'the text field follows the checkbox');
  assert.equal(roles.timers.size, 1, 'a checkbox change schedules an auto-save');
  await roles.runTimer();
  assert.equal(roleBodies[0].set['roles.coder'], 'senior-qa,tdd-guide');
  assert.match(roles.$('#cfg-out').textContent, /Saved automatically/);
  rc.cfgPickPreset('roles.coder', 'senior-qa', false); rc.cfgPickPreset('roles.coder', 'tdd-guide', false);
  assert.equal(roles.timers.size, 1, 'quick clicks debounce into one save');
  await roles.runTimer();
  assert.equal(roleBodies.length, 2);
  assert.equal(roleBodies[1].set['roles.coder'], '', 'unchecking all stores an empty list');
  assert.deepEqual(roleBodies[1].unset, []);
  rc.cfgPickPreset('roles.coder', 'bogus', true);
  assert.equal(roles.timers.size, 0, 'an unknown preset is not auto-saved');

  const local = setup(false);
  let fileText = '{"untouched":9007199254740999,"model":""}', writes = 0;
  local.ctx.handle = {
    getFile: async () => ({ text: async () => fileText }),
    createWritable: async () => ({ write: async text => { fileText = text; writes++; }, close: async () => {} })
  };
  local.ctx.cfgUpdate(); assert.equal(local.timers.size, 0, 'static pages need a chosen handle first');
  vm.runInContext('cfgFileHandle = handle; cfgFileTarget = "/project/.review-loop.json";', local.ctx);
  local.ctx.cfgUpdate(); await local.runTimer();
  assert.equal(writes, 1);
  assert.match(fileText, /9007199254740999/, 'lossless save preserves unrelated large integers');
  assert.equal(JSON.parse(fileText).model, 'first');
  fileText = fileText.replace('"untouched"', '"external-edit"');
  local.ctx.cfgState.form.model = 'second'; local.ctx.cfgUpdate(); await local.runTimer();
  assert.match(fileText, /external-edit/, 'each save reads the current file');
  fileText = '{broken';
  local.ctx.cfgState.form.model = 'third'; local.ctx.cfgUpdate(); await local.runTimer();
  assert.equal(writes, 2, 'invalid files are never overwritten');
  assert.match(local.$('#cfg-out').textContent, /Not saved/);
  assert.equal(local.timers.size, 0);

  // Exercise the real Start initialization, command builder, and submission
  // alongside auto-save; editing another provider must never change what the
  // server inherits, and a previously opened form must refresh its preview.
  const launch = setup(true), lc = launch.ctx;
  lc.esc = v => String(v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  lc.CFG.keys = [{ key: 'max_rounds', type: 'integer' }];
  const original = { backend: 'codex', model: '', effort: '', max_rounds: 5, usage: false };
  lc.launchEffective = { ...original };
  lc.CFG.show = { provider: 'claude', effective: { ...original }, files: [] };
  lc.cfgState.form = { max_rounds: '7' };
  lc.cfgState.mode = 'section'; lc.cfgState.provider = 'codex';
  vm.runInContext('let startBusy = false;\n' + html.slice(html.indexOf('  const startState ='), html.indexOf('  // Navigation:')), lc);
  let renders = 0;
  lc.startRenderFields = () => { renders++; };
  lc.fetch = async () => ({ ok: true, json: async () => ({ ok: true,
    show: { provider: 'codex', effective: { ...original, backend: 'claude', max_rounds: 7 }, files: [] },
    launch_effective: { ...original } }) });
  await lc.cfgApply();
  assert.equal(lc.CFG.show.provider, 'codex', 'configuration reconciles the provider being edited');
  lc.startInit(); lc.startReady = true;
  const form = vm.runInContext('startState', lc);
  assert.equal(form.backend, 'codex', 'Start initializes from the server provider, not the edited provider');
  assert.equal(form.max_rounds, '5');
  form.task = 'Keep this task'; lc.startUpdate();
  assert.doesNotMatch(launch.$('#start-cmd').textContent, /--max-rounds/);

  lc.cfgState.mode = 'shared'; lc.cfgState.form.max_rounds = '3';
  lc.fetch = async () => ({ ok: true, json: async () => ({ ok: true,
    show: { provider: 'claude', effective: { ...original, max_rounds: 3 }, files: [] },
    launch_effective: { ...original, max_rounds: 3 } }) });
  const before = renders;
  await lc.cfgApply();
  assert.equal(renders, before + 1, 'an open Start form refreshes after auto-save');
  assert.equal(form.task, 'Keep this task');
  assert.equal(form.max_rounds, '5', 'existing per-loop choices survive a configuration save');
  assert.match(launch.$('#start-cmd').textContent, /--max-rounds 5\b/, 'preview immediately includes the retained override');
  let submitted;
  lc.fetch = async (url, options) => {
    assert.equal(url, '/api/start'); submitted = JSON.parse(options.body);
    return { ok: false, json: async () => ({ ok: false, output: 'Test request captured' }) };
  };
  launch.$('#start-next').style = {};
  await lc.startGo();
  assert.equal(submitted.max_rounds, 5, 'Start submits the cap shown in the copied command');
  assert.equal(submitted.backend, undefined, 'matching server defaults need no backend override');
  console.log('auto-save debounce, serialized writes, edit reconciliation, retry, and lossless file saves passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
