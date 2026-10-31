function report = mcp_sim_arrange(model, opts)
%MCP_SIM_ARRANGE  Auto-arrange the blocks of one Simulink diagram layer
% (root or a subsystem) into a clean left-to-right signal-flow layout.
%   report = mcp_sim_arrange('model')                    -> root layer
%   report = mcp_sim_arrange('model','sys','model/Sub')  -> one subsystem
%
% Algorithm (Sugiyama-style, R14-safe):
%   1. build the connection graph src block -> dst block (root-level lines
%      only; ghost duplicates skipped; self-loops and cycles guarded)
%   2. v6b cycle breaking: find SCCs, cut exactly ONE edge per SCC --
%      the combination minimizing total edge span (cut edges are still
%      wires, so their span is scored too). Before v6, cycle members were
%      flattened onto their shallowest feeder's layer, piling whole
%      feedback chains -- SOC loop, distance loop -- into one tall column.
%   3. order blocks inside a layer by barycenter of predecessors' rows
%      (down-down-up-down sweeps) to reduce wire crossings
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
types = {};
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
    types{end+1} = bt; %#ok<AGROW>
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

% ---------------- layering: SCC cut search + Kahn longest path ------------
% v6b: cycle handling. v6 cut DFS back edges, which scattered loops (a cut
% at the wrong place turns a loop head into a fake source at L1 while its
% loop partners sit at L9 -- the wrap wire crosses the whole canvas).
% Proper approach: find SCCs (Kosaraju), cut exactly ONE edge per
% nontrivial SCC, and pick the combination minimizing the TOTAL edge span
% Sum |layer(u)-layer(v)| over all original edges (cut edges still exist
% as wires, so their span is scored too -- the wrap lands where a human
% would put it). Combos are capped: large SCCs first restrict candidates
% to edges entering state-holding blocks, then get truncated.
[sccs, nScc] = scc_kosaraju(edges, nb);
cand = cell(1, nScc);
nCombo = 1;
for c = 1:nScc
    mem = sccs{c};
    if numel(mem) < 2
        cand{c} = zeros(0, 2);
        continue;
    end
    list = zeros(0, 2);
    for a = 1:numel(mem)
        for b2 = 1:numel(mem)
            if edges(mem(a), mem(b2)) == 1
                list(end+1, :) = [mem(a), mem(b2)]; %#ok<AGROW>
            end
        end
    end
    cand{c} = list;
    nCombo = nCombo * max(size(list, 1), 1);
end
if nCombo > 256
    % restrict to edges entering state-holding blocks (Simulink breaks
    % algebraic loops there anyway)
    nCombo = 1;
    for c = 1:nScc
        list = cand{c};
        keep = zeros(0, 2);
        for t = 1:size(list, 1)
            dst = list(t, 2);
            if any(strcmp(types{dst}, {'Integrator', 'Memory', 'UnitDelay', ...
                    'DiscreteIntegrator', 'DiscreteTimeIntegrator'}))
                keep(end+1, :) = list(t, :); %#ok<AGROW>
            end
        end
        if size(keep, 1) > 0
            cand{c} = keep;
        end
        nCombo = nCombo * max(size(cand{c}, 1), 1);
    end
end
if nCombo > 256
    % last resort: truncate every list to 8 candidates (deterministic)
    for c = 1:nScc
        if size(cand{c}, 1) > 8
            cand{c} = cand{c}(1:8, :);
        end
    end
end
counts = zeros(1, nScc);
for c = 1:nScc
    counts(c) = size(cand{c}, 1);
end
layer = kahn_layers(edges, nb);
bestScore = Inf;
if nScc > 0 && any(counts > 0)
    idx = zeros(1, nScc);
    iter = 0;
    while iter < 400
        iter = iter + 1;
        edgesLay = edges;
        for c = 1:nScc
            if counts(c) > 0
                e2 = cand{c}(idx(c) + 1, :);
                edgesLay(e2(1), e2(2)) = 0;
            end
        end
        lay2 = kahn_layers(edgesLay, nb);
        sc = 0;
        for i = 1:nb
            for j = 1:nb
                if edges(i, j) == 1
                    sc = sc + abs(lay2(j) - lay2(i));
                end
            end
        end
        if sc < bestScore
            bestScore = sc;
            layer = lay2;
        end
        % mixed-radix increment over per-SCC candidate indices
        c = nScc;
        while c >= 1
            if counts(c) == 0
                c = c - 1;
                continue;
            end
            idx(c) = idx(c) + 1;
            if idx(c) < counts(c)
                break;
            end
            idx(c) = 0;
            c = c - 1;
        end
        if c < 1
            break;
        end
    end
end
nCuts = 0;
for c = 1:nScc
    if counts(c) > 0
        nCuts = nCuts + 1;
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

% ---------------- barycenter ordering inside layers ----------------
% v6: down-down-up-down sweeps. The up sweep pulls parents under their
% children, which matters once cut back edges feed earlier layers again.
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
    rows = bary_sweep(rows, edges, 1);
end
rows = bary_sweep(rows, edges, -1);
rows = bary_sweep(rows, edges, 1);

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
    'layers', nlayers, 'nblocks', nb, 'cuts', nCuts, 'span', bestScore, ...
    'details', {details});
end

% ======================================================================
function layer = kahn_layers(edgesLay, nb)
% longest-path layering (Kahn) on an acyclic edge set, with a safety net
% that assigns best-feeder+1 to anything unreachable.
layer = zeros(1, nb);
indeg = sum(edgesLay, 1);
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
        if edgesLay(i, j) == 1
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
for it = 1:20
    changed = false;
    for i = 1:nb
        if layer(i) > 0, continue; end
        best = 0;
        for u = 1:nb
            if edgesLay(u, i) == 1 && layer(u) > 0
                if layer(u) + 1 > best
                    best = layer(u) + 1;
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
end

% ======================================================================
function [sccs, nScc] = scc_kosaraju(edges, nb)
% strongly connected components, Kosaraju: DFS finish order on G, then DFS
% on G^T in reverse finish order. Iterative (R14 has no recursion issues,
% but explicit stacks keep it uniform with the rest of the file).
visited = zeros(1, nb);
order = [];
for s = 1:nb
    if visited(s), continue; end
    ptr = zeros(1, nb);
    visited(s) = 1;
    stack = s;
    while ~isempty(stack)
        u = stack(end);
        advanced = 0;
        for j = ptr(u)+1:nb
            if edges(u, j) == 1 && visited(j) == 0
                ptr(u) = j;
                visited(j) = 1;
                stack(end+1) = j; %#ok<AGROW>
                advanced = 1;
                break;
            end
        end
        if advanced == 0
            order(end+1) = u; %#ok<AGROW>
            stack(end) = [];
        end
    end
end
gt = edges';
visited2 = zeros(1, nb);
sccs = {};
for t = numel(order):-1:1
    s = order(t);
    if visited2(s), continue; end
    visited2(s) = 1;
    comp = s;
    stack = s;
    while ~isempty(stack)
        u = stack(end);
        advanced = 0;
        for j = 1:nb
            if gt(u, j) == 1 && visited2(j) == 0
                visited2(j) = 1;
                comp(end+1) = j; %#ok<AGROW>
                stack(end+1) = j; %#ok<AGROW>
                advanced = 1;
                break;
            end
        end
        if advanced == 0
            stack(end) = [];
        end
    end
    sccs{end+1} = comp; %#ok<AGROW>
end
nScc = numel(sccs);
end

% ======================================================================
function rows = bary_sweep(rows, edges, dir)
% order each layer by the mean row of its neighbours in the adjacent layer
% (dir = +1: predecessors of layer k live in k-1; dir = -1: successors of
% layer k live in k+1).
nlayers = numel(rows);
ks = [];
if dir > 0
    for k = 2:nlayers
        ks(end+1) = k; %#ok<AGROW>
    end
else
    for k = nlayers-1:-1:1
        ks(end+1) = k; %#ok<AGROW>
    end
end
for sw = 1:numel(ks)
    k = ks(sw);
    if k + dir < 1 || k + dir > nlayers, continue; end
    idx = rows{k};
    if isempty(idx), continue; end
    bc = zeros(1, numel(idx));
    for t = 1:numel(idx)
        if dir > 0
            nbList = find(edges(:, idx(t)) == 1)';
        else
            nbList = find(edges(idx(t), :) == 1)';
        end
        ssum = 0;
        n = 0;
        for u = 1:numel(nbList)
            pu = find_in(rows{k+dir}, nbList(u));
            if ~isempty(pu)
                ssum = ssum + pu;
                n = n + 1;
            end
        end
        if n > 0
            bc(t) = ssum / n;
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
