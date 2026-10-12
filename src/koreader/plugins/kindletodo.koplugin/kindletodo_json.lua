--[[
Minimal, dependency-free JSON for KindleTodo.

The encoder is deterministic (sorted keys, fixed indentation) so identical
data always produces an identical file. Arrays are tables with only 1..n keys;
an empty table under the key "tasks" is written as [].
]]

local Json = {}

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function encodeValue(v, indent, key)
    local tv = type(v)
    if tv == "nil" then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v % 1 == 0 and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif tv == "string" then return encodeString(v)
    elseif tv == "table" then
        local arr, n = isArray(v)
        local pad = string.rep("  ", indent + 1)
        local close = string.rep("  ", indent)
        if arr and (n > 0 or key == "tasks") then
            if n == 0 then return "[]" end
            local parts = {}
            for i = 1, n do parts[i] = pad .. encodeValue(v[i], indent + 1) end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then error("non-string key in object") end
            table.insert(keys, k)
        end
        if #keys == 0 then return "{}" end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            table.insert(parts, pad .. encodeString(k) .. ": " .. encodeValue(v[k], indent + 1, k))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "}"
    end
    error("cannot encode " .. tv)
end

function Json.encode(v)
    return encodeValue(v, 0) .. "\n"
end

-- Decoder -------------------------------------------------------------------

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function Json.decode(str)
    local pos = 1
    local function err(msg) error(string.format("JSON %s at %d", msg, pos), 0) end
    local function ws() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end
    local parseValue

    local function parseString()
        pos = pos + 1
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local e = str:sub(pos + 1, pos + 1)
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                if map[e] then
                    table.insert(buf, map[e]); pos = pos + 2
                elseif e == "u" then
                    local hex = str:sub(pos + 2, pos + 5)
                    if not hex:match("^%x%x%x%x$") then err("bad unicode escape") end
                    local cp = tonumber(hex, 16)
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    table.insert(buf, utf8char(cp))
                else
                    err("bad escape")
                end
            else
                local j = str:find('["\\]', pos) or (#str + 1)
                table.insert(buf, str:sub(pos, j - 1))
                pos = j
            end
        end
        return table.concat(buf)
    end

    function parseValue()
        ws()
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            ws()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                ws()
                if str:sub(pos, pos) ~= '"' then err("expected key") end
                local k = parseString()
                ws()
                if str:sub(pos, pos) ~= ":" then err("expected ':'") end
                pos = pos + 1
                obj[k] = parseValue()
                ws()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then err("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            ws()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                table.insert(arr, parseValue())
                ws()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then err("expected ',' or ']'") end
            end
        elseif c == '"' then
            return parseString()
        elseif str:find("^true", pos) then pos = pos + 4; return true
        elseif str:find("^false", pos) then pos = pos + 5; return false
        elseif str:find("^null", pos) then pos = pos + 4; return nil
        else
            local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" or not tonumber(num) then err("unexpected character") end
            pos = pos + #num
            return tonumber(num)
        end
    end

    local v = parseValue()
    ws()
    if pos <= #str then err("trailing data") end
    return v
end

return Json
