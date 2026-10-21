function v = json_decode(s)
%JSON_DECODE  Minimal JSON parser for the MCP bridge (MATLAB 7.0).
%   Supports objects, arrays, strings (with \uXXXX), numbers, true/false/null.
%   Returns struct (objects, lowercase fields as-is), cell (arrays), char/double.
s = strtrim(s);
[p, v] = pvalue(s, 1);
if p <= 0, error('JSON:parse', 'parse failed'); end

    function [np, val] = pvalue(str, p)
        [np, val] = pskip(str, p);
        c = str(np);
        switch c
            case '{',  [np, val] = pobj(str, np);
            case '[',  [np, val] = parr(str, np);
            case '"',  [np, val] = pstring(str, np);
            otherwise, [np, val] = pnum(str, np);
        end
    end

    function [p, v] = pskip(str, p)
        while p <= length(str)
            ch = str(p);
            if ch == ' ' || ch == char(9) || ch == sprintf('\n') || ch == sprintf('\r')
                p = p + 1;
            else
                break;
            end
        end
        v = p;
    end

    function [np, obj] = pobj(str, p)
        obj = struct();
        np = pskip2(str, p + 1);
        c = str(np);
        if c == '}', np = np + 1; return; end
        while true
            [np, key] = pstring(str, np);
            np = pskip2v(str, np);   % land on colon
            np = np + 1;             % consume colon
            [np, val] = pvalue(str, np);
            obj = setfield_dynamic(obj, key, val);
            np = pskip2v(str, np);
            if str(np) == ','
                np = pskip2(str, np + 1);   % skip whitespace after comma
            elseif str(np) == '}'
                np = np + 1; return;
            else
                error('json_decode:obj', 'parse error in object');
            end
        end
    end

    function [np, arr] = parr(str, p)
        arr = {};
        np = pskip2(str, p + 1);
        if str(np) == ']', np = np + 1; return; end
        while true
            [np, val] = pvalue(str, np);
            arr{end+1} = val; %#ok<AGROW>
            np = pskip2v(str, np);
            if str(np) == ','
                np = pskip2(str, np + 1);   % skip whitespace after comma
            elseif str(np) == ']'
                np = np + 1; return;
            else
                error('json_decode:arr', 'parse error in array');
            end
        end
        if isempty(arr), arr = {}; end
    end

    function [np, s] = pstring(str, p)
        % str(p) == '"'
        % Two sources of non-ASCII in a JSON string:
        %   1. raw UTF-8 bytes (Node JSON.stringify writes these) -> the
        %      accumulated chars are BYTES and need native2unicode('UTF-8');
        %   2. \uXXXX escapes (python json.dumps with ensure_ascii) -> char(cp)
        %      already IS a native char and must NOT be re-decoded.
        % Track whether any \u escape appeared; if so, decode the raw-byte
        % segments before appending escapes. Simplest correct approach: decode
        % bytes up to the first escape natively, append the escaped char, then
        % treat the remainder as bytes again (per-segment decode).
        p = p + 1;
        out = '';
        hasU = false;
        while p <= length(str)
            c = str(p);
            if c == '\'
                n = str(p+1);
                switch n
                    case '"',  out(end+1) = '"'; p = p + 2;
                    case '\',  out(end+1) = '\'; p = p + 2;
                    case '/',  out(end+1) = '/'; p = p + 2;
                    case 'n',  out(end+1) = sprintf('\n'); p = p + 2;
                    case 't',  out(end+1) = sprintf('\t'); p = p + 2;
                    case 'r',  out(end+1) = sprintf('\r'); p = p + 2;
                    case 'b',  out(end+1) = char(8); p = p + 2;
                    case 'f',  out(end+1) = char(12); p = p + 2;
                    case 'u'
                        hexs = str(p+2 : p+5);
                        cp = hex2dec(hexs);
                        out(end+1) = char(cp);
                        hasU = true;
                        p = p + 6;
                    otherwise
                        out(end+1) = n; p = p + 2;
                end
            elseif c == '"'
                np = p + 1;
                if hasU
                    s = mixed_to_char(out);
                else
                    s = utf8bytes_to_char(out);
                end
                return;
            else
                out(end+1) = c; p = p + 1;
            end
        end
        error('json_decode:str', 'parse error in string');
    end

    function s = mixed_to_char(carr)
        % String contains \u-escaped native chars mixed with raw UTF-8 bytes.
        % Walk through: byte-runs (chars <= 255) decode as UTF-8; chars > 255
        % are already native and pass through.
        s = '';
        seg = '';
        n = numel(carr);
        for k = 1:n
            ch = carr(k);
            if double(ch) > 255
                if ~isempty(seg)
                    s = [s, utf8bytes_to_char(seg)];
                    seg = '';
                end
                s = [s, ch];
            else
                seg(end+1) = ch;
            end
        end
        if ~isempty(seg)
            s = [s, utf8bytes_to_char(seg)];
        end
        s = reshape(s, 1, []);
    end

    function [np, v] = pnum(str, p)
        p0 = p;
        while p <= length(str)
            c = str(p);
            if ismember(c, '0123456789+-.eE')
                p = p + 1;
            else
                break;
            end
        end
        tok = str(p0:p-1);
        v = str2double(tok);
        np = p;
    end

    function o = setfield_dynamic(o, k, v)
        if isfield(o, k)
            o.(k) = v;
        else
            o = struct_addfield(o, k, v);
        end
    end

    function s = utf8bytes_to_char(carr)
        % carr holds raw bytes as chars (could be UTF-8 multibyte); convert to
        % MATLAB native chars so display/compare work. Force row vector.
        try
            b = uint8(carr);
            s = native2unicode(b(:)', 'UTF-8');
            s = reshape(s, 1, []);
        catch
            s = reshape(carr, 1, []);
        end
    end
end

function s = pskip2(str, p)
    while p <= length(str)
        c = str(p);
        if c == ' ' || c == char(9) || c == sprintf('\n') || c == sprintf('\r')
            p = p + 1;
        else
            break;
        end
    end
    s = p;
end

function p2 = pskip2v(str, p)  %#ok<DEFNU>
    p2 = pskip2(str, p);
end

function o = struct_addfield(o, k, v)
    f = fieldnames(o);
    fn = [f(:); {k}];
    % build order-preserving struct
    tmp = struct();
    for i = 1:numel(fn)-1
        tmp = setfield(tmp, fn{i}, o.(fn{i}));
    end
    tmp = setfield(tmp, k, v);
    o = tmp;
end
