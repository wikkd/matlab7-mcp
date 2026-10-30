function report = mcp_sim_route(model, opts)
%MCP_SIM_ROUTE  Re-route every line of one diagram layer as orthogonal
% polylines: no diagonal segments, no crossing through block bodies, and
% (v2) no running through block name labels. R14.
%   report = mcp_sim_route('model')                -> struct report
%   report = mcp_sim_route('model','spacing',30)   -> custom channel spacing
%
% v2 routing-quality rules (2026-10-30):
%   1. obstacles = inflated block bodies + visible name-label text rects
%      (R14 default label position is below the block; NameLocation is
%      honored where the block exposes it, masked blocks fall back to
%      bottom). Text width estimated at 7 px/char + 10 px padding.
%   2. a same-row line only stays straight when its run is actually clear;
%      otherwise it detours (v1 kept it straight unconditionally).
%   3. anchor-lane and go-around strategies now collision-check their
%      VERTICAL legs too (v1 checked horizontal runs only).
%   4. soft fallback: when no lane clears labels+bodies, retry with block
%      bodies only -- v2 is never worse than the label-blind v1.
%   5. rects/lines are collected at SearchDepth 1 only: subsystem-internal
%      Positions live in a different coordinate system and must not pollute
%      the root obstacle map (latent v1 bug, never triggered on flat
%      models).
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
%      branch anchor read back after a dummy set.
% Segments checked for collision: exit H, channel V, approach H, plus (v2)
% the vertical legs of anchor-lane and go-around detours.
% Branch lines ARE routed here; the anchor is honored so no branch-point
% association is broken.

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

% ------------- collect block rects of THIS layer (inflated) ----------
% SearchDepth 1 only: subsystem-internal Positions use a different
% coordinate system and would corrupt the obstacle map.
allPaths = find_system(model, 'SearchDepth', 1);
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

% ---------------- name-label text rects (v2) ----------------
% text width: real Java font metrics of the Simulink canvas font when
% available, else a 6 px/char conservative fallback (measured 4.7..6.5
% px/char on R14 models; the earlier 7 px/char guess over-blocked the
% corridors between labels and forced through-text fallbacks).
labelFontOK = false;
jfm = [];
try
    jtk = java.awt.Toolkit.getDefaultToolkit;
    jfm = jtk.getFontMetrics(java.awt.Font('Helvetica', 0, 10));
    jfm.stringWidth('test');
    labelFontOK = true;
catch
end
labelR = zeros(0, 4);
for b = 1:numel(allPaths)
    p = allPaths{b};
    try
        get_param(p, 'BlockType');
        nm = get_param(p, 'Name');
        r = get_param(p, 'Position');
    catch
        continue;
    end
    hide = 'off';
    try hide = get_param(p, 'HideName'); catch, end
    if strcmp(hide, 'on'), continue; end
    loc = 'bottom';   % R14 default; masked blocks do not expose NameLocation
    try loc = get_param(p, 'NameLocation'); catch, end
    cx = (r(1) + r(3)) / 2;
    cy = (r(2) + r(4)) / 2;
    if labelFontOK
        tw = jfm.stringWidth(nm) + 8;
    else
        tw = 6 * length(nm) + 10;
    end
    th = 14;
    switch loc
        case 'top'
            lr = [cx - tw/2, r(2) - th - 1, cx + tw/2, r(2) - 1];
        case 'left'
            lr = [r(1) - tw - 1, cy - th/2, r(1) - 1, cy + th/2];
        case 'right'
            lr = [r(3) + 1, cy - th/2, r(3) + tw + 1, cy + th/2];
        otherwise   % bottom
            lr = [cx - tw/2, r(4) + 1, cx + tw/2, r(4) + th + 1];
    end
    labelR(end+1, :) = round(lr); %#ok<AGROW>
end
Rfull = [R; labelR];

% ---------------- enumerate every line (trunk + branch) ----------------
% Each record: {dstLineHandle, dstPortHandle, isTrunk}
% trunk  = every dst row of a src outport's own line
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

% ---------------- group trunk recs by parent line handle -------------
uh = [];
udsts = {};
for r2 = 1:numel(recs)
    rec = recs{r2};
    if ~rec{3}, continue; end
    k = find(uh == rec{1}, 1);
    if isempty(k)
        uh(end+1) = rec{1}; %#ok<AGROW>
        udsts{end+1} = rec{2}; %#ok<AGROW>
    else
        udsts{k}(end+1) = rec{2}; %#ok<AGROW>
    end
end

% ---------------- route trunks first, then branches ----------------
nrouted = 0;
nkept = 0;
nfailed = 0;
njunc = 0;
juncSrc = [];
details = {};

% pass 1: trunks. A single-dst line is routed straight to its dst. A
% multi-dst line gets a JUNCTION STUB instead: the parent polyline ends at
% J = [port_x+12, port_y], and R14 anchors every dst's segment object at
% the parent's last point -- so all branches fork from a clean T right
% after the source port. (v1 re-routed the parent polyline toward its LAST
% dst, which dragged the junction to that dst's doorstep.)
for k = 1:numel(uh)
    h = uh(k);
    dsts = udsts{k};
    if numel(dsts) == 1
        % pin the anchor to its src port stub -- a tee dragged by an earlier
        % branch pass must not become the trunk's start point
        try
            spP = get_param(get_param(h, 'SrcPortHandle'), 'Position');
            spP = spP(1:2);
            Pc1 = get_param(h, 'Points');
            if ~isempty(Pc1) && (abs(Pc1(1, 1) - spP(1)) > 0.5 || ...
                                 abs(Pc1(1, 2) - spP(2)) > 0.5)
                set_param(h, 'Points', [spP; spP(1) + 16, spP(2)]);
            end
        catch
        end
        [okS, msg] = route_one(h, dsts(1), Rfull, R, spacing, true);
        if okS
            nrouted = nrouted + 1;
        elseif strcmp(msg, 'straight')
            nkept = nkept + 1;
        else
            nfailed = nfailed + 1;
            details{end+1} = msg; %#ok<AGROW>
        end
    else
        try
            spg = get_param(h, 'SrcPortHandle');
            spP = get_param(spg, 'Position');
            spP = spP(1:2);
            J = [spP(1) + 12, spP(2)];
            % v3.1: a dst on the port row BEHIND blockers would make its
            % segment same-row (sy==dy); R14 then forces the canonical
            % straight-elbow form and shears any detour into a diagonal
            % (probe E/F, 2026-10-30). When that case exists, drop the
            % junction below the source's own name label instead -- then
            % every segment of this port starts off-row and stays routable.
            needDrop = false;
            for d2 = 1:numel(dsts)
                dp2 = get_param(dsts(d2), 'Position');
                dp2 = dp2(1:2);
                if abs(dp2(2) - spP(2)) < 0.5 && ...
                        seg_blocked_h(J(1), dp2(1) - 12, spP(2), Rfull)
                    needDrop = true;
                    break;
                end
            end
            if needDrop
                sbh = get_param(spg, 'Parent');
                spos = get_param(sbh, 'Position');
                snm = get_param(sbh, 'Name');
                if labelFontOK
                    tw2 = jfm.stringWidth(snm) + 8;
                else
                    tw2 = 6 * length(snm) + 10;
                end
                jy = spos(4) + 15 + 6;              % below the label band
                for d2 = 1:numel(dsts)
                    dp2 = get_param(dsts(d2), 'Position');
                    if abs(jy - dp2(2)) < 2
                        jy = jy + 8;                % never land on a dst row
                    end
                end
                J = [max(spP(1) + 12, ...
                         (spos(1) + spos(3)) / 2 + tw2 / 2 + 6), jy];
                set_param(h, 'Points', [spP; J(1), spP(2); J]);
            else
                set_param(h, 'Points', [spP; J]);
            end
            juncSrc(end+1) = spg; %#ok<AGROW>
            njunc = njunc + 1;
        catch
        end
    end
end
% pass 2: branches (anchors depend on routed trunks)
for r2 = 1:numel(recs)
    rec = recs{r2};
    if rec{3}, continue; end
    % v2 junction hygiene for NON-junctioned parents only: a branch tee must
    % sit ON the trunk exit row right after the src port. Segments of a
    % junction-stub parent are anchored by the parent's own endpoint and
    % must not be touched here.
    try
        spg2 = get_param(rec{1}, 'SrcPortHandle');
        if isempty(find(juncSrc == spg2, 1))
            spP = get_param(spg2, 'Position');
            spP = spP(1:2);
            Pc2 = get_param(rec{1}, 'Points');
            if ~isempty(Pc2) && abs(Pc2(1, 2) - spP(2)) > 0.5
                tee = [spP(1) + 8, spP(2)];
                set_param(rec{1}, 'Points', [tee; tee(1) + 16, tee(2)]);
            end
        end
    catch
    end
    [okS, msg] = route_one(rec{1}, rec{2}, Rfull, R, spacing, false);
    if okS
        nrouted = nrouted + 1;
    elseif strcmp(msg, 'straight')
        nkept = nkept + 1;
    else
        nfailed = nfailed + 1;
        details{end+1} = msg; %#ok<AGROW>
    end
end
% pass 3: convergence - routing branches can drag a trunk's anchor to a new
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
        route_one(rec{1}, rec{2}, Rfull, R, spacing, rec{3});
    end
    if nfix == 0
        break;
    end
end

try
    save_system(model);
end

report = struct('model', model, 'routed', nrouted, 'kept', nkept, ...
    'failed', nfailed, 'ghost_lines', ndedup, ...
    'label_obstacles', size(labelR, 1), 'junctions', njunc, ...
    'details', {details});
end

% ======================================================================
function [ok, msg] = route_one(lineH, dstPort, Rfull, Rblk, spacing, isTrunk)
% Route one line, labels+bodies first, bodies-only as soft fallback.
[ok, msg] = route_attempt(lineH, dstPort, Rfull, spacing, isTrunk);
if ~ok && ~strcmp(msg, 'straight')
    [ok2, msg2] = route_attempt(lineH, dstPort, Rblk, spacing, isTrunk);
    if ok2
        ok = true;
        msg = '';
    else
        msg = msg2;
    end
end
end

% ======================================================================
function [ok, msg] = route_attempt(lineH, dstPort, R, spacing, isTrunk)
% Route one line as SAFE-Z against obstacle rect list R. ok=true if Points
% were (re)set; msg='straight' if already a clean straight line; otherwise
% msg carries the error.
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
    dp = dp(1:2);

    % v3.1 canonicalization probe: write a bare [P0; dp] and read back the
    % tail R14 appends. Port stub semantics vary by block type (README law
    % 4): for some ports get_param Position IS the dst point, for others it
    % is already the elbow (true dst = Position + (10,0)). Routing with the
    % wrong assumption puts our elbow point 10 px off R14's, which deletes
    % it and shears the final approach into a diagonal (exp6
    % Gain1/Gain_m/Constant_Ff, deterministic across runs).
    set_param(lineH, 'Points', [P0; dp]);
    Pp = get_param(lineH, 'Points');
    sx = Pp(1, 1);
    sy = Pp(1, 2);
    dx = Pp(end, 1);
    dy = Pp(end, 2);
    if size(Pp, 1) >= 3
        ex = Pp(end - 1, 1);   % R14's own elbow x for this port
    else
        ex = dx - 10;
    end

    % straight when R14's own canonical form is a clear same-row run
    if abs(sy - dy) < 0.5 && size(Pp, 1) <= 3 && ...
            ~seg_blocked_h(sx, dx, sy, R)
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
            % [P0; (c-8,P0y); (c,P0y); (c,Pny); (elbow,Pny)]
            % pair (c-8,c) survives R14 collinear compression on trunks
            P = [sx sy; cx - 8, sy; cx, sy; cx, dy; ex, dy];
        else
            % v3 segment pattern (probe-proven 2026-10-30): NO pair on the
            % exit row (a pair makes R14 drop the channel) and the middle
            % list MUST end at the canonical elbow -- R14 then appends dst
            % and stores the polyline verbatim.
            P = [sx sy; cx, sy; cx, dy; ex, dy];
        end
        P = dedup_pts(P);
        set_param(lineH, 'Points', P);
        % verify orthogonality of what R14 actually stored
        Pr = get_param(lineH, 'Points');
        if ~all_orthogonal(Pr)
            % v3.1: R14 replaced our tail with its canonical one -- learn
            % the true (dst, elbow) from the appended points and fall
            % through to the next strategy with calibrated values (Sum
            % inports fed from above/below have dst = dp +- 10 on the
            % approach COLUMN, which the bare-line probe cannot reveal).
            if size(Pr, 1) >= 2
                sx = Pr(1, 1);
                sy = Pr(1, 2);
                dx = Pr(end, 1);
                dy = Pr(end, 2);
                ex = Pr(end, 1);
            end
            chosen = [];
        else
            ok = true;
            msg = '';
            return;
        end
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
            if seg_blocked_h(min(sx, dx), max(sx, dx), cy2, R)
                continue;
            end
            % v2: both vertical legs must be clear as well
            if seg_blocked_v(sy, cy2, sx, R), continue; end
            if seg_blocked_v(cy2, dy, dx, R), continue; end
            laneY = cy2;
            break;
        end
        if laneY ~= 0
            % v3.1: BOTH kinds of line end at the calibrated elbow -- R14
            % force-normalizes the tail anyway and shears a mid-span final
            % point into a diagonal (exp6 Gain1/Gain_m regressions).
            P = [sx sy; sx laneY; ex, laneY; ex, dy];
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
            Pr = get_param(lineH, 'Points');
            if all_orthogonal(Pr)
                ok = true;
                msg = '';
                return;
            end
            if size(Pr, 1) >= 2
                sx = Pr(1, 1);
                sy = Pr(1, 2);
                dx = Pr(end, 1);
                dy = Pr(end, 2);
                ex = Pr(end, 1);
            end
            msg = 'anchor-lane sheared; falling through to go-around';
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
        % v3: SCAN lane rows across the span (step 8) instead of only the
        % blocker extremes -- the old laneUp/laneDn were computed from the
        % top/bottom of EVERY obstacle overlapping the x-span, so a long
        % same-row haul produced absurd candidates (e.g. y=+400 from a
        % label four rows below) while missing the clean corridors between
        % rows. Scan +-4*spacing around the signal rows; keep the old
        % extreme lanes only as last resorts.
        yLo = min(sy, dy) - 4 * spacing;
        yHi = max(sy, dy) + 4 * spacing;
        laneCands = [];
        yy2 = yHi;
        while yy2 >= yLo
            laneCands(end+1) = round(yy2); %#ok<AGROW>
            yy2 = yy2 - 8;
        end
        % nearest-the-signal-row first: small detours before big ones
        mid2 = (sy + dy) / 2;
        [tmp2, ord2] = sort(abs(laneCands - mid2));
        laneCands = laneCands(ord2); %#ok<NASGU>
        laneUp = top + max(12, spacing * 0.4);
        laneDn = bot - max(12, spacing * 0.4);
        laneCands = [laneCands, laneUp, laneDn, laneUp + 25, laneDn - 25, ...
                     laneUp + 50, laneDn - 50, laneUp + 75, laneDn - 75];
        for lc = 1:numel(laneCands)
            cyTry = laneCands(lc);
            if isempty(cyTry), continue; end
            if seg_blocked_h(sx, dx, cyTry, R), continue; end
            cxg = 0;
            for s4 = 0:10
                c4 = sx + s4 * 8;
                if ~seg_blocked_v(sy, cyTry, c4, R)
                    cxg = c4;
                    break;
                end
            end
            if cxg == 0, continue; end
            if seg_blocked_v(cyTry, dy, ex, R), continue; end
            % Lane pattern (proven): vertical at channel x, lane row, then
            % the canonical elbow (dx-10) and vertical to the dst row.
            % Trunks keep the (c-8,c) pairs vs collinear compression;
            % segments (v3) drop them and end at the elbow like B/C/D.
            if isTrunk
                P = [sx sy; cxg - 8, sy; cxg, sy; cxg, cyTry; ...
                     ex - 8, cyTry; ex, cyTry; ex, dy];
            else
                P = [sx sy; cxg, sy; cxg, cyTry; ex, cyTry; ex, dy];
            end
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
            Pr = get_param(lineH, 'Points');
            if all_orthogonal(Pr)
                ok = true;
                msg = '';
                return;
            end
            if size(Pr, 1) >= 2
                sx = Pr(1, 1);
                sy = Pr(1, 2);
                dx = Pr(end, 1);
                dy = Pr(end, 2);
                ex = Pr(end, 1);
            end
        end
    end

    msg = 'no clear channel found; left unchanged';
catch
    msg = ['route_attempt failed: ', lasterr];
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
