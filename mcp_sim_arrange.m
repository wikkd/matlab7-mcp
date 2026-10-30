function report = mcp_sim_arrange(model, opts)
%MCP_SIM_ARRANGE  Auto-arrange the blocks of one Simulink diagram layer
% (root or a subsystem) into a clean left-to-right signal-flow layout.
%   report = mcp_sim_arrange('model')                    -> root layer
%   report = mcp_sim_arrange('model','sys','model/Sub')  -> one subsystem
%
% Algorithm (Sugiyama-style, R14-safe):
%   1. build the connection graph src block -> dst block (root-level lines
%      only; ghost duplicates skipped; self-loops and cycles guarded)
%   2. layer each block by LONGEST path from any source (block with no
%      upstream connections); pure sinks go after their feeders
%   3. order blocks inside a layer by barycenter of predecessors' rows
%      (two sweeps) to reduce wire crossings
%   4. assign x per layer (fixed slot width) and y top-down per row with
%      row centering around the predecessors' mean y
%   5. move blocks via set_param Position (size preserved)
%   6. lines are NOT moved here -- follow with mcp_sim_route to re-route
%      everything orthogonally.
% Scope/Display/To Workspace/Terminator etc. are ordinary nodes; subsystems
% are atomic (their internals are untouched).

xgap = 90;          % horizontal slot width per layer
ygap = 45;          % vertical gap between rows (>= 45 leaves a clear lane
                    % corridor below the ~15 px name labels; v2 route uses it)
x0 = 40;            % left margin
y0 = 40;            % top margin
sys = model;
modelOrig = model;
if nargin < 2, opts = struct(); end
if isfield(opts, 'xgap'), xgap = opts.xgap; end
if isfield(opts, 'ygap'), ygap = opts.ygap; end
if isfield(opts, 'x0'), x0 = opts.x0; end
if isfield(opts, 'y0'), y0 = opts.y0; end
if isfield(opts, 'sys'), sys = opts.sys; end

% full-path models fail on this R14 ("no system named"): cd + bare name
if any(model == '/') || any(model == '\')
    [mp, mn] = fileparts(model);
    cd(mp);
    model = mn;
end
if strcmp(sys, modelOrig)
    sys = model;   % root layer follows the (possibly swapped) model name
end
load_system(model);

% ---------------- collect blocks in this layer ----------------
allPaths = find_system(sys, 'SearchDepth', 1);
names = {};
w = [];
h = [];
for b = 1:numel(allPaths)
    p = allPaths{b};
    if strcmp(p, sys), continue; end
    try
        bt = get_param(p, 'BlockType');
    catch
        continue;
    end
    % skip annotation-only entries; note: notes have no BlockType (caught)
    try
        r = get_param(p, 'Position');
    catch
        continue;
    end
    names{end+1} = p; %#ok<AGROW>
    w(end+1) = r(3) - r(1) + 1; %#ok<AGROW>
    h(end+1) = r(4) - r(2) + 1; %#ok<AGROW>
end
nb = numel(names);
if nb == 0
    report = struct('model', model, 'sys', sys, 'moved', 0, 'layers', 0, ...
        'details', {{'no blocks'}});
    return;
end

% ---------------- build connection graph (index-based) ----------------
% edges(i,j) = 1 if names{i} feeds names{j}. Must scan BOTH sides: the
% outport-side trunk line carries only its first dst row; branch lines
% (separate objects from the same src) appear on the dst block's Inport.
edges = zeros(nb, nb);
for b = 1:numel(allPaths)
    p = allPaths{b};
    if strcmp(p, sys), continue; end
    try
        get_param(p, 'BlockType');
        lh = get_param(p, 'LineHandles');
    catch
        continue;
    end
    % dst-side scan: every inport line of every block (covers trunk+branch)
    for s = 1:numel(lh.Inport)
        hLine = lh.Inport(s);
        if hLine == -1 || hLine == 0, continue; end
        try
            sp = get_param(hLine, 'SrcPortHandle');
        catch
            continue;
        end
        if sp == -1 || sp == 0, continue; end
        try
            sb = get_param(sp, 'Parent');
        catch
            continue;
        end
        i = find_same(names, sb);
        j = find_same(names, p);
        if isempty(i) || isempty(j), continue; end
        if i == j, continue; end
        edges(i, j) = 1;
    end
end

% ---------------- longest-path layering (Kahn + cycle fallback) ----------
% Kahn is correct now that branch edges are included (the earlier stale-layer
% bug came from missing branch edges, not from Kahn itself). Cycle members
% (feedback loops) never reach indeg 0; they get the layer of their
% shallowest finalized feeder + 1 so a feedback chain sits next to its
% forward targets instead of climbing to layer 100+.
layer = zeros(1, nb);
indeg = sum(edges, 1);
queue = [];
for i = 1:nb
    if indeg(i) == 0
        layer(i) = 1;
        queue(end+1) = i; %#ok<AGROW>
    end
end
while ~isempty(queue)
    i = queue(1);
    queue = queue(2:end);
    for j = 1:nb
        if edges(i, j) == 1
            if layer(j) < layer(i) + 1
                layer(j) = layer(i) + 1;
            end
            indeg(j) = indeg(j) - 1;
            if indeg(j) == 0
                queue(end+1) = j; %#ok<AGROW>
            end
        end
    end
end
% cycle members: assign iteratively -- each gets min(finalized feeder)+1;
% repeat until stable (handles chained cycles like SOC loops)
for it = 1:20
    changed = false;
    for i = 1:nb
        if layer(i) > 0, continue; end
        best = 0;
        for u = 1:nb
            if edges(u, i) == 1 && layer(u) > 0
                if best == 0 || layer(u) < best
                    best = layer(u);
                end
            end
        end
        if best > 0
            layer(i) = best;
            changed = true;
        end
    end
    if ~changed
        break;
    end
end
for i = 1:nb
    if layer(i) < 1
        layer(i) = 1;
    end
end
% compact empty layers (feedback loops can leave gaps)
used = unique(layer(layer >= 1));
newl = zeros(1, nb);
for i = 1:nb
    pos = 0;
    for k = 1:numel(used)
        if layer(i) == used(k)
            pos = k;
            break;
        end
    end
    newl(i) = pos;
end
layer = newl;
nlayers = max(layer);

% ---------------- barycenter ordering inside layers (2 sweeps) ----------------
rows = cell(1, nlayers);
for k = 1:nlayers
    rows{k} = find(layer == k);
end
if isfield(opts, 'debug') && opts.debug
    for k = 1:nlayers
        line_k = ['L' num2str(k) ':'];
        for t = 1:numel(rows{k})
            line_k = [line_k ' ' names{rows{k}(t)}];
        end
        disp(line_k);
    end
end
for sweep = 1:2
    for k = 2:nlayers
        idx = rows{k};
        bc = zeros(1, numel(idx));
        for t = 1:numel(idx)
            preds = find(edges(:, idx(t)) == 1);
            s = 0;
            n = 0;
            for u = 1:numel(preds)
                pu = find_in(rows{k-1}, preds(u));
                if ~isempty(pu)
                    s = s + pu;
                    n = n + 1;
                end
            end
            if n > 0
                bc(t) = s / n;
            else
                bc(t) = t;
            end
        end
        % tie-break duplicates with position epsilon (find-on-equal would
        % return the same index twice and silently DROP a block from the row)
        for t2 = 1:numel(bc)
            bc(t2) = bc(t2) + t2 * 1e-6;
        end
        tmp = sort(bc);
        ord = [];
        for t2 = 1:numel(tmp)
            k2 = find(bc == tmp(t2), 1);
            ord(end+1) = k2; %#ok<AGROW>
        end
        rows{k} = idx(ord);
    end
end

% ---------------- assign positions ----------------
% x per layer: CUMULATIVE (next layer starts right of the widest block of
% the previous layer + gap) so wide blocks never bleed into the next slot.
% Row y: stacked with gap, rows centered on the previous layer's mean y.
prevMidY = [];
xLeft = x0;
nmoved = 0;
details = {};
for k = 1:nlayers
    idx = rows{k};
    heights = [];
    for t = 1:numel(idx)
        heights(end+1) = h(idx(t)); %#ok<AGROW>
    end
    totalH = sum(heights) + ygap * (numel(idx) - 1);
    startY = y0;
    if ~isempty(prevMidY)
        startY = round(prevMidY - totalH / 2);
        if startY < y0
            startY = y0;
        end
    end
    yy = startY;
    midYs = [];
    maxX2 = xLeft;
    for t = 1:numel(idx)
        i = idx(t);
        newpos = [xLeft, yy, xLeft + w(i) - 1, yy + h(i) - 1];
        oldpos = get_param(names{i}, 'Position');
        if ~(abs(oldpos(1) - newpos(1)) < 0.5 && abs(oldpos(2) - newpos(2)) < 0.5)
            set_param(names{i}, 'Position', newpos);
            nmoved = nmoved + 1;
        end
        if xLeft + w(i) - 1 > maxX2
            maxX2 = xLeft + w(i) - 1;
        end
        midYs(end+1) = yy + h(i) / 2; %#ok<AGROW>
        yy = yy + h(i) + ygap;
    end
    xLeft = maxX2 + xgap;
    if isempty(midYs)
        prevMidY = [];
    else
        prevMidY = sum(midYs) / numel(midYs);
    end
end

save_system(model);

report = struct('model', model, 'sys', sys, 'moved', nmoved, ...
    'layers', nlayers, 'nblocks', nb, 'details', {details});
end

% ======================================================================
function i = find_same(names, p)
% find index of block path p in names (exact match)
i = [];
for k = 1:numel(names)
    if strcmp(names{k}, p)
        i = k;
        return;
    end
end
end

% ======================================================================
function i = find_in(idxList, v)
i = [];
for k = 1:numel(idxList)
    if idxList(k) == v
        i = k;
        return;
    end
end
end
