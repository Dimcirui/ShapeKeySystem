-- ShapeKeySystem: file helpers, name normalisation, small utilities.
-- Paths are relative to reframework/data (what json.load_file / fs.glob use).

local U = {}

U.ROOT = "ShapeKeySystem\\"

function U.path(...)
    return U.ROOT .. table.concat({ ... }, "\\")
end

function U.load_json(path)
    local ok, data = pcall(json.load_file, path)
    if ok and type(data) == "table" then return data end
    return nil
end

function U.save_json(path, data)
    local ok, res = pcall(json.dump_file, path, data, 2)
    return ok and res ~= false
end

-- List the .json files directly inside ShapeKeySystem\<sub> ("builtin\\profiles" etc.).
-- Returns { {path=, file=, base=} }, sorted by file name.
function U.list_json(sub)
    local pattern = "ShapeKeySystem\\\\" .. sub:gsub("\\", "\\\\") .. "\\\\[^\\\\]+\\.json"
    local ok, files = pcall(fs.glob, pattern)
    local out = {}
    if ok and type(files) == "table" then
        for _, p in ipairs(files) do
            local file = p:match("([^\\/]+)$")
            out[#out + 1] = { path = p, file = file, base = file:gsub("%.json$", "") }
        end
    end
    table.sort(out, function(a, b) return a.file < b.file end)
    return out
end

-- Width folding for MMD-style names: full-width ASCII (U+FF01..FF5E) -> ASCII, half-width
-- katakana (U+FF61..FF9F) -> full-width with ﾞ/ﾟ merged into the kana before them, the
-- ideographic space dropped. "ｳｨﾝｸ２右" and "ウィンク2右" fold to the same string.
local HALF_KANA = {}
do
    local half = { 0xFF61, 0xFF62, 0xFF63, 0xFF64, 0xFF65 }
    local full = { 0x3002, 0x300C, 0x300D, 0x3001, 0x30FB }
    local kana = "ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン"
    local code = 0xFF66
    for _, c in utf8.codes(kana) do
        half[#half + 1] = code; full[#full + 1] = c; code = code + 1
    end
    for i, h in ipairs(half) do HALF_KANA[h] = full[i] end
end
-- kana that take the voiced mark (+1); the ハ row also takes the semi-voiced mark (+2)
local VOICED, SEMI = {}, {}
for _, c in ipairs({ 0x30AB, 0x30AD, 0x30AF, 0x30B1, 0x30B3, 0x30B5, 0x30B7, 0x30B9, 0x30BB, 0x30BD,
                     0x30BF, 0x30C1, 0x30C4, 0x30C6, 0x30C8, 0x30CF, 0x30D2, 0x30D5, 0x30D8, 0x30DB }) do
    VOICED[c] = true
end
for _, c in ipairs({ 0x30CF, 0x30D2, 0x30D5, 0x30D8, 0x30DB }) do SEMI[c] = true end

function U.fold_width(s)
    local out, n = {}, 0
    local ok = pcall(function()
        for _, c in utf8.codes(s) do
            if c >= 0xFF01 and c <= 0xFF5E then
                c = c - 0xFEE0
            elseif HALF_KANA[c] then
                c = HALF_KANA[c]
            elseif c == 0x301C then
                c = 0x7E   -- 〜 -> ~, same as full-width ～
            end
            local prev = out[n]
            if (c == 0xFF9E or c == 0x3099 or c == 0x309B) and prev and (VOICED[prev] or prev == 0x30A6) then
                out[n] = (prev == 0x30A6) and 0x30F4 or prev + 1
            elseif (c == 0xFF9F or c == 0x309A or c == 0x309C) and prev and SEMI[prev] then
                out[n] = prev + 2
            elseif c ~= 0x3000 then
                n = n + 1; out[n] = c
            end
        end
    end)
    if not ok then return s end   -- not valid UTF-8: compare the bytes as they are
    return utf8.char(table.unpack(out, 1, n))
end

-- Case / separator / width insensitive key: "Eye_Left_Blink" and "eyeleftblink" compare equal,
-- so do "ｳｨﾝｸ２右" and "ウィンク2右".
function U.norm(name)
    if name:find("[\128-\255]") then name = U.fold_width(name) end
    return (name:lower():gsub("[_%-%s]", ""))
end

-- Safe file-name stem for user presets.
function U.safe_id(name)
    local s = tostring(name or ""):gsub("[\\/:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- 32-bit FNV-1a over a string, as 8 hex digits (channel-set fingerprints).
function U.fnv(s)
    local h = 0x811C9DC5
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 0x01000193) & 0xFFFFFFFF
    end
    return string.format("%08x", h)
end

-- deterministic text form of a JSON-like value (sorted keys), for change detection
function U.signature(v)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            local x = v[k]
            if x == nil then x = v[tonumber(k)] end
            parts[#parts + 1] = k .. "=" .. U.signature(x)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "number" then
        return string.format("%.6g", v)
    end
    return tostring(v)
end

function U.copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = U.copy(x) end
    return t
end

function U.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

return U
