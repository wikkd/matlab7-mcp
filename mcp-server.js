#!/usr/bin/env node
/**
 * matlab7-mcp-server v3.1 — MCP stdio server bridging to MATLAB 7.0 (R14)
 * via a persistent mcp_worker.m process (file-based JSON protocol).
 *
 * Zero npm dependencies. Node >= 16.
 *
 * v3 changes over v2 (based on exp1–exp8 full-course battle damage):
 *   - matlab_check: syntax-check code BEFORE running (R14 checkcode parse).
 *   - matlab_eval check_first option: run checkcode, refuse on parse errors.
 *   - matlab_summary: fetch big arrays with row budget + stats (no more
 *     multi-MB JSON dumps for a 50000-point simout).
 *   - matlab_sim_info / matlab_sim_clean: Simulink ghost-line audit and
 *     repair (orphan segments, duplicate destinations, unconnected ports) —
 *     the single biggest time sink of the whole exp6/exp7 build.
 *   - matlab_sim_route: orthogonal auto-routing for all model lines
 *     (horizontal/vertical only, avoids block bodies, handles branches).
 *   - matlab_cleanup: close all figures and/or loaded models in one call.
 *   - matlab_write_file gains append mode (build logs without fprintf %%
 *     escaping) via matlab_append_file tool.
 *   - matlab_window_png: capture a real window (Simulink model editor,
 *     Scope) by title substring via the bundled cap_window.ps1 — R14's
 *     print('-sModel') is broken ("Error using ==> graphics") in this env.
 *   - matlab_progress: read mcp_progress() markers from long evals.
 *   - eval warns when user code contains bare clear/clear all (wipes the
 *     marker + loop variables; classic "Reference to a cleared variable").
 *
 * v3.1 changes (2026-10-30, battle damage from the EV energy/range project):
 *   - NON-BLOCKING request dispatch: waitForResponse now polls asynchronously,
 *     so the server keeps serving tools/list, matlab_status and matlab_progress
 *     while a long eval/sim runs. Previously one long MATLAB call froze the
 *     whole server (Atomics.wait) — even status timed out and the only escape
 *     was matlab_restart.
 *   - matlab_last: fetch the most recent completed worker response. When a
 *     client-side tool timeout abandons a request, the job keeps running in
 *     MATLAB and its console output used to be lost; now it is always
 *     retrievable (response archived to res_last.json).
 *   - matlab_status shows busy-elapsed seconds so polling long jobs is usable.
 *   - Long-job pattern (documented in eval/run_file descriptions): fire the
 *     call (the client may cut it at ~30 s — that is fine), then poll with
 *     matlab_status / matlab_progress, then collect with matlab_last.
 *
 * Env vars:
 *   MATLAB7_DIR    MATLAB root, e.g. D:\MATLAB7   (default: auto-detect)
 *   MCP_WORK_DIR   Working folder for req/res files (default: <server_dir>)
 *   MCP_BOOT_WAIT  Max seconds to wait for worker boot (default: 120)
 *   MCP_KILL_ALL   1 = kill every MATLAB.exe on stale-cleanup (v1 behaviour)
 *   MCP_MAX_CHARS  Truncate long text outputs to this many chars (default 200000)
 *
 * Tools (22):
 *   matlab_eval        Run MATLAB code in base workspace, return console text
 *   matlab_run_file    Run a .m script/function file (cache-safe, restores cwd)
 *   matlab_check       Syntax-check MATLAB code without running it
 *   matlab_get_var     Read a base-workspace variable as JSON
 *   matlab_set_var     Write a JSON value into a base-workspace variable
 *   matlab_summary     Read a (large) variable with row budget + stats
 *   matlab_workspace   List workspace variables (name/class/size)
 *   matlab_write_file  Write text to disk (.m auto GBK for R14, others UTF-8)
 *   matlab_append_file Append text to a file on disk
 *   matlab_read_file   Read a text file (.m auto GBK decode, others UTF-8)
 *   matlab_dir         List a directory via MATLAB
 *   matlab_figure_png  Export a figure (default = most recent) to PNG, as image
 *   matlab_window_png  Capture a window by title substring (Simulink/Scope)
 *   matlab_figures     List open figure windows
 *   matlab_sim_info    Audit a Simulink model for ghost lines / unconnected ports
 *   matlab_sim_clean   Remove orphan line segments from a model and save
 *   matlab_sim_route   Auto-route all lines orthogonally, avoiding blocks
 *   matlab_cleanup     Close all figures and/or loaded models
 *   matlab_progress    Read progress of a long-running eval
 *   matlab_status      Worker status (pid / alive / boot / busy)
 *   matlab_restart     Kill and restart the worker
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- config
const SERVER_DIR = __dirname;
const WORK_DIR = process.env.MCP_WORK_DIR || SERVER_DIR;
const REQ_FILE = path.join(WORK_DIR, 'req.json');
const RES_FILE = path.join(WORK_DIR, 'res.json');
const RES_LAST_FILE = path.join(WORK_DIR, 'res_last.json');
const PID_FILE = path.join(WORK_DIR, 'worker.pid');
const BUSY_FILE = path.join(WORK_DIR, 'busy.json');
const PROGRESS_FILE = path.join(WORK_DIR, 'progress.json');
const CAP_PS1 = path.join(SERVER_DIR, 'cap_window.ps1');
const BOOT_WAIT_SEC = parseInt(process.env.MCP_BOOT_WAIT || '120', 10);
const KILL_ALL = process.env.MCP_KILL_ALL === '1';
const MAX_CHARS = parseInt(process.env.MCP_MAX_CHARS || '200000', 10);

function findMatlab() {
  const cand = process.env.MATLAB7_DIR;
  const roots = cand ? [cand] : ['D:\\MATLAB7', 'C:\\MATLAB7', 'C:\\MATLAB_R14'];
  for (const r of roots) {
    const exe = path.join(r, 'bin', 'win32', 'MATLAB.exe');
    if (fs.existsSync(exe)) return exe;
  }
  return null;
}
const MATLAB_EXE = findMatlab();

// ------------------------------------------------------------- MCP plumbing
let nextId = 1;

process.stdin.setEncoding('utf8');
let inBuf = '';

process.stdin.on('data', (chunk) => {
  inBuf += chunk;
  let idx;
  while ((idx = inBuf.indexOf('\n')) >= 0) {
    const line = inBuf.slice(0, idx).trim();
    inBuf = inBuf.slice(idx + 1);
    if (line) handleMcpLine(line);
  }
});
process.stdin.on('end', () => shutdown());
process.on('SIGINT', () => shutdown());
process.on('SIGTERM', () => shutdown());

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}
function rpcError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}
function rpcResult(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function handleMcpLine(line) {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.jsonrpc !== '2.0') return;

  if (msg.method === 'initialize') {
    rpcResult(msg.id, {
      protocolVersion: msg.params?.protocolVersion || '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'matlab7-mcp-server', version: '3.2.0' },
    });
    return;
  }
  if (msg.method === 'notifications/initialized' || (msg.method || '').startsWith('notifications/')) {
    return; // no response for notifications
  }
  if (msg.method === 'tools/list') {
    rpcResult(msg.id, { tools: TOOLS });
    return;
  }
  if (msg.method === 'tools/call') {
    const { name, arguments: args } = msg.params || {};
    callTool(name, args || {})
      .then((result) => rpcResult(msg.id, result))
      .catch((err) => rpcResult(msg.id, {
        content: [{ type: 'text', text: 'Tool error: ' + err.message }],
        isError: true,
      }));
    return;
  }
  if (msg.method === 'ping') {
    rpcResult(msg.id, {});
    return;
  }
  if (msg.id !== undefined) {
    rpcError(msg.id, -32601, 'Method not found: ' + msg.method);
  }
}

// ------------------------------------------------------------------ worker
let workerProc = null;
let workerBootedAt = null;
let workerVersion = '';

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function readPid() {
  try {
    const s = fs.readFileSync(PID_FILE, 'utf8').trim();
    const pid = parseInt(s, 10);
    return Number.isFinite(pid) && pid > 0 ? pid : null;
  } catch { return null; }
}
function pidAlive(pid) {
  if (!pid) return false;
  const r = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8' });
  return r.status === 0 && (r.stdout || '').includes('MATLAB');
}
function readBusy() {
  try { return JSON.parse(fs.readFileSync(BUSY_FILE, 'utf8')); } catch { return null; }
}

async function killStaleWorker() {
  const pid = readPid();
  if (pid && pidAlive(pid)) {
    try { spawnSync('taskkill', ['/PID', String(pid), '/F']); } catch {}
  }
  // Only nuke ALL MATLAB processes when explicitly asked: the user may have
  // their own MATLAB GUI open, killing it would lose their work.
  if (KILL_ALL) {
    try { spawnSync('taskkill', ['/IM', 'MATLAB.exe', '/F']); } catch {}
  }
  for (let i = 0; i < 20; i++) {
    if (!pidAlive(pid)) break;
    await sleep(500);
  }
  // clear protocol files from any previous session
  for (const f of [REQ_FILE, RES_FILE, BUSY_FILE]) {
    try { if (fs.existsSync(f)) fs.unlinkSync(f); } catch {}
  }
}

async function startWorker() {
  if (!MATLAB_EXE) throw new Error('MATLAB 7.0 not found. Set MATLAB7_DIR env var.');
  killStaleWorker();
  // Rotate the boot log so it cannot grow without bound (R14 appends forever).
  try {
    const log = path.join(WORK_DIR, 'worker_boot.log');
    if (fs.existsSync(log)) fs.renameSync(log, log.replace(/\.log$/, '.log.1'));
  } catch {}
  // progress.json from a previous session would make matlab_progress report
  // stale numbers before the first eval of this session has run.
  try { if (fs.existsSync(PROGRESS_FILE)) fs.unlinkSync(PROGRESS_FILE); } catch {}
  const code = `cd('${WORK_DIR.replace(/\\/g, '/')}'), addpath('${SERVER_DIR.replace(/\\/g, '/')}'), mcp_worker('req.json','res.json','worker.pid','busy.json'), exit`;
  workerProc = spawn(MATLAB_EXE, ['-nosplash', '-nodesktop', '-logfile', path.join(WORK_DIR, 'worker_boot.log'), '-r', code], {
    cwd: WORK_DIR,
    detached: false,
    stdio: 'ignore',
  });
  workerProc.on('exit', () => { workerProc = null; workerBootedAt = null; });

  const t0 = Date.now();
  while (Date.now() - t0 < BOOT_WAIT_SEC * 1000) {
    if (fs.existsSync(RES_FILE)) {
      try {
        const j = JSON.parse(fs.readFileSync(RES_FILE, 'utf8'));
        if (j.ok) {
          workerBootedAt = new Date().toISOString();
          workerVersion = j.version || '';
          return;
        }
      } catch {}
    }
    await sleep(500); // v3.1: yield to the event loop while booting
  }
  throw new Error(`MATLAB worker failed to boot within ${BOOT_WAIT_SEC}s`);
}

async function ensureWorker() {
  const pid = readPid();
  if (!pid || !pidAlive(pid)) {
    await startWorker();
  }
}

/** Archive the current res.json to res_last.json (best-effort: attach the
 *  busy cmd when the worker has not cleared busy.json yet). */
function archiveRes() {
  try {
    const j = JSON.parse(fs.readFileSync(RES_FILE, 'utf8'));
    try {
      const b = JSON.parse(fs.readFileSync(BUSY_FILE, 'utf8'));
      if (b && b.cmd && Number(b.id) === Number(j.id)) j.cmd = b.cmd;
    } catch {}
    fs.writeFileSync(RES_LAST_FILE, JSON.stringify(j), 'utf8');
  } catch {}
}

/**
 * Send a request to the worker and wait for the matching response.
 * ASYNC on purpose (v3.1): the Node event loop must stay free so that
 * matlab_status / matlab_progress / tools/list remain responsive while a
 * long MATLAB job runs. A client-side tool timeout no longer wedges the
 * server: the abandoned promise resolves later and its output is archived
 * to res_last.json for matlab_last.
 */
async function workerRequest(payload, timeoutSec) {
  await ensureWorker();  const id = nextId++;
  const req = JSON.stringify(Object.assign({ id }, payload));
  // 1) archive + clear any previous response (matlab_last can still read it)
  archiveRes();
  try { fs.unlinkSync(RES_FILE); } catch {}
  // 2) write request atomically (write tmp, rename)
  const tmp = REQ_FILE + '.tmp';
  fs.writeFileSync(tmp, req, 'utf8');
  fs.renameSync(tmp, REQ_FILE);
  // 3) wait for the matching response by polling
  return waitForResponse(id, timeoutSec * 1000);
}

async function waitForResponse(id, timeoutMs) {
  const deadline = Date.now() + timeoutMs;

  const check = () => {
    if (!fs.existsSync(RES_FILE)) return null;
    try {
      const j = JSON.parse(fs.readFileSync(RES_FILE, 'utf8'));
      if (j.id === id) {
        archiveRes();
        try { fs.unlinkSync(RES_FILE); } catch {}
        return j;
      }
      // stale/mismatched response — keep waiting (worker may still be writing)
    } catch {} // partial write, retry
    return null;
  };

  let result = check();
  if (result) return result;

  while (Date.now() < deadline) {
    // yield to the event loop so other MCP requests keep flowing
    await new Promise((r) => setTimeout(r, 100));
    result = check();
    if (result) return result;
    // abort if worker died
    const pid = readPid();
    if (!pid || !pidAlive(pid)) {
      throw new Error('MATLAB worker died mid-request (check worker_boot.log)');
    }
  }
  // Timeout: report what the worker was doing so the caller can decide to
  // wait more or restart. The MATLAB job itself keeps running.
  const busy = readBusy();
  let hint = `MATLAB worker timeout after ${Math.round(timeoutMs / 1000)}s (req id=${id}).`;
  if (busy) {
    hint += ` Worker still busy with cmd="${busy.cmd}" since ${busy.since} — increase timeout_sec or use matlab_restart to abort. ` +
    'After the run finishes (or via matlab_restart), matlab_progress shows how far it got if the code called mcp_progress.';
  } else {
    hint += ' Worker idle — the request may have been lost; retry or matlab_restart.';
  }
  throw new Error(hint);
}

// ------------------------------------------------------------------- tools
const R14_NOTES = ' Use R14-era syntax only: single-quoted char strings (no "..." strings), '
  + 'no arguments blocks, no implicit expansion, no name=value pairs.';

const TOOLS = [
  {
    name: 'matlab_eval',
    description: 'Execute MATLAB 7.0 (R14) code in the base workspace and return console output. '
      + 'Syntax errors AND runtime errors are both reported reliably.' + R14_NOTES
      + ' Figure windows may be created; close them or use matlab_figure_png / matlab_figures. '
      + 'For long runs call mcp_progress(frac,msg) inside the loop, then matlab_progress to poll. '
      + 'LONG-JOB PATTERN (v3.1): jobs outliving the client tool timeout (~30 s) keep running; '
      + 'poll matlab_status/matlab_progress while they run, then collect the console output with '
      + 'matlab_last. Keep each single call under ~25 s when possible (e.g. chunk long loops). '
      + 'A bare "clear"/"clear all" in the code wipes loop variables and triggers a warning — use "clear <name>".',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'MATLAB code to evaluate' },
        timeout_sec: { type: 'number', description: 'Timeout in seconds (default 120, max 1800 for long sims)' },
        check_first: { type: 'boolean', description: 'Syntax-check via checkcode first; refuse to run on parse errors (default false)' },
      },
      required: ['code'],
    },
  },
  {
    name: 'matlab_check',
    description: 'Syntax-check MATLAB 7.0 code WITHOUT running it (R14 checkcode parser). '
      + 'Returns clean=true or the parse-error list with line numbers. Use before matlab_eval '
      + 'or matlab_write_file of long scripts to catch typos early.' + R14_NOTES,
    inputSchema: {
      type: 'object',
      properties: { code: { type: 'string', description: 'MATLAB code to check' } },
      required: ['code'],
    },
  },
  {
    name: 'matlab_run_file',
    description: 'Run a .m script/function file in MATLAB base workspace (absolute path). '
      + 'Clears the function cache for that file first (picks up edits), cds into its folder, '
      + 'and always restores the previous working directory afterwards. '
      + 'LONG-JOB PATTERN (v3.1): if the client cuts the call (~30 s) the script keeps running; '
      + 'poll matlab_status/matlab_progress, then collect output with matlab_last.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute path to the .m file' },
        timeout_sec: { type: 'number' },
      },
      required: ['path'],
    },
  },
  {
    name: 'matlab_get_var',
    description: 'Read a variable from the MATLAB base workspace. Returns JSON '
      + '(numbers/arrays/chars/cells/structs; NaN/Inf come back as strings "NaN"/"Inf"). '
      + 'For large arrays (simout, tout...) prefer matlab_summary to avoid dumping megabytes.',
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string', description: 'Variable name or expression, e.g. "ber" or "simout(1:10)"' } },
      required: ['name'],
    },
  },
  {
    name: 'matlab_summary',
    description: 'Read a (possibly large) variable with a row budget and summary stats. '
      + 'Returns meta {name,class,size,numel,complete}, stats {min,max,mean,std} for numeric, '
      + 'and the full array if it fits the budget, else a uniformly downsampled preview. '
      + 'Ideal for simulation logs (simout, tout, SOC traces) where full data is not needed.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Variable name or expression' },
        max_rows: { type: 'number', description: 'Row/element budget before downsampling (default 200)' },
      },
      required: ['name'],
    },
  },
  {
    name: 'matlab_set_var',
    description: 'Set a variable in the MATLAB base workspace from a JSON value.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        value: { description: 'JSON value (number, array, string, object)' },
      },
      required: ['name', 'value'],
    },
  },
  {
    name: 'matlab_workspace',
    description: 'List variables in the MATLAB base workspace with class and size.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'matlab_write_file',
    description: 'Write text to a file via MATLAB. .m files are written GBK-encoded '
      + '(what MATLAB 7.0 expects for Chinese comments), everything else UTF-8. '
      + 'Use this instead of external editors so the encoding is always right. '
      + 'Refuses binary extensions (.mat/.mdl/.fig).',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute file path' },
        content: { type: 'string', description: 'Text content to write' },
        enc: { type: 'string', enum: ['auto', 'gbk', 'utf8'], description: 'Encoding (default auto)' },
      },
      required: ['path', 'content'],
    },
  },
  {
    name: 'matlab_append_file',
    description: 'Append text to a file on disk (encoding rules same as matlab_write_file). '
      + 'Great for incrementally building .md logs/report snippets without fprintf %%-escaping pain.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute file path' },
        text: { type: 'string', description: 'Text to append' },
        enc: { type: 'string', enum: ['auto', 'gbk', 'utf8'], description: 'Encoding (default auto)' },
      },
      required: ['path', 'text'],
    },
  },
  {
    name: 'matlab_read_file',
    description: 'Read a text file via MATLAB and return its content. .m files are '
      + 'decoded as GBK (R14 codepage), everything else UTF-8. Max 2 MB.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Absolute file path' },
        enc: { type: 'string', enum: ['auto', 'gbk', 'utf8'], description: 'Encoding (default auto)' },
      },
      required: ['path'],
    },
  },
  {
    name: 'matlab_dir',
    description: 'List a directory (default: current MATLAB working directory) with sizes.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Directory path (default cwd)' } },
    },
  },
  {
    name: 'matlab_figure_png',
    description: 'Export a MATLAB figure window to PNG and return it as an image. '
      + 'Run plotting code with matlab_eval first. Default exports the most recently '
      + 'created figure (true gcf semantics). Supports dpi and auto-close.',
    inputSchema: {
      type: 'object',
      properties: {
        fig: { type: 'number', description: 'Figure handle (default 0 = most recent figure)' },
        file: { type: 'string', description: 'Output PNG path (default <work_dir>/figure_<ts>.png)' },
        dpi: { type: 'number', description: 'Resolution in DPI (default 110)' },
        close: { type: 'boolean', description: 'Close the figure after export (default false)' },
      },
    },
  },
  {
    name: 'matlab_window_png',
    description: 'Capture a live window (Simulink model editor, Scope, any GUI) by title '
      + 'substring to PNG via PowerShell screen capture, and return it as an image. '
      + 'Use this for Simulink/Scope screenshots: R14 print(-sModel) fails in this environment. '
      + 'The window is brought to front first and restored from minimized state; it is captured '
      + 'at its current size unless resize_width/resize_height are given (e.g. 1250x900 for models).',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Window title substring, e.g. "Comm_Link" or "Scope"' },
        file: { type: 'string', description: 'Output PNG path (default <work_dir>/window_<ts>.png)' },
        resize_width: { type: 'number', description: 'Resize window to this width before capture (0 = keep, default 0)' },
        resize_height: { type: 'number', description: 'Resize window to this height before capture (0 = keep, default 0)' },
      },
      required: ['title'],
    },
  },
  {
    name: 'matlab_figures',
    description: 'List open figure windows (handle, number, name, visibility).',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'matlab_sim_scan',
    description: 'Regex-search saved .mdl file(s) on disk WITHOUT loading the model into '
      + 'Simulink. R14 models are plain text, so this finds block names, parameter values, '
      + 'or any string quickly and safely -- even when the model is too broken to load. '
      + 'Pass a folder to scan every .mdl in it. Case-insensitive.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '.mdl file path, or a folder to scan all .mdl in it' },
        pattern: { type: 'string', description: 'Regular expression to search for' },
      },
      required: ['path', 'pattern'],
    },
  },
  {
    name: 'matlab_sim_info',
    description: 'Audit a loaded-or-not Simulink model for R14 ghost-line problems: orphan '
      + 'line segments, lines with duplicate destination ports, unconnected input AND output '
      + 'ports, and dangling line tails (source ok, destination floats). '
      + 'With fix=true it also deletes the offending lines (caller re-adds connections). '
      + 'Run after any session of add_line/delete_block surgery that produced '
      + '"destination port already has a line connection" errors.',
    inputSchema: {
      type: 'object',
      properties: {
        model: { type: 'string', description: 'Model name (loaded) or path to .mdl' },
        fix: { type: 'boolean', description: 'Also delete ghost lines (default false)' },
      },
      required: ['model'],
    },
  },
  {
    name: 'matlab_sim_clean',
    description: 'Remove orphan line segments (no valid source and/or no valid destination) '
      + 'from a Simulink model and save it. Healthy lines are never touched. '
      + 'Safe to call repeatedly. Less aggressive than matlab_sim_info fix=true.',
    inputSchema: {
      type: 'object',
      properties: {
        model: { type: 'string', description: 'Model name or path to .mdl' },
      },
      required: ['model'],
    },
  },
  {
    name: 'matlab_sim_route',
    description: 'Re-route every line in a Simulink model as clean orthogonal (horizontal/'
      + 'vertical) polylines that do not cross any block body, then save. Handles straight, '
      + 'L/Z shapes, inverted-Z, and go-around lanes for blocked spans; branch lines included. '
      + 'Use after programmatic model building (add_block/add_line) or after matlab_sim_arrange '
      + 'to make the diagram readable. Lines keep their connectivity; a few geometry-degenerate '
      + 'lines may be reported as failed and left in R14 canonical form.',
    inputSchema: {
      type: 'object',
      properties: {
        model: { type: 'string', description: 'Model name or path to .mdl' },
        spacing: { type: 'number', description: 'Preferred channel offset from ports in px (default 30)' },
        margin: { type: 'number', description: 'Extra clearance around blocks in px (default 4)' },
      },
      required: ['model'],
    },
  },
  {
    name: 'matlab_sim_arrange',
    description: 'Auto-arrange the blocks of one Simulink diagram layer (root or a subsystem) '
      + 'into a clean left-to-right signal-flow layout: longest-path layering over the '
      + 'connection graph (feedback loops handled), barycenter ordering to reduce crossings, '
      + 'cumulative-x slots so wide blocks never bleed into the next layer. Moves blocks only; '
      + 'follow with matlab_sim_route to re-route the lines orthogonally. Arranges '
      + '<model> root by default; pass sys for a subsystem.',
    inputSchema: {
      type: 'object',
      properties: {
        model: { type: 'string', description: 'Model name or path to .mdl' },
        sys: { type: 'string', description: 'Subsystem path to arrange (default: model root)' },
        xgap: { type: 'number', description: 'Horizontal gap between layers in px (default 90)' },
        ygap: { type: 'number', description: 'Vertical gap between rows in px (default 35)' },
      },
      required: ['model'],
    },
  },
  {
    name: 'matlab_cleanup',
    description: 'Bulk cleanup: close all open figures and/or all loaded Simulink models '
      + '(without saving). Returns how many of each were closed. Use between experiments '
      + 'or after a long GUI screenshot batch.',
    inputSchema: {
      type: 'object',
      properties: {
        close_figs: { type: 'boolean', description: 'Close all figure windows (default false)' },
        close_models: { type: 'boolean', description: 'Close all loaded Simulink models (default false)' },
      },
    },
  },
  {
    name: 'matlab_progress',
    description: 'Read progress of the LAST eval that called mcp_progress(frac, msg): '
      + 'returns {pct, msg} or "(no progress reported)". '
      + 'Since v3.1 the server stays responsive during long runs, so you can poll '
      + 'this (and matlab_status) WHILE an eval is running.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'matlab_last',
    description: 'Fetch the most recent completed worker response (cmd, ok, stdout/error). '
      + 'Use this when a long eval/run_file tool call was cut by the client-side '
      + 'timeout: the MATLAB job keeps running and its console output is archived '
      + 'here when it finishes. Long-job pattern: fire -> poll matlab_status / '
      + 'matlab_progress -> collect with matlab_last.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'matlab_status',
    description: 'Get MATLAB worker status: PID, alive, boot time, MATLAB version, and what command it is busy with right now (with elapsed seconds). Never blocks, even during long jobs.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'matlab_restart',
    description: 'Kill the MATLAB worker process and start a fresh one (clears base workspace; runs worker_init.m if present).',
    inputSchema: { type: 'object', properties: {} },
  },
];

let figCounter = 0;

function truncate(text) {
  if (!text || text.length <= MAX_CHARS) return text;
  return text.slice(0, MAX_CHARS) + `\n...[truncated ${text.length - MAX_CHARS} chars]`;
}

function textOut(text, isError) {
  const content = [{ type: 'text', text: text || '(no output)' }];
  return isError ? { content, isError: true } : { content };
}

async function callTool(name, args) {
  switch (name) {
    case 'matlab_eval': {
      const timeout = Math.min(1800, Math.max(1, args.timeout_sec || 120));
      if (args.check_first) {
        const c = await workerRequest({ cmd: 'check', code: String(args.code) }, 60);
        if (c.ok && c.value && c.value.clean === false) {
          return textOut('Syntax check failed — not run.\n' + c.value.issues, true);
        }
      }
      const r = await workerRequest({ cmd: 'eval', code: String(args.code) }, timeout);
      return textOut(truncate((r.stdout || '').replace(/\r\n/g, '\n').trim()), !r.ok);
    }
    case 'matlab_check': {
      const r = await workerRequest({ cmd: 'check', code: String(args.code) }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      return textOut(v.clean ? 'OK — code parses clean.' : ('Parse issues:\n' + v.issues), !v.clean);
    }
    case 'matlab_run_file': {
      const p = String(args.path || '');
      if (!fs.existsSync(p)) throw new Error('File not found: ' + p);
      const timeout = Math.min(1800, Math.max(1, args.timeout_sec || 300));
      const r = await workerRequest({ cmd: 'run_file', file: p }, timeout);
      return textOut(truncate((r.stdout || '').replace(/\r\n/g, '\n').trim()), !r.ok);
    }
    case 'matlab_get_var': {
      const r = await workerRequest({ cmd: 'get', var: String(args.name) }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_summary': {
      const r = await workerRequest({
        cmd: 'summary',
        var: String(args.name),
        max_rows: Number.isFinite(args.max_rows) ? args.max_rows : 200,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r, null, 1));
    }
    case 'matlab_set_var': {
      const vj = JSON.stringify(args.value);
      const r = await workerRequest({ cmd: 'set', var: String(args.name), value_json: vj }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(`Set ${args.name} OK`);
    }
    case 'matlab_workspace': {
      const r = await workerRequest({ cmd: 'ws' }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((v) => `${v.name}  ${v.class}  ${v.size}`);
      return textOut(lines.length ? lines.join('\n') : '(empty workspace)');
    }
    case 'matlab_write_file': {
      const r = await workerRequest({
        cmd: 'write_file',
        file: String(args.path),
        content: String(args.content ?? ''),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(r.stdout || 'written');
    }
    case 'matlab_append_file': {
      const r = await workerRequest({
        cmd: 'append',
        file: String(args.path),
        text: String(args.text ?? ''),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(r.stdout || 'appended');
    }
    case 'matlab_read_file': {
      const r = await workerRequest({
        cmd: 'read_file',
        file: String(args.path),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(truncate(r.value ?? ''));
    }
    case 'matlab_dir': {
      const r = await workerRequest({ cmd: 'dir', file: String(args.path || '.') }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((d) => `${d.isdir ? '<DIR> ' : ''}${d.name}${d.isdir ? '' : '  ' + d.bytes + ' B'}`);
      return textOut(lines.length ? lines.join('\n') : '(empty)');
    }
    case 'matlab_figure_png': {
      figCounter += 1;
      const fig = Number.isFinite(args.fig) ? args.fig : 0;
      const file = args.file || path.join(WORK_DIR, `figure_${Date.now()}.png`);
      const r = await workerRequest({
        cmd: 'put_png',
        fig,
        file,
        dpi: Number.isFinite(args.dpi) ? args.dpi : 110,
        close: args.close ? 1 : 0,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'png export failed'), true);
      if (!fs.existsSync(file)) return textOut('Error: PNG not created', true);
      const b64 = fs.readFileSync(file).toString('base64');
      return {
        content: [
          { type: 'text', text: `Figure exported to ${file}` },
          { type: 'image', data: b64, mimeType: 'image/png' },
        ],
      };
    }
    case 'matlab_window_png': {
      const title = String(args.title || '');
      if (!title) return textOut('Error: title is required', true);
      const file = args.file || path.join(WORK_DIR, `window_${Date.now()}.png`);
      const psArgs = [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CAP_PS1,
        '-Title', title, '-Out', file,
      ];
      if (Number.isFinite(args.resize_width) || Number.isFinite(args.resize_height)) {
        psArgs.push('-ResizeWidth', String(args.resize_width | 0), '-ResizeHeight', String(args.resize_height | 0));
      }
      const r = spawnSync('powershell.exe', psArgs, { encoding: 'utf8', timeout: 30000 });
      const out = (r.stdout || '') + (r.stderr || '');
      if (!fs.existsSync(file)) {
        let hint = out.trim();
        if (/MINIMIZED/.test(hint)) {
          hint = 'window is minimized; call matlab_eval with open_system(<model>) or figure(<handle>) first, then retry';
        } else if (/NOTFOUND/.test(hint)) {
          hint = 'no visible window title contains "' + title + '"; check exact title (model name, Scope number) and open the window first';
        }
        return textOut('Capture failed: ' + hint, true);
      }
      const b64 = fs.readFileSync(file).toString('base64');
      return {
        content: [
          { type: 'text', text: `Window "${title}" captured to ${file} (${out.trim()})` },
          { type: 'image', data: b64, mimeType: 'image/png' },
        ],
      };
    }
    case 'matlab_figures': {
      const r = await workerRequest({ cmd: 'figs' }, 30);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((f, i) => `handle ${f.handle}  (newest=${i === 0})  ${f.visible}${f.name ? '  "' + f.name + '"' : ''}`);
      return textOut(lines.length ? lines.join('\n') : '(no open figures)');
    }
    case 'matlab_sim_scan': {
      const r = await workerRequest({
        cmd: 'sim_scan',
        model: String(args.path),
        pattern: String(args.pattern),
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      const head = `${v.nMatches} match(es) for /${v.pattern}/i in ${v.nLinesScanned} scanned lines of ${v.path}`;
      const hits = (v.lines || []).map(h => `  L${h.lineNo}: ${h.text}`);
      return textOut([head].concat(hits).join('\n'));
    }
    case 'matlab_sim_info': {
      const r = await workerRequest({
        cmd: 'sim_info',
        model: String(args.model),
        fix: args.fix ? 1 : 0,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_sim_clean': {
      const r = await workerRequest({
        cmd: 'sim_clean',
        model: String(args.model),
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_sim_route': {
      const r = await workerRequest({
        cmd: 'sim_route',
        model: String(args.model),
        spacing: Number.isFinite(args.spacing) ? args.spacing : 30,
        margin: Number.isFinite(args.margin) ? args.margin : 4,
      }, 300);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      let out = `Routed ${v.routed} line(s), kept ${v.kept} as-is, failed ${v.failed}. Model saved.`;
      if ((v.ghost_lines || 0) > 0) {
        out += `\nNote: ${v.ghost_lines} ghost duplicate-dst line row(s) detected — they render red-dashed but sim fine. ` +
          'Run matlab_sim_info (no fix) for details; interactive cleanup recommended (scripted deletion rewires branch rows).';
      }
      if (v.details && v.details.length) out += '\n' + v.details.join('\n');
      return textOut(out, (v.failed || 0) > 0);
    }
    case 'matlab_sim_arrange': {
      const r = await workerRequest({
        cmd: 'sim_arrange',
        model: String(args.model),
        sys: String(args.sys || ''),
        xgap: Number.isFinite(args.xgap) ? args.xgap : 90,
        ygap: Number.isFinite(args.ygap) ? args.ygap : 35,
      }, 300);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      return textOut(`Arranged ${v.nblocks} block(s) in ${v.layers} layer(s), moved ${v.moved}. ` +
        'Follow with matlab_sim_route to re-route the lines.');
    }
    case 'matlab_cleanup': {
      const r = await workerRequest({
        cmd: 'closeall',
        close_figs: args.close_figs ? 1 : 0,
        close_models: args.close_models ? 1 : 0,
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      return textOut(`Closed ${v.figures || 0} figure(s), ${v.models || 0} model(s)` + (v.notes ? `\nNotes: ${v.notes}` : ''));
    }
    case 'matlab_progress': {
      let pct = null, msg = '';
      try {
        const j = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
        pct = j.pct; msg = j.msg || '';
      } catch {
        return textOut('(no progress reported — either the last eval never called mcp_progress, or progress.json was cleaned)');
      }
      return textOut(`progress: ${pct}% ${msg}`.trimEnd());
    }
    case 'matlab_last': {
      // Prefer an unclaimed res.json: if a finished job's response is still
      // sitting there (client cut the call before the server-side promise
      // consumed it), it IS the most recent completed output.
      let j = null;
      try { j = JSON.parse(fs.readFileSync(RES_FILE, 'utf8')); } catch {}
      if (!j || j.id === undefined) {
        try { j = JSON.parse(fs.readFileSync(RES_LAST_FILE, 'utf8')); } catch {}
      }
      if (!j) return textOut('(no completed worker response archived yet)');
      const head = `cmd=${j.cmd || '?'}  ok=${j.ok}  id=${j.id}`;
      const body = j.ok
        ? truncate((j.stdout || '').replace(/\r\n/g, '\n').trim() || '(no stdout)')
        : ('Error: ' + (j.error || 'unknown'));
      return textOut(head + '\n' + body, !j.ok);
    }
    case 'matlab_status': {
      const pid = readPid();
      const alive = pidAlive(pid);
      const busy = readBusy();
      let busyLine = 'Busy: no (idle)';
      if (busy) {
        let elapsed = '';
        const t = Date.parse(busy.since || '');
        if (Number.isFinite(t)) elapsed = `, ${Math.round((Date.now() - t) / 1000)}s elapsed`;
        busyLine = `Busy: cmd="${busy.cmd}" since ${busy.since} (req id=${busy.id}${elapsed})`;
      }
      const lines = [
        `MATLAB exe: ${MATLAB_EXE || '(not found)'}`,
        `Worker PID: ${pid || '-'}  alive: ${alive}`,
        `Booted at: ${workerBootedAt || '-'}`,
        `MATLAB version: ${workerVersion || '-'}`,
        busyLine,
        `Work dir: ${WORK_DIR}`,
        `Kill-all mode: ${KILL_ALL ? 'on (MCP_KILL_ALL=1)' : 'off (only pidfile PID is killed)'}`,
      ];
      return textOut(lines.join('\n'));
    }
    case 'matlab_restart': {
      await startWorker();
      return textOut(`Worker restarted (PID ${readPid()})`);
    }
    default:
      throw new Error('Unknown tool: ' + name);
  }
}

function shutdown() {
  try {
    const pid = readPid();
    if (pid && pidAlive(pid)) spawnSync('taskkill', ['/PID', String(pid), '/F']);
  } catch {}
  process.exit(0);
}

// -------------------------------------------------------------------- main
try { fs.mkdirSync(WORK_DIR, { recursive: true }); } catch {}
send({ jsonrpc: '2.0', method: 'notifications/log', params: { level: 'info', data: `matlab7-mcp-server v3.2 ready (${TOOLS.length} tools)` } });
// Keep the process alive; worker starts lazily on first tool call.
setInterval(() => {}, 1 << 30);
