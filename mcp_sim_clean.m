function report = mcp_sim_clean(model)
%MCP_SIM_CLEAN  Remove orphan/ghost line segments left by add_line/delete_block.
%   report = mcp_sim_clean('model') -> struct report
%
% Deletes line handles that:
%   - throw on SrcPortHandle/DstPortHandle lookup, or
%   - have neither a valid source nor any valid destination port.
% Healthy branched lines (valid src + >=1 valid dst) are never touched.
% Safe to call repeatedly; returns what was removed.

report = struct('model', model, 'removed', {{}}, 'kept', 0);

load_system(model);
% NOTE: find_system(model,'Type','Block') returns zero rows on this R14
% install -- enumerate everything and keep entries that expose BlockType.
allPaths = find_system(model);
blks = {};
for b = 1:numel(allPaths)
    try
        get_param(allPaths{b}, 'BlockType');
        blks{end+1} = allPaths{b}; %#ok<AGROW>
    catch
        % not a block
    end
end

lineHandles = [];
for b = 1:numel(blks)
    lh = get_param(blks{b}, 'LineHandles');
    lineHandles = [lineHandles, lh.Inport, lh.Outport, lh.LConn, lh.RConn]; %#ok<AGROW>
end
lineHandles = unique(lineHandles(lineHandles ~= -1 & lineHandles ~= 0));

for k = 1:numel(lineHandles)
    h = lineHandles(k);
    ok = true;
    src = -1;
    dsts = -1;
    try
        src = get_param(h, 'SrcPortHandle');
        dsts = get_param(h, 'DstPortHandle');
    catch
        ok = false;
    end
    if ok
        validDst = 0;
        for p = 1:numel(dsts)
            if dsts(p) ~= -1 && dsts(p) ~= 0
                validDst = validDst + 1;
            end
        end
        if src == -1 || src == 0
            ok = (validDst > 0);   % trunkless branch line is legal only if attached
        else
            ok = true;             % has a source: keep
        end
    end
    if ok
        report.kept = report.kept + 1;
    else
        try
            delete_line(h);
            report.removed{end+1} = num2str(h); %#ok<AGROW>
        catch
            % handle already gone — still counts as removed
            report.removed{end+1} = [num2str(h), ' (gone)']; %#ok<AGROW>
        end
    end
end

try
    save_system(model);
end
end
