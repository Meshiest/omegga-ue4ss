-- Minimal, dependency-free JSON encode/decode for BrickadiaBridge (Phase 1).
-- Encodes Lua nil->null, booleans, numbers, strings (escaped), and tables
-- (array if keys are 1..n, else object; empty table -> {}). Unsupported values
-- (userdata/function) are stringified so a stray UObject can't break a response.
local json = {}

-- ===== encode =====
local escape_map = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function escape_char(c)
    return escape_map[c] or string.format('\\u%04x', string.byte(c))
end
local function encode_string(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then return false, 0 end
        n = n + 1
    end
    return n == #t, n
end

local encode_value
local function encode_table(t)
    local arr, n = is_array(t)
    local parts = {}
    if arr and n > 0 then
        for i = 1, #t do parts[i] = encode_value(t[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
    else
        local i = 0
        for k, v in pairs(t) do
            i = i + 1
            parts[i] = encode_string(tostring(k)) .. ':' .. encode_value(v)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
end

function encode_value(v)
    local tv = type(v)
    if v == nil then return 'null'
    elseif tv == 'boolean' then return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v % 1 == 0 then return string.format('%d', v) end
        return tostring(v)
    elseif tv == 'string' then return encode_string(v)
    elseif tv == 'table' then return encode_table(v)
    else return encode_string(tostring(v)) end
end

function json.encode(v) return encode_value(v) end

-- ===== decode =====
local function derr(i, msg) error(string.format('json decode: %s at %d', msg, i)) end

local function skip_ws(s, i)
    local _, j = s:find('^[ \t\r\n]*', i)
    return (j or (i - 1)) + 1
end

local function parse_string(s, i)
    local res = {}
    local j = i + 1 -- skip opening quote
    while true do
        local c = s:sub(j, j)
        if c == '' then derr(j, 'unterminated string') end
        if c == '"' then return table.concat(res), j + 1 end
        if c == '\\' then
            local e = s:sub(j + 1, j + 1)
            if e == 'n' then res[#res + 1] = '\n'
            elseif e == 't' then res[#res + 1] = '\t'
            elseif e == 'r' then res[#res + 1] = '\r'
            elseif e == 'b' then res[#res + 1] = '\b'
            elseif e == 'f' then res[#res + 1] = '\f'
            elseif e == '/' then res[#res + 1] = '/'
            elseif e == '"' then res[#res + 1] = '"'
            elseif e == '\\' then res[#res + 1] = '\\'
            elseif e == 'u' then
                local code = tonumber(s:sub(j + 2, j + 5), 16)
                if not code then derr(j, 'bad \\u escape') end
                res[#res + 1] = (utf8 and utf8.char(code)) or string.char(code % 256)
                j = j + 4
            else derr(j, 'bad escape') end
            j = j + 2
        else
            res[#res + 1] = c
            j = j + 1
        end
    end
end

local function parse_number(s, i)
    local span = s:match('^[%-+%deE.]+', i)
    local num = tonumber(span)
    if not num then derr(i, 'bad number') end
    return num, i + #span
end

local decode_value
function decode_value(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return parse_string(s, i)
    elseif c == '{' then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            local key; key, i = parse_string(s, skip_ws(s, i))
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ':' then derr(i, "expected ':'") end
            local val; val, i = decode_value(s, i + 1)
            obj[key] = val
            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == '}' then return obj, i + 1 end
            if ch ~= ',' then derr(i, "expected ',' or '}'") end
            i = skip_ws(s, i + 1)
        end
    elseif c == '[' then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        while true do
            local val; val, i = decode_value(s, i)
            arr[#arr + 1] = val
            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == ']' then return arr, i + 1 end
            if ch ~= ',' then derr(i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == 't' then
        if s:sub(i, i + 3) == 'true' then return true, i + 4 end
        derr(i, 'bad literal')
    elseif c == 'f' then
        if s:sub(i, i + 4) == 'false' then return false, i + 5 end
        derr(i, 'bad literal')
    elseif c == 'n' then
        if s:sub(i, i + 3) == 'null' then return nil, i + 4 end
        derr(i, 'bad literal')
    else
        return parse_number(s, i)
    end
end

function json.decode(s)
    local v = decode_value(s, 1)
    return v
end

return json
