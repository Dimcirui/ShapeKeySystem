-- ShapeKeySystem: export the setup in effect as the files of a mod (API export_mod). What is on
-- screen is what gets exported, unsaved edits included.
--
-- Output: export/<prefix>/reframework/data/ShapeKeySystem/mods/..., the tree a mod archive holds:
--   <model>/<representative part>.json   binding naming everything below, with fingerprints
--   <model>/sculpt/<id>.json             the sculpt values in effect
--   profiles/<prefix>.<id>.json          the profile in effect, flattened (builtin: referenced only)
--   conditions/<prefix>.<id>.json        the condition set in effect
--   drivers/<prefix>.<id>.json           the driver set in effect
-- Global ids get the author prefix so two mods never ship the same file; file names are ASCII.
--
-- X.build(src) is pure: src = { prefix, model, base (representative part), binding (data or nil),
-- profile_id, profile (sks.profile/1 data to copy, nil = reference profile_id as it is), sculpt
-- (sks.sculpt/1 data), conditions ({id, name, data} or nil), drivers ({id, name, groups} or nil),
-- fingerprints, gains, eyes }. Returns { {rel, data} } (rel under mods\).

local U = require("ShapeKeySystem_Core.Util")

local X = {}

function X.valid_prefix(p)
    return type(p) == "string" and #p <= 24 and p:match("^[%w_%-]+$") ~= nil
end

function X.root(prefix)
    return U.path("export", prefix, "reframework", "data", "ShapeKeySystem", "mods")
end

function X.build(src)
    local prefix, files = src.prefix, {}
    local function pid(id)
        if id:sub(1, #prefix + 1) == prefix .. "." then return id end
        return prefix .. "." .. U.file_id(id)
    end
    local function add(rel, data) files[#files + 1] = { rel = rel, data = data } end

    local b = U.copy(src.binding or {})
    b.global, b.deleted = nil, nil
    b.schema, b.part = "sks.binding/1", src.base

    b.profile = src.profile_id
    if src.profile and src.profile_id then
        local d = U.copy(src.profile)
        d.id = pid(src.profile_id)
        add("profiles\\" .. d.id .. ".json", d)
        b.profile = d.id
    end

    b.sculpt = nil
    if src.sculpt then
        add(src.model .. "\\sculpt\\" .. U.file_id(src.sculpt.name) .. ".json", U.copy(src.sculpt))
        b.sculpt = src.sculpt.name
    end

    b.conditions = nil
    if src.conditions then
        local d = U.copy(src.conditions.data)
        d.schema, d.name = "sks.conditions/1", src.conditions.name
        b.conditions = pid(src.conditions.id)
        add("conditions\\" .. b.conditions .. ".json", d)
    end

    b.drivers = nil
    if src.drivers then
        b.drivers = pid(src.drivers.id)
        add("drivers\\" .. b.drivers .. ".json", { schema = "sks.drivers/2", name = src.drivers.name, groups = U.copy(src.drivers.groups) })
    end

    b.gains, b.eyes = U.copy(src.gains), U.copy(src.eyes)
    if b.gains and b.gains.for_profile == src.profile_id then b.gains.for_profile = b.profile end
    b.fingerprints = src.fingerprints
    add(src.model .. "\\" .. src.base .. ".json", b)
    return files
end

return X
