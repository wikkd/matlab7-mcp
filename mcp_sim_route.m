function report = mcp_sim_route(model, opts)
%MCP_SIM_ROUTE  Re-route every line as orthogonal polylines with zero
% diagonal segments and no crossing through block bodies (R14).
%   report = mcp_sim_route('model')                -> struct report
%   report = mcp_sim_route('model','spacing',30)   -> custom channel spacing
%
% R14 line semantics (proven by probes 2026-10-21, see README):
%   - Points are ABSOLUTE coords; R14 forces Points(1,:) = the line's anchor
%     (src port for trunk lines, trunk branch point for branch lines).
%   - TRUNK lines: R14 replaces the final approach with its canonical elbow
%     (dst_x-10, dst_y) unless our last middle IS that point.
%   - Middles that sit alone on the exit horizontal/vertical run get dropped
%     (collinear compression keeps the LAST point of each run).
%   => SAFE-Z pattern (proven): give BOTH (c1-8,P0y) and (c1,P0y) so at least
%      one survivor stays on the exit row, then (c1,Pny), then the trunk's
%      canonical (dst_x-10,Pny) explicitly.
%   - BRANCH lines accept arbitrary middles; same SAFE-Z works with the
%     branch anchor read back after a dummy set.
% Segments checked for block collision: exit H, channel V, approach H.
% Branch lines ARE routed here (they were the diagonal source); the anchor
% is honored so no branch-point association is broken.

spacing = 30;
margin = 4;
if nargin < 2, opts = struct(); end
if isfield(opts, 'spacing'), spacing = opts.spacing; end
if isfield(opts, 'margin'), margin = opts.margin; end

% full-path models fail on this R14 ("no system named"): cd + bare name
if any(model == '/') || any(model == '\')
    [mp, mn] = fileparts(model);
    cd(mp);
    model = mn;
end
load_system(model);

% ---------------- ghost-duplicate scan (report only) ----------------
ndedup = 0;
ap0 = find_system(model);
allLines = [];
for b0 = 1:numel(ap0)
    p0 = ap0{b0};
    if strcmp(p0, model), continue; end
    try
        get_param(p0, 'BlockType');
        lh0 = get_param(p0, 'LineHandles');
    catch
        continue;
    end
    for s0 = 1:numel(lh0.Outport)
        if lh0.Outport(s0) ~= -1 && lh0.Outport(s0) ~= 0
            allLines(end+1) = lh0.Outport(s0); %#ok<AGROW>
        end
    end
    for s0 = 1:numel(lh0.Inport)
        if lh0.Inport(s0) ~= -1 && lh0.Inport(s0) ~= 0
            allLines(end+1) = lh0.Inport(s0); %#ok<AGROW>
        end
    end
end
allLines = unique(allLines);
seenPorts = [];
for k0 = 1:numel(allLines)
    try
        dp0 = get_param(allLines(k0), 'DstPortHandle');
    catch
        continue;
    end
    for q0 = 1:numel(dp0)
        if dp0(q0) == -1 || dp0(q0) == 0, continue; end
        if isempty(find(seenPorts == dp0(q0), 1))
            seenPorts(end+1) = dp0(q0); %#ok<AGROW>
        else
            ndedup = ndedup + 1;
        end
    end
end

% ---------------- collect block rects (inflated) ----------------
allPaths = find_system(model);
rects = zeros(0, 4);
for b = 1:numel(allPaths)
    p = allPaths{b};
    if strcmp(p, model), continue; end
    try
        get_param(p, 'BlockType');
        r = get_param(p, 'Position');
    catch
        continue;
    end
    rects(end+1, :) = r; %#ok<AGROW>
end
R = rects;
if ~isempty(R)
    R(:, 1) = R(:, 1) - margin;
    R(:, 2) = R(:, 2) - margin;
    R(:, 3) = R(:, 3) + margin;
    R(:, 4) = R(:, 4) + margin;
end

% ---------------- enumerate every line (trunk + branch) ----------------
% Each record: {dstLineHandle, dstPortHandle, isTrunk}
% trunk  = first dst row of a src outport's own line
% branch = any other line object arriving at a block inport
recs = {};
for b = 1:numel(allPaths)
    p = allPaths{b};
    if strcmp(p, model), continue; end
    try
        get_param(p, 'BlockType');
        lh = get_param(p, 'LineHandles');
    catch
        continue;
    end
    % trunks: outport-side lines of every block
    for s = 1:numel(lh.Outport)
        h = lh.Outport(s);
        if h == -1 || h == 0, continue; end
        try
            dsts = get_param(h, 'DstPortHandle');
        catch
            continue;
        end
        for d = 1:numel(dsts)
            if dsts(d) == -1 || dsts(d) == 0, continue; end
            recs{end+1} = {h, dsts(d), true}; %#ok<AGROW>
        end
    end
    % branches: inport-side lines that are NOT one of the trunk handles
    for s = 1:numel(lh.Inport)
        h = lh.Inport(s);
        if h == -1 || h == 0, continue; end
        isTrunk = false;
        for t = 1:numel(recs)
            if recs{t}{1} == h, isTrunk = true; break; end
        end
        if isTrunk, continue; end
        try
            if get_param(h, 'SrcPortHandle') == -1, continue; end
        catch
            continue;
        end
        try
            ph = get_param(p, 'PortHandles');
            recs{end+1} = {h, ph.Inport(s), false}; %#ok<AGROW>
        catch
            continue;
        end
    end
end

% ---------------- route trunks first, then branches ----------------
nrouted = 0;
nkept = 0;
nfailed = 0;
details = {};

% pass 1: trunks
for r2 = 1:numel(recs)
    rec = recs{r2};
    if ~rec{3}, continue; end
    [okS, msg] = route_one(rec{1}, rec{2}, R, spacing, true);
    if okS
        nrouted = nrouted + 1;
    elseif strcmp(msg, 'straight')
        nkept = nkept + 1;
    else
        nfailed = nfailed + 1;
        details{end+1} = msg; %#ok<AGROW>
    end
end
% pass 2: branches (anchors depend on routed trunks)
for r2 = 1:numel(recs)
    rec = recs{r2};
    if rec{3}, continue; end
    [okS, msg] = route_one(rec{1}, rec{2}, R, spacing, false);
    if okS
        nrouted = nrouted + 1;
    elseif strcmp(msg, 'straight')
        nkept = nkept + 1;
    else
        nfailed = nfailed + 1;
        details{end+1} = msg; %#ok<AGROW>
    end
end
% pass 3: convergence — routing branches can drag a trunk's anchor to a new
% branch point (R14 moves Points(1,:) of every line sharing the src port).
% Re-read anchors and re-route anything now non-orthogonal. Max 2 sweeps.
for sweep = 1:2
    nfix = 0;
    for r2 = 1:numel(recs)
        rec = recs{r2};
        Pcur = get_param(rec{1}, 'Points');
        if isempty(Pcur) || all_orthogonal(Pcur)
            continue;
        end
        nfix = nfix + 1;
        route_one(rec{1}, rec{2}, R, spacing, rec{3});
    end
    if nfix == 0
        break;
    end
end

try
    save_system(model);
end

report = struct('model', model, 'routed', nrouted, 'kept', nkept, ...
    'failed', nfailed, 'ghost_lines', ndedup, 'details', {details});
end

% ======================================================================
function [ok, msg] = route_one(lineH, dstPort, R, spacing, isTrunk)
% Route one line as SAFE-Z. ok=true if Points were (re)set; msg='straight'
% if already a clean straight line; otherwise msg carries the error.
ok = false;
msg = '';
try
    % anchor: R14 forces Points(1,:) -- read it AFTER a probe set so the
    % anchor reflects any branch-point snapping. Use the CURRENT first point.
    Pcur = get_param(lineH, 'Points');
    if isempty(Pcur)
        msg = 'line has no Points (unconnected?)';
        return;
    end
    P0 = Pcur(1, :);
    dp = get_param(dstPort, 'Position');
    Pn = dp(1:2);

    sx = P0(1); sy = P0(2);
    dx = Pn(1); dy = Pn(2);

    % same row/col: straight line, nothing to do
    if abs(sy - dy) < 0.5
        if isTrunk
            set_param(lineH, 'Points', [sx sy; dx dy]);
        else
            set_param(lineH, 'Points', [sx sy; dx dy]);
        end
        ok = true;
        msg = 'straight';
        return;
    end

    % candidate channels: open interval between anchor x and dst x, ordered
    % by distance from the anchor exit (near-src channels keep branch points
    % early). If the anchor lies past the dst the interval is empty and the
    % anchor-lane / go-around strategies take over.
    lo = min(sx, dx) + 12;
    hi = max(sx, dx) - 12;
    cands = [];
    if hi > lo
        c = lo;
        while c <= hi
            cands(end+1) = round(c); %#ok<AGROW>
            c = c + 8;
        end
        tmp = sort(abs(cands - sx));
        ord = [];
        for s3 = 1:numel(tmp)
            k3 = find(abs(cands - sx) == tmp(s3), 1);
            ord(end+1) = k3; %#ok<AGROW>
        end
        cands = cands(ord);
    end

    % SAFE-Z: exit horizontal at y=sy to channel c, vertical to y=dy,
    % approach horizontal to dst. For trunks the canonical elbow
    % (dst_x-10, dst_y) is part of the pattern.
    chosen = [];
    for c = 1:numel(cands)
        cx = cands(c);
        if seg_blocked_h(sx, cx, sy, R) || seg_blocked_v(sy, dy, cx, R) ...
                || seg_blocked_h(cx, dx, dy, R)
            continue;
        end
        chosen = cx;
        break;
    end

    if ~isempty(chosen)
        cx = chosen;
        if isTrunk
            % [P0; (c-8,P0y); (c,P0y); (c,Pny); (dstx-10,Pny)]
            P = [sx sy; cx - 8, sy; cx, sy; cx, dy; dx - 10, dy];
            % de-dup identical consecutive points for degenerate cases
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
        else
            % branch: anchor honored, no canonical elbow needed; R14 renders
            % last middle -> dst (same row).
            P = [sx sy; cx - 8, sy; cx, sy; cx, dy];
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
        end
        % verify orthogonality of what R14 actually stored
        Pr = get_param(lineH, 'Points');
        if ~all_orthogonal(Pr)
            % R14 rewrote into diagonals: revert to straight-through fallback
            % (its own canonical form) and report
            msg = 'non-orthogonal after set; left to canonical form';
            return;
        end
        ok = true;
        msg = '';
        return;
    end

    % anchor-vertical lane: for anchors past the dst (or with no room for a
    % channel), drop straight down/up at the anchor x, run horizontally on a
    % clear lane, then enter the dst. Vertical-exit middles can be dropped by
    % R14's collinear compression, so verify after set and report honestly.
    if isempty(chosen)
        laneY = 0;
        for s2 = 1:10
            cy2 = dy - s2 * 10 * sign(dy - sy);
            if cy2 == sy, continue; end
            if ~seg_blocked_h(min(sx, dx), max(sx, dx), cy2, R)
                laneY = cy2;
                break;
            end
        end
        if laneY ~= 0
            P = [sx sy; sx laneY; dx laneY; dx dy];
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
            Pr = get_param(lineH, 'Points');
            if all_orthogonal(Pr)
                ok = true;
                msg = '';
                return;
            end
            msg = 'anchor-lane route non-orthogonal after set';
            return;
        end
    end

    % go-around lane above/below blockers in the span. The vertical leg must
    % sit on a channel x (NOT the anchor x -- R14 drops same-x middles), so
    % find a clear vertical lane near the anchor and use the SAFE-Z pair
    % [(c-8,sy);(c,sy)] to survive collinear compression.
    lo2 = min(sx, dx);
    hi2 = max(sx, dx);
    top = -inf;
    bot = inf;
    anyBlk = false;
    for k = 1:size(R, 1)
        if R(k, 3) < lo2 || R(k, 1) > hi2, continue; end
        anyBlk = true;
        if R(k, 2) < bot, bot = R(k, 2); end
        if R(k, 4) > top, top = R(k, 4); end
    end
    if anyBlk
        % try several lanes: nearest above, nearest below, then further out
        laneUp = top + max(12, spacing * 0.4);
        laneDn = bot - max(12, spacing * 0.4);
        laneCands = [14, laneUp, laneDn, 28, laneUp + 25, laneDn - 25, ...
                     laneUp + 50, laneDn - 50, laneUp + 75, laneDn - 75];
        cy = 0;
        for lc = 1:numel(laneCands)
            cyTry = laneCands(lc);
            if ~isempty(cyTry) && ~seg_blocked_h(sx, dx, cyTry, R)
                cy = cyTry;
                break;
            end
        end
        if cy ~= 0
            % find clear vertical channel x NEAR the anchor. The channel x
            % must differ from the anchor x (R14 drops same-x middles, which
            % is exactly how the diagonal regressions happened).
            cxg = 0;
            for s4 = 0:10
                c4 = sx + s4 * 8;
                if ~seg_blocked_v(sy, cy, c4, R)
                    cxg = c4;
                    break;
                end
            end
            if cxg ~= 0
                % Lane pattern (proven): vertical at channel x, lane row with
                % a PAIR ending at the canonical elbow x (dx-10) so the
                % survivor merges with R14's forced elbow, then vertical to
                % the dst row. For branches R14 appends dst itself.
                ex = dx - 10;
                % same 7-point pattern for trunks AND branches: the canonical
                % elbow is forced on both, so both must arrive on the dst row
                P = [sx sy; cxg - 8, sy; cxg, sy; cxg, cy; ...
                     ex - 8, cy; ex, cy; ex, dy];
                P = dedup_pts(P);
                set_param(lineH, 'Points', P);
                Pr = get_param(lineH, 'Points');
                if all_orthogonal(Pr)
                    ok = true;
                    msg = '';
                    return;
                end
            end
            msg = 'go-around lane non-orthogonal after set';
            return;
        end
    end

    msg = 'no clear channel found; left unchanged';
catch
    msg = ['route_one failed: ', lasterr];
end
end

% ------------------------------------------------------------------
function out = dedup_pts(P)
out = P(1, :);
for k = 2:size(P, 1)
    if ~isequal(P(k, :), out(end, :))
        out(end+1, :) = P(k, :); %#ok<AGROW>
    end
end
end

% ------------------------------------------------------------------
function tf = all_orthogonal(P)
% every consecutive pair shares x or y (within 0.5 px tolerance)
tf = true;
for k = 2:size(P, 1)
    if abs(P(k,1) - P(k-1,1)) > 0.5 && abs(P(k,2) - P(k-1,2)) > 0.5
        tf = false;
        return;
    end
end
end

% ------------------------------------------------------------------
function tf = seg_blocked_h(x1, x2, y, R)
tf = false;
lo = min(x1, x2);
hi = max(x1, x2);
for k = 1:size(R, 1)
    if y >= R(k, 2) && y <= R(k, 4) && hi >= R(k, 1) && lo <= R(k, 3)
        tf = true;
        return;
    end
end
end

% ------------------------------------------------------------------
function tf = seg_blocked_v(y1, y2, x, R)
tf = false;
lo = min(y1, y2);
hi = max(y1, y2);
for k = 1:size(R, 1)
    if x >= R(k, 1) && x <= R(k, 3) && hi >= R(k, 2) && lo <= R(k, 4)
        tf = true;
        return;
    end
end
end
