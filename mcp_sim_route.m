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

% v5 A* options threaded to route_one -> route_astar
aopts = struct('method', 'astar', 'bend', 60, 'cross', 20, ...
               'congest', 8, 'budget', 30000, 'span', 2 * spacing);
if isfield(opts, 'method'), aopts.method = opts.method; end
if isfield(opts, 'bend'), aopts.bend = opts.bend; end
if isfield(opts, 'cross'), aopts.cross = opts.cross; end
if isfield(opts, 'congest'), aopts.congest = opts.congest; end

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

% ------------- v6: relocate labels off vertical-entry corridors ------
% A block whose input port sits on its top/bottom edge can only be wired
% from that outer side; a name printed on the same side sits exactly in
% the mandatory approach corridor (R14 prints bottom labels 1..15 px below
% the body). Move such names to the left side BEFORE routing so no wire
% ever has to cross its own label.
for b = 1:numel(allPaths)
    p = allPaths{b};
    if strcmp(p, model), continue; end
    try
        get_param(p, 'BlockType');
        lhv = get_param(p, 'LineHandles');
        rv = get_param(p, 'Position');
        locv = get_param(p, 'NameLocation');
    catch
        continue;
    end
    if ~any(strcmp(locv, {'bottom', 'top'})), continue; end
    entrySide = 0;   % +1 bottom edge, -1 top edge
    for s = 1:numel(lhv.Inport)
        hLine = lhv.Inport(s);
        if hLine == -1 || hLine == 0, continue; end
        try
            ppv = get_param(hLine, 'DstPortHandle');
            if isempty(ppv) || ppv(1) == -1, continue; end
            dposv = get_param(ppv(1), 'Position');
        catch
            continue;
        end
        if abs(dposv(2) - rv(4)) <= 1
            entrySide = 1;
        elseif abs(dposv(2) - rv(2)) <= 1
            entrySide = -1;
        end
    end
    if entrySide == 1 && strcmp(locv, 'bottom')
        set_param(p, 'NameLocation', 'left');
    elseif entrySide == -1 && strcmp(locv, 'top')
        set_param(p, 'NameLocation', 'left');
    end
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
labelPath = {};
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
    labelPath{end+1} = p; %#ok<AGROW>
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

% v5: most-constrained-first ordering -- multi-dst nets, then longest span
if ~isempty(uh)
    keyU = zeros(size(uh));
    for k2 = 1:numel(uh)
        spk = [];
        try
            spk = get_param(get_param(uh(k2), 'SrcPortHandle'), 'Position');
        catch
        end
        spank = 0;
        if ~isempty(spk)
            for d3 = 1:numel(udsts{k2})
                dpk = get_param(udsts{k2}(d3), 'Position');
                dpk = dpk(1:2);
                spank = max(spank, abs(dpk(1) - spk(1)) + ...
                                abs(dpk(2) - spk(2)));
            end
        end
        keyU(k2) = 100000 * numel(udsts{k2}) + spank;
    end
    [tmpK, ordK] = sort(keyU, 'descend'); %#ok<NASGU>
    uh = uh(ordK);
    udsts = udsts(ordK);
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
                               wireA, wireFam, [], [], aopts);
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
                           wireA, wireFam, [], [], aopts);
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
                  wireA, wireFam, [], [], aopts);
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
                                    recN{3}, wireA, wireFam, fx{3}, [], aopts);
        else
            [okS, msgN] = route_one(h, recN{2}, Rfull, R, spacing, ...
                                    recN{3}, wireA, wireFam, [], fx{3}, aopts);
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
                  wireA, wireFam, [], [], aopts);
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, rec{1});
    end
end
nSuper1 = wire_count_super(wireA, wireFam, wireLine, wireOrd, wireLast);

% ---------------- pass 5: label-repair (v6) ----------------
% A routed wire grazing a block name means the name sits in a corridor.
% Flip the name to the free side (guarding against the side a vertical
% entry needs), rebuild the label rects, and re-route only the grazing
% lines. Two rounds max; whatever still grazes is reported honestly.
nLabFix = 0;
for round5 = 1:2
    hitLbl = [];
    hitRec = [];
    for li = 1:size(labelR, 1)
        lr5 = labelR(li, :);
        for r5 = 1:numel(recs)
            P5 = get_param(recs{r5}{1}, 'Points');
            if size(P5, 1) < 2, continue; end
            hit5 = false;
            for j5 = 3:size(P5, 1)   % skip the R14 exit-stub pair (j=1,2)
                if abs(P5(j5,2) - P5(j5-1,2)) < 0.5
                    yy5 = P5(j5,2);
                    if yy5 >= lr5(2)-0.5 && yy5 <= lr5(4)+0.5 && ...
                       max(P5(j5,1), P5(j5-1,1)) > lr5(1)+0.5 && ...
                       min(P5(j5,1), P5(j5-1,1)) < lr5(3)-0.5
                        hit5 = true;
                    end
                else
                    xx5 = P5(j5,1);
                    if xx5 >= lr5(1)-0.5 && xx5 <= lr5(3)+0.5 && ...
                       max(P5(j5,2), P5(j5-1,2)) > lr5(2)+0.5 && ...
                       min(P5(j5,2), P5(j5-1,2)) < lr5(4)-0.5
                        hit5 = true;
                    end
                end
                if hit5
                    if isempty(find(hitLbl == li & hitRec == r5, 1))
                        hitLbl(end+1) = li; %#ok<AGROW>
                        hitRec(end+1) = r5; %#ok<AGROW>
                    end
                    break;
                end
            end
        end
    end
    if isempty(hitLbl)
        break;
    end
    % flip each hit label once (same side-guard as the pre-pass)
    uLbl = unique(hitLbl);
    flippedAny = false;
    for t5 = 1:numel(uLbl)
        li = uLbl(t5);
        p5 = labelPath{li};
        try
            loc5 = get_param(p5, 'NameLocation');
            rv5 = get_param(p5, 'Position');
            lhv5 = get_param(p5, 'LineHandles');
            entrySide = 0;
            for s5 = 1:numel(lhv5.Inport)
                hLine5 = lhv5.Inport(s5);
                if hLine5 == -1 || hLine5 == 0, continue; end
                try
                    ppv5 = get_param(hLine5, 'DstPortHandle');
                    if isempty(ppv5) || ppv5(1) == -1, continue; end
                    dpos5 = get_param(ppv5(1), 'Position');
                catch
                    continue;
                end
                if abs(dpos5(2) - rv5(4)) <= 1
                    entrySide = 1;
                elseif abs(dpos5(2) - rv5(2)) <= 1
                    entrySide = -1;
                end
            end
            newLoc = '';
            if strcmp(loc5, 'bottom') && entrySide ~= -1
                newLoc = 'top';
            elseif strcmp(loc5, 'top') && entrySide ~= 1
                newLoc = 'bottom';
            elseif any(strcmp(loc5, {'bottom', 'top'}))
                newLoc = 'left';
            end
            if ~isempty(newLoc)
                set_param(p5, 'NameLocation', newLoc);
                nLabFix = nLabFix + 1;
                flippedAny = true;
            end
        catch
        end
    end
    if ~flippedAny
        break;
    end
    % rebuild label rects (cheap) and re-route only the grazing lines
    labelR = zeros(0, 4);
    for b5 = 1:numel(labelPath)
        p5 = labelPath{b5};
        try
            nm5 = get_param(p5, 'Name');
            r5b = get_param(p5, 'Position');
            loc5b = get_param(p5, 'NameLocation');
        catch
            continue;
        end
        cx5 = (r5b(1) + r5b(3)) / 2;
        cy5 = (r5b(2) + r5b(4)) / 2;
        if labelFontOK
            tw5 = jfm.stringWidth(nm5) + 8;
        else
            tw5 = 6 * length(nm5) + 10;
        end
        switch loc5b
            case 'top'
                lr5b = [cx5 - tw5/2, r5b(2) - 15, cx5 + tw5/2, r5b(2) - 1];
            case 'left'
                lr5b = [r5b(1) - tw5 - 1, cy5 - 7, r5b(1) - 1, cy5 + 7];
            case 'right'
                lr5b = [r5b(3) + 1, cy5 - 7, r5b(3) + tw5 + 1, cy5 + 7];
            otherwise
                lr5b = [cx5 - tw5/2, r5b(4) + 1, cx5 + tw5/2, r5b(4) + 15];
        end
        labelR(end+1, :) = round(lr5b); %#ok<AGROW>
    end
    Rfull = [R; labelR];
    uRec = unique(hitRec);
    for t5 = 1:numel(uRec)
        r5 = uRec(t5);
        route_one(recs{r5}{1}, recs{r5}{2}, Rfull, R, spacing, ...
                  recs{r5}{3}, wireA, wireFam, [], [], aopts);
        [wireA, wireFam, wireLine, wireOrd, wireLast] = wire_add(wireA, ...
            wireFam, wireLine, wireOrd, wireLast, recs{r5}{1});
    end
end

try
    save_system(model);
end

report = struct('model', model, 'routed', nrouted, 'kept', nkept, ...
    'failed', nfailed, 'ghost_lines', ndedup, ...
    'label_obstacles', size(labelR, 1), 'junctions', njunc, ...
    'super_before', nSuper0, 'super_after', nSuper1, 'nudged', nNudged, ...
    'label_fixes', nLabFix, 'details', {details});
end

% ======================================================================
function [ok, msg] = route_one(lineH, dstPort, Rfull, Rblk, spacing, ...
                               isTrunk, wireA, wireFam, hardBanX, hardBanY, ...
                               aopts)
% Route one line: v5 A* first, then patterns, labels+bodies fallback.
% Every failure path restores the pre-attempt geometry (minimum disturbance:
% a failed route must never leave a mutated shape behind).
if nargin < 9, hardBanX = []; end
if nargin < 10, hardBanY = []; end
if nargin < 11
    aopts = struct('method', 'pattern', 'bend', 60, 'cross', 20, ...
                   'congest', 8, 'budget', 30000, 'span', 180);
end
Psave = [];
try Psave = get_param(lineH, 'Points'); catch, end
[ok, msg] = route_attempt(lineH, dstPort, Rfull, spacing, isTrunk, ...
                          wireA, wireFam, hardBanX, hardBanY, aopts);
if ~ok && ~strcmp(msg, 'straight')
    [ok2, msg2] = route_attempt(lineH, dstPort, Rblk, spacing, isTrunk, ...
                                wireA, wireFam, hardBanX, hardBanY, aopts);
    if ok2
        ok = true;
        msg = '';
    else
        msg = msg2;
    end
end
if ~ok && ~strcmp(msg, 'straight') && ~isempty(Psave)
    try set_param(lineH, 'Points', Psave); catch, end
end
end

% ======================================================================
function [ok, msg] = route_attempt(lineH, dstPort, R, spacing, isTrunk, ...
                                   wireA, wireFam, hardBanX, hardBanY, aopts)
% Route one line as SAFE-Z against obstacle rect list R. ok=true if Points
% were (re)set; msg='straight' if already a clean straight line; otherwise
% msg carries the error.
if nargin < 10
    aopts = struct('method', 'pattern', 'bend', 60, 'cross', 20, ...
                   'congest', 8, 'budget', 30000, 'span', 180);
end
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
        global DBGLOG
        if isa(DBGLOG, 'cell')
            DBGLOG{end+1} = sprintf('(%d,%d)->(%d,%d) ex=%d trunk=%d via straight', ...
                sx, sy, dx, dy, ex, isTrunk); %#ok<AGROW>
        end
        ok = true;
        msg = 'straight';
        return;
    end

    % v5: A* mid-section search on a per-net Hanan-style lattice before the
    % hand-written pattern strategies. Patterns remain the verified
    % fallback; failure here costs nothing.
    [okA, msgA] = route_astar(lineH, dstPort, R, wireA, wireFam, ...
                              sx, sy, dx, dy, ex, P0, aopts, ...
                              hardBanX, hardBanY);
    global ASTARSTAT ASTARMSGS
    if ~isempty(ASTARSTAT)
        ASTARMSGS{end+1} = msgA; %#ok<AGROW>
    end
    if okA
        global DBGLOG
        if isa(DBGLOG, 'cell')
            DBGLOG{end+1} = sprintf('(%d,%d)->(%d,%d) ex=%d trunk=%d via astar', ...
                sx, sy, dx, dy, ex, isTrunk); %#ok<AGROW>
        end
        ok = true;
        msg = '';
        return;
    end
    msg = msgA;

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
            global DBGLOG
            if isa(DBGLOG, 'cell')
                DBGLOG{end+1} = sprintf('(%d,%d)->(%d,%d) ex=%d trunk=%d via safez cx=%d', ...
                    sx, sy, dx, dy, ex, isTrunk, cx); %#ok<AGROW>
            end
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
        % vertical-entry side: +1 bottom edge, -1 top edge, 0 unknown. A
        % vertical port can ONLY be entered from its outer side, so offer
        % lanes there too (the sy->dy lanes are all on the inner side).
        sideV = 0;
        try
            dblk = get_param(dstPort, 'Parent');
            dbpos = get_param(dblk, 'Position');
            if abs(dy - dbpos(4)) <= 1
                sideV = 1;
            elseif abs(dy - dbpos(2)) <= 1
                sideV = -1;
            end
        catch
        end
        if sideV ~= 0
            for s6 = 1:5
                laneList(end+1) = dy + s6 * 10 * sideV; %#ok<AGROW>
            end
        end
        laneList = cands_keep(laneList, softY, hardBanY);
        laneY = 0;
        for t5 = 1:numel(laneList)
            cy2 = laneList(t5);
            if seg_blocked_h(min(sx, dx), max(sx, dx), cy2, R)
                continue;
            end
            if seg_blocked_v(sy, cy2, sx, R), continue; end
            if ex < dx - 0.5
                if seg_blocked_v(cy2, dy, dx, R), continue; end
            else
                % vertical entry: the descent rides the dst block column,
                % so check it but leave the last 12 px before the port
                % unchecked (margin zone by design -- R14 rewrites the
                % tail to (dx, dy -/+ 5) there); a full-span check would
                % also reject correct-side approaches.
                if cy2 < dy
                    vLo = cy2; vHi = dy - 12;
                else
                    vLo = dy + 12; vHi = cy2;
                end
                if vHi > vLo && seg_blocked_v(vLo, vHi, dx, R), continue; end
            end
            laneY = cy2;
            break;
        end
        if laneY ~= 0
            if ex < dx - 0.5
                % real canonical elbow discovered: the descent may leave it,
                % but the stored tail must still END at (ex, dy) -- R14
                % rewrites the last point to the canonical elbow otherwise
                % (shear).
                X2 = ex_pick(wireA, wireFam, myFam, ex, laneY, dy, R);
                if isempty(X2) || seg_blocked_h(min(sx, X2), max(sx, X2), ...
                        laneY, R)
                    laneY = 0;   % every entry column blocked; try go-around
                end
            else
                X2 = ex;   % vertical-entry port: descent must stay at dx
            end
        end
        if laneY ~= 0
            P = [sx sy; sx laneY; X2, laneY; X2, dy; ex, dy];
            P = dedup_pts(P);
            set_param(lineH, 'Points', P);
            Pr = get_param(lineH, 'Points');
            if all_orthogonal(Pr)
                global DBGLOG
                if isa(DBGLOG, 'cell')
                    DBGLOG{end+1} = sprintf('(%d,%d)->(%d,%d) ex=%d trunk=%d via anchor laneY=%d X2=%d blkH=%d', ...
                        sx, sy, dx, dy, ex, isTrunk, laneY, X2, ...
                        seg_blocked_h(min(sx, dx), max(sx, dx), laneY, R)); %#ok<AGROW>
                end
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
        gaRow = 0; gaCxg = 0; gaX2 = 0; gaExt = 0; gaLeg = 0; gaSet = 0; gaLast = 0;
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
            % final descent (X2, cyTry -> dy): for vertical entries X2 == dx
            % rides the dst block column, so a channel on the wrong side of
            % the port would pierce the block body (the bug that drew wires
            % straight through Sum blocks). Check the leg but leave the last
            % 12 px before the port unchecked (margin zone by design -- R14
            % rewrites the tail to (dx, dy -/+ 5) there).
            if cyTry < dy
                vLo = cyTry; vHi = dy - 12;
            else
                vLo = dy + 12; vHi = cyTry;
            end
            if vHi > vLo && seg_blocked_v(vLo, vHi, X2, R)
                gaLeg = gaLeg + 1;
                gaLast = cyTry;
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
                global DBGLOG
                if isa(DBGLOG, 'cell')
                    hits = '';
                    for rk = 1:size(R, 1)
                        if cyTry >= R(rk,2) && cyTry <= R(rk,4) && ...
                                245 >= R(rk,1) - 0.5
                            hits = [hits sprintf('[%d %d %d %d]', ...
                                R(rk,1), R(rk,2), R(rk,3), R(rk,4))]; %#ok<AGROW>
                        end
                    end
                    DBGLOG{end+1} = sprintf('(%d,%d)->(%d,%d) ex=%d trunk=%d via goaround cyTry=%d X2=%d nR=%d yhit=%d %s', ...
                        sx, sy, dx, dy, ex, isTrunk, cyTry, X2, size(R,1), ...
                        seg_blocked_h(sx, dx, cyTry, R), hits); %#ok<AGROW>
                end
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

% ======================================================================
% v5 A* mid-section router (see docs/astar-router-design.md)
% ======================================================================
function [ok, msg] = route_astar(lineH, dstPort, R, wireA, wireFam, ...
                                 sx, sy, dx, dy, ex, P0, aopts, ...
                                 hardBanX, hardBanY)
% Direction-state A* on a per-net Hanan-style sparse lattice. Chooses the
% path under cost = length + bends + crossings + congestion, emits through
% the R14 serialization rules (probe-learned canonical elbow tail), and
% verifies by readback + wire audit. Any failure returns ok=false and the
% caller falls back to the pattern strategies.
ok = false;
msg = '';
try
    global ASTARSTAT ASTARMSGS
    if ~isempty(ASTARSTAT), ASTARSTAT(1) = ASTARSTAT(1) + 1; end
    if ~isfield(aopts, 'method') || ~strcmpi(aopts.method, 'astar')
        msg = 'astar: disabled';
        return;
    end
    myFam = 0;
    try myFam = get_param(lineH, 'SrcPortHandle'); catch, end
    if abs(sy - dy) < 0.5
        msg = 'astar: same-row delegated to patterns';
        return;
    end
    vertEntry = (abs(ex - dx) < 0.5);   % no canonical elbow discovered
    ASTARPHASE = 'init';

    % ---------------- lattice line collection ----------------
    span = aopts.span;
    xlo = min([sx, dx, ex]) - span;
    xhi = max([sx, dx, ex]) + span;
    ylo = min([sy, dy]) - span;
    yhi = max([sy, dy]) + span;
    xs = [sx, sx + 8, dx];
    ys = [sy, dy];
    if vertEntry
        ys = [ys, dy - 10, dy - 20, dy + 10, dy + 20];
    else
        sgn = sign(ex - dx);
        if sgn == 0, sgn = -1; end
        for k = 1:6
            xs(end+1) = ex + sgn * 10 * k; %#ok<AGROW>
        end
    end
    for r = 1:size(R, 1)
        if R(r,3) < xlo || R(r,1) > xhi || R(r,4) < ylo || R(r,2) > yhi
            continue;
        end
        xs(end+1) = R(r,1) - 12; %#ok<AGROW>
        xs(end+1) = R(r,3) + 12; %#ok<AGROW>
        ys(end+1) = R(r,2) - 12; %#ok<AGROW>
        ys(end+1) = R(r,4) + 12; %#ok<AGROW>
    end
    xs = astar_merge(xs, xlo, xhi);
    ys = astar_merge(ys, ylo, yhi);
    xs = astar_force(xs, [sx, sx + 8, dx, ex]);
    ys = astar_force(ys, [sy, dy]);
    nx = numel(xs);
    ny = numel(ys);
    if nx * ny > 25000
        msg = 'astar: lattice too large';
        return;
    end

    ASTARPHASE = 'rects';
    % ---------------- edge cost layers ----------------
    % Hc(j,k): cost of the horizontal edge [xs(k),xs(k+1)] at row ys(j)
    % Vc(j,i): cost of the vertical edge [ys(j),ys(j+1)] at column xs(i)
    % Inf = impassable. Edges exactly on an inflated-rect boundary are
    % allowed (0.6 eps), matching the seg_blocked_* margin semantics.
    Hc = repmat(diff(xs), ny, 1);
    Vc = repmat(diff(ys)', 1, nx);
    lamX = aopts.cross;
    lamC = aopts.congest;
    for r = 1:size(R, 1)
        r1 = R(r,1); r2 = R(r,2); r3 = R(r,3); r4 = R(r,4);
        if r3 < xs(1) || r1 > xs(nx) || r4 < ys(1) || r2 > ys(ny)
            continue;
        end
        j1 = find(ys > r2 - 0.6, 1);
        j2 = find(ys < r4 + 0.6, 1, 'last');
        k1 = find(xs(1:end-1) < r3, 1, 'last');
        k2 = find(xs(2:end) > r1, 1);
        if ~(isempty(j1) || isempty(j2) || isempty(k1) || isempty(k2)) ...
                && j1 <= j2 && k2 <= k1
            for j = j1:j2
                for k = k2:k1
                    if xs(k+1) > r1 - 0.5 && xs(k) < r3 + 0.5
                        Hc(j, k) = Inf;
                    end
                end
            end
        end
        i1 = find(xs > r1 - 0.6, 1);
        i2 = find(xs < r3 + 0.6, 1, 'last');
        l1 = find(ys(1:end-1) < r4, 1, 'last');
        l2 = find(ys(2:end) > r2, 1);
        if ~(isempty(i1) || isempty(i2) || isempty(l1) || isempty(l2)) ...
                && i1 <= i2 && l2 <= l1
            for i = i1:i2
                for j = l2:l1
                    if ys(j+1) > r2 - 0.5 && ys(j) < r4 + 0.5
                        Vc(j, i) = Inf;
                    end
                end
            end
        end
    end

    ASTARPHASE = 'wireV';
    % wire layers: other families only. Aligned same-direction = hard
    % (overlap is the defect); perpendicular = crossing price; anything
    % within 10 px = congestion price (lane spreading, emergent entry lanes)
    for s = 1:size(wireA, 1)
        if wireFam(s) == myFam, continue; end
        sw = wireA(s, :);
        if abs(sw(1) - sw(3)) < 0.5
            xv = sw(1);
            ya = min(sw(2), sw(4));
            yb = max(sw(2), sw(4));
            i = find(abs(xs - xv) < 0.5, 1);
            if ~isempty(i)
                [ja, jb] = astar_ivl(ys, ya, yb);
                if ja > 0
                    Vc(ja:jb, i) = Inf;
                end
            end
            jr = find(ys >= ya - 0.5 & ys <= yb + 0.5);
            if ~isempty(jr)
                k = astar_ivl_at(xs, xv);
                if k > 0
                    Hc(jr, k) = Hc(jr, k) + lamX;
                end
            end
            jr2 = find(ys >= ya - 10 & ys <= yb + 10);
            if ~isempty(jr2)
                for jj = jr2
                    for k = 1:nx-1
                        if Hc(jj, k) < Inf && ...
                           min(abs(xs(k) - xv), abs(xs(k+1) - xv)) <= 10
                            Hc(jj, k) = Hc(jj, k) + lamC;
                        end
                    end
                end
            end
            ir2 = find(xs >= xv - 10 & xs <= xv + 10);
            [ja, jb] = astar_ivl(ys, ya - 10, yb + 10);
            if ~isempty(ir2) && ja > 0
                for ii = ir2
                    if ii <= nx
                        for jv = ja:jb
                            if Vc(jv, ii) < Inf
                                Vc(jv, ii) = Vc(jv, ii) + lamC;
                            end
                        end
                    end
                end
            end
        else
            ASTARPHASE = 'wireH-hard';
            yh = sw(2);
            xa = min(sw(1), sw(3));
            xb = max(sw(1), sw(3));
            j = find(abs(ys - yh) < 0.5, 1);
            if ~isempty(j)
                [ia, ib] = astar_ivl(xs, xa, xb);
                if ia > 0
                    Hc(j, ia:ib) = Inf;
                end
            end
            ASTARPHASE = 'wireH-cross';
            ir = find(xs >= xa - 0.5 & xs <= xb + 0.5);
            if ~isempty(ir)
                j2 = astar_ivl_at(ys, yh);
                if j2 > 0
                    Vc(j2, ir) = Vc(j2, ir) + lamX;
                end
            end
            ASTARPHASE = 'wireH-congV';
            ir2 = find(xs >= xa - 10 & xs <= xb + 10);
            if ~isempty(ir2)
                for ii = ir2
                    for j = 1:ny-1
                        if Vc(j, ii) < Inf && ...
                           min(abs(ys(j) - yh), abs(ys(j+1) - yh)) <= 10
                            Vc(j, ii) = Vc(j, ii) + lamC;
                        end
                    end
                end
            end
            ASTARPHASE = 'wireH-congH';
            jr2 = find(ys >= yh - 10 & ys <= yh + 10);
            if ~isempty(jr2)
                [ia, ib] = astar_ivl(xs, xa - 10, xb + 10);
                if ia > 0
                    for jj = jr2
                        for k2 = ia:ib
                            if Hc(jj, k2) < Inf
                                Hc(jj, k2) = Hc(jj, k2) + lamC;
                            end
                        end
                    end
                end
            end
        end
    end

    % nudge hard bans: whole rows / columns near the banned coordinate
    for t = 1:numel(hardBanX)
        ii = find(abs(xs - hardBanX(t)) < 4);
        if ~isempty(ii)
            Vc(:, ii) = Inf;
        end
    end
    for t = 1:numel(hardBanY)
        jj = find(abs(ys - hardBanY(t)) < 4);
        if ~isempty(jj)
            Hc(jj, :) = Inf;
        end
    end

    ASTARPHASE = 'search';
    % ---------------- direction-state A* ----------------
    is0 = find(abs(xs - (sx + 8)) < 0.5, 1);
    js0 = find(abs(ys - sy) < 0.5, 1);
    if isempty(is0) || isempty(js0)
        msg = 'astar: no start node';
        return;
    end
    if is0 > 1
        Hc(js0, is0 - 1) = Inf;   % never double back over the exit stub
    end
    if vertEntry
        gi = find(abs(xs - dx) < 0.5, 1);
        gjs = find(abs(ys - dy) <= 20.5 & abs(ys - dy) > 0.5);
        % restrict the goals to the OUTSIDE side of the dst block: a
        % vertical port can only be entered from its outer side; inner-side
        % goal cells sit inside the block and can only be "reached" by a
        % piercing path.
        try
            dblk = get_param(dstPort, 'Parent');
            dbpos = get_param(dblk, 'Position');
            if abs(dy - dbpos(4)) <= 1
                gjs = find(abs(ys - dy) <= 20.5 & ys > dy);
            elseif abs(dy - dbpos(2)) <= 1
                gjs = find(abs(ys - dy) <= 20.5 & ys < dy);
            end
        catch
        end
        if isempty(gi) || isempty(gjs)
            msg = 'astar: no goal node';
            return;
        end
    else
        gi = find(abs(xs - ex) < 0.5, 1);
        gjs = find(abs(ys - dy) < 0.5, 1);
        if isempty(gi) || isempty(gjs)
            msg = 'astar: no goal node';
            return;
        end
    end
    gx = xs(gi);

    g3 = inf(ny, nx, 2);
    parI = zeros(ny, nx, 2);
    parJ = zeros(ny, nx, 2);
    parD = zeros(ny, nx, 2);
    cl3 = false(ny, nx, 2);
    h0 = abs(xs(is0) - gx) + astar_hrow(ys(js0), ys, gjs);
    oI = is0; oJ = js0; oD = 1; oG = 0; oF = h0;
    g3(js0, is0, 1) = 0;
    found = false;
    pops = 0;
    while ~isempty(oF)
        [fmin, kk] = min(oF); %#ok<NASGU>
        ci = oI(kk); cj = oJ(kk); cd = oD(kk); cg = oG(kk);
        oI(kk) = []; oJ(kk) = []; oD(kk) = []; oG(kk) = []; oF(kk) = [];
        if cl3(cj, ci, cd), continue; end
        cl3(cj, ci, cd) = true;
        pops = pops + 1;
        if pops > aopts.budget
            msg = 'astar: budget exceeded';
            return;
        end
        if ci == gi && ~isempty(find(cj == gjs, 1))
            found = true;
            break;
        end
        for mv = 1:4
            if mv == 1
                ni = ci + 1;
                if ni > nx, continue; end
                nj = cj; ec = Hc(cj, ci); nd = 1;
            elseif mv == 2
                ni = ci - 1;
                if ni < 1, continue; end
                nj = cj; ec = Hc(cj, ni); nd = 1;
            elseif mv == 3
                nj = cj + 1;
                if nj > ny, continue; end
                ni = ci; ec = Vc(cj, ci); nd = 2;
            else
                nj = cj - 1;
                if nj < 1, continue; end
                ni = ci; ec = Vc(nj, ci); nd = 2;
            end
            if ~(ec < Inf), continue; end
            if nd ~= cd, ec = ec + aopts.bend; end
            ng = cg + ec;
            if ng < g3(nj, ni, nd) && ~cl3(nj, ni, nd)
                g3(nj, ni, nd) = ng;
                parI(nj, ni, nd) = ci;
                parJ(nj, ni, nd) = cj;
                parD(nj, ni, nd) = cd;
                oI(end+1) = ni; oJ(end+1) = nj; oD(end+1) = nd;
                oG(end+1) = ng;
                oF(end+1) = ng + abs(xs(ni) - gx) + ...
                            astar_hrow(ys(nj), ys, gjs);
            end
        end
    end
    if ~found
        msg = 'astar: no path found';
        return;
    end

    ASTARPHASE = 'emit';
    % ---------------- reconstruct + emit ----------------
    nodes = [ci cj cd];
    while ~(nodes(1,1) == is0 && nodes(1,2) == js0)
        cI = nodes(1,1); cJ = nodes(1,2); cD = nodes(1,3);
        pI = parI(cJ, cI, cD); pJ = parJ(cJ, cI, cD); pD = parD(cJ, cI, cD);
        if pI == 0 && pJ == 0
            break;
        end
        nodes = [pI pJ pD; nodes]; %#ok<AGROW>
    end
    pts = [P0; xs(is0), ys(js0)];
    prevD = 1;
    for t = 2:size(nodes, 1)
        if nodes(t,3) ~= prevD
            pts(end+1, :) = [xs(nodes(t-1,1)), ys(nodes(t-1,2))]; %#ok<AGROW>
            prevD = nodes(t,3);
        end
    end
    pts(end+1, :) = [xs(nodes(end,1)), ys(nodes(end,2))]; %#ok<AGROW>
    % vertical-entry tail: pre-apply R14's own rewrite (law: the stored tail
    % lands at (dx, dy -/+ 5)). Without this, R14 shifts the proposed goal
    % point 5 px off a horizontal rung and shears a diagonal -- the reason
    % vertEntry A* attempts used to die with "sheared on emit".
    if vertEntry
        gy = ys(nodes(end, 2));
        pts(end+1, :) = [gx, dy + 5 * sign(gy - dy)]; %#ok<AGROW>
    end
    P = dedup_pts(pts);
    set_param(lineH, 'Points', P);
    Pr = get_param(lineH, 'Points');
    if ~all_orthogonal(Pr)
        msg = 'astar: sheared on emit';
        return;
    end
    if abs(Pr(1,1) - P0(1)) > 0.5 || abs(Pr(1,2) - P0(2)) > 0.5
        msg = 'astar: anchor moved';
        return;
    end
    % audit all segments except the port stubs (first = exit stub, last =
    % entry rung -- both R14-mandated and inside the margin zone by design)
    for j = 3:size(Pr, 1) - 1
        if abs(Pr(j,2) - Pr(j-1,2)) < 0.5
            if seg_blocked_h(Pr(j-1,1), Pr(j,1), Pr(j,2), R)
                msg = 'astar: obstacle on emit';
                return;
            end
        else
            if seg_blocked_v(Pr(j-1,2), Pr(j,2), Pr(j,1), R)
                msg = 'astar: obstacle on emit';
                return;
            end
        end
    end
    for j = 2:size(Pr, 1)
        for s = 1:size(wireA, 1)
            if wireFam(s) == myFam, continue; end
            sw = wireA(s, :);
            ov = 0;
            if abs(Pr(j,2) - Pr(j-1,2)) < 0.5 && abs(sw(2) - sw(4)) < 0.5 ...
                    && abs(Pr(j,2) - sw(2)) < 0.5
                ov = min(max(Pr(j,1), Pr(j-1,1)), max(sw(1), sw(3))) - ...
                     max(min(Pr(j,1), Pr(j-1,1)), min(sw(1), sw(3)));
            end
            if abs(Pr(j,1) - Pr(j-1,1)) < 0.5 && abs(sw(1) - sw(3)) < 0.5 ...
                    && abs(Pr(j,1) - sw(1)) < 0.5
                ov = min(max(Pr(j,2), Pr(j-1,2)), max(sw(2), sw(4))) - ...
                     max(min(Pr(j,2), Pr(j-1,2)), min(sw(2), sw(4)));
            end
            if ov > 6
                msg = 'astar: wire overlap on emit';
                return;
            end
        end
    end
    ok = true;
    if ~isempty(ASTARSTAT), ASTARSTAT(2) = ASTARSTAT(2) + 1; end
catch
    realMsg = lasterr;
    msg = ['astar failed [', ASTARPHASE, '] nx=', num2str(numel(xs)), ...
           ' ny=', num2str(numel(ys)), ' : ', realMsg];
    global ASTARSTAT
    if ~isempty(ASTARSTAT)
        try
            save('astar_debug.mat', 'xs', 'ys', 'wireA', 'wireFam', ...
                 'myFam', 'R', 'sx', 'sy', 'dx', 'dy', 'ex', 'P0', 'nx', 'ny');
        catch
        end
    end
end
end

% ------------------------------------------------------------------
function v = astar_merge(vals, lo, hi)
% sort, clamp, drop duplicates and anything closer than 5 px to the last kept
v = sort(vals(:)');
keep = [];
for k = 1:numel(v)
    if v(k) < lo || v(k) > hi, continue; end
    if isempty(keep) || v(k) - keep(end) > 4
        keep(end+1) = v(k); %#ok<AGROW>
    end
end
v = keep;
end

% ------------------------------------------------------------------
function v = astar_force(vals, need)
% insert exact required coordinates (start/goal nodes must exist verbatim)
v = vals;
for k = 1:numel(need)
    if isempty(find(abs(v - need(k)) < 0.5, 1))
        v(end+1) = need(k); %#ok<AGROW>
    end
end
v = sort(v);
end

% ------------------------------------------------------------------
function [j1, j2] = astar_ivl(vals, a, b)
% index range [j1,j2] of intervals [vals(j),vals(j+1)] overlapping [a,b]
j1 = find(vals(2:end) > a, 1);
j2 = find(vals(1:end-1) < b, 1, 'last');
if isempty(j1) || isempty(j2) || j1 > j2
    j1 = 0; j2 = 0;
end
end

% ------------------------------------------------------------------
function k = astar_ivl_at(vals, v)
% index of the interval [vals(k),vals(k+1)] containing v; 0 if outside
if v < vals(1) || v > vals(end)
    k = 0;
    return;
end
k = find(vals <= v, 1, 'last');
if k >= numel(vals), k = numel(vals) - 1; end
end

% ------------------------------------------------------------------
function h = astar_hrow(y, ys, gjs)
% admissible vertical distance to the nearest goal row
h = inf;
for k = 1:numel(gjs)
    h = min(h, abs(y - ys(gjs(k))));
end
if isinf(h), h = 0; end
end
