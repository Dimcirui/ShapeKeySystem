-- ShapeKeySystem: channel names on engines that only keep their hashes.
-- Some RE Engine builds (Onimusha: Way of the Sword) drop via.render.Mesh.getBlendShapeChannelName
-- and keep get_ChannelNameHash: murmur3 x86 32-bit over the full channel name in UTF-16LE, seed
-- 0xFFFFFFFF (checked against vanilla and mod meshes, 2026-10-14). A hash is turned back into a
-- name through every name SKS knows (H.table); the rest show as "#XXXXXXXX", which a preset can
-- store and match like any other name.

local U = require("ShapeKeySystem_Core.Util")

local H = {}

H.NAMES_SCHEMA = "sks.names/1"

-- UTF-8 -> UTF-16 code units
local function utf16(s)
    local units = {}
    for _, c in utf8.codes(s) do
        if c >= 0x10000 then
            c = c - 0x10000
            units[#units + 1] = 0xD800 + (c >> 10)
            units[#units + 1] = 0xDC00 + (c & 0x3FF)
        else
            units[#units + 1] = c
        end
    end
    return units
end

local M = 0xFFFFFFFF
local function mul(a, b) return (a * b) & M end
local function rotl(x, r) return ((x << r) | (x >> (32 - r))) & M end

-- murmur3 x86 32-bit over the UTF-16LE bytes, seed 0xFFFFFFFF
function H.murmur3(s)
    local bytes = {}
    for _, x in ipairs(utf16(s)) do bytes[#bytes + 1] = x & 0xFF; bytes[#bytes + 1] = (x >> 8) & 0xFF end
    local c1, c2 = 0xcc9e2d51, 0x1b873593
    local h = 0xFFFFFFFF
    local n = #bytes
    local i = 1
    while i + 3 <= n do
        local k = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16) | (bytes[i + 3] << 24)
        k = mul(rotl(mul(k, c1), 15), c2)
        h = rotl(h ~ k, 13)
        h = (mul(h, 5) + 0xe6546b64) & M
        i = i + 4
    end
    local k, rem = 0, n - i + 1
    if rem >= 3 then k = k ~ (bytes[i + 2] << 16) end
    if rem >= 2 then k = k ~ (bytes[i + 1] << 8) end
    if rem >= 1 then
        k = k ~ bytes[i]
        k = mul(rotl(mul(k, c1), 15), c2)
        h = h ~ k
    end
    h = h ~ n
    h = h ~ (h >> 16); h = mul(h, 0x85ebca6b)
    h = h ~ (h >> 13); h = mul(h, 0xc2b2ae35)
    h = h ~ (h >> 16)
    return h
end

local memo = {}
function H.hash(s)
    local v = memo[s]
    if not v then v = H.murmur3(s); memo[s] = v end
    return v
end
local hash = H.hash

function H.label(h) return string.format("#%08X", h) end

-- The usual spellings of an ASCII name, so "browDownLeft" also finds a mesh's "Brow_Down_Left"
-- (name matching elsewhere ignores case and underscores; a hash cannot). Words split at "_",
-- spaces and lower -> upper case steps.
local function title(w) return w:sub(1, 1):upper() .. w:sub(2):lower() end
function H.spellings(name)
    local out = { name }
    if name:find("[\128-\255]") then return out end
    local words = {}
    for part in name:gsub("(%l)(%u)", "%1 %2"):gmatch("[^_%s]+") do words[#words + 1] = part end
    if #words < 2 then return out end
    local t, l = {}, {}
    for i, w in ipairs(words) do t[i] = title(w); l[i] = w:lower() end
    out[#out + 1] = table.concat(t)                    -- BrowDownLeft
    out[#out + 1] = l[1] .. table.concat(t, "", 2)     -- browDownLeft
    out[#out + 1] = table.concat(t, "_")               -- Brow_Down_Left
    out[#out + 1] = table.concat(l, "_")               -- brow_down_left
    return out
end

-- The name tables mods and users add: <src>/names/*.json, { "schema": "sks.names/1",
-- "names": ["Breasts_big", ...] }. Names only: the hash says which mesh channel is which.
function H.table_names()
    local out = {}
    for _, src in ipairs({ "user", "mods" }) do
        for _, f in ipairs(U.list_json(src .. "\\names")) do
            local d = U.load_json(f.path)
            if d and (d.schema == nil or d.schema == H.NAMES_SCHEMA) and type(d.names) == "table" then
                for _, n in ipairs(d.names) do
                    if type(n) == "string" and n ~= "" then out[#out + 1] = n end
                end
            end
        end
    end
    return out
end

-- hash -> name for every spelling of every name given; the first name to claim a hash keeps it
function H.table(names)
    local t = {}
    for _, n in ipairs(names) do
        for _, s in ipairs(H.spellings(n)) do
            local h = hash(s)
            if t[h] == nil then t[h] = s end
        end
    end
    return t
end

local function unbox(v)
    if math.type(v) == "integer" then return v & M end
    if type(v) == "number" then return math.tointeger(v) end
    local ok, s = pcall(function() return v:call("ToString()") end)
    local n = ok and tonumber(s)
    return n and math.tointeger(n) or nil
end

-- names[1..n] of a mesh from its name hashes (known: H.table); nil when the mesh has none
function H.names_of(mesh, n, known)
    local ok, arr = pcall(mesh.call, mesh, "get_ChannelNameHash")
    if not ok or not arr then return nil end
    local ok2, elems = pcall(arr.get_elements, arr)
    -- REF can expose get_elements() as an indexed userdata container instead of a Lua table.
    if not ok2 or (type(elems) ~= "table" and type(elems) ~= "userdata") then elems = nil end
    local names = {}
    for i = 1, n do
        local h
        if elems then pcall(function() h = unbox(elems[i]) end) end
        if h == nil then
            local got, v = pcall(arr.call, arr, "get_Item", i - 1)
            if got then h = unbox(v) end
        end
        names[i] = h and (known[h] or H.label(h)) or ""
    end
    return names
end

return H
