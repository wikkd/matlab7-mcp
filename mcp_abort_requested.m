function tf = mcp_abort_requested()
%MCP_ABORT_REQUESTED  Cooperative abort check for long-running matlab_eval.
%   TF = mcp_abort_requested() returns true when the matlab_abort tool has
%   flagged the currently running request. R14 cannot interrupt running
%   code, so long loops should poll this and bail out cleanly:
%
%       for k = 1:1000
%           if mcp_abort_requested(), break; end   % cooperative stop
%           ... work ...
%       end
%
%   The flag file (abort.json in the work dir) is written by the server's
%   matlab_abort tool and cleared by the worker before/after every request,
%   so a flag never leaks into the next job. Cheap enough to call every
%   iteration. Path resolution mirrors mcp_progress: global pinned by the
%   worker frame, then root-graphics appdata (survives clear/clear all on
%   R14), then which()-based fallback, then pwd.

tf = false;
global MCP_ABORT_FILE
f = '';
if ~isempty(MCP_ABORT_FILE), f = MCP_ABORT_FILE; end
if isempty(f)
    a = getappdata(0, 'MCP_ABORT_FILE');
    if ischar(a) && ~isempty(a), f = a; end
end
if isempty(f)
    p = which('mcp_abort_requested');
    if ~isempty(p), f = fullfile(fileparts(p), 'abort.json'); end
end
if isempty(f), f = fullfile(pwd, 'abort.json'); end
tf = (exist(f, 'file') == 2);
end
