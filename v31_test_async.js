// v3.1 async-dispatch test: proves the server stays responsive while a long
// eval runs, and that matlab_last can rescue an abandoned job's output.
// Usage: node v31_test_async.js <workdir>
// Requires MCP_WORK_DIR isolation so the shared ZCode worker is not touched.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const WORK = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'mcp31_test'));
fs.mkdirSync(WORK, { recursive: true });

let proc = spawn('node', [path.join(ROOT, 'mcp-server.js')], {
  env: Object.assign({}, process.env, { MCP_WORK_DIR: WORK, MCP_BOOT_WAIT: '150' }),
  stdio: ['pipe', 'pipe', 'pipe'],
});
let buf = '';
let nextId = 1;
const pending = new Map();
const order = [];

proc.stdout.setEncoding('utf8');
proc.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      p(m);
    }
  }
});
proc.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

function rpc(method, params) {
  return new Promise((res) => {
    const id = nextId++;
    pending.set(id, res);
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

function fail(msg) { console.error('FAIL: ' + msg); process.exit(1); }

(async () => {
  // boot
  const init = await rpc('initialize', { protocolVersion: '2024-11-05', params: {} });
  if (!init.result) fail('initialize failed');
  console.log('PASS initialize');

  // warmup: boot the isolated worker with a short eval first
  const warm = await rpc('tools/call', { name: 'matlab_eval', arguments: { code: "disp('warm');", timeout_sec: 200 } });
  if (!warm.result || !/warm/.test(warm.result.content[0].text)) fail('warmup eval failed: ' + JSON.stringify(warm).slice(0, 300));
  console.log('PASS worker booted (warmup eval ok)');

  // 1) long eval (10 s) — fire it, do NOT await yet
  const t0 = Date.now();
  const longP = rpc('tools/call', { name: 'matlab_eval', arguments: { code: "disp('tick'); pause(10); disp('long-eval-done');", timeout_sec: 60 } });

  // give the server time to dispatch to MATLAB, then hit it with status
  await new Promise((r) => setTimeout(r, 2500));
  const tS = Date.now();
  const st = await rpc('tools/call', { name: 'matlab_status', arguments: {} });
  const stMs = Date.now() - tS;
  const stText = st.result && st.result.content[0].text;
  if (stMs > 3000) fail('status took ' + stMs + ' ms while eval running (should be instant)');
  if (!/Busy: cmd="eval"/.test(stText)) fail('status does not show busy eval:\n' + stText);
  console.log('PASS status responsive during long eval (' + stMs + ' ms) and shows busy:\n    ' + stText.split('\n')[4]);

  // 2) matlab_progress must also respond
  const pr = await rpc('tools/call', { name: 'matlab_progress', arguments: {} });
  if (!pr.result) fail('progress failed');
  console.log('PASS progress responsive: ' + pr.result.content[0].text.replace(/\n/g, ' '));

  // 3) the long eval eventually resolves
  const long = await longP;
  const longMs = Date.now() - t0;
  const longText = long.result && long.result.content[0].text || '';
  if (longText.indexOf('long-eval-done') < 0) fail('long eval output missing: ' + longText);
  console.log('PASS long eval resolved after ' + Math.round(longMs / 1000) + ' s with full output');

  // 4) matlab_last archives the completed eval
  const last = await rpc('tools/call', { name: 'matlab_last', arguments: {} });
  const lastText = last.result && last.result.content[0].text || '';
  if (/long-eval-done/.test(lastText) === false) {
    fail('matlab_last did not archive the eval output:\n' + lastText);
  }
  console.log('PASS matlab_last archives completed job output');

  // 5) abandoned-job rescue: fire a 6 s eval, treat it as "cut" (never await),
  //    poll status until idle, then matlab_last must hold the output.
  const ghostP = rpc('tools/call', { name: 'matlab_eval', arguments: { code: "pause(6); disp('ghost-job-output');", timeout_sec: 60 } });
  await new Promise((r) => setTimeout(r, 1500));
  let idle = false;
  for (let k = 0; k < 40; k++) {
    await new Promise((r) => setTimeout(r, 500));
    const s2 = await rpc('tools/call', { name: 'matlab_status', arguments: {} });
    if (/Busy: no/.test(s2.result.content[0].text)) { idle = true; break; }
  }
  if (!idle) fail('worker never went idle after ghost job');
  const last2 = await rpc('tools/call', { name: 'matlab_last', arguments: {} });
  const last2Text = last2.result && last2.result.content[0].text || '';
  if (/ghost-job-output/.test(last2Text) === false) fail('matlab_last missing ghost output:\n' + last2Text);
  console.log('PASS abandoned (client-cut) job output rescued via matlab_last');
  await ghostP; // clean up the pending promise

  console.log('ALL v3.1 ASYNC TESTS PASS');
  proc.kill();
  process.exit(0);
})().catch((e) => { console.error('FAIL: ' + e.message); process.exit(1); });
