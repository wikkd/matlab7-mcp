function issues = mcp_check(code)
%MCP_CHECK  Syntax-check MATLAB code WITHOUT running it (R14).
%   issues = mcp_check('for k=1:10\ndisp(k)\nend')  -> '' (parses clean)
%   issues = mcp_check('for k=1:10 disp(k)')        -> imbalance error
%   issues = mcp_check('x = 1; y = );')             -> pcode parse error
%
% Two-stage check, both present in every R14 install:
%   1. textual block-keyword balance (pcode tolerates a MISSING 'end' in
%      single-function files, so a lone 'for k=1:10 disp(k)' must be caught
%      by counting for/while/if/switch/try/function vs end)
%   2. pcode full parse (catches bad parentheses, invalid tokens, ...)
% Keep this file pure ASCII: worker .m files are read by R14 as GBK.

issues = '';

% ---------- stage 1: block keyword balance ----------
scrub = code;
% strip string literals and comments (single pass, char by char)
nb = numel(scrub);
masked = zeros(1, nb);
inStr = false;
i2 = 1;
while i2 <= nb
    ch = scrub(i2);
    if inStr
        if ch == ''''
            if i2 < nb && scrub(i2+1) == ''''
                masked(i2) = 1;
                masked(i2+1) = 1;
                i2 = i2 + 2;
                continue;
            end
            masked(i2) = 1;
            inStr = false;
        else
            masked(i2) = 1;
        end
    else
        if ch == '%'
            % comment to end of line
            nl = strfind(scrub(i2:end), sprintf('\n'));
            if isempty(nl)
                masked(i2:end) = 1;
                i2 = nb + 1;
            else
                masked(i2:i2+nl(1)-1) = 1;
                i2 = i2 + nl(1);
            end
            continue;
        elseif ch == ''''
            % transpose vs string start: treat as string start (good enough;
            % a transposed char literal still balances the same way)
            inStr = true;
            masked(i2) = 1;
        end
    end
    i2 = i2 + 1;
end
scrub(masked == 1) = ' ';

% tokenize identifiers and count block keywords. 'end' inside parentheses or
% brackets is an INDEX keyword (Points(end,:), x(end+1)), not a block close,
% so track paren/bracket depth and only count statement-level 'end'.
openers = 0;
enders = 0;
wstart = -1;
pdepth = 0;
scrub2 = [lower(scrub), ' '];
for i3 = 1:numel(scrub2)
    ch = scrub2(i3);
    if ch == '(' || ch == '{' || ch == '['
        pdepth = pdepth + 1;
    elseif ch == ')' || ch == '}' || ch == ']'
        if pdepth > 0
            pdepth = pdepth - 1;
        end
    end
    isword = (ch >= 'a' && ch <= 'z') || ch == '_';
    if isword
        if wstart < 0, wstart = i3; end
    else
        if wstart > 0
            w = scrub2(wstart:i3-1);
            if pdepth == 0
                if strcmp(w, 'for') || strcmp(w, 'while') || strcmp(w, 'if') ...
                        || strcmp(w, 'switch') || strcmp(w, 'try') || strcmp(w, 'function')
                    openers = openers + 1;
                elseif strcmp(w, 'end')
                    enders = enders + 1;
                end
            end
            wstart = -1;
        end
    end
end
if openers ~= enders
    issues = ['block keyword imbalance: ' num2str(openers) ...
        ' openers (for/while/if/switch/try/function) vs ' num2str(enders) ' "end"'];
end

% ---------- stage 2: pcode full parse ----------
if isempty(issues)
    tf = [tempname, '.m'];
    try
        hdr = ['function mcp_check_tmp()', char(10), ...
            'if mcp_check_sentinel, return; end', char(10)];
        body = [hdr, code, char(10), 'end'];
        fid = fopen(tf, 'wb');
        if fid <= 0
            issues = 'mcp_check: cannot create temp file';
            return;
        end
        fwrite(fid, uint8(unicode2native(body, 'GBK')), 'uint8');
        fclose(fid);
        try
            pcode(tf, '-inplace');
            pf = [tf(1:end-1), 'p'];
            if exist(pf, 'file')
                delete(pf);
            end
        catch
            issues = lasterr;
            % keep only "Line: N Column: M ..." onward (File: is a temp path)
            k = strfind(issues, 'Line:');
            if ~isempty(k)
                issues = issues(k(1):end);
            end
            issues = strrep(issues, '??? ', '');
        end
        if exist(tf, 'file')
            delete(tf);
        end
    catch
        try
            delete(tf);
        end
        issues = ['mcp_check: internal failure (', lasterr, ') - treat as unchecked'];
    end
end
end
