function s = mcp2json(x)
%MCP2JSON  Serialize a MATLAB value to a JSON string (MATLAB 7.0 compatible).
%   s = mcp2json(x)  ->  char array of JSON.
%
%   v2: NaN/Inf emitted as JSON strings ("NaN"/"Inf"/"-Inf") so the output is
%   ALWAYS valid JSON (bare NaN/Inf broke JSON.parse on the server). N-D
%   arrays nest as arrays-of-arrays. Logical arrays serialize as boolean
%   arrays. Char matrices serialize as cell array of row strings. Large
%   arrays use preallocated cell + one final concat (no O(n^2) growth).
%
%   Supports: double (any-D, real/complex), char (vector/matrix), logical,
%   cell arrays (N-D), struct arrays, Inf/NaN. Other classes -> class name.

if nargin < 1
    s = 'null';
else
    s = encswitch(x);
end


    function out = encswitch(v)
        if ischar(v)
            out = enc_char(v);
        elseif islogical(v)
            out = enc_logical(v);
        elseif isempty(v)
            out = 'null';
        elseif iscell(v)
            out = enc_nd(v, 1);
        elseif isstruct(v)
            out = enc_struct(v);
        elseif isnumeric(v)
            out = enc_num(v);
        else
            out = qescape(class(v));
        end
    end

    % ---------- char ----------
    function out = enc_char(v)
        if isempty(v)
            out = '""';
            return;
        end
        [r, c] = size(v);
        if r <= 1
            out = qescape(reshape(v, 1, []));
        else
            % char matrix: array of row strings
            parts = cell(1, r);
            for k = 1:r
                parts{k} = qescape(reshape(v(k, :), 1, []));
            end
            out = ['[' join_comma(parts) ']'];
        end
    end

    % ---------- logical ----------
    function out = enc_logical(v)
        if isscalar(v)
            if v, out = 'true'; else, out = 'false'; end
            return;
        end
        parts = rowmajor_parts(v, 0);
        out = nest_by_shape(parts, size(v));
    end

    % ---------- numeric ----------
    function out = enc_num(v)
        if any(imag(v(:)) ~= 0)
            out = enc_complex(v);
            return;
        end
        n = numel(v);
        if n == 1
            out = scalar2str(v(1));
        elseif n == 0
            out = 'null';
        else
            parts = rowmajor_parts(v, 0);
            out = nest_by_shape(parts, size(v));
        end
    end

    function out = enc_complex(v)
        n = numel(v);
        re = real(v); im = imag(v);
        if n == 1
            out = ['{"real":' scalar2str(re) ',"imag":' scalar2str(im) '}'];
            return;
        end
        parts = rowmajor_parts(v, 1);
        out = nest_by_shape(parts, size(v));
    end

    % walk an array in ROW-MAJOR order (JSON convention), producing serialized
    % scalars. cmplx=1 wraps each element as {"real":..,"imag":..}.
    % Works for any dimensionality via a full odometer.
    function parts = rowmajor_parts(v, cmplx)
        sz = size(v);
        nd = numel(sz);
        n = numel(v);
        parts = cell(1, n);
        idx = ones(1, nd);
        re = real(v); im = imag(v);
        for k = 1:n
            lin = sub2ind_calced(sz, idx, nd);
            if cmplx
                parts{k} = ['{"real":' scalar2str(re(lin)) ...
                    ',"imag":' scalar2str(im(lin)) '}'];
            else
                parts{k} = scalar2str(v(lin));
            end
            % odometer: last dim fastest (row-major)
            d = nd;
            while d >= 1
                idx(d) = idx(d) + 1;
                if idx(d) <= sz(d)
                    break;
                end
                idx(d) = 1;
                d = d - 1;
            end
        end
    end

    % column-major linear index from a full-dim subscript vector
    function lin = sub2ind_calced(sz, idx, nd)
        lin = 1;
        stride = 1;
        for d = 1:nd
            lin = lin + (idx(d) - 1) * stride;
            stride = stride * sz(d);
        end
    end

    % group an already-serialized flat cell (row-major) into nested JSON arrays
    % according to sz. 1-D/2-D row vector stays flat.
    function out = nest_by_shape(parts, sz)
        nd = numel(sz);
        n = numel(parts);
        if n == 0, out = 'null'; return; end
        if nd <= 1
            out = ['[' join_comma(parts) ']'];
            return;
        end
        if nd == 2 && (sz(1) == 1 || sz(2) == 1)
            % row or column vector: flat array (consistent with enc_nd)
            out = ['[' join_comma(parts) ']'];
            return;
        end
        if nd == 2
            rows = sz(1); cols = sz(2);
            rp = cell(1, rows);
            for r = 1:rows
                seg = parts((r-1)*cols+1 : r*cols);
                rp{r} = ['[' join_comma(seg) ']'];
            end
            out = ['[' join_comma(rp) ']'];
            return;
        end
        % >=3 dims: nest along first dim
        m = sz(1);
        per = n / m;
        pp = cell(1, m);
        for k = 1:m
            pp{k} = nest_by_shape(parts((k-1)*per+1 : k*per), sz(2:end));
        end
        out = ['[' join_comma(pp) ']'];
    end

    % ---------- cell (N-D) ----------
    function out = enc_nd(c, depth)
        % Cell arrays serialize in ROW-MAJOR order like numeric arrays.
        n = numel(c);
        if n == 0, out = 'null'; return; end
        sz = size(c);
        nd = ndims(c);
        if nd <= 1
            parts = cell(1, n);
            for k = 1:n
                parts{k} = encswitch(c(k));
            end
            out = ['[' join_comma(parts) ']'];
            return;
        end
        if depth > 8
            parts = cell(1, n);
            for k = 1:n
                parts{k} = encswitch(c(k));
            end
            out = ['[' join_comma(parts) ']'];
            return;
        end
        % recurse row-major: first element of each row-major step
        if nd == 2 && sz(1) == 1
            parts = cell(1, n);
            for k = 1:n
                parts{k} = encswitch(c{k});
            end
            out = ['[' join_comma(parts) ']'];
            return;
        end
        if nd == 2 && (sz(1) == 1 || sz(2) == 1)
            % row or column vector: flat array
            parts = cell(1, n);
            for k = 1:n
                parts{k} = encswitch(c(k));
            end
            out = ['[' join_comma(parts) ']'];
            return;
        end
        % >=3 dims: nest along first dim
        m = sz(1);
        pp = cell(1, m);
        for k = 1:m
            idx = repmat({':'}, 1, nd - 1);
            sub = c(k, idx{:});
            pp{k} = enc_nd(sub, depth + 1);
        end
        out = ['[' join_comma(pp) ']'];
    end

    % ---------- struct ----------
    function out = enc_struct(st)
        n = numel(st);
        if n == 0, out = 'null'; return; end
        fns = fieldnames(st);
        objs = cell(1, n);
        for e = 1:n
            parts = cell(1, numel(fns));
            for f = 1:numel(fns)
                parts{f} = [qescape(fns{f}) ':' encswitch(st(e).(fns{f}))];
            end
            objs{e} = ['{' join_comma(parts) '}'];
        end
        if n == 1
            out = objs{1};
        else
            out = ['[' join_comma(objs) ']'];
        end
    end

    % ---------- scalars & text ----------
    function s = scalar2str(v)
        if isnan(v)
            s = '"NaN"';
        elseif isinf(v)
            if v > 0, s = '"Inf"'; else, s = '"-Inf"'; end
        else
            s = num2str(v, '%.17g');
        end
    end

    function out = qescape(str)
        % UTF-8 encode for JSON transport (worker files are GBK on this system)
        u = unicode2utf8(str);
        u = strrep(u, '\', '\\');
        u = strrep(u, '"', '\"');
        u = strrep(u, sprintf('\n'), '\n');
        u = strrep(u, sprintf('\r'), '\r');
        u = strrep(u, sprintf('\t'), '\t');
        out = ['"' u '"'];
    end

    function u8 = unicode2utf8(str)
        % Convert char (GBK-decoded by MATLAB) to UTF-8 bytes, returned as char.
        % unicode2native('') throws in R14 - guard empty first.
        if isempty(str)
            u8 = '';
            return;
        end
        try
            native = unicode2native(str, 'UTF-8');
            u8 = reshape(char(native'), 1, []);
        catch
            u8 = str;  % fallback: leave as-is
        end
    end

    function out = join_comma(parts)
        out = '';
        n = numel(parts);
        if n == 0, return; end
        sep = ',';
        total = 0;
        for k = 1:n
            total = total + numel(parts{k}) + 1;
        end
        buf = blanks(total);
        pos = 1;
        for k = 1:n
            L = numel(parts{k});
            buf(pos:pos+L-1) = parts{k};
            pos = pos + L;
            if k < n
                buf(pos:pos) = sep;
                pos = pos + 1;
            end
        end
        out = buf(1:pos-1);
    end
end
