// lib/tools.js — the 26 tool definitions (pure data, verbatim from the
// former single-file mcp-server.js; v3.3.0 refactor). Descriptions are
// agent-facing API: change them only deliberately.
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
      + 'Optionally pass job_id to fetch an OLDER completed job from the ring-buffer '
      + 'history (last 20 kept, survives later tool calls), or list=true to show the '
      + 'recent-job table (id / ok / cmd / time) without bodies. '
      + 'Use this when a long eval/run_file tool call was cut by the client-side '
      + 'timeout: the MATLAB job keeps running and its console output is archived '
      + 'here when it finishes. Long-job pattern: fire -> poll matlab_status / '
      + 'matlab_progress -> collect with matlab_last.',
    inputSchema: {
      type: 'object',
      properties: {
        job_id: { type: 'number', description: 'Fetch this completed job from history instead of the newest' },
        list: { type: 'boolean', description: 'List recent completed jobs (id, ok, cmd, finished-at)' },
      },
    },
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
  {
    name: 'matlab_assert',
    description: 'Batch grading primitive (R14, no unittest framework): evaluate one boolean '
      + 'expression in the base workspace and record PASS/FAIL into a persistent log inside '
      + 'the worker. A throwing expression counts as FAIL, not a tool error. Results '
      + 'accumulate across calls — collect them with matlab_assert_report. '
      + 'Typical loop: run a student script via matlab_run_file, then one matlab_assert '
      + 'per expected result.',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'Boolean MATLAB expression, e.g. "abs(E - 1.09) < 0.01" or "strcmp(class(y), \'double\')"' },
        text: { type: 'string', description: 'Human label of this check (what is being asserted)' },
        group: { type: 'string', description: 'Group tag, e.g. the student name or experiment number' },
      },
      required: ['code'],
    },
  },
  {
    name: 'matlab_assert_report',
    description: 'Summarize the assertion log accumulated by matlab_assert: total, passed, and '
      + 'one PASS/FAIL line per check. Pass clear=true to empty the log after collecting '
      + '(or to start a fresh batch).',
    inputSchema: {
      type: 'object',
      properties: {
        clear: { type: 'boolean', description: 'Empty the assertion log after reporting (default false)' },
      },
    },
  },
];

module.exports = { TOOLS, R14_NOTES };
