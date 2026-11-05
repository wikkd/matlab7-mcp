// v3.2 instance-isolation / boot-hygiene / protocol-negative test driver.
// Covers what v3_regress.js cannot: it needs its own work dir and two server
// instances sharing one worker, plus planted protocol garbage.
//   Phase 0  stale junk planted BEFORE boot (dead-instance files, stale
//            busy.json, dead-pid worker.pid, backdated boot.lock, old figure)
//   Phase A  fresh boot sweeps exactly the planted junk, spares nothing else;
//            live per-instance files appear after requests
//   Phase B  mid-session junk is NOT swept while the worker stays alive
//   Phase C  two server instances share one worker: status stays instant
//            during the other instance's long eval, and each instance's
//            history file holds only its own jobs (reply-tag isolation)
//   Phase D  protocol negatives: stale res with mismatched id, malformed
//            request JSON, residual busy.json - none wedge the worker
// Usage: node v32_test_isolation.js [workdir]   (default %TEMP%/mcp32_test)
// Requires a real MATLAB 7.0 (R14): it boots its own worker in WORK.
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const WORK = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'mcp32_test'));
const BOOTED = []; // servers to kill in finally

let fails = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  :: ' + detail : ''}`);
  if (!ok) fails++;
}

function makeServer() {
  const proc = spawn('node', [path.join(ROOT, 'mcp-server.js')], {
    env: Object.assign({}, process.env, { MCP_WORK_DIR: WORK, MCP_BOOT_WAIT: '150' }),
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let buf = '';
  let nextId = 1;
  const pending = new Map();
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
  proc.stderr.on('data', (d) => process.stderr.write('[srv] ' + d));
  const rpc = (method, params, timeoutMs = 300000) => new Promise((res, rej) => {
    const id = nextId++;
    pending.set(id, res);
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); rej(new Error('rpc timeout ' + method)); }
    }, timeoutMs);
  });
  const tool = async (name, args) => {
    const r = await rpc('tools/call', { name, arguments: args });
    const texts = (r.result && r.result.content || []).filter((c) => c.type === 'text').map((c) => c.text);
    return { isError: !!(r.result && r.result.isError), text: texts.join('\n') };
  };
  const s = { proc, rpc, tool };
  BOOTED.push(proc);
  return s;
}

async function init(s) {
  const r = await s.rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'v32test', version: '3.2' } });
  if (!r.result) throw new Error('initialize failed');
  s.rpc('notifications/initialized', {});
}

const exists = (f) => fs.existsSync(path.join(WORK, f));
const gone = (f) => !exists(f);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // ---- Phase 0: plant junk a dead run might have left behind --------------
  fs.rmSync(WORK, { recursive: true, force: true });
  fs.mkdirSync(WORK, { recursive: true });
  const planted = ['req_i111111.json', 'res_i111111.json', 'res_history_i111111.jsonl',
    'res_last_i111111.json', 'req.json', 'res.json', 'figure_1700000000000.png'];
  for (const f of planted) {
    fs.writeFileSync(path.join(WORK, f), f.endsWith('.jsonl') ? '{"id":1}\n' : (f === 'res.json' ? '{"id":1,"ok":true}' : 'x'));
  }
  fs.writeFileSync(path.join(WORK, 'busy.json'), '{"id":0,"cmd":"stale"}');
  // worker.pid pointing at a live non-MATLAB process (this test): the server
  // must treat it as dead and boot a fresh worker without killing anything.
  fs.writeFileSync(path.join(WORK, 'worker.pid'), String(process.pid));
  // boot.lock backdated beyond MCP_BOOT_WAIT so it cannot block the boot
  const old = new Date(Date.now() - 600000);
  fs.writeFileSync(path.join(WORK, 'boot.lock'), '0');
  fs.utimesSync(path.join(WORK, 'boot.lock'), old, old);

  // ---- Phase A: fresh boot sweeps the planted junk ------------------------
  const A = makeServer();
  await init(A);
  const warm = await A.tool('matlab_eval', { code: "disp('warm-A');", timeout_sec: 300 });
  check('A:boot-warmup', !warm.isError && /warm-A/.test(warm.text), warm.text.slice(0, 120));
  check('A:boot-swept', planted.every(gone) && gone('busy.json'),
    planted.filter(exists).concat(exists('busy.json') ? ['busy.json'] : []).join(','));
  const pidA = parseInt(fs.readFileSync(path.join(WORK, 'worker.pid'), 'utf8').trim(), 10);
  check('A:worker-pid-replaced', Number.isFinite(pidA) && pidA !== process.pid, `pid=${pidA}`);
  await A.tool('matlab_eval', { code: "disp('warm-A-2');" });
  check('A:live-instance-files', exists(`res_history_i${A.proc.pid}.jsonl`) && exists(`res_last_i${A.proc.pid}.json`),
    `hist=${exists(`res_history_i${A.proc.pid}.jsonl`)} last=${exists(`res_last_i${A.proc.pid}.json`)}`);

  // ---- Phase B: mid-session junk is NOT swept while the worker is alive ---
  fs.writeFileSync(path.join(WORK, 'res_i888888.json'), '{"id":1}');
  fs.writeFileSync(path.join(WORK, 'figure_1700000000001.png'), 'x');
  const wb = await A.tool('matlab_eval', { code: "disp('mid-session');" });
  check('B:eval-ok', !wb.isError && /mid-session/.test(wb.text), wb.text.slice(0, 120));
  check('B:no-mid-session-sweep', exists('res_i888888.json') && exists('figure_1700000000001.png'));

  // ---- Phase C: two instances, one worker ---------------------------------
  const B = makeServer();
  await init(B);
  const warmB = await B.tool('matlab_eval', { code: "disp('warm-B');" });
  check('C:B-warmup-shares-worker', !warmB.isError && /warm-B/.test(warmB.text), warmB.text.slice(0, 120));
  const mkA = 'MARK-A-' + Date.now();
  const mkB = 'MARK-B-' + Date.now();
  const longP = A.rpc('tools/call', { name: 'matlab_eval', arguments: { code: `pause(8); disp('${mkA}');`, timeout_sec: 120 } });
  await sleep(2500);
  const tS = Date.now();
  const stB = await B.tool('matlab_status', {});
  const stMs = Date.now() - tS;
  check('C:B-status-instant-while-A-busy', !stB.isError && stMs < 3000 && /Busy: cmd="eval"/.test(stB.text), `${stMs} ms`);
  const prB = await B.tool('matlab_progress', {});
  check('C:B-progress-responsive', !prB.isError, prB.text.replace(/\s+/g, ' ').slice(0, 80));
  const qB = B.rpc('tools/call', { name: 'matlab_eval', arguments: { code: `disp('${mkB}');` } });
  const longR = await longP;
  const longText = ((longR.result || {}).content || []).map((c) => c.text || '').join('\n');
  check('C:A-long-eval-output', longText.includes(mkA), longText.replace(/\s+/g, ' ').slice(0, 140));
  const qBR = await qB;
  const qBText = ((qBR.result || {}).content || []).map((c) => c.text || '').join('\n');
  check('C:B-queued-eval-output', qBText.includes(mkB), qBText.replace(/\s+/g, ' ').slice(0, 140));
  // reply-tag isolation: each instance's history holds only its own jobs
  const histA = fs.readFileSync(path.join(WORK, `res_history_i${A.proc.pid}.jsonl`), 'utf8');
  const histB = fs.readFileSync(path.join(WORK, `res_history_i${B.proc.pid}.jsonl`), 'utf8');
  check('C:history-isolation', histA.includes(mkA) && !histA.includes(mkB) &&
    histB.includes(mkB) && !histB.includes(mkA),
    `A:${histA.includes(mkA)}/${!histA.includes(mkB)} B:${histB.includes(mkB)}/${!histB.includes(mkA)}`);

  // ---- Phase D: protocol negatives ----------------------------------------
  // D1: stale response with a mismatched id must be skipped, not consumed
  fs.writeFileSync(path.join(WORK, `res_i${A.proc.pid}.json`), '{"id":424242,"ok":true,"stdout":"STALE-RES-MARKER"}');
  const d1 = await A.tool('matlab_eval', { code: "disp('fresh-after-stale');" });
  check('D1:stale-res-skipped', !d1.isError && d1.text.includes('fresh-after-stale') && !d1.text.includes('STALE-RES-MARKER'),
    d1.text.replace(/\s+/g, ' ').slice(0, 140));
  // D2: malformed request JSON - worker answers with an error on the legacy
  // channel (reply tag unrecoverable) and stays alive
  fs.writeFileSync(path.join(WORK, `req_i${A.proc.pid}.json`), '{"id":777001,"reply":"i' + A.proc.pid + '","cmd":"eval","code":"DEFINITELY NOT VALID JSON');
  let bootRes = '';
  for (let k = 0; k < 40 && !/777001/.test(bootRes); k++) {
    await sleep(250);
    try { bootRes = fs.readFileSync(path.join(WORK, 'res_boot.json'), 'utf8'); } catch {}
  }
  check('D2:garbage-req-error-res', /"id":777001/.test(bootRes) && /"ok":false/.test(bootRes), bootRes.slice(0, 140));
  const d2 = await A.tool('matlab_eval', { code: "disp('alive-after-garbage');" });
  check('D2:worker-alive-after-garbage', !d2.isError && /alive-after-garbage/.test(d2.text), d2.text.slice(0, 120));
  // D3: residual busy.json must not wedge the next request
  fs.writeFileSync(path.join(WORK, 'busy.json'), '{"id":999999,"cmd":"ghost"}');
  const d3 = await A.tool('matlab_eval', { code: "disp('ok-after-stale-busy');" });
  check('D3:stale-busy-no-wedge', !d3.isError && /ok-after-stale-busy/.test(d3.text), d3.text.slice(0, 120));
  check('D3:busy-cleaned-after-request', gone('busy.json'));

  console.log(`\n==== RESULT: ${fails === 0 ? 'ALL PASS' : fails + ' FAIL'} ====`);
}

main().catch((e) => { fails++; console.error('FAIL  driver error: ' + e.message); })
  .then(() => {
    // cleanup: kill the isolated worker (never the shared one) and servers
    try {
      const pid = parseInt(fs.readFileSync(path.join(WORK, 'worker.pid'), 'utf8').trim(), 10);
      if (Number.isFinite(pid) && pid !== process.pid) spawnSync('taskkill', ['/PID', String(pid), '/F']);
    } catch {}
    for (const p of BOOTED) { try { p.kill(); } catch {} }
    try { fs.rmSync(WORK, { recursive: true, force: true }); } catch {}
    process.exit(fails > 0 ? 1 : 0);
  });
