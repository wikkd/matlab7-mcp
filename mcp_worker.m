function mcp_worker(reqfile, resfile, pidfile, busyfile)
%MCP_WORKER  Persistent command worker for the MATLAB 7.0 MCP bridge (v3).
%   R14-SAFE: no "catch err", no MException, no dir datenum, no isrow,
%   no strsplit/strjoin, no "~" output-ignoring, two-arg error() only.
%   Protocol (file-based, UTF-8 JSON):
%     request : {"id":N,"cmd":"...","code":"...","var":"name","file":"path",
%                "fig":h,"dpi":N,"close":0/1,"enc":"auto|gbk|utf8",
%                "content":"...","value_json":"...","model":"name",
%                "fix":0/1,"max_rows":N,"close_figs":0/1,"close_models":0/1,
%                "text":"..."}
%     response: {"id":N,"ok":true,"stdout":"...","value":<json>}
%             or {"id":N,"ok":false,"error":"...","stdout":"..."}
%   Commands: ping stop eval run_file get set ws figs put_png
%             write_file read_file dir
%             v3: check sim_info sim_clean summary closeall append
%   Requires mcp2json.m and json_decode.m on the path (same folder).
%   Optional: mcp_progress.m (long-eval progress reporting).

if nargin < 1 || isempty(reqfile),  reqfile  = 'req.json';  end
if nargin < 2 || isempty(resfile),  resfile  = 'res.json';  end
if nargin < 3 || isempty(pidfile),  pidfile  = 'worker.pid'; end
if nargin < 4 || isempty(busyfile), busyfile = 'busy.json';  end
% Pin to absolute paths so user code can cd freely
reqfile  = fullfile(pwd, reqfile);
resfile  = fullfile(pwd, resfile);
pidfile  = fullfile(pwd, pidfile);
busyfile = fullfile(pwd, busyfile);
reqdir   = pwd;   % boot dir: where all req_i*.json channels live (pinned)

% Stale-file cleanup (server kills old worker before starting us)
if exist(reqfile, 'file'),  delete(reqfile);  end
if exist(resfile, 'file'),  delete(resfile);  end
if exist(busyfile, 'file'), delete(busyfile); end

pid = 0;
try
    pid = feature('getpid');
end
fid = fopen(pidfile, 'wb');
if fid > 0
    fprintf(fid, '%d', pid);
    fclose(fid);
end

% Optional user init script: persistent addpath/cd/config executed at every
% boot, in base workspace, BEFORE the boot response is written.
if exist(fullfile(pwd, 'worker_init.m'), 'file')
    try
        evalin('base', 'worker_init');
    end
end

% v3: publish progress.json path as a global so mcp_progress() calls inside
% user eval code land in the worker's work dir regardless of cwd. The file
% is cleared BEFORE each request and after a stop, so matlab_progress only
% ever reports the last eval that actually wrote progress.
try
    evalin('base', ['global MCP_PROGRESS_FILE; MCP_PROGRESS_FILE = ''' ...
        strrep(fullfile(pwd, 'progress.json'), '''', '''''') ''';']);
    pf = fullfile(pwd, 'progress.json');
    if exist(pf, 'file'), delete(pf); end
catch
end

verstr = '';
try
    verstr = version;
end
boot = ['{"id":0,"ok":true,"stdout":"worker-boot","pid":' num2str(pid) ...
        ',"version":' jstr(verstr) '}'];
write_resp(resfile, boot);

NL = char(10);
while true
    got = false;
    raw = '';
    reqpath = '';
    try
        % v3.2 instance isolation: poll EVERY instance channel (req_i*.json)
        % plus the legacy req.json, oldest first (FIFO across instances).
        % Each server owns its own req file, so shared-queue write races are
        % structurally impossible. All paths are pinned to the BOOT directory
        % (reqdir), NOT runtime pwd: user code cd's freely and the worker
        % must keep listening while eval'd scripts change directory.
        cands = [dir(fullfile(reqdir, 'req_i*.json')); dir(fullfile(reqdir, 'req.json'))];
        if ~isempty(cands)
            % oldest first for FIFO fairness. R14 dir() has no datenum field
            % and no ~ output-ignoring, so order by name with a dummy first
            % output (Windows dir listing is name-ordered anyway).
            [junk, idx] = sort({cands.name}); %#ok<ASGLU>
            cands = cands(idx);
            f1 = fullfile(reqdir, cands(1).name);
            d1 = dir(f1);
            if ~isempty(d1) && d1(1).bytes >= 10
                pause(0.05);
                d2 = dir(f1);
                if ~isempty(d2) && d2(1).bytes == d1(1).bytes
                    raw = read_bin(f1);
                    got = true;
                    reqpath = f1;
                    delete(f1);
                end
            end
        end
    end
    if ~got
        pause(0.08);
        continue;
    end

    % Recover the request id even if JSON parsing later fails, so an error
    % response can still be matched by the server.
    rid = extract_id(raw);

    % New request: drop the previous eval's progress so matlab_progress never
    % reports stale numbers for this run (mcp_progress re-creates the file).
    % Pinned to reqdir: after an eval cd's away, runtime pwd cleanup would
    % miss the boot-dir progress.json (regression caught by v3_regress).
    try
        pf = fullfile(reqdir, 'progress.json');
        if exist(pf, 'file'), delete(pf); end
    end

    write_busy(busyfile, rid, raw);
    stopReq = false;
    resp = '';
    replyfile = resfile;
    try
        req = parse_req(raw);
        rid = req.id;
        % v3.2 instance isolation: a request may carry "reply" naming the
        % server instance tag; the response goes to res_<reply>.json so two
        % servers sharing this worker never read each other's answers.
        % Requests without "reply" (legacy server) answer on resfile as before.
        try
            if isfield(req, 'reply') && ~isempty(req.reply)
                [rpdir, rpname] = fileparts(resfile);
                replyfile = fullfile(rpdir, ['res_' req.reply '.json']);
            end
        end
        [stopReq, resp] = handle_req(req, replyfile);
    catch
        msg = lasterr;
        resp = ['{"id":' num2str(rid) ',"ok":false,"error":' jstr(msg) '}'];
    end
    if ~stopReq && ~isempty(resp)
        write_resp(replyfile, resp);
    end
    try
        if exist(busyfile, 'file'), delete(busyfile); end
    end
    if stopReq
        % Leaving? Also drop the progress file so a later worker does not
        % inherit this session's last progress numbers.
        try
            pf = fullfile(reqdir, 'progress.json');
            if exist(pf, 'file'), delete(pf); end
        end
        return;
    end
end
end

% ------------------------------------------------------------------
function rid = extract_id(raw)
% Pull "id":N out of the raw request with plain string ops (no JSON parse).
rid = 0;
k = strfind(raw, '"id"');
if ~isempty(k)
    p = k(1) + 4;
    n = length(raw);
    while p <= n && (raw(p) == ' ' || raw(p) == ':')
        p = p + 1;
    end
    q = p;
    while q <= n && ismember(raw(q), '0123456789-')
        q = q + 1;
    end
    if q > p
        rid = str2double(raw(p:q-1));
        if isnan(rid), rid = 0; end
    end
end
end

% ------------------------------------------------------------------
function write_busy(busyfile, rid, raw)
% Write a busy marker so the server's status tool can see we are working.
cmd = 'unknown';
k = strfind(raw, '"cmd"');
if ~isempty(k)
    q = strfind(raw, '"');
    % crude: take text between the quote after "cmd": and the next quote
    p = k(1) + 5;
    n = length(raw);
    while p <= n && raw(p) ~= '"'
        p = p + 1;
    end
    p = p + 1;
    q2 = p;
    while q2 <= n && raw(q2) ~= '"'
        q2 = q2 + 1;
    end
    if q2 > p
        cmd = raw(p:q2-1);
    end
end
c = clock;
ts = sprintf('%04d-%02d-%02dT%02d:%02d:%02d', round(c(1)), round(c(2)), ...
    round(c(3)), round(c(4)), round(c(5)), round(c(6)));
s = ['{"id":' num2str(rid) ',"cmd":' jstr(cmd) ',"since":' jstr(ts) '}'];
fid = fopen(busyfile, 'wb');
if fid > 0
    fwrite(fid, uint8(s), 'uint8');
    fclose(fid);
end
end

% ------------------------------------------------------------------
function [stopReq, resp] = handle_req(req, resfile)
% NOTE: never build strings containing user text via sprintf("%s") - R14's
% sprintf mangles multi-byte chars to SUB (0x1A). Use [] concatenation with
% num2str for numbers and jstr() for text.
stopReq = false;
resp = '';
cmd = lower(req.cmd);

switch cmd
    case 'ping'
        resp = ['{"id":' num2str(req.id) ',"ok":true,"stdout":"pong"}'];

    case 'stop'
        write_resp(resfile, ['{"id":' num2str(req.id) ',"ok":true,"stdout":"bye"}']);
        stopReq = true;

    case 'eval'
        dtxt = [tempname, '.diary'];
        [good, txt] = eval_capture(req.code, dtxt, '');
        % v3.2: on failure with console output, append the diary tail (last
        % 30 lines) to the error so one call shows both the error and the
        % console context that led to it - no follow-up eval needed.
        if ~good && ~isempty(strtrim(txt))
            resp = ['{"id":' num2str(req.id) ',"ok":' bool2str(good) ...
                ',"stdout":' jstr(txt) ...
                ',"error":' jstr(['(console tail, last 30 lines)' char(10) diary_tail(txt, 30)]) '}'];
        else
            % v3: warn when user code contains a bare clear/clear all - it wipes
            % the caller's loop variables too (classic "Reference to a cleared
            % variable" failure seen with eval'd scripts in for-loops).
            % NOTE: bare clear/clear all always makes the eval FAIL (good=false),
            % so the warning is attached when the code matches, regardless of ok.
            hasClearWarn = ~isempty(strfind(req.code, 'clear all')) || ...
                ~isempty(regexpi(req.code, '(^|[\n;,])\s*clear\s*([;,\n]|$)'));
            if hasClearWarn
                txt = [txt, char(10), ...
                    'NOTE: code contains bare "clear"/"clear all" - it also wipes loop ', ...
                    'variables and workspace data. Use "clear <name>" or clear(''vars'') selectively.'];
            end
            resp = ['{"id":' num2str(req.id) ',"ok":' bool2str(good) ...
                ',"stdout":' jstr(txt) '}'];
        end

    case 'run_file'
        % Run a .m file: fresh (clear cached function by name), auto cd into
        % its folder, always restore the previous working directory.
        [stopReq, resp] = do_run_file(req, resfile);

    case 'assert'
        % v3.2 batch grading: evaluate one expression in the base workspace
        % and record the boolean result into a base-workspace cell variable
        % (MCP_ASSERT_LOG). Base workspace, NOT a global: R14 global bindings
        % declared inside try blocks proved unreliable across handle_req
        % calls, and the log must persist between requests.
        % Group tests with req.group; label each with req.text (the what).
        resp = '';
        grp = '';
        what = 'assert';
        try
            if isfield(req, 'text') && ~isempty(req.text), what = req.text; end
            if isfield(req, 'group'), grp = req.group; end
            v = evalin('base', req.code);
            passed = ~isempty(v) && islogical(v) && v == true;
            if ~islogical(v)
                passed = ~isempty(v) && isnumeric(v) && ~isnan(v(1)) && v(1) ~= 0;
            end
            % stash the actual value so the report can show expected vs got
            try
                dv = mcp2json(v);
            catch
                dv = '"?"';
            end
            mcp_assert_log(grp, what, passed, dv);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":{"passed":' bool2str(passed) ...
                ',"name":' jstr(what) ',"got":' dv '}}'];
        catch
            % a throwing expression is a failed assertion, not a tool error
            mcp_assert_log(grp, what, false, jstr(lasterr));
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":{"passed":false' ...
                ',"name":' jstr(what) ',"error":' jstr(lasterr) '}}'];
        end

    case 'assert_report'
        % Summarize (and optionally clear) the MCP_ASSERT_LOG base variable.
        try
            L = [];
            try
                L = evalin('base', 'MCP_ASSERT_LOG');
            end
            if ~isa(L, 'cell'), L = {}; end
            n = size(L, 1);
            npass = 0;
            lines = cell(1, n);
            for k = 1:n
                if L{k, 3}, npass = npass + 1; end
                lines{k} = sprintf('%s [%s] %s', L{k, 1}, ...
                    mpl_bool(L{k, 3}), L{k, 2});
            end
            clearIt = isfield(req, 'close') && req.close == 1;
            if clearIt
                assignin('base', 'MCP_ASSERT_LOG', {});
            end
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":{"total":' num2str(n) ...
                ',"passed":' num2str(npass) ...
                ',"cleared":' bool2str(clearIt) ...
                ',"lines":' mcp2json(lines) '}}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'get'
        try
            v = evalin('base', req.var);
            jj = mcp2json(v);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'set'
        try
            v = json_decode(req.value_json);
            assignin('base', req.var, v);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"stdout":"set"}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'ws'
        try
            names = evalin('base', 'who');
            parts = {};
            for k = 1:numel(names)
                v = evalin('base', names{k});
                parts{end+1} = ['{"name":' jstr(names{k}) ...
                    ',"class":' jstr(class(v)) ...
                    ',"size":' jstr(mat2str(size(v))) '}']; %#ok<AGROW>
            end
            arr = join_parts(parts);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":[' arr ']}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'figs'
        try
            hs = findobj('Type', 'figure');
            % newest figure first (matches "gcf" semantics of put_png)
            hs = sort(hs, 'descend');
            parts = {};
            for k = 1:numel(hs)
                h = hs(k);
                nm  = get(h, 'Name');
                vis = get(h, 'Visible');
                parts{end+1} = ['{"handle":' num2str(double(h)) ... %#ok<AGROW>
                    ',"name":' jstr(nm) ',"visible":' jstr(vis) '}'];
            end
            arr = join_parts(parts);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":[' arr ']}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'put_png'
        resp = do_put_png(req);

    case 'write_file'
        resp = do_write_file(req);

    case 'read_file'
        resp = do_read_file(req);

    case 'dir'
        try
            d = dir(req.file);
            parts = {};
            for k = 1:numel(d)
                parts{end+1} = ['{"name":' jstr(d(k).name) ... %#ok<AGROW>
                    ',"bytes":' num2str(d(k).bytes) ...
                    ',"isdir":' bool2str(d(k).isdir) '}'];
            end
            arr = join_parts(parts);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":[' arr ']}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    % ---------------- v3 commands ----------------

    case 'check'
        % Syntax-check code without running it (catches typos before eval).
        try
            issues = mcp_check(req.code);
            if isempty(issues)
                resp = ['{"id":' num2str(req.id) ',"ok":true,"value":{"clean":true,"issues":""}}'];
            else
                resp = ['{"id":' num2str(req.id) ',"ok":true,"value":{"clean":false,"issues":' ...
                    jstr(issues) '}}'];
            end
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'sim_scan'
        % Regex-search saved .mdl file(s) on disk WITHOUT loading the model
        % (R14 .mdl is plain text -- the official model_scan for .slx, but
        % easier here). Also handy when a model is too broken to load.
        try
            rep = mcp_sim_scan(req.model, req.pattern);
            jj = mcp2json(rep);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'sim_info'
        % Simulink model integrity audit (ghost lines, unconnected ports).
        try
            rep = mcp_sim_audit(req.model, struct('fix', req.fix ~= 0));
            jj = mcp2json(rep);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'sim_clean'
        % Remove orphan line segments from a model and save it.
        try
            rep = mcp_sim_clean(req.model);
            jj = mcp2json(rep);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'sim_route'
        % Re-route all lines as clean orthogonal polylines avoiding blocks.
        try
            o = struct('spacing', 30, 'margin', 4);
            if isfield(req, 'spacing') && ~isempty(req.spacing) && req.spacing > 0
                o.spacing = req.spacing;
            end
            if isfield(req, 'margin') && ~isempty(req.margin) && req.margin >= 0
                o.margin = req.margin;
            end
            rep = mcp_sim_route(req.model, o);
            jj = mcp2json(rep);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'sim_arrange'
        % Auto-arrange blocks into a layered signal-flow layout.
        try
            o = struct('xgap', 90, 'ygap', 35, 'x0', 40, 'y0', 40, 'debug', 0);
            if isfield(req, 'xgap') && ~isempty(req.xgap) && req.xgap > 0
                o.xgap = req.xgap;
            end
            if isfield(req, 'ygap') && ~isempty(req.ygap) && req.ygap > 0
                o.ygap = req.ygap;
            end
            rep = mcp_sim_arrange(req.model, o);
            jj = mcp2json(rep);
            resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj '}'];
        catch
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
        end

    case 'summary'
        % Fetch a big numeric variable row-chunked with downsample option.
        [stopReq, resp] = do_summary(req, resfile);

    case 'closeall'
        % Cleanup: close figures and/or loaded models. Returns counts.
        resp = do_closeall(req);

    case 'append'
        % Append text to a file on disk (log building without fprintf %% pain).
        resp = do_append(req);

    otherwise
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['unknown cmd: ' cmd]) '}'];
end
end

% ------------------------------------------------------------------
function [stopReq, resp] = do_run_file(req, resfile)
stopReq = false;
f = req.file;
if isempty(f) || ~exist(f, 'file')
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['file not found: ' f]) '}'];
    return;
end
[pth, nm, ext] = fileparts(f);
if ~strcmpi(ext, '.m')
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['not a .m file: ' ext]) '}'];
    return;
end
% Only clear the cache for function files; scripts are re-read each run and
% "clear <scriptname>" would be a no-op at best.
preamble = [];
try
    whichinfo = which(fullfile(pth, [nm ext]));
    isfun = ~isempty(whichinfo);
end
if isfun
    preamble = ['clear ', nm, char(10), 'rehash;', char(10)];
else
    preamble = ['rehash;', char(10)];
end
code = ['oldcd = pwd;', char(10), preamble, ...
    'cd(''', strrep(pth, '''', ''''''), ''');', char(10), ...
    nm, char(10), ...
    'cd(oldcd);'];
dtxt = [tempname, '.diary'];
[good, txt] = eval_capture(code, dtxt, '');
resp = ['{"id":' num2str(req.id) ',"ok":' bool2str(good) ...
    ',"stdout":' jstr(txt) '}'];
end

% ------------------------------------------------------------------
function resp = do_put_png(req)
% Guard: exporting a non-existent figure hangs R14's print. Check first.
resp = '';
try
    fig = req.fig;
    if isempty(fig) || fig <= 0
        hs = findobj('Type', 'figure');
        if isempty(hs)
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"no open figure (run plotting code via matlab_eval first)"}'];
            return;
        end
        fig = max(hs);
    else
        has = evalin('base', sprintf('ishandle(%d)', fig));
        if ~has
            resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"no figure with handle ' num2str(fig) ' (run plotting code via matlab_eval first)"}'];
            return;
        end
    end
    dpi = req.dpi;
    if isempty(dpi) || dpi <= 0, dpi = 110; end
    pcmd = ['print(' num2str(double(fig)) ', ''' ...
        strrep(req.file, '''', '''''') ''', ''-dpng'', ''-r' num2str(dpi) ''');'];
    evalin('base', pcmd);
    if req.close == 1
        try
            evalin('base', ['close(' num2str(double(fig)) ');']);
        end
    end
    resp = ['{"id":' num2str(req.id) ',"ok":true,"stdout":"png"}'];
catch
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
end
end

% ------------------------------------------------------------------
function resp = do_write_file(req)
% Write text to disk. The JSON string decodes to native (GBK-domain) chars;
% re-encode explicitly per request. auto: .m files -> GBK, else UTF-8.
resp = '';
try
    f = req.file;
    if isempty(f)
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"empty file path"}'];
        return;
    end
    [pth, nm, ext] = fileparts(f);
    lowerext = lower(ext);
    if any(strcmp(lowerext, {'.mat', '.mdl', '.fig', '.slx', '.mexw', '.mex'}))
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['refusing to write binary file type as text: ' ext]) '}'];
        return;
    end
    if isempty(pth), pth = pwd; end
    full = fullfile(pth, [nm ext]);
    enc = lower(req.enc);
    if isempty(enc) || strcmp(enc, 'auto')
        if strcmp(lowerext, '.m')
            enc = 'gbk';
        else
            enc = 'utf8';
        end
    end
    txt = req.content;
    if strcmp(enc, 'gbk')
        bytes = unicode2native(txt, 'GBK');
    else
        bytes = unicode2native(txt, 'UTF-8');
    end
    fid = fopen(full, 'wb');
    if fid <= 0
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['cannot open for write: ' full]) '}'];
        return;
    end
    fwrite(fid, bytes, 'uint8');
    fclose(fid);
    rehash;
    resp = ['{"id":' num2str(req.id) ',"ok":true,"stdout":' jstr(['written ' num2str(numel(bytes)) ' bytes (' enc ')']) '}'];
catch
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
end
end

% ------------------------------------------------------------------
function resp = do_read_file(req)
% Read a text file and return it as a JSON string. auto: .m -> GBK decode,
% everything else -> UTF-8 decode. Explicit enc overrides.
resp = '';
try
    f = req.file;
    if isempty(f) || ~exist(f, 'file')
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['file not found: ' f]) '}'];
        return;
    end
    d = dir(f);
    if d(1).bytes > 2097152
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"file too large (>2 MB) for text read"}'];
        return;
    end
    if d(1).isdir
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"path is a directory"}'];
        return;
    end
    fid = fopen(f, 'rb');
    if fid <= 0
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['cannot open: ' f]) '}'];
        return;
    end
    b = fread(fid, inf, 'uint8')';
    fclose(fid);
    enc = lower(req.enc);
    if isempty(enc) || strcmp(enc, 'auto')
        [pth, nm, ext] = fileparts(f);
        if strcmpi(ext, '.m')
            enc = 'gbk';
        else
            enc = 'utf8';
        end
    end
    if strcmp(enc, 'gbk')
        txt = native2unicode(b, 'GBK');
    else
        txt = native2unicode(b, 'UTF-8');
    end
    txt = reshape(txt, 1, []);
    resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jstr(txt) '}'];
catch
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
end
end

% ------------------------------------------------------------------
function [good, txt] = eval_capture(code, dtxt, cleanup)
% Evaluate in base workspace with console capture via diary (GBK codepage).
% v2: multi-line safe (a trailing % comment can no longer swallow the
% catch clause), success detected via a marker variable (no text matching),
% and syntax errors are reported instead of silently swallowed.
% The whole snippet is parsed up-front, so user syntax errors land in the
% outer catch with lasterr. cleanup code (e.g. cd-back) runs after the
% user try/catch on both success and failure paths.
good = true;
NL = char(10);
code = strrep(code, sprintf('\r\n'), NL);
code = strrep(code, sprintf('\r'), NL);
if isempty(strtrim(code))
    code = 'disp('''')';
end
dtxt = strrep(dtxt, '''', '''''');
mark = 'mcp_err_v2';
inner = ['try' NL ...
    'clear ' mark ';' NL ...
    code NL ...
    'catch' NL ...
    mark ' = 1;' NL ...
    'fprintf(2, [''ERROR: '' lasterr char(10)]);' NL ...
    'end'];
if ~isempty(cleanup)
    inner = [inner NL cleanup];
end
big = ['diary(''' dtxt ''');' NL ...
    inner NL ...
    'fprintf(char(10));' NL ...
    'diary off;'];

% Clear any marker left over from a previous run
try
    evalin('base', ['clear ' mark ';']);
end

syntax_ok = true;
synmsg = '';
try
    evalin('base', big);
catch
    syntax_ok = false;
    synmsg = lasterr;
    try
        evalin('base', 'diary off;');
    end
end

marker = 0;
try
    marker = evalin('base', ['exist(''' mark ''',''var'')']);
end
txt = read_diary(dtxt);
if ~syntax_ok
    good = false;
    if isempty(strtrim(txt))
        txt = synmsg;
    else
        txt = [txt, char(10), synmsg];
    end
elseif marker ~= 0
    good = false;
end
end

% ------------------------------------------------------------------
function tail = diary_tail(txt, want)
% Last `want` lines of a diary string (R14-safe: index loop, no strsplit).
% Collapses blank runs so the tail carries maximum context in minimum bytes.
if isempty(txt)
    tail = '';
    return;
end
NL = char(10);
lines = cell(1, 1);
pos = 1;
n = 0;
while pos <= numel(txt)
    nl = strfind(txt(pos:end), NL);
    if isempty(nl)
        chunk = txt(pos:end);
        pos = numel(txt) + 1;
    else
        chunk = txt(pos:pos + nl(1) - 1);
        pos = pos + nl(1);
    end
    n = n + 1;
    if n > numel(lines)
        lines{end + 1} = '';  %#ok<AGROW>
    end
    lines{n} = chunk;
end
% collapse consecutive blank lines
keep = zeros(1, n);
nk = 0;
prevBlank = true;  % suppress leading blanks
for k = 1:n
    blank = isempty(strtrim(lines{k}));
    if ~(blank && prevBlank)
        nk = nk + 1;
        keep(nk) = k;
    end
    prevBlank = blank;
end
lines = lines(keep(1:nk));
n = nk;
if n <= want
    tail = strjoin_r14(lines, NL);
else
    tail = strjoin_r14(lines(n - want + 1:end), NL);
end
end

% ------------------------------------------------------------------
function txt = read_diary(dtxt)
txt = '';
if exist(dtxt, 'file')
    fid = fopen(dtxt, 'rb');
    if fid > 0
        b = fread(fid, inf, 'uint8')';
        fclose(fid);
        if numel(b) > 0
            txt = reshape(native2unicode(uint8(b), 'GBK'), 1, []);
        end
    end
    try
        delete(dtxt);
    end
end
end

function s = read_bin(fn)
s = '';
fid = fopen(fn, 'rb');
if fid > 0
    b = fread(fid, inf, 'uint8')';
    fclose(fid);
    if numel(b) > 0
        s = char(uint8(b));   % keep raw UTF-8 bytes as chars; json_decode converts
    end
end
end

function write_resp(fn, s)
try
    if exist(fn, 'file'), delete(fn); end
end
fid = fopen(fn, 'wb');
if fid > 0
    % s already contains UTF-8 byte values as chars (jstr/mcp2json converted
    % text to UTF-8 bytes; native2unicode results were re-encoded there).
    % Write bytes directly - a second unicode2native here would double-encode.
    fwrite(fid, uint8(s), 'uint8');
    fclose(fid);
end
end

function req = parse_req(raw)
req = struct('id', 0, 'cmd', 'ping', 'code', '', 'var', '', 'file', '', ...
    'fig', 0, 'dpi', 0, 'close', 0, 'enc', 'auto', 'content', '', 'value_json', '', ...
    'model', '', 'fix', 0, 'max_rows', 0, 'close_figs', 0, 'close_models', 0, ...
    'text', '', 'spacing', 0, 'margin', 0, 'sys', '', 'xgap', 0, 'ygap', 0, ...
    'reply', '', 'group', '');
p = json_decode(raw);
if isfield(p, 'id'),          req.id = p.id;   end
if isfield(p, 'cmd'),         req.cmd = p.cmd; end
if isfield(p, 'code'),        req.code = p.code; end
if isfield(p, 'var'),         req.var = p.var; end
if isfield(p, 'file'),        req.file = p.file; end
if isfield(p, 'fig'),         req.fig = p.fig; end
if isfield(p, 'dpi'),         req.dpi = p.dpi; end
if isfield(p, 'close'),       req.close = p.close; end
if isfield(p, 'enc'),         req.enc = p.enc; end
if isfield(p, 'content'),     req.content = p.content; end
if isfield(p, 'value_json'),  req.value_json = p.value_json; end
if isfield(p, 'model'),       req.model = p.model; end
if isfield(p, 'fix'),         req.fix = p.fix; end
if isfield(p, 'max_rows'),    req.max_rows = p.max_rows; end
if isfield(p, 'close_figs'),  req.close_figs = p.close_figs; end
if isfield(p, 'close_models'), req.close_models = p.close_models; end
if isfield(p, 'text'),        req.text = p.text; end
if isfield(p, 'spacing'),     req.spacing = p.spacing; end
if isfield(p, 'margin'),      req.margin = p.margin; end
if isfield(p, 'sys'),         req.sys = p.sys; end
if isfield(p, 'xgap'),        req.xgap = p.xgap; end
if isfield(p, 'ygap'),        req.ygap = p.ygap; end
if isfield(p, 'reply'),       req.reply = p.reply; end
if isfield(p, 'group'),       req.group = p.group; end
end

function mcp_assert_log(grp, what, passed, detail)
% Append one row {group, label, passed, detail} to the MCP_ASSERT_LOG cell
% array in the BASE workspace (survives across requests; immune to the R14
% global-in-try scope quirk that broke the first cut of this feature).
L = [];
try
    L = evalin('base', 'MCP_ASSERT_LOG');
end
if ~isa(L, 'cell'), L = {}; end
k = size(L, 1) + 1;
L{k, 1} = grp;
L{k, 2} = what;
L{k, 3} = passed;
L{k, 4} = detail;
assignin('base', 'MCP_ASSERT_LOG', L);
end

function s = mpl_bool(v)
if v, s = 'PASS'; else, s = 'FAIL'; end
end

function s = jstr(t)
% NOTE: unicode2native('') throws "One dimension must be unary" in R14 -
% guard the empty string first.
if isempty(t)
    s = '""';
    return;
end
try
    b = unicode2native(t, 'UTF-8');
    t = reshape(char(b'), 1, []);
end
t = strrep(t, '\', '\\');
t = strrep(t, '"', '\"');
t = strrep(t, sprintf('\n'), '\n');
t = strrep(t, sprintf('\r'), '\r');
t = strrep(t, sprintf('\t'), '\t');
s = ['"' t '"'];
end

function s = bool2str(v)
if v
    s = 'true';
else
    s = 'false';
end
end

function out = join_parts(parts)
out = '';
for k = 1:numel(parts)
    if k > 1, out = [out ',']; end
    out = [out parts{k}];
end
end

% ================= v3 helper commands =================

% ------------------------------------------------------------------
function [stopReq, resp] = do_summary(req, resfile) %#ok<INUSD>
% Fetch a numeric variable with row budgeting. For huge arrays the default
% matlab_get_var would serialize tens of MB of JSON; summary returns:
%   value: full array IF numel <= max_rows (default 200), else a
%   downsampled preview (uniformly sampled rows) plus stats.
% response fields: name, class, size, numel, complete (0/1),
%   value (array or nested), stats {min,max,mean,std} for numeric.
stopReq = false;
try
    v = evalin('base', req.var);
    sz = size(v);
    n = numel(v);
    maxRows = req.max_rows;
    if isempty(maxRows) || maxRows <= 0, maxRows = 200; end
    complete = 1;
    val = v;
    if n > maxRows
        complete = 0;
        % downsample the FIRST dimension that exceeds the budget (rows, or
        % columns for a 1xN row vector), keeping endpoints.
        if sz(1) > maxRows
            rows = unique(round(linspace(1, sz(1), maxRows)));
            val = v(rows, :); %#ok<AGROW>
        elseif ndims(v) >= 2 && sz(2) > maxRows
            cols = unique(round(linspace(1, sz(2), maxRows)));
            val = v(:, cols); %#ok<AGROW>
        end
    end
    stats = '';
    if isnumeric(v) && n > 0
        vv = v(isfinite(v));
        if isempty(vv)
            stats = ',"stats":{"note":"no finite values"}';
        else
            stats = [', "stats":{"min":' mcp2json(min(vv(:))) ...
                ',"max":' mcp2json(max(vv(:))) ...
                ',"mean":' mcp2json(mean(vv(:))) ...
                ',"std":' mcp2json(std(vv(:))) '}'];
        end
    end
    jj = mcp2json(val);
    resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' jj ...
        ',"meta":{"name":' jstr(req.var) ...
        ',"class":' jstr(class(v)) ...
        ',"size":' jstr(mat2str(size(v))) ...
        ',"numel":' num2str(n) ...
        ',"complete":' bool2str(complete) '}' stats '}'];
catch
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
end
end

% ------------------------------------------------------------------
function resp = do_closeall(req)
% Bulk cleanup: close figures and/or loaded Simulink models. Never errors
% on already-closed things; returns counts so the caller knows what moved.
nfig = 0;
nmdl = 0;
notes = {};
if req.close_figs ~= 0
    try
        hs = findobj('Type', 'figure');
        nfig = numel(hs);
        if nfig > 0, close(hs); end
    catch
        notes{end+1} = 'figure close failed'; %#ok<AGROW>
    end
end
if req.close_models ~= 0
    try
        sys = find_system('Type', 'block_diagram');
        nmdl = numel(sys);
        for k = 1:numel(sys)
            try
                close_system(sys{k}, 0);
            catch
                % ignore individually stuck models
            end
        end
    catch
        notes{end+1} = 'model close failed'; %#ok<AGROW>
    end
end
parts = ['{"figures":' num2str(nfig) ',"models":' num2str(nmdl)];
if ~isempty(notes)
    parts = [parts ',"notes":' jstr(strjoin_r14(notes, '; '))];
end
parts = [parts '}'];
resp = ['{"id":' num2str(req.id) ',"ok":true,"value":' parts '}'];
end

% ------------------------------------------------------------------
function resp = do_append(req)
% Append text to a file. Encoding mirrors write_file (auto: .m -> GBK).
% Useful for building log/report snippets without fprintf %% escaping.
resp = '';
try
    f = req.file;
    if isempty(f)
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":"empty file path"}'];
        return;
    end
    [pth, nm, ext] = fileparts(f);
    lowerext = lower(ext);
    if isempty(pth), pth = pwd; end
    full = fullfile(pth, [nm ext]);
    enc = lower(req.enc);
    if isempty(enc) || strcmp(enc, 'auto')
        if strcmp(lowerext, '.m')
            enc = 'gbk';
        else
            enc = 'utf8';
        end
    end
    txt = req.text;
    if strcmp(enc, 'gbk')
        bytes = unicode2native(txt, 'GBK');
    else
        bytes = unicode2native(txt, 'UTF-8');
    end
    fid = fopen(full, 'ab');
    if fid <= 0
        resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(['cannot open for append: ' full]) '}'];
        return;
    end
    fwrite(fid, bytes, 'uint8');
    fclose(fid);
    resp = ['{"id":' num2str(req.id) ',"ok":true,"stdout":' jstr(['appended ' num2str(numel(bytes)) ' bytes (' enc ')']) '}'];
catch
    resp = ['{"id":' num2str(req.id) ',"ok":false,"error":' jstr(lasterr) '}'];
end
end

% ------------------------------------------------------------------
function out = strjoin_r14(parts, sep)
out = '';
for k = 1:numel(parts)
    if k > 1, out = [out sep]; end %#ok<AGROW>
    out = [out parts{k}]; %#ok<AGROW>
end
end
