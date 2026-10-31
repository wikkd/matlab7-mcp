// v3 regression driver: speaks MCP stdio to mcp-server.js, runs every tool once.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const WORK = path.resolve(process.argv[2] || __dirname);
const SERVER = path.join(WORK, 'mcp-server.js');

let proc;
let buf = '';
let nextId = 1;
const pending = new Map();

function rpc(method, params) {
  return new Promise((res, rej) => {
    const id = nextId++;
    if (method.startsWith('notifications/')) {
      proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
      res({});
      return;
    }
    pending.set(id, { res, rej });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); rej(new Error('rpc timeout ' + method)); }
    }, 300000);
  });
}

function onLine(line) {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id);
    pending.delete(m.id);
    if (m.error) p.rej(new Error(m.error.message));
    else p.res(m.result);
  }
}

async function tool(name, args) {
  const r = await rpc('tools/call', { name, arguments: args });
  const texts = (r.content || []).filter(c => c.type === 'text').map(c => c.text);
  const images = (r.content || []).filter(c => c.type === 'image');
  return { isError: !!r.isError, text: texts.join('\n'), nImages: images.length, content: r.content };
}

function report(label, r, expectOk = true) {
  const okFlag = expectOk ? !r.isError : r.isError;
  const txt = r.text.replace(/\s+/g, ' ').slice(0, 180);
  console.log(`${okFlag ? 'PASS' : 'FAIL'}  ${label}  ${expectOk ? '' : '(expected-error)'} :: ${txt}`);
  return okFlag;
}

async function main() {
  const results = { pass: 0, fail: 0 };
  const T = async (label, expectOk, fn) => {
    try {
      const r = await fn();
      if (report(label, r, expectOk)) results.pass++; else results.fail++;
      return r;
    } catch (e) {
      console.log(`FAIL  ${label}  exception: ${e.message}`);
      results.fail++;
      return null;
    }
  };

  // start clean: drop leftover artifacts from previous rounds
  for (const f of ['v3_test_file.m', 'v3_log.md', 'v3tst.mdl', 'req.json', 'res.json', 'progress.json']) {
    try { fs.unlinkSync(path.join(WORK, f)); } catch {}
  }

  proc = spawn('node', [SERVER], { cwd: WORK, stdio: ['pipe', 'pipe', 'pipe'] });
  proc.stdout.setEncoding('utf8');
  proc.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (l) onLine(l); } });
  proc.stderr.on('data', (d) => process.stderr.write('[srv] ' + d));
  await new Promise((res) => setTimeout(res, 500));

  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'regress', version: '3' } });
  rpc('notifications/initialized', {});

  const tl = await rpc('tools/list', {});
  console.log(`tools/list: ${tl.tools.length} tools`);

  // ---- v2 baseline tools ----
  await T('eval-basic', true, () => tool('matlab_eval', { code: 'disp(6*7)' }));
  await T('eval-error', false, () => tool('matlab_eval', { code: "error('boom')" }));
  await T('eval-syntax', false, () => tool('matlab_eval', { code: 'for k=1:10 disp(k)' }));

  // bare clear: R14 does NOT error on a bare clear itself, so the eval
  // succeeds - but it must carry the clear-warning (probe-verified).
  const rclr = await T('eval-bare-clear-warns', true, () => tool('matlab_eval', { code: 'v3keep = 1; clear' }));
  if (rclr && !/bare "clear"/i.test(rclr.text)) { console.log('FAIL  bare-clear-warning-missing', rclr.text.slice(0, 120)); results.fail++; }
  else console.log('PASS  bare-clear-warning-present');
  // and the bare clear really did wipe the workspace variable
  const rcl2 = await T('eval-bare-clear-wiped', false, () => tool('matlab_get_var', { name: 'v3keep' }));
  if (rcl2 && !/Undefined/.test(rcl2.text)) { console.log('FAIL  bare-clear-not-wiped', rcl2.text.slice(0, 120)); results.fail++; }
  // a failed eval WITHOUT bare clear must NOT carry the warning
  const rnoc = await T('eval-error-plain', false, () => tool('matlab_eval', { code: "error('plain boom')" }));
  if (rnoc && /bare "clear"/i.test(rnoc.text)) { console.log('FAIL  clear-warning-false-positive', rnoc.text.slice(0, 160)); results.fail++; }
  // selective clear must pass clean with no warning
  const rsel = await T('eval-selective-clear-ok', true, () => tool('matlab_eval', { code: 'v3keep = 1; clear v3keep; disp(42)' }));
  if (rsel && /bare "clear"/i.test(rsel.text)) { console.log('FAIL  clear-warning-on-selective', rsel.text.slice(0, 160)); results.fail++; }

  // check tool
  const rc = await T('check-clean', true, () => tool('matlab_check', { code: 'x = 1; y = x + 1; disp(y)' }));
  if (rc && !rc.text.includes('OK')) { console.log('FAIL  check-clean-message', rc.text); results.fail++; }
  await T('check-bad', false, () => tool('matlab_check', { code: 'for k=1:10 disp(k)' }));
  const rc2 = await T('check-bad-message', false, () => tool('matlab_check', { code: 'for k=1:10 disp(k)' }));
  if (rc2 && /imbalance/.test(rc2.text)) console.log('PASS  check-bad-message-content (imbalance reported)');
  else if (rc2) { console.log('FAIL  check-bad-message-content', rc2.text); results.fail++; }

  // check_first
  await T('eval-checkfirst-refuse', false, () => tool('matlab_eval', { code: 'for k=1:10 disp(k)', check_first: true }));

  // vars
  await T('set-var', true, () => tool('matlab_set_var', { name: 'v3test', value: [[1, 2, 3], [4, 5, 6]] }));
  await T('get-var', true, () => tool('matlab_get_var', { name: 'v3test' }));
  await T('get-missing', false, () => tool('matlab_get_var', { name: 'no_such_var_xyz' }));
  await T('workspace', true, () => tool('matlab_workspace', {}));

  // summary on a big array
  await tool('matlab_eval', { code: 'bigarr = sin((0:49999)/100);' });
  const rs = await T('summary-big', true, () => tool('matlab_summary', { name: 'bigarr', max_rows: 100 }));
  if (rs) {
    const j = JSON.parse(rs.text);
    if (!j.meta || j.meta.numel !== 50000 || j.meta.complete !== false) { console.log('FAIL  summary-meta', JSON.stringify(j.meta)); results.fail++; }
    if (!j.stats || typeof j.stats.mean !== 'number') { console.log('FAIL  summary-stats', JSON.stringify(j.stats)); results.fail++; }
    const flat = JSON.stringify(j.value);
    if (flat.length > 20000) { console.log('FAIL  summary-too-big', flat.length); results.fail++; }
    else console.log(`PASS  summary-downsample (value chars=${flat.length})`);
  }
  const rs2 = await T('summary-small-complete', true, () => tool('matlab_summary', { name: 'v3test', max_rows: 100 }));
  if (rs2) {
    const j2 = JSON.parse(rs2.text);
    if (j2.meta.complete !== true) { console.log('FAIL  summary-small-complete', JSON.stringify(j2.meta)); results.fail++; }
  }

  // file tools
  const tf = path.join(WORK, 'v3_test_file.m');
  await T('write-file', true, () => tool('matlab_write_file', { path: tf, content: '% 测试中文\nx = 42;\ndisp(x);\n' }));
  await T('read-file', true, () => tool('matlab_read_file', { path: tf }));
  const rr = await T('read-file-roundtrip', true, () => tool('matlab_read_file', { path: tf }));
  if (rr && !rr.text.includes('测试中文')) { console.log('FAIL  gbk-roundtrip'); results.fail++; } else console.log('PASS  gbk-roundtrip');
  await T('append-file', true, () => tool('matlab_append_file', { path: path.join(WORK, 'v3_log.md'), text: 'line1\nline2 中文\n' }));
  await T('append-file-2', true, () => tool('matlab_append_file', { path: path.join(WORK, 'v3_log.md'), text: 'line3\n' }));
  const rl = await T('append-verify', true, () => tool('matlab_read_file', { path: path.join(WORK, 'v3_log.md') }));
  if (rl && !(rl.text.includes('line1') && rl.text.includes('line3'))) { console.log('FAIL  append-content', rl.text); results.fail++; }

  // run_file
  await T('run-file', true, () => tool('matlab_run_file', { path: tf }));

  await T('dir', true, () => tool('matlab_dir', { path: WORK }));

  // figures
  await T('figure-create', true, () => tool('matlab_eval', { code: ["figure; plot((1:10).^2); title('v3fig'); drawnow;"].join('\n'), timeout_sec: 60 }));
  await T('figures-list', true, () => tool('matlab_figures', {}));
  await T('figure-png', true, () => tool('matlab_figure_png', { close: true }));

  // Simulink audit: build a small model, then verify the audit detects the
  // known-good line (nlines>=1) and that sim_clean keeps it.
  await T('sim-build', true, () => tool('matlab_eval', { code: [
    "old = find_system('Type','block_diagram');",
    "for kk=1:numel(old), if ~strcmp(old{kk},'v3tst'), close_system(old{kk},0); end, end;",
    "new_system('v3tst');",
    "add_block('built-in/Integrator','v3tst/Int1','Position',[50 50 90 90]);",
    "add_block('built-in/Outport','v3tst/Out1','Position',[150 60 180 80]);",
    "add_line('v3tst','Int1/1','Out1/1');",
    "save_system('v3tst');",
    "disp('built');",
  ].join('\n'), timeout_sec: 120 }));
  const ra = await T('sim_info', true, () => tool('matlab_sim_info', { model: 'v3tst' }));
  if (ra) {
    const j = JSON.parse(ra.text);
    if (typeof j.nlines !== 'number' || j.nlines < 1) { console.log('FAIL  sim_info-nlines', ra.text); results.fail++; }
    else console.log(`PASS  sim_info-nlines (${j.nlines})`);
  }
  await T('sim_clean', true, () => tool('matlab_sim_clean', { model: 'v3tst' }));
  // arrange + route on the tiny model: both must run and keep the line connected
  await T('sim_arrange', true, () => tool('matlab_sim_arrange', { model: 'v3tst' }));
  const rr2 = await T('sim_route', true, () => tool('matlab_sim_route', { model: 'v3tst' }));
  if (rr2) {
    const mj = rr2.text.match(/Routed (\d+) line\(s\), kept (\d+) as-is, failed (\d+)/);
    if (!mj) { console.log('FAIL  sim_route-json', rr2.text); results.fail++; }
    else {
      const routed = parseInt(mj[1], 10), failed = parseInt(mj[3], 10);
      if (routed < 1) { console.log('FAIL  sim_route-count', rr2.text); results.fail++; }
      else if (failed > 0) { console.log('FAIL  sim_route-failures', rr2.text); results.fail++; }
      else console.log(`PASS  sim_route-count (${routed} routed, ${failed} failed)`);
    }
  }
  const rck = await T('sim_route-connectivity', true, () => tool('matlab_eval', { code: [
    "% line hangs on the DESTINATION block's Inports (R14 pitfall #20)",
    "lh = get_param('v3tst/Out1','LineHandles');",
    "if isempty(lh.Inport) || lh.Inport(1) <= 0, error('line lost'); end",
    "src = get_param(lh.Inport(1),'SrcPortHandle');",
    "phs = get_param('v3tst/Int1','PortHandles');",
    "if src ~= phs.Outport(1), error('wrong src'); end",
    "disp('wire ok');",
  ].join('\n') }));
  if (rck && !rck.text.includes('wire ok')) { console.log('FAIL  sim_route-wire-lost', rck.text); results.fail++; }
  await T('sim-teardown', true, () => tool('matlab_eval', { code: "close_system('v3tst',0); delete('v3tst.mdl'); disp('cleaned');" }));

  // cleanup tool
  await T('figs-recreate', true, () => tool('matlab_eval', { code: "figure; plot((1:5)); figure; plot((1:7)); drawnow;" , timeout_sec: 60 }));
  await T('cleanup-figs', true, () => tool('matlab_cleanup', { close_figs: true }));
  const rf = await T('cleanup-verify', true, () => tool('matlab_figures', {}));
  if (rf && !rf.text.includes('no open figures')) { console.log('FAIL  cleanup-verify', rf.text); results.fail++; }

  // progress (no eval running: idle)
  await T('progress-idle', true, () => tool('matlab_progress', {}));

  // eval + progress combined
  const rp = await T('eval-with-progress', true, () => tool('matlab_eval', { code: [
    'for k=1:3',
    "  mcp_progress(k/3, sprintf('step %d', k));",
    '  pause(0.2);',
    'end',
    "disp('prog done');",
  ].join('\n'), timeout_sec: 60 }));
  if (rp && !rp.text.includes('prog done')) { console.log('FAIL  eval-with-progress-output', rp.text); results.fail++; }
  // after that eval, matlab_progress must show its last written value
  const rpw = await T('progress-after-eval', true, () => tool('matlab_progress', {}));
  if (rpw && !rpw.text.includes('100')) { console.log('FAIL  progress-after-eval-value', rpw.text); results.fail++; }
  // a NEW eval without mcp_progress must reset the progress file
  await T('eval-no-progress', true, () => tool('matlab_eval', { code: 'disp(1+1)' }));
  const rpn = await T('progress-reset-by-new-eval', true, () => tool('matlab_progress', {}));
  if (rpn && !rpn.text.includes('no progress reported')) { console.log('FAIL  progress-not-reset', rpn.text); results.fail++; }

  await T('status', true, () => tool('matlab_status', {}));

  console.log(`\n==== RESULT: ${results.pass} pass, ${results.fail} fail ====`);
  // teardown: drop artifacts this round wrote into the repo dir (the ascii
  // static check fails if v3_test_file.m with Chinese content is left behind)
  for (const f of ['v3_test_file.m', 'v3_log.md', 'v3tst.mdl', 'progress.json']) {
    try { fs.unlinkSync(path.join(WORK, f)); } catch {}
  }
  proc.kill();
  process.exit(results.fail > 0 ? 1 : 0);
}

main().catch((e) => { console.error('driver error:', e); try { proc.kill(); } catch {} process.exit(2); });
