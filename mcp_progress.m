function mcp_progress(pct, msg)
%MCP_PROGRESS  Report progress of a long-running matlab_eval from user code.
%   mcp_progress(0.4)              -> 40 percent done
%   mcp_progress(0.4, 'sim 3/5')   -> with a short status message
%
% The MCP server reads progress.json for matlab_status / matlab_progress.
% Call it inside long matlab_eval code, e.g. inside a for-loop over
% simulation runs. Cheap enough to call every iteration.

if nargin < 1 || isempty(pct), pct = 0; end
if nargin < 2, msg = ''; end

global MCP_PROGRESS_FILE
f = '';
if ~isempty(MCP_PROGRESS_FILE), f = MCP_PROGRESS_FILE; end
if isempty(f)
    % v3.2.1: three-level fallback. R14 globals published from inside a try
    % (worker boot does exactly that) proved unreliable across calls, and
    % user code may run clear/clear all mid-eval which wipes globals too.
    % The old pwd fallback then leaked progress.json into the user's project
    % directory while matlab_progress kept reporting "(no progress
    % reported)" for the whole run (observed 2026-11-04 on a multi-cycle
    % RDR eval). Prefer the directory this file lives in: the server
    % addpath'd it at boot and reads progress from its own work dir, which
    % is the same folder in the standard single-directory layout.
    p = which('mcp_progress');
    if ~isempty(p), f = fullfile(fileparts(p), 'progress.json'); end
end
if isempty(f), f = fullfile(pwd, 'progress.json'); end

p = 100 * min(max(pct, 0), 1);
% ASCII-only percent; message escaped the crude but safe way
m = msg;
m = strrep(m, '\', '/');
m = strrep(m, '"', '''');
m = strrep(m, sprintf('\n'), ' ');
m = strrep(m, sprintf('\r'), ' ');
s = ['{"pct":' num2str(p, '%.2f') ',"msg":' qesc(m) '}'];
try
    fid = fopen(f, 'wb');
    if fid > 0
        fwrite(fid, uint8(s), 'uint8');
        fclose(fid);
    end
end
end

function s = qesc(t)
if isempty(t)
    s = '""';
    return;
end
b = unicode2native(t, 'UTF-8');
t = reshape(char(b'), 1, []);
t = strrep(t, '\', '\\');
t = strrep(t, '"', '\"');
s = ['"' t '"'];
end
