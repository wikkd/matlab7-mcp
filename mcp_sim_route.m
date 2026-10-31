function report = mcp_sim_route(model, opts)
%MCP_SIM_ROUTE  Re-route every line of one diagram layer as orthogonal
% polylines: no diagonal segments, no crossing through block bodies or name
% labels, and (v4) no two lines of different families running on top of
% each other. R14.
%   report = mcp_sim_route('model')                -> struct report
%   report = mcp_sim_route('model','spacing',30)   -> custom channel spacing
%
% v4 line-line avoidance (2026-10-31), adopting the official Simulink
% objective ("avoid overlap with blocks, annotations, and other signal
% lines", see docs/routing-design-notes.md):
%   1. WIRE MAP: every routed line's segments are tracked as thin rects
%      tagged with a family id (= its src port handle). Parent + its branch
%      segments share a family, so their legal tee overlaps are exempt.
%   2. SOFT AVOIDANCE: candidate channels (x) and lanes (y) already occupied
%      by another family with overlapping span are tried LAST -- soft, so
%      the router can never over-constrain itself.
%   3. NUDGE PASS: after convergence, middle segments (ordinal >= 2) of two
%      different families sharing a corridor (same row/col, > 6 px overlap)
%      are separated by re-routing the later line with the colliding
%      coordinate HARD-banned; on failure the previous geometry is restored.
%      Two sweeps max.
%   report.super_before / super_after / nudged quantify the pass.
%
% v3 routing-quality rules (2026-10-30/31, unchanged):
%   1. obstacles = inflated block bodies + visible name-label text rects
%   2. a same-row line only stays straight when its run is actually clear
%   3. anchor-lane and go-around strategies collision-check vertical legs
%   4. soft fallback: when no lane clears labels+bodies, retry with block
%      bodies only -- never worse than the label-blind v1
%   5. rects/lines collected at SearchDepth 1 only (subsystem coordinate
%      systems must not pollute the root obstacle map)
%   6. canonicalization probe: a bare [P0;dp] set reads back R14's own
%      canonical tail to calibrate the true elbow/dst per port; if a set is
%      still sheared the router learns (dst,elbow) from the appended points
%      and retries the next strategy calibrated
%   7. multi-dst ports get a junction stub (all branches fork at a clean T
%      right after the source port); same-row branch segments shear into
%      diagonals in R14, so the junction drops below the source label when
%      one dst sits on the port row behind blockers
%
% R14 line semantics (probe-verified, see README "line-semantics laws"):
% trunk SAFE-Z needs the (c-8,c) pair vs collinear compression, segments
% must not use it; every middle list must end at the calibrated elbow;
% Points(1,:) is forced to the line anchor; branch anchors follow the
% parent polyline's last point.

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

% ---------------- name-label text rects ----------------
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
    loc = 'bottom';
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
        otherwise
            lr = [cx - tw/2, r(4) + 1, cx + tw/2, r(4) + th + 1];
    end
    labelR(end+1, :) = round(lr); %#ok<AGROW>
end
Rfull = [R; labelR];

% ---------------- enumerate every line (trunk + branch) ----------------
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

% v4 wire map: segments of every routed line
wireA = zeros(0, 4);   % [x1 y1 x2 y2] normalized (H: y1==y2, V: x1==x2)
wireFam = [];          % family id = src port handle of the owning line
wireLine = [];         % owning line handle
wireOrd = [];          % segment ordinal in the polyline (1 = exit rung)
wireLast = [];         % 1 = approach segment (R14 canonical, unmovable)

% pass 1: trunks
for k = 1:numel(uh)
    h = uh(k);
    dsts = udsts{k};
    if numel(dsts) == 1
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
        [okS, msg] = route_one(h, dsts(1), Rfull, R, spacing, true, ...
                               wireA, wireFam, [], []);
        if okS
            nrouted = nrouted + 1;
        elseif strcmp(msg, 'straight')
            nkept = nkept + 1;
        else
            nfailed = nfailed + 1;
            details{end+1} = msg; %#ok<AGROW>
        end
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, h);
    else
        try
            spg = get_param(h, 'SrcPortHandle');
            spP = get_param(spg, 'Position');
            spP = spP(1:2);
            J = [spP(1) + 12, spP(2)];
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
                jy = spos(4) + 15 + 6;
                for d2 = 1:numel(dsts)
                    dp2 = get_param(dsts(d2), 'Position');
                    if abs(jy - dp2(2)) < 2
                        jy = jy + 8;
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
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, h);
    end
end
% pass 2: branches (anchors depend on routed trunks)
for r2 = 1:numel(recs)
    rec = recs{r2};
    if rec{3}, continue; end
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
    [okS, msg] = route_one(rec{1}, rec{2}, Rfull, R, spacing, false, ...
                           wireA, wireFam, [], []);
    if okS
        nrouted = nrouted + 1;
    elseif strcmp(msg, 'straight')
        nkept = nkept + 1;
    else
        nfailed = nfailed + 1;
        details{end+1} = msg; %#ok<AGROW>
    end
    [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
        wireFam, wireLine, wireOrd, wireLast, rec{1});
end
% pass 3: convergence - re-read anchors and re-route anything now
% non-orthogonal. Max 2 sweeps.
for sweep = 1:2
    nfix = 0;
    for r2 = 1:numel(recs)
        rec = recs{r2};
        Pcur = get_param(rec{1}, 'Points');
        if isempty(Pcur) || all_orthogonal(Pcur)
            continue;
        end
        nfix = nfix + 1;
        route_one(rec{1}, rec{2}, Rfull, R, spacing, rec{3}, ...
                  wireA, wireFam, [], []);
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, rec{1});
    end
    if nfix == 0
        break;
    end
end

% ---------------- pass 4: wire separation (v4 nudge) ----------------
% Middle segments (ordinal >= 2) of two different families sharing a
% corridor are separated by re-routing the later line with the colliding
% coordinate hard-banned. Two sweeps max; failures restore the previous
% geometry, so the pass can only improve.
nSuper0 = wire_count_super(wireA, wireFam, wireLine, wireOrd, wireLast);
nNudged = 0;
for sweep = 1:2
    [ns, fixes] = wire_super_fixes(wireA, wireFam, wireLine, wireOrd, wireLast);
    if ns == 0
        break;
    end
    did = false;
    handled = [];
    for f = 1:numel(fixes)
        fx = fixes{f};
        h = fx{1};
        if ~isempty(find(handled == h, 1)), continue; end
        handled(end+1) = h; %#ok<AGROW>
        recN = [];
        for r2 = 1:numel(recs)
            if recs{r2}{1} == h
                recN = recs{r2};
                break;
            end
        end
        if isempty(recN), continue; end
        Pold = [];
        try Pold = get_param(h, 'Points'); catch, end
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_del(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, h);
        if fx{2} == 1
            [okS, msgN] = route_one(h, recN{2}, Rfull, R, spacing, ...
                                    recN{3}, wireA, wireFam, fx{3}, []);
        else
            [okS, msgN] = route_one(h, recN{2}, Rfull, R, spacing, ...
                                    recN{3}, wireA, wireFam, [], fx{3});
        end
        if okS || strcmp(msgN, 'straight')
            nNudged = nNudged + 1;
            did = true;
        else
            if ~isempty(Pold)
                try set_param(h, 'Points', Pold); catch, end
            end
        end
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, h);
    end
    if ~did
        break;
    end
    % anchors may have been dragged by the re-routes: re-converge
    for r2 = 1:numel(recs)
        rec = recs{r2};
        Pcur = get_param(rec{1}, 'Points');
        if isempty(Pcur) || all_orthogonal(Pcur)
            continue;
        end
        route_one(rec{1}, rec{2}, Rfull, R, spacing, rec{3}, ...
                  wireA, wireFam, [], []);
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, rec{1});
    end
end
nSuper1 = wire_count_super(wireA, wireFam, wireLine, wireOrd, wireLast);

try
    save_system(model);
end

report = struct('model', model, 'routed', nrouted, 'kept', nkept, ...
    'failed', nfailed, 'ghost_lines', ndedup, ...
    'label_obstacles', size(labelR, 1), 'junctions', njunc, ...
    'super_before', nSuper0, 'super_after', nSuper1, 'nudged', nNudged, ...
    'details', {details});
end

% ======================================================================
function [ok, msg] = route_one(lineH, dstPort, Rfull, Rblk, spacing, ...
                               isTrunk, wireA, wireFam, hardBanX, hardBanY)
% Route one line, labels+bodies first, bodies-only as soft fallback.
if nargin < 9, hardBanX = []; end
if nargin < 10, hardBanY = []; end
[ok, msg] = route_attempt(lineH, dstPort, Rfull, spacing, isTrunk, ...
                          wireA, wireFam, hardBanX, hardBanY);
if ~ok && ~strcmp(msg, 'straight')
    [ok2, msg2] = route_attempt(lineH, dstPort, Rblk, spacing, isTrunk, ...
                                wireA, wireFam, hardBanX, hardBanY);
    if ok2
        ok = true;
        msg = '';
    else
        msg = msg2;
    end
end
end

% ======================================================================
function [ok, msg] = route_attempt(lineH, dstPort, R, spacing, isTrunk, ...
                                   wireA, wireFam, hardBanX, hardBanY)
% Route one line as SAFE-Z against obstacle rect list R. ok=true if Points
% were (re)set; msg='straight' if already a clean straight line; otherwise
% msg carries the error.
ok = false;
msg = '';
try
    Pcur = get_param(lineH, 'Points');
    if isempty(Pcur)
        msg = 'line has no Points (unconnected?)';
        return;
    end
    P0 = Pcur(1, :);
    dp = get_param(dstPort, 'Position');
    dp = dp(1:2);

    % v3.1 canonicalization probe: write a bare [P0; dp] and read back the
    % tail R14 appends -- calibrates the true elbow/dst for this port.
    set_param(lineH, 'Points', [P0; dp]);
    Pp = get_param(lineH, 'Points');
    sx = Pp(1, 1);
    sy = Pp(1, 2);
    dx = Pp(end, 1);
    dy = Pp(end, 2);
    if size(Pp, 1) >= 3
        ex = Pp(end - 1, 1);
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

    % v4: soft lane/channel bans from already-routed lines of other
    % families. A V channel at an x another family's V segment occupies with
    % overlapping y-span would run on top of it; same for H lanes. Soft =
    % tried last, so this can never over-constrain. Hard bans (nudge pass)
    % are skipped entirely.
    softX = [];
    softY = [];
    myFam = 0;
    try myFam = get_param(lineH, 'SrcPortHandle'); catch, end
    for w = 1:size(wireA, 1)
        if wireFam(w) == myFam, continue; end
        sw = wireA(w, :);
        if sw(1) == sw(3)
            if sw(2) < max(sy, dy) - 4 && sw(4) > min(sy, dy) + 4
                softX(end+1) = sw(1); %#ok<AGROW>
            end
        else
            if sw(1) < max(sx, dx) - 4 && sw(3) > min(sx, dx) + 4
                softY(end+1) = sw(2); %#ok<AGROW>
            end
        end
    end
    softY = setdiff(softY, [sy, dy]);

    % candidate channels: open interval between anchor x and dst x, ordered
    % by distance from the anchor exit.
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
    cands = cands_keep(cands, softX, hardBanX);

    % SAFE-Z: exit horizontal at y=sy to channel c, vertical to y=dy,
    % approach horizontal to dst.
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
            P = [sx sy; cx - 8, sy; cx, sy; cx, dy; ex, dy];
        else
            P = [sx sy; cx, sy; cx, dy; ex, dy];
        end
        P = dedup_pts(P);
        set_param(lineH, 'Points', P);
        Pr = get_param(lineH, 'Points');
        if ~all_orthogonal(Pr)
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

    % anchor-vertical lane: drop at the anchor x, run horizontally on a
    % clear lane, then enter the dst.
    if isempty(chosen)
        laneList = [];
        for s2 = 1:10
            cy2 = dy - s2 * 10 * sign(dy - sy);
            if cy2 == sy, continue; end
            laneList(end+1) = cy2; %#ok<AGROW>
        end
        laneList = cands_keep(laneList, softY, hardBanY);
        laneY = 0;
        for t5 = 1:numel(laneList)
            cy2 = laneList(t5);
            if seg_blocked_h(min(sx, dx), max(sx, dx), cy2, R)
                continue;
            end
            if seg_blocked_v(sy, cy2, sx, R), continue; end
            if seg_blocked_v(cy2, dy, dx, R), continue; end
            laneY = cy2;
            break;
        end
        if laneY ~= 0 && ex < dx - 0.5
            % real canonical elbow discovered: the descent may leave it,
            % but the stored tail must still END at (ex, dy) -- R14 rewrites
            % the last point to the canonical elbow otherwise (shear).
            X2 = ex_pick(wireA, wireFam, myFam, ex, laneY, dy, R);
            if isempty(X2) || seg_blocked_h(min(sx, X2), max(sx, X2), ...
                    laneY, R)
                laneY = 0;   % every entry column blocked; try go-around
            end
        end
        if laneY ~= 0
            P = [sx sy; sx laneY; X2, laneY; X2, dy; ex, dy];
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

    % go-around lane above/below blockers in the span.
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
        yLo = min(sy, dy) - 4 * spacing;
        yHi = max(sy, dy) + 4 * spacing;
        laneCands = [];
        yy2 = yHi;
        while yy2 >= yLo
            laneCands(end+1) = round(yy2); %#ok<AGROW>
            yy2 = yy2 - 8;
        end
        mid2 = (sy + dy) / 2;
        [tmp2, ord2] = sort(abs(laneCands - mid2));
        laneCands = laneCands(ord2); %#ok<NASGU>
        laneUp = top + max(12, spacing * 0.4);
        laneDn = bot - max(12, spacing * 0.4);
        laneCands = [laneCands, laneUp, laneDn, laneUp + 25, laneDn - 25, ...
                     laneUp + 50, laneDn - 50, laneUp + 75, laneDn - 75];
        laneCands = cands_keep(laneCands, softY, hardBanY);
        global DBGR gaRow gaCxg gaX2 gaExt gaSet gaLast
        gaRow = 0; gaCxg = 0; gaX2 = 0; gaExt = 0; gaSet = 0; gaLast = 0;
        for lc = 1:numel(laneCands)
            cyTry = laneCands(lc);
            if isempty(cyTry), continue; end
            if seg_blocked_h(sx, dx, cyTry, R)
                gaRow = gaRow + 1;
                continue;
            end
            cxg = 0;
            cxgFB = 0;
            for s4 = 0:10
                c4 = sx + s4 * 8;
                if seg_blocked_v(sy, cyTry, c4, R), continue; end
                if ~isempty(find(abs(hardBanX - c4) < 4, 1)), continue; end
                if isempty(find(abs(softX - c4) < 4, 1))
                    cxg = c4;
                    break;
                end
                if cxgFB == 0, cxgFB = c4; end
            end
            if cxg == 0, cxg = cxgFB; end
            if cxg == 0
                gaCxg = gaCxg + 1;
                continue;
            end
            if ex < dx - 0.5
                % real canonical elbow discovered: descent may leave it, but
                % the stored tail must still END at (ex, dy) -- R14 rewrites
                % the last point to the canonical elbow otherwise (shear).
                X2 = ex_pick(wireA, wireFam, myFam, ex, cyTry, dy, R);
            else
                X2 = ex;   % vertical-entry port: descent must stay at dx
            end
            if isempty(X2)
                gaX2 = gaX2 + 1;
                continue;
            end
            if seg_blocked_h(min([sx, dx, X2 - 8]), ...
                    max([sx, dx, X2 - 8]), cyTry, R)
                gaExt = gaExt + 1;
                gaLast = cyTry;
                continue;
            end
            if isTrunk
                P = [sx sy; cxg - 8, sy; cxg, sy; cxg, cyTry; ...
                     X2 - 8, cyTry; X2, cyTry; X2, dy; ex, dy];
            else
                P = [sx sy; cxg, sy; cxg, cyTry; X2, cyTry; X2, dy; ex, dy];
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
            gaSet = gaSet + 1;
            gaLast = cyTry;
        end
    end

    global DBGR
    if ~isempty(DBGR)
        fprintf('ROUTE-FAIL (%d,%d)->(%d,%d) ex=%d trunk=%d laneC=%d: row=%d cxg=%d x2=%d ext=%d set=%d lastLane=%d\n', ...
            sx, sy, dx, dy, ex, isTrunk, numel(laneCands), gaRow, gaCxg, ...
            gaX2, gaExt, gaSet, gaLast);
    end
    msg = 'no clear channel found; left unchanged';
catch
    msg = ['route_attempt failed: ', lasterr];
end
end

% ------------------------------------------------------------------
function out = cands_keep(cands, softVals, hardVals)
% v4 candidate ordering: drop hard-banned entirely; move soft-occupied to
% the back (preserving the original preference order otherwise).
out = [];
lastC = [];
for k = 1:numel(cands)
    cv = cands(k);
    if ~isempty(hardVals) && ~isempty(find(abs(hardVals - cv) < 4, 1))
        continue;
    end
    if ~isempty(softVals) && ~isempty(find(abs(softVals - cv) < 4, 1))
        lastC(end+1) = cv; %#ok<AGROW>
    else
        out(end+1) = cv; %#ok<AGROW>
    end
end
out = [out, lastC];
end

% ------------------------------------------------------------------
function X = ex_pick(wireA, wireFam, myFam, exBase, ty, dy, R)
% v4.1 entry-descent de-confliction. R14 pins every stored tail to the
% canonical elbow (dst_x-10, dst_y), so all lines entering a block-edge
% column used to descend the SAME vertical lane and stack on top of each
% other. Probe-verified shape shift: descend at X < dx-10, then run along
% the dst row to the canonical elbow -- R14 keeps it orthogonal. Prefer the
% canonical column; step left in 10 px while another family's V segment
% overlaps the descent span, or the dst-row rung would overlap another
% family's H segment, or blocks/labels sit on the descent. Returns the
% first wire-occupied-but-unblocked column as soft fallback, [] when every
% candidate is block-blocked (caller skips the lane).
spanLo = min(ty, dy);
spanHi = max(ty, dy);
X = [];
Xfb = [];
for k = 0:6
    xc = exBase - 10 * k;
    if seg_blocked_v(spanLo, spanHi, xc, R)
        continue;
    end
    occ = false;
    for w = 1:size(wireA, 1)
        if wireFam(w) == myFam, continue; end
        sw = wireA(w, :);
        if sw(1) == sw(3) && abs(sw(1) - xc) < 0.5
            lo = max(min(sw(2), sw(4)), spanLo);
            hi = min(max(sw(2), sw(4)), spanHi);
            if hi - lo > 6
                occ = true;
                break;
            end
        end
        if sw(2) == sw(4) && abs(sw(2) - dy) < 0.5
            lo = max(min(sw(1), sw(3)), min(xc, exBase));
            hi = min(max(sw(1), sw(3)), max(xc, exBase));
            if hi - lo > 6
                occ = true;
                break;
            end
        end
    end
    if isempty(Xfb)
        Xfb = xc;
    end
    if ~occ
        X = xc;
        break;
    end
end
if isempty(X)
    X = Xfb;
end
end

% ------------------------------------------------------------------
function [A, F, L, O, W] = wire_add(A, F, L, O, W, lineH)
% (Re-)register one line's segments into the wire map. W marks the approach
% segment (last ordinal) -- R14 canonicalizes it, so it is unmovable.
[A, F, L, O, W] = wire_del(A, F, L, O, W, lineH);
try
    P = get_param(lineH, 'Points');
    fam = get_param(lineH, 'SrcPortHandle');
catch
    return;
end
if isempty(P) || size(P, 1) < 2, return; end
ax = P(1, 1);
ay = P(1, 2);
for k = 2:size(P, 1)
    x1 = P(k-1, 1); y1 = P(k-1, 2);
    x2 = P(k, 1);   y2 = P(k, 2);
    if abs(y1 - y2) < 0.5
        s = [min(x1, x2), y1, max(x1, x2), y1];
    else
        s = [x1, min(y1, y2), x1, max(y1, y2)];
    end
    A(end+1, :) = s; %#ok<AGROW>
    F(end+1) = fam;  %#ok<AGROW>
    L(end+1) = lineH; %#ok<AGROW>
    O(end+1) = k - 1; %#ok<AGROW>
    forced = 0;
    if k >= size(P, 1) - 1
        forced = 1;   % last two segments: approach rung + canonical elbow
    end               % column/stub are R14-forced, unmovable
    if ~forced
        % exit run: collinear with the anchor point -- its row/column is
        % the port's, also unmovable (includes the (c-8,c) pair rows)
        if (abs(y1 - y2) < 0.5 && abs(y1 - ay) < 0.5) || ...
                (abs(x1 - x2) < 0.5 && abs(x1 - ax) < 0.5)
            forced = 1;
        end
    end
    W(end+1) = forced;
end
end

% ------------------------------------------------------------------
function [A, F, L, O, W] = wire_del(A, F, L, O, W, lineH)
kill = find(L == lineH);
A(kill, :) = [];
F(kill) = [];
L(kill) = [];
O(kill) = [];
W(kill) = [];
end

% ------------------------------------------------------------------
function [ns, fixes] = wire_super_fixes(A, F, L, O, W)
% Superposing segments of two different families (both ordinal >= 2). The
% nudge target is always a MOVABLE side: if one segment is the approach rung
% (last ordinal, R14-canonical), the other one moves; when both are forced
% the pair is skipped (official Simulink renders those merged too). The fix
% bans the SHARED corridor coordinate for the movable line.
ns = 0;
fixes = {};
n = size(A, 1);
for i = 1:n
    if O(i) <= 1, continue; end
    for j = i+1:n
        if O(j) <= 1, continue; end
        if F(i) == F(j), continue; end
        si = A(i, :);
        sj = A(j, :);
        if si(1) == si(3) && sj(1) == sj(3) && abs(si(1) - sj(1)) < 2
            ov = min(si(4), sj(4)) - max(si(2), sj(2));
            if ov > 6
                if W(i) && W(j)
                    continue;   % both canonical approach columns
                end
                ns = ns + 1;
                if W(j)
                    fixes{end+1} = {L(i), 1, sj(1)}; %#ok<AGROW>
                else
                    fixes{end+1} = {L(j), 1, si(1)}; %#ok<AGROW>
                end
            end
        elseif si(1) ~= si(3) && sj(1) ~= sj(3) && abs(si(2) - sj(2)) < 2
            ov = min(si(3), sj(3)) - max(si(1), sj(1));
            if ov > 6
                if W(i) && W(j)
                    continue;
                end
                ns = ns + 1;
                if W(j)
                    fixes{end+1} = {L(i), 2, sj(2)}; %#ok<AGROW>
                else
                    fixes{end+1} = {L(j), 2, si(2)}; %#ok<AGROW>
                end
            end
        end
    end
end
end

% ------------------------------------------------------------------
function ns = wire_count_super(A, F, L, O, W)
ns = 0;
n = size(A, 1);
for i = 1:n
    if O(i) <= 1, continue; end
    for j = i+1:n
        if O(j) <= 1, continue; end
        if F(i) == F(j), continue; end
        if W(i) && W(j)
            continue;   % both canonical approach segments: official-normal
        end
        si = A(i, :);
        sj = A(j, :);
        if si(1) == si(3) && sj(1) == sj(3) && abs(si(1) - sj(1)) < 2
            if min(si(4), sj(4)) - max(si(2), sj(2)) > 6
                ns = ns + 1;
            end
        elseif si(1) ~= si(3) && sj(1) ~= sj(3) && abs(si(2) - sj(2)) < 2
            if min(si(3), sj(3)) - max(si(1), sj(1)) > 6
                ns = ns + 1;
            end
        end
    end
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
