function m = mcp_sim_metrics(model, verbose)
%MCP_SIM_METRICS Independent routing-quality grader (v5 acceptance tool).
% Shares no state with mcp_sim_route: reads stored geometry only.
%   m = mcp_sim_metrics(model)          -> metrics struct
%   m = mcp_sim_metrics(model, true)    -> also print a full report
if nargin < 2, verbose = false; end
load_system(model);

% ---- blocks, labels (Java font metrics, same math the router uses) ----
blks = find_system(model, 'SearchDepth', 1, 'Type', 'block');
n = length(blks);
Rb = zeros(n, 4); LR = -1e9 * ones(n, 4); nms = cell(n, 1); bh = zeros(n, 1);
jfm = [];
try
    jtk = java.awt.Toolkit.getDefaultToolkit;
    jfm = jtk.getFontMetrics(java.awt.Font('Helvetica', 0, 10));
catch
    jfm = [];
end
xmin = 1e9; ymin = 1e9; xmax = -1e9; ymax = -1e9;
for i = 1:n
    p = get_param(blks{i}, 'Position');
    Rb(i, :) = p;
    nms{i} = get_param(blks{i}, 'Name');
    try, bh(i) = get_param(blks{i}, 'Handle'); catch, bh(i) = -1; end
    xmin = min(xmin, p(1)); ymin = min(ymin, p(2));
    xmax = max(xmax, p(3)); ymax = max(ymax, p(4));
    loc = 'bottom';
    try, loc = get_param(blks{i}, 'NameLocation'); catch, end
    if ~isempty(jfm)
        w = jfm.stringWidth(nms{i}) + 8;
    else
        w = 6 * length(nms{i}) + 10;
    end
    cx = (p(1) + p(3)) / 2;
    if strcmp(loc, 'bottom')
        LR(i, :) = [cx - w/2, p(4), cx + w/2, p(4) + 15];
    else
        LR(i, :) = [cx - w/2, p(2) - 15, cx + w/2, p(2)];
    end
end

% ---- lines: segments with family + owning line ----
L = get_param(model, 'Lines');
hs = find_system(model, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'line');
seg = []; segFam = []; segLn = []; segIdx = [];
lastSeg = zeros(size(L, 1), 1);
totLen = 0; totBend = 0; nDiag = 0; nOut = 0; outList = [];
det = zeros(size(L, 1), 2);   % [len, manhattan] per line row
for i = 1:size(L, 1)
    P = L(i).Points;
    if size(P, 1) < 2, continue; end
    % family via handle match on first point
    fam = -1;
    for t = 1:length(hs)
        Ph = get_param(hs(t), 'Points');
        if size(Ph, 1) >= 2 && abs(Ph(1,1)-P(1,1)) < 0.5 && ...
                           abs(Ph(1,2)-P(1,2)) < 0.5
            fam = get_param(hs(t), 'SrcPortHandle');
            break;
        end
    end
    len = 0; bnd = 0; lastDir = '-';
    for j = 2:size(P, 1)
        dx = P(j,1) - P(j-1,1); dy = P(j,2) - P(j-1,2);
        if abs(dx) < 0.5 && abs(dy) < 0.5, continue; end
        len = len + abs(dx) + abs(dy);
        if abs(dx) < 0.5, d = 'V'; else, d = 'H'; end
        if ~strcmp(d, lastDir) && ~strcmp(lastDir, '-')
            bnd = bnd + 1;
        end
        lastDir = d;
        if abs(dx) > 0.5 && abs(dy) > 0.5
            nDiag = nDiag + 1;
        end
        seg = [seg; P(j-1,1) P(j-1,2) P(j,1) P(j,2)];  %#ok<AGROW>
        segFam = [segFam; fam];                        %#ok<AGROW>
        segLn = [segLn; i];                            %#ok<AGROW>
        segIdx = [segIdx; j-1];                        %#ok<AGROW>
        lastSeg(i) = j - 1;                            %#ok<AGROW>
    end
    man = abs(P(end,1)-P(1,1)) + abs(P(end,2)-P(1,2));
    det(i, :) = [len, max(man, 1)];
    totLen = totLen + len; totBend = totBend + bnd;
    if min(P(:,1)) < xmin-40 || max(P(:,1)) > xmax+40 || ...
       min(P(:,2)) < ymin-40 || max(P(:,2)) > ymax+40
        nOut = nOut + 1;
        outList = [outList; i];                        %#ok<AGROW>
    end
end

% ---- colinear overlaps (cross-family) ----
nOv = 0; ovTxt = '';
for a = 1:size(seg, 1)
    for b = a+1:size(seg, 1)
        if segLn(a) == segLn(b), continue; end
        if segFam(a) == segFam(b), continue; end
        x1=seg(a,1); y1=seg(a,2); x2=seg(a,3); y2=seg(a,4);
        u1=seg(b,1); v1=seg(b,2); u2=seg(b,3); v2=seg(b,4);
        ov = 0;
        if abs(y1-y2) < 0.5 && abs(v1-v2) < 0.5 && abs(y1-v1) < 0.5
            ov = min(max(x1,x2), max(u1,u2)) - max(min(x1,x2), min(u1,u2));
        end
        if abs(x1-x2) < 0.5 && abs(u1-u2) < 0.5 && abs(x1-u1) < 0.5
            ov = min(max(y1,y2), max(v1,v2)) - max(min(y1,y2), min(v1,v2));
        end
        if ov > 6
            nOv = nOv + 1;
            ovTxt = [ovTxt, sprintf('  L%02d(%d,%d)-(%d,%d) x L%02d(%d,%d)-(%d,%d) ov=%d\n', ...
                segLn(a), x1, y1, x2, y2, segLn(b), u1, v1, u2, v2, round(ov))]; %#ok<AGROW>
        end
    end
end

% ---- perpendicular crossings between different families ----
nCross = 0;
for a = 1:size(seg, 1)
    if abs(seg(a,2) - seg(a,4)) < 0.5, continue; end  % only H rows host
    for b = 1:size(seg, 1)
        if segLn(b) == segLn(a), continue; end
        if segFam(b) == segFam(a), continue; end
        if abs(seg(b,1) - seg(b,3)) > 0.5, continue; end % V only
        xv = seg(b,1);
        if xv > max(seg(a,1), seg(a,3)) - 0.5 && ...
           xv < min(seg(a,1), seg(a,3)) + 0.5, continue; end
        if xv >= min(seg(a,1), seg(a,3)) && xv <= max(seg(a,1), seg(a,3)) && ...
           min(seg(a,2), seg(a,4)) - 0.5 <= min(seg(b,2), seg(b,4)) && ...
           max(seg(a,2), seg(a,4)) + 0.5 >= max(seg(b,2), seg(b,4))
            nCross = nCross + 1;
        end
    end
end

% ---- block / label hits ----
% Segments 1-2 of each line are the R14-mandated exit-stub pair (rewritten
% by R14 itself after every set; hidden under the port arrow) -- exempt.
% The LAST segment grazing its OWN destination block's LABEL is exempt:
% R14 prints Sum/Constant names (no NameLocation parameter) in a fixed
% band that is the mandatory approach corridor of a vertical-entry port.
% Own BLOCK-body hits on the tail are still counted (real defects).
nBlk = 0; nLab = 0; hitTxt = '';
for s = 1:size(seg, 1)
    if segIdx(s) <= 2, continue; end
    for i = 1:n
        for which = 1:2
            if which == 1, q = Rb(i, :); else, q = LR(i, :); end
            if which == 2 && segIdx(s) == lastSeg(segLn(s)) && ...
                    bh(i) == L(segLn(s)).DstBlock(1)
                continue;   % own label in the mandatory approach corridor
            end
            if abs(seg(s,2) - seg(s,4)) < 0.5
                yy = seg(s,2);
                if yy >= q(2)-0.5 && yy <= q(4)+0.5 && ...
                   max(seg(s,1), seg(s,3)) > q(1)+0.5 && ...
                   min(seg(s,1), seg(s,3)) < q(3)-0.5
                    if which == 1, nBlk = nBlk + 1; else, nLab = nLab + 1; end
                    hitTxt = [hitTxt, sprintf('  L%02d x %s\n', segLn(s), nms{i})]; %#ok<AGROW>
                end
            else
                xx = seg(s,1);
                if xx >= q(1)-0.5 && xx <= q(3)+0.5 && ...
                   max(seg(s,2), seg(s,4)) > q(2)+0.5 && ...
                   min(seg(s,2), seg(s,4)) < q(4)-0.5
                    if which == 1, nBlk = nBlk + 1; else, nLab = nLab + 1; end
                    hitTxt = [hitTxt, sprintf('  L%02d x %s\n', segLn(s), nms{i})]; %#ok<AGROW>
                end
            end
        end
    end
end

% ---- worst detours ----
[worst, idx] = sort(det(:,1) ./ det(:,2), 'descend');
detTxt = '';
for k = 1:min(5, length(idx))
    if worst(k) > 1.5
        detTxt = [detTxt, sprintf('  L%02d r=%.1f (len=%d man=%d)\n', ...
            idx(k), worst(k), round(det(idx(k),1)), round(det(idx(k),2)))]; %#ok<AGROW>
    end
end

m = struct('model', model, 'lines', size(L,1), 'diag', nDiag, ...
    'outOfBbox', nOut, 'crossFamOverlaps', nOv, 'crossings', nCross, ...
    'blockHits', nBlk, 'labelHits', nLab, 'totalLen', totLen, ...
    'totalBends', totBend, 'maxDetour', worst(1));
if verbose
    fprintf('=== METRICS %s ===\n', model);
    fprintf('lines=%d diag=%d out=%d xFamOv=%d crossings=%d blk=%d lab=%d len=%d bends=%d maxDet=%.1f\n', ...
        size(L,1), nDiag, nOut, nOv, nCross, nBlk, nLab, totLen, totBend, worst(1));
    if nOv > 0, fprintf('overlaps:\n%s', ovTxt); end
    if nBlk + nLab > 0, fprintf('hits:\n%s', hitTxt); end
    if ~isempty(detTxt), fprintf('worst detours:\n%s', detTxt); end
    fprintf('=== end ===\n');
end
