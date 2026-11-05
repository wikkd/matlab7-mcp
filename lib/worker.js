// lib/worker.js — MATLAB worker lifecycle and the per-instance request
// channel (spawn/boot-lock/sweep, workerRequest/waitForResponse, history
// ring buffer). Extracted from the former single-file mcp-server.js
// (v3.3.0 refactor); behavior identical to v3.2.2.
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const C = require('./config');

let workerProc = null;
let workerBootedAt = null;
let workerVersion = '';

// id -> cmd name, recorded when the request is written so archiveRes can
// label history entries even after the worker has cleared busy.json.
const pendingCmd = {};
let nextId = 1;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readPid() {
  try {
    const s = fs.readFileSync(C.PID_FILE, 'utf8').trim();
    const pid = parseInt(s, 10);
    return Number.isFinite(pid) && pid > 0 ? pid : null;
  } catch { return null; }
}
function readBusy() {
  try { return JSON.parse(fs.readFileSync(C.BUSY_FILE, 'utf8')); } catch { return null; }
}

async function killStaleWorker() {
  const pid = readPid();
  if (pid && C.pidAlive(pid)) {
    try { spawnSync('taskkill', ['/PID', String(pid), '/F']); } catch {}
  }
  // Only nuke ALL MATLAB processes when explicitly asked: the user may have
  // their own MATLAB GUI open, killing it would lose their work.
  if (C.KILL_ALL) {
    try { spawnSync('taskkill', ['/IM', 'MATLAB.exe', '/F']); } catch {}
  }
  for (let i = 0; i < 20; i++) {
    if (!C.pidAlive(pid)) break;
    await sleep(500);
  }
  // clear protocol files from any previous session (all instances + legacy)
  // v3.2.1: also sweep per-instance history/last files of dead instances and
  // stale default-named figure PNGs - both accumulated forever in the work
  // dir (14 res_history_i*/res_last_i* + 4 figure_<ts>.png observed
  // 2026-11-05 after a week of sessions). Runs only when (re)booting a dead
  // worker, so a live instance's files are never touched.
  try {
    for (const f of fs.readdirSync(C.WORK_DIR)) {
      if (/^(req_i\d+|res_i\d+|res_boot)\.json$/.test(f) ||
          /^res_history_i\d+\.jsonl$/.test(f) ||
          /^res_last_i\d+\.json$/.test(f) ||
          f === 'res_history.jsonl' || f === 'res_last.json' ||
          /^figure_\d{13}\.png$/.test(f) ||
          f === 'req.json' || f === 'res.json' || f === C.BUSY_FILE) {
        try { fs.unlinkSync(path.join(C.WORK_DIR, f)); } catch {}
      }
    }
  } catch {}
}

async function startWorker() {
  if (!C.MATLAB_EXE) throw new Error('MATLAB 7.0 not found. Set MATLAB7_DIR env var.');
  // v3.2: the worker is SHARED between server instances. If another instance
  // is already booting (boot.lock fresh) or a live worker exists, wait for it
  // instead of spawning a second MATLAB.
  const lockFresh = (() => {
    try {
      const st = fs.statSync(C.BOOT_LOCK);
      return (Date.now() - st.mtimeMs) < C.BOOT_WAIT_SEC * 1000;
    } catch { return false; }
  })();
  const pid0 = readPid();
  if (lockFresh && !pid0) {
    // another instance is mid-boot — wait for the shared pidfile
    const t0w = Date.now();
    while (Date.now() - t0w < C.BOOT_WAIT_SEC * 1000) {
      const p = readPid();
      if (p && C.pidAlive(p)) return;
      await sleep(500);
    }
    throw new Error('Another mcp-server instance was booting the worker but it never came up');
  }
  if (pid0 && C.pidAlive(pid0)) return; // healthy shared worker already running

  // We are the booter: take the lock so late joiners wait on us.
  try { fs.writeFileSync(C.BOOT_LOCK, String(process.pid), 'utf8'); } catch {}
  await killStaleWorker();
  // Rotate the boot log so it cannot grow without bound (R14 appends forever).
  try {
    const log = path.join(C.WORK_DIR, 'worker_boot.log');
    if (fs.existsSync(log)) fs.renameSync(log, log.replace(/\.log$/, '.log.1'));
  } catch {}
  // progress.json from a previous session would make matlab_progress report
  // stale numbers before the first eval of this session has run.
  try { if (fs.existsSync(C.PROGRESS_FILE)) fs.unlinkSync(C.PROGRESS_FILE); } catch {}
  const code = `cd('${C.WORK_DIR.replace(/\\/g, '/')}'), addpath('${C.SERVER_DIR.replace(/\\/g, '/')}'), mcp_worker('req.json','res_boot.json','worker.pid','busy.json'), exit`;
  workerProc = spawn(C.MATLAB_EXE, ['-nosplash', '-nodesktop', '-logfile', path.join(C.WORK_DIR, 'worker_boot.log'), '-r', code], {
    cwd: C.WORK_DIR,
    detached: false,
    stdio: 'ignore',
  });
  workerProc.on('exit', () => { workerProc = null; workerBootedAt = null; });

  // The boot response lands on the shared res_boot.json (not any instance's
  // own channel); boot success = live shared pidfile.
  const BOOT_RES = path.join(C.WORK_DIR, 'res_boot.json');
  const t0 = Date.now();
  while (Date.now() - t0 < C.BOOT_WAIT_SEC * 1000) {
    if (fs.existsSync(BOOT_RES)) {
      try {
        const j = JSON.parse(fs.readFileSync(BOOT_RES, 'utf8'));
        if (j.ok) {
          workerBootedAt = new Date().toISOString();
          workerVersion = j.version || '';
          try { fs.unlinkSync(C.BOOT_LOCK); } catch {}
          return;
        }
      } catch {}
    }
    await sleep(500); // v3.1: yield to the event loop while booting
  }
  try { fs.unlinkSync(C.BOOT_LOCK); } catch {}
  throw new Error(`MATLAB worker failed to boot within ${C.BOOT_WAIT_SEC}s`);
}

async function ensureWorker() {
  const pid = readPid();
  if (!pid || !C.pidAlive(pid)) {
    await startWorker();
  }
}

/** Archive the current res.json to res_last.json (best-effort: attach the
 *  busy cmd when the worker has not cleared busy.json yet) and append it to
 *  the ring-buffer history (res_history.jsonl, newest last, HIST_KEEP kept). */
function archiveRes() {
  try {
    const j = JSON.parse(fs.readFileSync(C.RES_FILE, 'utf8'));
    try {
      const b = JSON.parse(fs.readFileSync(C.BUSY_FILE, 'utf8'));
      if (b && b.cmd && Number(b.id) === Number(j.id)) j.cmd = b.cmd;
    } catch {}
    if (!j.cmd && pendingCmd[j.id] !== undefined) j.cmd = pendingCmd[j.id];
    if (pendingCmd[j.id] !== undefined && j.ok !== undefined) delete pendingCmd[j.id];
    fs.writeFileSync(C.RES_LAST_FILE, JSON.stringify(j), 'utf8');
    // Append to history (skip if this id is already the newest entry —
    // archiveRes can run more than once for the same response).
    let hist = [];
    try {
      hist = fs.readFileSync(C.RES_HIST_FILE, 'utf8').split('\n').filter(Boolean).map((l) => {
        try { return JSON.parse(l); } catch { return null; }
      }).filter(Boolean);
    } catch {}
    if (!hist.length || Number(hist[hist.length - 1].id) !== Number(j.id)) {
      hist.push(j);
      while (hist.length > C.HIST_KEEP) hist.shift();
      fs.writeFileSync(C.RES_HIST_FILE, hist.map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8');
    }
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
  await ensureWorker();
  const id = nextId++;
  const req = JSON.stringify(Object.assign({ id, reply: C.INST }, payload));
  pendingCmd[id] = payload.cmd || '?';
  // 1) archive + clear any previous response (matlab_last can still read it)
  archiveRes();
  try { fs.unlinkSync(C.RES_FILE); } catch {}
  // 2) write request atomically (write tmp, rename)
  const tmp = C.REQ_FILE + '.tmp';
  fs.writeFileSync(tmp, req, 'utf8');
  fs.renameSync(tmp, C.REQ_FILE);
  // 3) wait for the matching response by polling
  return waitForResponse(id, timeoutSec * 1000);
}

async function waitForResponse(id, timeoutMs) {
  const deadline = Date.now() + timeoutMs;

  const check = () => {
    if (!fs.existsSync(C.RES_FILE)) return null;
    try {
      const j = JSON.parse(fs.readFileSync(C.RES_FILE, 'utf8'));
      if (j.id === id) {
        archiveRes();
        try { fs.unlinkSync(C.RES_FILE); } catch {}
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
    if (!pid || !C.pidAlive(pid)) {
      delete pendingCmd[id];
      throw new Error('MATLAB worker died mid-request (check worker_boot.log)');
    }
  }
  // v3.3: drop the pending-cmd label on timeout too (was a small leak: one
  // stale entry per timed-out request lived in pendingCmd forever).
  delete pendingCmd[id];

  // Timeout: the promise dies, but the MATLAB job keeps running — the user
  // can collect the output later with matlab_last, or restart.
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

/** v3.3: matlab_restart now honors its description — actually kill the
 *  worker (and sweep protocol files) instead of silently returning when a
 *  live worker exists. Destructive by definition; other instances' in-flight
 *  jobs die with the worker and re-boot on their next request. */
async function restartWorker() {
  await killStaleWorker();
  await startWorker();
}

/** Kill the shared worker on graceful server exit. Best-effort: on Windows a
 *  hard TerminateProcess never reaches these handlers, so a killed server
 *  leaves the worker running (it re-boots on demand later). */
function shutdownKillWorker() {
  try {
    const pid = readPid();
    if (pid && C.pidAlive(pid)) spawnSync('taskkill', ['/PID', String(pid), '/F']);
  } catch {}
}

module.exports = {
  workerRequest, waitForResponse, ensureWorker, startWorker, restartWorker,
  killStaleWorker, archiveRes, readPid, readBusy, shutdownKillWorker,
  get bootedAt() { return workerBootedAt; },
  get version() { return workerVersion; },
};
