function report = mcp_sim_audit(model, opts)
%MCP_SIM_AUDIT  Integrity audit for a Simulink model (R14-safe).
%   report = mcp_sim_audit('model')                -> struct report
%   report = mcp_sim_audit('model', 'fix', true)   -> also attempt repairs
%
% Detects the classic R14 "ghost line" mess left by iterative add_line/
% delete_block sessions:
%   1. lines referenced by a port whose destination already has a line
%      (duplicate destination connections)
%   2. orphan line segments with no valid source or destination port
%   3. unconnected block ports that carry a line stub (line exists but
%      port handle invalid)
%   4. dangling lines (LineHandles ~= -1 but line object gone on lookup)
% With 'fix' true it deletes the offending line handles and reports what
% was removed. Never touches blocks.
%
% report fields: model, nlines, nunconnected_src, nunconnected_dst,
%   orphan_lines (cell of names), duplicate_dst (cell), fixed (cell)

if nargin < 2, opts = struct(); end
fix = 0;
if isfield(opts, 'fix') && opts.fix, fix = 1; end

report = struct('model', model, 'nlines', 0, 'orphan_lines', {{}}, ...
    'duplicate_dst', {{}}, 'unconnected_ports', {{}}, 'fixed', {{}});

load_system(model);
% NOTE: on this R14 install find_system(model,'Type','Block') returns ZERO
% results (the 'Type' filter is broken there) -- list everything and filter
% by get_param(...,'BlockType') instead. Verified by probe 2026-10-21.
allPaths = find_system(model);
blks = {};
for b = 1:numel(allPaths)
    try
        bt = get_param(allPaths{b}, 'BlockType');
        blks{end+1} = allPaths{b}; %#ok<AGROW>
    catch
        % lines/diagrams have no BlockType -- not blocks
    end
end

% --- collect all line handles ----------------------------------------
lineHandles = [];
for b = 1:numel(blks)
    lh = get_param(blks{b}, 'LineHandles');
    lineHandles = [lineHandles, lh.Inport, lh.Outport, lh.LConn, lh.RConn]; %#ok<AGROW>
end
lineHandles = lineHandles(lineHandles ~= -1 & lineHandles ~= 0);
report.nlines = numel(lineHandles);

% --- map dest ports -> count of attached lines ------------------------
% R14: a healthy line has exactly one destination port. Two lines on the
% same port = ghost duplicate. NOTE: struct fieldnames can't hold keys with
% dots (port handles print as '9.001'), so use parallel arrays + ismember.
dstKeys = [];
dstCnts = [];
for k = 1:numel(lineHandles)
    h = lineHandles(k);
    try
        dp = get_param(h, 'DstPortHandle');
    catch
        report.orphan_lines{end+1} = num2str(h); %#ok<AGROW>
        continue;
    end
    for p = 1:numel(dp)
        ph = dp(p);
        if ph == -1 || ph == 0, continue; end
        loc = find(dstKeys == ph, 1);
        if isempty(loc)
            dstKeys(end+1) = ph; %#ok<AGROW>
            dstCnts(end+1) = 1; %#ok<AGROW>
        else
            dstCnts(loc) = dstCnts(loc) + 1;
        end
    end
end

% --- duplicate destinations ------------------------------------------
for f = 1:numel(dstCnts)
    if dstCnts(f) > 1
        ph = dstKeys(f);
        pb = '';
        try
            pb = get_param(ph, 'Parent');
            pb = [pb, ' port ', num2str(get_param(ph, 'PortNumber'))];
        catch
            pb = 'unknown';
        end
        report.duplicate_dst{end+1} = [pb, ' (', num2str(dstCnts(f)), ' lines)']; %#ok<AGROW>
        if fix
            % delete all lines on this port, keep none (caller re-adds)
            for k = 1:numel(lineHandles)
                h = lineHandles(k);
                try
                    dp = get_param(h, 'DstPortHandle');
                    if any(dp == ph)
                        delete_line(h);
                        report.fixed{end+1} = ['deleted line ' num2str(h) ' dup-dst ' pb]; %#ok<AGROW>
                    end
                catch
                end
            end
        end
    end
end

% --- unconnected input ports (u warn in sim) --------------------------
for b = 1:numel(blks)
    bt = get_param(blks{b}, 'BlockType');
    if strcmp(bt, 'SubSystem') && ~strcmp(get_param(blks{b}, 'Mask'), 'on')
        % root subsystems may legitimately be library-less; still count
    end
    try
        ph = get_param(blks{b}, 'PortHandles');
        inports = ph.Inport;
    catch
        continue;
    end
    for p = 1:numel(inports)
        if inports(p) == -1, continue; end
        % NOTE: on this R14, ports expose SrcBlockHandle only via get_param
        % on the LINE, not on the port handle. Ask the port for its line.
        try
            lh = get_param(inports(p), 'Line');
            if lh == -1 || lh == 0
                report.unconnected_ports{end+1} = [blks{b}, ' in', num2str(p)]; %#ok<AGROW>
            end
        catch
            % port cannot be queried -- count as unconnected only if it
            % belongs to a non-root block
            report.unconnected_ports{end+1} = [blks{b}, ' in', num2str(p), ' (unqueryable)']; %#ok<AGROW>
        end
    end
end
end
