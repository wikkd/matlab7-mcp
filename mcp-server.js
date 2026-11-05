#!/usr/bin/env node
/**
 * matlab7-mcp-server — MCP stdio server bridging to MATLAB 7.0 (R14)
 * via a persistent mcp_worker.m process (file-based JSON protocol).
 *
 * Zero npm dependencies. Node >= 16.
 *
 * v3.3.0 (2026-11-06): full internal refactor. The former single 1111-line
 * file is split into lib/config.js (constants + env), lib/worker.js
 * (lifecycle + per-instance request channel), lib/tools.js (the 26 tool
 * schemas) and lib/handlers.js (the tool implementations). This entry keeps
 * only MCP stdio plumbing. Tool schemas are byte-identical to v3.2.2
 * (machine-diffed); the wire protocol is unchanged. Contract fixes that
 * came out of the code review ride along: matlab_restart really restarts,
 * text outputs honor MCP_MAX_CHARS uniformly, timed-out requests no longer
 * leak a pendingCmd entry.
 *
 * Version history (details in README.md):
 *   v3.0  check_first / summary / sim audit+route / window capture / progress
 *   v3.1  async dispatch (server stays responsive during long jobs) +
 *         matlab_last abandoned-job rescue
 *   v3.2  per-instance protocol channels (two sessions, one shared worker) +
 *         matlab_assert batch grading + sim_scan
 *   v3.2.1 runtime hygiene: boot sweep of dead-instance files, progress-path
 *         hardening (globals are unreliable on R14)
 *   v3.2.2 test net: 56-case regress + isolation/negative driver; found the
 *         parse_req 'pattern' gap and the which()-fallback blind spot
 *
 * Env vars:
 *   MATLAB7_DIR    MATLAB root, e.g. D:\MATLAB7   (default: auto-detect)
 *   MCP_WORK_DIR   Working folder for req/res files (default: <server_dir>)
 *   MCP_BOOT_WAIT  Max seconds to wait for worker boot (default: 120)
 *   MCP_KILL_ALL   1 = kill every MATLAB.exe on stale-cleanup (v1 behaviour)
 *   MCP_MAX_CHARS  Truncate long text outputs to this many chars (default 200000)
 */

const fs = require('fs');
const C = require('./lib/config');
const { TOOLS } = require('./lib/tools');
const { callTool } = require('./lib/handlers');
const worker = require('./lib/worker');

// ------------------------------------------------------------- MCP plumbing
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
      serverInfo: { name: 'matlab7-mcp-server', version: C.VERSION },
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

function shutdown() {
  worker.shutdownKillWorker();
  process.exit(0);
}

// -------------------------------------------------------------------- main
try { fs.mkdirSync(C.WORK_DIR, { recursive: true }); } catch {}
send({ jsonrpc: '2.0', method: 'notifications/log', params: { level: 'info', data: `matlab7-mcp-server v${C.VERSION} ready (${TOOLS.length} tools)` } });
// Keep the process alive; worker starts lazily on first tool call.
setInterval(() => {}, 1 << 30);
