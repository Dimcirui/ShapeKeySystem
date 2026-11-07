-- ShapeKeySystem: display names for shape keys (builtin/labels.json, <src>/names/*.json "labels").
--
-- Constraints:
-- - Display only. Matching, presets, bindings and commands keep the mesh name; a label never
--   goes into an index or a saved file, so two keys sharing a label stay two keys.
-- - Order: user/names, then mods/names, then the builtin table; a name the builtin table only
--   knows through an alias set takes its ARKit name's label.

local U = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")

local L = {}

L.SCHEMA = "sks.labels/1"
L.builtin = {}   -- norm(name) -> label
L.extra = {}     -- the same for mod and user name tables
L.names = {}     -- every labelled name as written (NameHash needs the exact spelling)
-- section titles of the names files: norm(first key of the section) -> title. Display only, like
-- the labels: "sections": [{ "title": "EYE", "before": "eye_close" }, ...]
L.sections = {}

local function add(t, name, label)
    if type(name) == "string" and name ~= "" and type(label) == "string" and label ~= "" then
        t[U.norm(name)] = label
        L.names[#L.names + 1] = name
    end
end

function L.load()
    L.builtin, L.extra, L.names, L.sections = {}, {}, {}, {}
    local data = U.load_json(U.path("builtin", "labels.json"))
    if data and (data.schema == nil or data.schema == L.SCHEMA) and type(data.sets) == "table" then
        for _, set in pairs(data.sets) do
            for name, label in pairs(type(set) == "table" and type(set.labels) == "table" and set.labels or {}) do
                add(L.builtin, name, label)
            end
        end
    end
    -- mods first so a user file overwrites the same name
    for _, src in ipairs({ "mods", "user" }) do
        for _, f in ipairs(U.list_json(src .. "\\names")) do
            local d = U.load_json(f.path)
            if d and (d.schema == nil or d.schema == "sks.names/1") and type(d.labels) == "table" then
                for name, label in pairs(d.labels) do add(L.extra, name, label) end
            end
            if d and (d.schema == nil or d.schema == "sks.names/1") and type(d.sections) == "table" then
                for _, sec in ipairs(d.sections) do
                    if type(sec) == "table" and type(sec.title) == "string" and sec.title ~= ""
                        and type(sec.before) == "string" and sec.before ~= "" then
                        L.sections[U.norm(sec.before)] = sec.title
                    end
                end
            end
        end
    end
end

-- A channel named like "=====EYE=====" only separates keys (Blender habit): its title, else nil.
function L.separator_title(name)
    if type(name) ~= "string" or name:sub(1, 1) ~= "=" then return nil end
    local title = name:gsub("^[=%s]+", ""):gsub("[=%s]+$", "")
    return title
end

-- the section title the names files put before this key, or nil
function L.section_before(name)
    if type(name) ~= "string" or name == "" then return nil end
    return L.sections[U.norm(name)]
end

-- Label for a mesh channel or key name ("node.Name" and "_LODn" forms included), or nil.
function L.of(name)
    if type(name) ~= "string" or name == "" then return nil end
    local keys, n = Names.keys(name)
    for i = 1, n do
        local v = L.extra[keys[i]]
        if v then return v end
    end
    for i = 1, n do
        local v = L.builtin[keys[i]]
        if v then return v end
    end
    -- after the loops: arkit_of reuses the key buffer
    local a = Names.arkit_of(name)
    return a and L.builtin[U.norm(a)] or nil
end

return L
