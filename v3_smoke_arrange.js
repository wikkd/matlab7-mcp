// smoke: drive the v3 server for sim_arrange + sim_route via stdio MCP
const { spawn } = require('child_process');
const path = require('path');
const WORK = path.resolve(process.argv[2] || __dirname);
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
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error('timeout ' + method)); } }, 240000);
  });
}
proc = spawn('node', [path.join(WORK, 'mcp-server.js')], { cwd: WORK, stdio: ['pipe', 'pipe', 'pipe'] });
proc.stdout.setEncoding('utf8');
proc.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const l = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!l) continue;
    let m;
    try { m = JSON.parse(l); } catch { continue; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      m.error ? p.rej(new Error(m.error.message)) : p.res(m.result);
    }
  }
});
(async () => {
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'smoke', version: '1' } });
  rpc('notifications/initialized', {});
  const MODEL = process.argv[3] || 'C:/path/to/your/model/MyModel';
  const r1 = await rpc('tools/call', { name: 'matlab_sim_arrange', arguments: { model: MODEL } });
  const t1 = (r1.content || []).filter(c => c.type === 'text').map(c => c.text).join(' ');
  console.log('arrange:', r1.isError ? 'ERR' : 'OK ', t1.slice(0, 120));
  const r2 = await rpc('tools/call', { name: 'matlab_sim_route', arguments: { model: MODEL } });
  const t2 = (r2.content || []).filter(c => c.type === 'text').map(c => c.text).join(' ');
  console.log('route:', r2.isError ? 'ERR' : 'OK ', t2.slice(0, 120));
  proc.kill();
  process.exit(0);
})().catch((e) => { console.error('smoke err:', e.message); proc.kill(); process.exit(1); });
