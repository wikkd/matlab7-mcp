// lib/config.js — all constants and env resolution for the matlab7-mcp server.
// Split out of the former single-file mcp-server.js (v3.3.0 refactor); no
// behavior change. NOTE: __dirname here is <repo>/lib, so SERVER_DIR points
// one level up (where mcp_worker.m and the test drivers live).
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Advertised in serverInfo during MCP initialize. check_static parses this
// line (server:version-shape), so keep the literal form `VERSION = 'x.y.z'`.
const VERSION = '3.3.0';
const SERVER_DIR = path.resolve(__dirname, '..');
const WORK_DIR = process.env.MCP_WORK_DIR || SERVER_DIR;
// v3.2 instance isolation: each server process gets its own request/response/
// history channels (req_<pid>.json etc.) so two ZCode sessions using matlab7
// simultaneously no longer stomp each other's protocol files. The MATLAB
// worker itself is SHARED: requests are picked up in arrival order and each
// response goes back on the channel named in the request's "reply" tag.
// worker.pid / busy.json / worker_boot.log stay shared.
const INST = 'i' + process.pid;
const REQ_FILE = path.join(WORK_DIR, 'req_' + INST + '.json');
const RES_FILE = path.join(WORK_DIR, 'res_' + INST + '.json');
const RES_LAST_FILE = path.join(WORK_DIR, 'res_last_' + INST + '.json');
const RES_HIST_FILE = path.join(WORK_DIR, 'res_history_' + INST + '.jsonl');
const HIST_KEEP = 20; // ring buffer size for completed-job history
const PID_FILE = path.join(WORK_DIR, 'worker.pid');
const BUSY_FILE = path.join(WORK_DIR, 'busy.json');
const PROGRESS_FILE = path.join(WORK_DIR, 'progress.json');
const BOOT_LOCK = path.join(WORK_DIR, 'boot.lock');
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

function pidAlive(pid) {
  if (!pid) return false;
  const r = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8' });
  return r.status === 0 && (r.stdout || '').includes('MATLAB');
}

module.exports = {
  VERSION, SERVER_DIR, WORK_DIR, INST,
  REQ_FILE, RES_FILE, RES_LAST_FILE, RES_HIST_FILE, HIST_KEEP,
  PID_FILE, BUSY_FILE, PROGRESS_FILE, BOOT_LOCK, CAP_PS1,
  BOOT_WAIT_SEC, KILL_ALL, MAX_CHARS, MATLAB_EXE, pidAlive,
};
