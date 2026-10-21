// smoke: drive the v3 server for window_png + a couple of new tools only
const { spawn } = require('child_process');
const path = require('path');
const WORK = path.resolve(process.argv[2] || __dirname);
let proc, buf = '', nextId = 1;
const pending = new Map();
function rpc(method, params) {
  return new Promise((res, rej) => {
    const id = nextId++;
    if (method.startsWith('notifications/')) { proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); res({}); return; }
    pending.set(id, { res, rej });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error('timeout ' + method)); } }, 120000);
  });
}
proc = spawn('node', [path.join(WORK, 'mcp-server.js')], { cwd: WORK, stdio: ['pipe', 'pipe', 'pipe'] });
proc.stdout.setEncoding('utf8');
proc.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (!l) continue; let m; try { m = JSON.parse(l); } catch { continue; } if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); } } });
(async () => {
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'smoke', version: '3' } });
  rpc('notifications/initialized', {});
  // the desktop MATLAB (window open) is the worker already; server should adopt it via pidfile
  const tl = await rpc('tools/list', {});
  console.log('tools:', tl.tools.length);
  const call = async (name, args) => {
    const r = await rpc('tools/call', { name, arguments: args });
    const texts = (r.content || []).filter(c => c.type === 'text').map(c => c.text).join(' ');
    console.log(`[${r.isError ? 'ERR' : 'OK '}] ${name}: ${texts.slice(0, 140).replace(/\n/g, ' ')}  imgs=${(r.content || []).filter(c => c.type === 'image').length}`);
    return r;
  };
  await call('matlab_status', {});
  await call('matlab_window_png', { title: 'EV_Drag_Power', file: path.join(WORK, 'server_cap.png'), resize_width: 1250, resize_height: 900 });
  await call('matlab_window_png', { title: 'Nonexistent_Window_XYZ' });
  proc.kill();
  process.exit(0);
})().catch((e) => { console.error('smoke error:', e.message); proc.kill(); process.exit(1); });
