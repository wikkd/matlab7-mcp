// v6.2 validation driver: opts.only_dirty min-disturbance prefilter.
// Works on a COPY of a real model in a TEMP scratch dir (never the original):
//   A) route only_dirty on a clean model  -> every line untouched (idempotent)
//   B) shear one line, route only_dirty   -> the model is orthogonal again,
//      dirty lines routed, clean ones left alone
//   C) only_dirty again after the fix     -> strict no-op
// Usage: node v62_test_onlydirty.js <repoDir> <model.mdl> [moreModel.mdl ...]
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const WORK = path.resolve(process.argv[2] || __dirname);
const MODELS = process.argv.slice(3);
if (!MODELS.length) { console.error('usage: node v62_test_onlydirty.js <repoDir> <model.mdl> [...]'); process.exit(2); }

const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp_onlydirty_'));
for (const m of MODELS) {
  fs.copyFileSync(m, path.join(SCRATCH, path.basename(m)));
}
console.log('scratch:', SCRATCH);

let proc, buf = '', nextId = 1;
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
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error('timeout ' + method)); } }, 420000);
  });
}
function onLine(l) {
  let m;
  try { m = JSON.parse(l); } catch { return; }
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id);
    pending.delete(m.id);
    m.error ? p.rej(new Error(m.error.message)) : p.res(m.result);
  }
}
async function tool(name, args) {
  const r = await rpc('tools/call', { name, arguments: args });
  return (r.content || []).filter(c => c.type === 'text').map(c => c.text).join('\n');
}

// R14-safe line collection via the destination Inports, ROOT LAYER ONLY
// (SearchDepth 1 -- the router is root-layer by design, so subsystem lines
// must not pollute the comparison). withLoad=true only for the FIRST collect
// of a model; later collects reuse the in-memory state (close+reload would
// wipe unsaved probe geometry AND renumber every line handle).
const COLLECT = (mdl, withLoad) => {
  const L = [];
  if (withLoad) {
    // never assume the worker cwd: router cd-drift is legal worker state,
    // so cd to the scratch dir explicitly before load
    L.push("cd('" + SCRATCH.replace(/\\/g, '/').replace(/'/g, "''") + "');");
    L.push("try, load_system('" + mdl + "'); catch, disp(['LOADERR: ' lasterr]); disp(['CWD=' pwd]); disp(['EX=' num2str(exist('" + mdl + ".mdl', 'file'))]); error('collect load failed'); end");
  }
  L.push("blks = find_system('" + mdl + "', 'SearchDepth', 1);");
  L.push('lh = [];');
  L.push('for b = 1:numel(blks)');
  L.push('  p = blks{b};');
  L.push("  if strcmp(p, '" + mdl + "'), continue; end");
  L.push("  l = get_param(p, 'LineHandles');");
  L.push('  for s = 1:numel(l.Inport)');
  L.push('    h = l.Inport(s);');
  L.push('    if h == -1 || h == 0, continue; end');
  L.push('    lh(end+1) = h;');
  L.push('  end');
  L.push('end');
  L.push('lh = unique(lh);');
  L.push('P0 = cell(numel(lh), 1);');
  L.push('for k = 1:numel(lh)');
  L.push("  P0{k} = get_param(lh(k), 'Points');");
  L.push('end');
  L.push("fprintf('lines=%d\\n', numel(lh));");
  return L.join('\n');
};
const COMPARE = () => [
  'n_chg = 0;',
  'for k = 1:numel(lh)',
  "  P1 = get_param(lh(k), 'Points');",
  '  if ~isequal(P1, P0{k}), n_chg = n_chg + 1; end',
  'end',
  "fprintf('changed=%d of %d\\n', n_chg, numel(lh));",
].join('\n');
const DIAGCOUNT = () => [
  'nbad = 0;',
  'for k = 1:numel(lh)',
  "  Pt = get_param(lh(k), 'Points');",
  '  for j = 2:size(Pt, 1)',
  '    if abs(Pt(j,1) - Pt(j-1,1)) > 0.5 && abs(Pt(j,2) - Pt(j-1,2)) > 0.5, nbad = nbad + 1; end',
  '  end',
  'end',
  "fprintf('diag=%d\\n', nbad);",
].join('\n');

let fail = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ' :: ' + detail : ''}`);
  if (!ok) fail++;
};
const num = (t, re) => { const m = t.match(re); return m ? parseInt(m[1], 10) : null; };

(async () => {
  proc = spawn('node', [path.join(WORK, 'mcp-server.js')], {
    cwd: WORK, stdio: ['pipe', 'pipe', 'pipe'],
    env: Object.assign({}, process.env, { MCP_WORK_DIR: SCRATCH }),
  });
  proc.stdout.setEncoding('utf8');
  proc.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (l) onLine(l); } });
  proc.stderr.on('data', (d) => process.stderr.write('[srv] ' + d));
  await new Promise((r) => setTimeout(r, 500));
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'onlydirty-val', version: '1' } });
  rpc('notifications/initialized', {});

  for (const mdlPath of MODELS) {
    const mdl = path.basename(mdlPath, '.mdl');
    console.log(`\n==== ${mdl} ====`);

    // baseline: collect pristine geometry + report pre-existing dirt
    const rc0 = await tool('matlab_eval', { code: COLLECT(mdl, true) });
    const nLines = num(rc0, /lines=(\d+)/);
    check(`${mdl}:collect`, nLines !== null && nLines > 0, rc0.slice(0, 120));
    const rpre = await tool('matlab_eval', { code: DIAGCOUNT() });
    const diagPre = num(rpre, /diag=(\d+)/);
    console.log(`info  ${mdl}:pre-dirt :: diagonal segments in root layer: ${diagPre}`);

    // A) only_dirty on the pristine model: clean lines must not move; any
    // line the router re-routes must have been genuinely dirty
    const rA = await tool('matlab_sim_route', { model: mdlPath, only_dirty: true });
    const routA = num(rA, /Routed (\d+) line/);
    const cleanA = num(rA, /left (\d+) clean/);
    const failA = num(rA, /failed (\d+)/);
    check(`${mdl}:A-route`, rA.includes('Model saved') && failA === 0, rA.slice(0, 160));
    check(`${mdl}:A-clean-ge`, routA === 0 || cleanA >= 1, `routed=${routA} clean=${cleanA}`);
    const rcA = await tool('matlab_eval', { code: COMPARE() });
    const chgA = num(rcA, /changed=(\d+)/);
    const rAorth = await tool('matlab_eval', { code: DIAGCOUNT() });
    check(`${mdl}:A-untouched`, routA > 0 || chgA === 0,
      `routed=${routA} changed=${chgA} (nothing moves unless something routed)`);
    check(`${mdl}:A-orthogonal`, num(rAorth, /diag=(\d+)/) === 0, rAorth.slice(0, 120));

    // B) shear one line into a diagonal, then only_dirty: the model must be
    // orthogonal again. (changed vs post-shear baseline counts router
    // rewrites PLUS branch anchors R14 legally dragged along -- so only a
    // lower bound is asserted here; the strict no-op proof is A and C.)
    const rD = await tool('matlab_eval', { code: [
      'hb = lh(1);',
      "Pb = get_param(hb, 'Points');",
      "if size(Pb, 1) < 2, error('line too short'); end",
      'Pd = [Pb(1, :); round((Pb(1, 1) + Pb(end, 1)) / 2), round((Pb(1, 2) + Pb(end, 2)) / 2); Pb(end, :)];',
      "set_param(hb, 'Points', Pd);",
      "disp('sheared');",
    ].join('\n') });
    check(`${mdl}:B-shear`, rD.includes('sheared'), rD.slice(0, 120));
    const rcB0 = await tool('matlab_eval', { code: COLLECT(mdl, false) });
    check(`${mdl}:B-recollect`, num(rcB0, /lines=(\d+)/) === nLines, rcB0.slice(0, 120));
    const rB = await tool('matlab_sim_route', { model: mdlPath, only_dirty: true });
    const routB = num(rB, /Routed (\d+) line/);
    const failB = num(rB, /failed (\d+)/);
    const rcB = await tool('matlab_eval', { code: COMPARE() });
    const chgB = num(rcB, /changed=(\d+)/);
    check(`${mdl}:B-fixes-dirty`, routB >= 1 && failB === 0 && chgB >= 1,
      `routed=${routB} changed=${chgB} failed=${failB}`);
    const rorth = await tool('matlab_eval', { code: DIAGCOUNT() });
    check(`${mdl}:B-orthogonal`, num(rorth, /diag=(\d+)/) === 0, rorth.slice(0, 120));

    // C) after the fix, only_dirty must be a strict no-op again
    // (baseline refresh: P0 must be the POST-FIX geometry, not the sheared one)
    const rcB2 = await tool('matlab_eval', { code: COLLECT(mdl, false) });
    check(`${mdl}:C-recollect`, num(rcB2, /lines=(\d+)/) === nLines, rcB2.slice(0, 120));
    const rC = await tool('matlab_sim_route', { model: mdlPath, only_dirty: true });
    const routC = num(rC, /Routed (\d+) line/);
    check(`${mdl}:C-idempotent`, routC === 0, `routed=${routC}`);
    const rcC = await tool('matlab_eval', { code: COMPARE() });
    check(`${mdl}:C-untouched`, num(rcC, /changed=(\d+)/) === 0, rcC.slice(0, 120));

    await tool('matlab_eval', { code: "close_system('" + mdl + "', 0); disp('closed');" });
  }

  console.log(`\n==== ONLYDIRTY: ${fail === 0 ? 'ALL PASS' : fail + ' FAIL'} ====`);
  proc.kill();
  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => { console.error('driver error:', e.message); try { proc.kill(); } catch {} process.exit(2); });
