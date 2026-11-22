// lib/handlers.js — the 26 tool implementations. Extracted from the former
// single-file mcp-server.js (v3.3.0 refactor). Deliberate deltas from
// v3.2.2, all contract alignments:
//   - matlab_restart actually kills + re-boots the worker now (its
//     description always said so; the old code silently no-op'd on a live
//     worker, so stale worker code survived a "restart").
//   - textOut truncates internally, so every text output (dir, workspace,
//     sim_scan...) honors MCP_MAX_CHARS, not just eval/run_file/read_file.
//   - timed-out requests no longer leak a pendingCmd entry.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const C = require('./config');
const worker = require('./worker');

function truncate(text) {
  if (!text || text.length <= C.MAX_CHARS) return text;
  return text.slice(0, C.MAX_CHARS) + `\n...[truncated ${text.length - C.MAX_CHARS} chars]`;
}

function textOut(text, isError) {
  const content = [{ type: 'text', text: truncate(text) || '(no output)' }];
  return isError ? { content, isError: true } : { content };
}

function imageOut(text, file) {
  const b64 = fs.readFileSync(file).toString('base64');
  return {
    content: [
      { type: 'text', text },
      { type: 'image', data: b64, mimeType: 'image/png' },
    ],
  };
}

async function callTool(name, args) {
  switch (name) {
    case 'matlab_eval': {
      const timeout = Math.min(1800, Math.max(1, args.timeout_sec || 120));
      if (args.check_first) {
        const c = await worker.workerRequest({ cmd: 'check', code: String(args.code) }, 60);
        if (c.ok && c.value && c.value.clean === false) {
          return textOut('Syntax check failed — not run.\n' + c.value.issues, true);
        }
      }
      const r = await worker.workerRequest({ cmd: 'eval', code: String(args.code) }, timeout);
      return textOut((r.stdout || '').replace(/\r\n/g, '\n').trim(), !r.ok);
    }
    case 'matlab_check': {
      const r = await worker.workerRequest({ cmd: 'check', code: String(args.code) }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      return textOut(v.clean ? 'OK — code parses clean.' : ('Parse issues:\n' + v.issues), !v.clean);
    }
    case 'matlab_run_file': {
      const p = String(args.path || '');
      if (!fs.existsSync(p)) throw new Error('File not found: ' + p);
      const timeout = Math.min(1800, Math.max(1, args.timeout_sec || 300));
      const r = await worker.workerRequest({ cmd: 'run_file', file: p }, timeout);
      return textOut((r.stdout || '').replace(/\r\n/g, '\n').trim(), !r.ok);
    }
    case 'matlab_get_var': {
      const r = await worker.workerRequest({ cmd: 'get', var: String(args.name) }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_summary': {
      const r = await worker.workerRequest({
        cmd: 'summary',
        var: String(args.name),
        max_rows: Number.isFinite(args.max_rows) ? args.max_rows : 200,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r, null, 1));
    }
    case 'matlab_set_var': {
      const vj = JSON.stringify(args.value);
      const r = await worker.workerRequest({ cmd: 'set', var: String(args.name), value_json: vj }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(`Set ${args.name} OK`);
    }
    case 'matlab_workspace': {
      const r = await worker.workerRequest({ cmd: 'ws' }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((v) => `${v.name}  ${v.class}  ${v.size}`);
      return textOut(lines.length ? lines.join('\n') : '(empty workspace)');
    }
    case 'matlab_write_file': {
      const r = await worker.workerRequest({
        cmd: 'write_file',
        file: String(args.path),
        content: String(args.content ?? ''),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(r.stdout || 'written');
    }
    case 'matlab_append_file': {
      const r = await worker.workerRequest({
        cmd: 'append',
        file: String(args.path),
        text: String(args.text ?? ''),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(r.stdout || 'appended');
    }
    case 'matlab_read_file': {
      const r = await worker.workerRequest({
        cmd: 'read_file',
        file: String(args.path),
        enc: String(args.enc || 'auto'),
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(r.value ?? '');
    }
    case 'matlab_dir': {
      const r = await worker.workerRequest({ cmd: 'dir', file: String(args.path || '.') }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((d) => `${d.isdir ? '<DIR> ' : ''}${d.name}${d.isdir ? '' : '  ' + d.bytes + ' B'}`);
      return textOut(lines.length ? lines.join('\n') : '(empty)');
    }
    case 'matlab_figure_png': {
      const fig = Number.isFinite(args.fig) ? args.fig : 0;
      const file = args.file || path.join(C.WORK_DIR, `figure_${Date.now()}.png`);
      const r = await worker.workerRequest({
        cmd: 'put_png',
        fig,
        file,
        dpi: Number.isFinite(args.dpi) ? args.dpi : 110,
        close: args.close ? 1 : 0,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'png export failed'), true);
      if (!fs.existsSync(file)) return textOut('Error: PNG not created', true);
      return imageOut(`Figure exported to ${file}`, file);
    }
    case 'matlab_window_png': {
      const title = String(args.title || '');
      if (!title) return textOut('Error: title is required', true);
      const file = args.file || path.join(C.WORK_DIR, `window_${Date.now()}.png`);
      const psArgs = [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', C.CAP_PS1,
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
      return imageOut(`Window "${title}" captured to ${file} (${out.trim()})`, file);
    }
    case 'matlab_figures': {
      const r = await worker.workerRequest({ cmd: 'figs' }, 30);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const lines = (r.value || []).map((f, i) => `handle ${f.handle}  (newest=${i === 0})  ${f.visible}${f.name ? '  "' + f.name + '"' : ''}`);
      return textOut(lines.length ? lines.join('\n') : '(no open figures)');
    }
    case 'matlab_sim_scan': {
      const r = await worker.workerRequest({
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
      const r = await worker.workerRequest({
        cmd: 'sim_info',
        model: String(args.model),
        fix: args.fix ? 1 : 0,
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_sim_clean': {
      const r = await worker.workerRequest({
        cmd: 'sim_clean',
        model: String(args.model),
      }, 120);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      return textOut(JSON.stringify(r.value, null, 1));
    }
    case 'matlab_sim_route': {
      const r = await worker.workerRequest({
        cmd: 'sim_route',
        model: String(args.model),
        spacing: Number.isFinite(args.spacing) ? args.spacing : 30,
        margin: Number.isFinite(args.margin) ? args.margin : 4,
        only_dirty: args.only_dirty ? 1 : 0,
      }, 300);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      let out = `Routed ${v.routed} line(s), kept ${v.kept} as-is` +
        (v.clean ? `, left ${v.clean} clean line(s) untouched` : '') +
        `, failed ${v.failed}. Model saved.`;
      if ((v.ghost_lines || 0) > 0) {
        out += `\nNote: ${v.ghost_lines} ghost duplicate-dst line row(s) detected — they render red-dashed but sim fine. ` +
          'Run matlab_sim_info (no fix) for details; interactive cleanup recommended (scripted deletion rewires branch rows).';
      }
      if (v.details && v.details.length) out += '\n' + v.details.join('\n');
      return textOut(out, (v.failed || 0) > 0);
    }
    case 'matlab_sim_arrange': {
      const r = await worker.workerRequest({
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
      const r = await worker.workerRequest({
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
        const j = JSON.parse(fs.readFileSync(C.PROGRESS_FILE, 'utf8'));
        pct = j.pct; msg = j.msg || '';
      } catch {
        return textOut('(no progress reported — either the last eval never called mcp_progress, or progress.json was cleaned)');
      }
      return textOut(`progress: ${pct}% ${msg}`.trimEnd());
    }
    case 'matlab_last': {
      const wantList = !!(args && args.list);
      const wantId = args && args.job_id !== undefined ? Number(args.job_id) : null;
      // History table: id / ok / cmd / finished-at for the last HIST_KEEP jobs.
      if (wantList) {
        let hist = [];
        try {
          hist = fs.readFileSync(C.RES_HIST_FILE, 'utf8').split('\n').filter(Boolean).map((l) => {
            try { return JSON.parse(l); } catch { return null; }
          }).filter(Boolean);
        } catch {}
        if (!hist.length) return textOut('(no completed worker responses archived yet)');
        const rows = hist.map((j) => `id=${j.id}  ok=${j.ok}  ${(j.cmd || '?').replace(/\s+/g, ' ').slice(0, 60)}`);
        return textOut(`recent jobs (oldest first, ${hist.length}/${C.HIST_KEEP} kept):\n` + rows.join('\n'));
      }
      let j = null;
      if (wantId !== null) {
        // Fetch a specific older job from the ring-buffer history.
        let hist = [];
        try {
          hist = fs.readFileSync(C.RES_HIST_FILE, 'utf8').split('\n').filter(Boolean).map((l) => {
            try { return JSON.parse(l); } catch { return null; }
          }).filter(Boolean);
        } catch {}
        j = hist.find((e) => Number(e.id) === wantId) || null;
        if (!j) {
          return textOut(`(job_id=${wantId} not in history — call matlab_last {list:true} to see kept ids, ` +
            `or the job predates the ${C.HIST_KEEP}-entry ring buffer)`, true);
        }
      } else {
        // Prefer an unclaimed res.json: if a finished job's response is still
        // sitting there (client cut the call before the server-side promise
        // consumed it), it IS the most recent completed output.
        try { j = JSON.parse(fs.readFileSync(C.RES_FILE, 'utf8')); } catch {}
        if (!j || j.id === undefined) {
          try { j = JSON.parse(fs.readFileSync(C.RES_LAST_FILE, 'utf8')); } catch {}
        }
      }
      if (!j) return textOut('(no completed worker response archived yet)');
      const head = `cmd=${j.cmd || '?'}  ok=${j.ok}  id=${j.id}`;
      const body = j.ok
        ? truncate((j.stdout || '').replace(/\r\n/g, '\n').trim() || '(no stdout)')
        : ('Error: ' + (j.error || 'unknown'));
      return textOut(head + '\n' + body, !j.ok);
    }
    case 'matlab_abort': {
      const pid = worker.readPid();
      if (!pid || !C.pidAlive(pid)) {
        return textOut('Worker is not running — nothing to abort.', true);
      }
      const busy = worker.readBusy();
      if (!busy) {
        return textOut('Worker is idle — no running job to abort. (A flag written '
          + 'now would be dropped before the next request, so nothing is written.)');
      }
      // Cooperative abort: the worker clears the flag at request start and
      // after each response, so a stale flag can never kill a later job.
      const flag = path.join(C.WORK_DIR, 'abort.json');
      fs.writeFileSync(flag, JSON.stringify({
        req_id: busy.id !== undefined ? busy.id : 0,
        cmd: busy.cmd || '?',
        since: busy.since || '',
        requested_at: new Date().toISOString(),
      }), 'utf8');
      return textOut(`Abort flag written for req id=${busy.id} (cmd="${busy.cmd}", `
        + `running since ${busy.since}). It takes effect only if the running code `
        + 'polls mcp_abort_requested() in its loop — otherwise hard-kill with '
        + 'matlab_restart (workspace lost).');
    }
    case 'matlab_snapshot': {
      const action = String(args.action || 'save');
      const file = String(args.file || '') || path.join(C.WORK_DIR, 'workspace_snap.mat');
      if (action === 'status') {
        if (!fs.existsSync(file)) return textOut(`no snapshot at ${file}`);
        const st = fs.statSync(file);
        return textOut(`snapshot: ${file}\nbytes: ${st.size}  modified: ${st.mtime.toISOString()}`);
      }
      const cmd = action === 'restore' ? 'restore' : 'snapshot';
      const r = await worker.workerRequest({ cmd, file }, 300);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      if (cmd === 'snapshot') {
        return textOut(`Snapshot saved: ${v.saved} variable(s), ${v.bytes} bytes -> ${v.file}\n`
          + (v.vars || []).join('  '));
      }
      return textOut(`Restored ${v.restored} variable(s) from ${v.file}\n`
        + (v.vars || []).join('  '));
    }
    case 'matlab_status': {
      const pid = worker.readPid();
      const alive = C.pidAlive(pid);
      const busy = worker.readBusy();
      let busyLine = 'Busy: no (idle)';
      if (busy) {
        let elapsed = '';
        const t = Date.parse(busy.since || '');
        if (Number.isFinite(t)) elapsed = `, ${Math.round((Date.now() - t) / 1000)}s elapsed`;
        busyLine = `Busy: cmd="${busy.cmd}" since ${busy.since} (req id=${busy.id}${elapsed})`;
      }
      const lines = [
        `MATLAB exe: ${C.MATLAB_EXE || '(not found)'}`,
        `Worker PID: ${pid || '-'}  alive: ${alive}`,
        `Booted at: ${worker.bootedAt || '-'}`,
        `MATLAB version: ${worker.version || '-'}`,
        busyLine,
        `Work dir: ${C.WORK_DIR}`,
        `Kill-all mode: ${C.KILL_ALL ? 'on (MCP_KILL_ALL=1)' : 'off (only pidfile PID is killed)'}`,
      ];
      return textOut(lines.join('\n'));
    }
    case 'matlab_restart': {
      const keep = !!(args && args.keep_workspace);
      const snap = path.join(C.WORK_DIR, 'workspace_snap.mat');
      const notes = [];
      let restoreIt = false;
      if (keep) {
        const pid = worker.readPid();
        const busy = worker.readBusy();
        if (pid && C.pidAlive(pid) && !busy) {
          // A busy worker cannot take the snapshot request (it would queue
          // behind the very job we are about to kill), so only an idle,
          // alive worker can preserve its workspace.
          try {
            const s = await worker.workerRequest({ cmd: 'snapshot', file: snap }, 300);
            if (s.ok) {
              notes.push(`workspace snapshotted (${(s.value || {}).saved} vars, ${(s.value || {}).bytes} bytes)`);
              restoreIt = true;
            } else {
              notes.push('snapshot before restart failed: ' + (s.error || 'unknown'));
            }
          } catch (e) {
            notes.push('snapshot before restart failed: ' + e.message);
          }
        } else if (busy) {
          notes.push('worker busy — killed without workspace snapshot');
        } else {
          notes.push('worker not running — nothing to snapshot');
        }
      }
      await worker.restartWorker();
      if (restoreIt) {
        try {
          const r = await worker.workerRequest({ cmd: 'restore', file: snap }, 300);
          if (r.ok) {
            notes.push(`workspace restored (${(r.value || {}).restored} vars)`);
          } else {
            notes.push('restore after boot failed: ' + (r.error || 'unknown'));
          }
        } catch (e) {
          notes.push('restore after boot failed: ' + e.message);
        }
      }
      return textOut(`Worker restarted (PID ${worker.readPid()})`
        + (notes.length ? '\n' + notes.join('\n') : ''));
    }
    case 'matlab_assert': {
      const r = await worker.workerRequest({
        cmd: 'assert',
        code: String(args.code),
        text: args.text ? String(args.text) : '',
        group: args.group ? String(args.group) : '',
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      const head = `${v.passed ? 'PASS' : 'FAIL'}  ${v.name || '(unlabeled)'}`;
      const tail = v.error ? `\n  threw: ${v.error}` : (v.got !== undefined ? `\n  got: ${JSON.stringify(v.got)}` : '');
      return textOut(head + tail, !v.passed);
    }
    case 'matlab_assert_report': {
      const r = await worker.workerRequest({
        cmd: 'assert_report',
        close: args.clear ? 1 : 0,
      }, 60);
      if (!r.ok) return textOut('Error: ' + (r.error || 'unknown'), true);
      const v = r.value || {};
      const lines = (v.lines || []).join('\n');
      return textOut(`${v.passed}/${v.total} passed${v.cleared ? ' (log cleared)' : ''}\n${lines}`);
    }
    default:
      throw new Error('Unknown tool: ' + name);
  }
}

module.exports = { callTool, textOut, truncate };
