function report = mcp_sim_scan(path, pattern)
%MCP_SIM_SCAN  Regex-search a saved .mdl file on disk WITHOUT loading it.
%   report = mcp_sim_scan('C:\path\model.mdl', 'Kp|Gain1')
%   report = mcp_sim_scan('C:\path',      'RelationalOperator')
%
% The official server's model_scan works on .slx (zip). R14's .mdl is plain
% text, so the disk search needs no model load at all -- grep semantics are
% enough and safer than opening a possibly broken model.
%
% report fields:
%   path, nMatches, lines (struct array: lineNo, text), nLinesScanned
% Text beyond 500 chars per hit is truncated (block params live on one
% line each in R14 .mdl; long strings are usually base64 NameValue data).

if nargin < 2 || isempty(pattern)
    error('mcp_sim_scan:usage', 'pattern (regexp) is required');
end
[path, pat] = deal(path, pattern);
if exist(path, 'dir')
    d = dir(fullfile(path, '*.mdl'));
    files = cell(1, numel(d));
    for k = 1:numel(d)
        files{k} = fullfile(path, d(k).name);  % R14 dir() has no .folder field
    end
    if isempty(files)
        error('mcp_sim_scan:nomdl', 'No .mdl files in %s', path);
    end
elseif exist(path, 'file')
    files = {path};
else
    error('mcp_sim_scan:nofile', 'No such file or folder: %s', path);
end

hits_lines = [];   % line numbers
hits_text = {};    % truncated text
hits_file = {};    % owning file
nScan = 0;
for f = 1:numel(files)
    fid = fopen(files{f}, 'r');
    if fid == -1
        error('mcp_sim_scan:open', 'Cannot open %s', files{f});
    end
    ln = 0;
    while true
        t = fgetl(fid);
        if ~ischar(t), break; end
        ln = ln + 1;
        nScan = nScan + 1;
        if ~isempty(regexpi(t, pat, 'once'))
            if length(t) > 500, t = [t(1:500), ' ...']; end
            hits_lines(end+1) = ln;           %#ok<AGROW>
            hits_text{end+1} = t;             %#ok<AGROW>
            hits_file{end+1} = files{f};      %#ok<AGROW>
        end
    end
    fclose(fid);
end

n = numel(hits_lines);
hits = struct('lineNo', {}, 'text', {}, 'file', {});
for k = 1:n
    hits(k) = struct('lineNo', hits_lines(k), 'text', hits_text{k}, ...
        'file', hits_file{k});
end
report = struct('path', path, 'pattern', pattern, 'nMatches', n, ...
    'nLinesScanned', nScan, 'lines', hits);
end
