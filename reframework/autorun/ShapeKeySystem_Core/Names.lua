-- ShapeKeySystem: canonical names (ARKit lowerCamelCase), alias tables, and mesh channel
-- name matching (case-insensitive, accepts "node.Name" and "_LODn" suffixes).

local U = require("ShapeKeySystem_Core.Util")

local N = {}

N.ARKIT52 = {
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight",
    "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel",
    "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
    "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft",
    "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
}

N.ARKIT_BY_NORM = {}
for _, n in ipairs(N.ARKIT52) do N.ARKIT_BY_NORM[U.norm(n)] = n end

-- alias sets: set name -> { norm(alias) = canonical }
N.alias_sets = {}
N.alias_names = {}   -- every alias and canonical as written (NameHash needs the exact spelling)

function N.load_aliases()
    N.alias_sets, N.alias_names = {}, {}
    local data = U.load_json(U.path("builtin", "aliases.json"))
    if data and type(data.sets) == "table" then
        for set, map in pairs(data.sets) do
            local t = {}
            for a, c in pairs(map) do
                t[U.norm(a)] = c
                N.alias_names[#N.alias_names + 1] = a; N.alias_names[#N.alias_names + 1] = c
            end
            N.alias_sets[set] = t
        end
    end
end

-- Candidate lookup keys for one mesh channel name, most specific first.
-- "blendShape1_LOD1.JawOpen_LOD1" -> full, after first dot, after last dot; each also without _LODn.
-- Returns keys (normalised) and whether the name was an LOD copy.
local key_buf = {}
function N.keys(channel_name)
    local n = 0
    local is_lod = false
    local function add(s)
        if not s or s == "" then return end
        local base = s:gsub("_[Ll][Oo][Dd]%d+$", "")
        if base ~= s then is_lod = true end
        n = n + 1; key_buf[n] = U.norm(s)
        if base ~= s then n = n + 1; key_buf[n] = U.norm(base) end
    end
    add(channel_name)
    local first = channel_name:match("^[^%.]+%.(.+)$")
    add(first)
    local last = channel_name:match("^.+%.([^%.]+)$")
    if last ~= first then add(last) end
    for i = n + 1, #key_buf do key_buf[i] = nil end
    return key_buf, n, is_lod
end

-- index[N.META] = { rank = {norm -> n}, ranked = {slot -> true}, unless = {slot -> {slots}} }
-- for profile entries with "any" / "unless" (MMD-style names, see N.match_part)
N.META = {}

-- Build a lookup index for a compiled profile: norm(name) -> slot, plus aliases that point
-- at a channel present in the profile. entries (optional) = the resolved profile channels:
--   "any": ["name", ...]   more mesh names for the channel, best first; on one part only the
--                          best-ranked name present drives it (the channel name itself is rank 0)
--   "unless": ["channel", ...]  the channel is left alone on a part where one of these matched
function N.build_index(channel_names, alias_set_names, entries)
    local idx = {}
    for slot, name in ipairs(channel_names) do idx[U.norm(name)] = slot end
    local meta = { rank = {}, ranked = {}, unless = {} }
    for slot, e in ipairs(entries or {}) do
        if type(e.any) == "table" then
            meta.ranked[slot] = true
            for r, a in ipairs(e.any) do
                local k = type(a) == "string" and U.norm(a)
                if k and k ~= "" and idx[k] == nil then idx[k] = slot; meta.rank[k] = r end
            end
        end
    end
    local slot_of = {}
    for slot, name in ipairs(channel_names) do slot_of[name] = slot end
    for slot, e in ipairs(entries or {}) do
        if type(e.unless) == "table" then
            local list = {}
            for _, other in ipairs(e.unless) do
                if slot_of[other] then list[#list + 1] = slot_of[other] end
            end
            if #list > 0 then meta.unless[slot] = list end
        end
    end
    for _, set in ipairs(alias_set_names or {}) do
        local map = N.alias_sets[set]
        if map then
            for a, canonical in pairs(map) do
                local s = idx[U.norm(canonical)]
                if s and idx[a] == nil then idx[a] = s end
            end
        end
    end
    idx[N.META] = meta
    return idx
end

-- Match one mesh channel name against an index. Returns slot, matched key or nil.
function N.match(index, channel_name)
    local keys, n = N.keys(channel_name)
    for i = 1, n do
        local s = index[keys[i]]
        if s then return s, keys[i] end
    end
    return nil
end

-- Match every channel of one part. Returns sel[i] = slot or false for names[i], with "any"
-- ranking and "unless" applied (LOD copies of the chosen name are all kept).
function N.match_part(index, names)
    local meta = index[N.META]
    local sel, rank, best = {}, {}, {}
    for i, cn in ipairs(names) do
        local s, key = false, nil
        if cn ~= "" then s, key = N.match(index, cn) end
        sel[i] = s or false
        if s and meta and meta.ranked[s] then
            local r = meta.rank[key] or 0
            rank[i] = r
            if best[s] == nil or r < best[s] then best[s] = r end
        end
    end
    if not meta then return sel end
    local present = {}
    for i, s in ipairs(sel) do
        if s and rank[i] and rank[i] > best[s] then sel[i] = false end
        if sel[i] then present[sel[i]] = true end
    end
    if next(meta.unless) then
        local drop = {}
        for s, list in pairs(meta.unless) do
            if present[s] then
                for _, o in ipairs(list) do
                    if present[o] then drop[s] = true; break end
                end
            end
        end
        for i, s in ipairs(sel) do
            if s and drop[s] then sel[i] = false end
        end
    end
    return sel
end

-- ARKit canonical name for a mesh channel (through every alias set), or nil.
function N.arkit_of(channel_name)
    local keys, n = N.keys(channel_name)
    for i = 1, n do
        local k = keys[i]
        local c = N.ARKIT_BY_NORM[k]
        if c then return c end
        for _, map in pairs(N.alias_sets) do
            local a = map[k]
            if a and N.ARKIT_BY_NORM[U.norm(a)] then return N.ARKIT_BY_NORM[U.norm(a)] end
        end
    end
    return nil
end

return N
