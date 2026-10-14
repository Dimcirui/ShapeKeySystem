-- ShapeKeySystem: parent presets (bindings) and sculpt presets on disk.
-- Layout (reframework/data/ShapeKeySystem), mods/ read-only, user/ the only place we write:
--   <src>/default.json                     global default binding
--   <src>/sculpt/*.json                    general sculpt presets (not tied to one model)
--   <src>/<model>/<part>.json              per-part bindings, e.g. mods/ch03_012_001/ch03_012_0014.json
--   <src>/<model>/sculpt/*.json            sculpt presets that belong to that model
-- Profiles stay global (builtin/, mods/profiles, user/profiles; see Profile.lua).
--
-- Binding lookup for part P = ch03_012_0014 (series 012, model 001, slot 4). The model's
-- representative R is its slot-2 (body) part, ch03_012_0012:
--   1. R with "global": true      -> one preset for every part of the model, own files ignored
--   2. P itself                   -> each part's own file wins
--   3. R                          -> the model's shared preset
--   4. default.json
-- Each step tries user/ then mods/. A mods binding may carry "fingerprints": {part: hash}; when
-- the worn mesh's channel fingerprint differs, the file is stale (left by a mod whose mesh was
-- later overwritten by another mod) and is skipped. user/ files are never skipped for that.
-- A binding's sculpt name is looked up in its own model folder first, then among the general ones.
-- REFramework Lua cannot delete files reliably, so "deleting" a user file writes a tombstone
-- { "deleted": true }; tombstoned files are treated as missing.

local U = require("ShapeKeySystem_Core.Util")

local P = {}

P.BINDING_SCHEMA = "sks.binding/1"
P.SCULPT_SCHEMA = "sks.sculpt/1"

local function live_json(path)
    local data = U.load_json(path)
    if not data or data.deleted == true then return nil end
    return data
end

-- model a part belongs to, slot, and the part that represents the model: the adapter's naming
-- (`P.adapter`); nil when the game has none or the part does not follow it
P.adapter = {}   -- set by SKS.init
function P.model_of(part)
    local f = P.adapter.model_of
    if not f then return nil end
    return f(part)
end

function P.representative_of(part)
    local f = P.adapter.representative_of
    return f and f(part) or nil
end

-- folder of a part's bindings: its model, or the part ID itself when the adapter names no model
function P.folder_of(part)
    return P.model_of(part) or U.safe_id(part)
end

-- relative file path and the short form shown in the UI
local function binding_file(source, part_or_default)
    if part_or_default == "default" then
        return U.path(source, "default.json"), source .. "/default.json"
    end
    local folder = P.folder_of(part_or_default)
    local base = U.safe_id(part_or_default)
    return U.path(source, folder, base .. ".json"), source .. "/" .. folder .. "/" .. base .. ".json"
end

local function sculpt_file(source, folder, id)
    if folder then return U.path(source, folder, "sculpt", id .. ".json") end
    return U.path(source, "sculpt", id .. ".json")
end

-- ---------------------------------------------------------------- validation
local function check_values(t, what)
    if t == nil then return true end
    if type(t) ~= "table" then return false, what .. " must be an object" end
    for k, v in pairs(t) do
        if type(k) ~= "string" or type(v) ~= "number" then return false, what .. " must map names to numbers" end
    end
    return true
end

function P.validate_binding(d)
    if type(d) ~= "table" then return false, "not an object" end
    if d.schema ~= nil and d.schema ~= P.BINDING_SCHEMA then return false, "unsupported schema " .. tostring(d.schema) end
    for _, k in ipairs({ "part", "profile", "sculpt", "conditions" }) do
        if d[k] ~= nil and type(d[k]) ~= "string" then return false, k .. " must be a string" end
    end
    if d.global ~= nil and type(d.global) ~= "boolean" then return false, "global must be true / false" end
    if d.fingerprints ~= nil then
        if type(d.fingerprints) ~= "table" then return false, "fingerprints must be an object" end
        for k, v in pairs(d.fingerprints) do
            if type(k) ~= "string" or type(v) ~= "string" then return false, "fingerprints must map part IDs to strings" end
        end
    end
    local g = d.gains
    if g ~= nil then
        if type(g) ~= "table" then return false, "gains must be an object" end
        for _, k in ipairs({ "master_gain", "gaze_gain", "smoothing" }) do
            if g[k] ~= nil and type(g[k]) ~= "number" then return false, "gains." .. k .. " must be a number" end
        end
        if g.for_profile ~= nil and type(g.for_profile) ~= "string" then return false, "gains.for_profile must be a string" end
        local ok, msg = check_values(g.region_gains, "gains.region_gains"); if not ok then return false, msg end
        ok, msg = check_values(g.channel_gains, "gains.channel_gains"); if not ok then return false, msg end
    end
    local e = d.eyes
    if e ~= nil then
        if type(e) ~= "table" then return false, "eyes must be an object" end
        local ok, msg = check_values(e.full_deg, "eyes.full_deg"); if not ok then return false, msg end
        for _, k in ipairs({ "invert", "sets" }) do
            if e[k] ~= nil then
                if type(e[k]) ~= "table" then return false, "eyes." .. k .. " must be an object" end
                for kk, v in pairs(e[k]) do
                    if type(kk) ~= "string" or type(v) ~= "boolean" then return false, "eyes." .. k .. " must map names to booleans" end
                end
            end
        end
    end
    return true
end

function P.validate_sculpt(d)
    if type(d) ~= "table" then return false, "not an object" end
    if d.schema ~= nil and d.schema ~= P.SCULPT_SCHEMA then return false, "unsupported schema " .. tostring(d.schema) end
    if d.name ~= nil and type(d.name) ~= "string" then return false, "name must be a string" end
    local ok, msg = check_values(d.values, "values"); if not ok then return false, msg end
    if d.overrides ~= nil then
        if type(d.overrides) ~= "table" then return false, "overrides must be an object" end
        for part, vals in pairs(d.overrides) do
            ok, msg = check_values(vals, "overrides." .. tostring(part)); if not ok then return false, msg end
        end
    end
    if d.target ~= nil and type(d.target) ~= "table" then return false, "target must be an object" end
    return true
end

-- ---------------------------------------------------------------- bindings
-- Returns { part, chain = {{path, exists, hit, level, error?}}, hit = shown path?, source?, data?,
--           base? (part ID of the file, or "default"), level?, folder? }
-- level: "global" / "own" / "model" / "default".
-- only_source = "mods": the chain a mod alone defines (the defaults for reset / A-B preview).
-- fingerprint: the worn mesh's channel fingerprint for this part (stale check), may be nil.
function P.resolve_binding(part, only_source, fingerprint)
    local rep = P.representative_of(part)
    local steps = {}
    if rep then steps[#steps + 1] = { base = rep, level = "global", need_global = true } end
    steps[#steps + 1] = { base = part, level = "own" }
    if rep and rep ~= part then steps[#steps + 1] = { base = rep, level = "model" } end
    steps[#steps + 1] = { base = "default", level = "default" }
    local res = { part = part, chain = {} }
    local listed = {}
    local sources = only_source and { only_source } or { "user", "mods" }
    for _, step in ipairs(steps) do
        for _, source in ipairs(sources) do
            local path, shown = binding_file(source, step.base)
            local data = live_json(path)
            local entry = { path = shown, exists = data ~= nil, hit = false, level = step.level }
            if step.need_global and not (data and data.global == true) then
                entry = nil   -- not a global preset: it is listed again at its own / model step
            elseif listed[shown] then
                entry = nil   -- the global preset again at its model step
            elseif data and not res.hit then
                local ok, msg = P.validate_binding(data)
                local fps = type(data.fingerprints) == "table" and data.fingerprints or nil
                if ok and source == "mods" and fingerprint and fps and fps[part] and fps[part] ~= fingerprint then
                    ok, msg = false, "通道指纹不符（可能是被覆盖的旧 mod 留下的），已跳过"
                end
                if ok then
                    entry.hit = true
                    res.hit, res.source, res.data, res.base, res.level = shown, source, data, step.base, step.level
                    res.folder = step.base ~= "default" and P.folder_of(step.base) or nil
                else
                    entry.error = msg
                end
            end
            if entry then res.chain[#res.chain + 1] = entry; listed[shown] = true end
        end
    end
    return res
end

-- base: a part ID (written to user/<model>/<part>.json) or "default" (user/default.json)
function P.write_binding(base, data)
    data.schema = P.BINDING_SCHEMA
    if base ~= "default" then data.part = base end
    local ok, msg = P.validate_binding(data)
    if not ok then return false, "E_SCHEMA", msg end
    local path, shown = binding_file("user", base)
    if not U.save_json(path, data) then return false, "E_IO", "write failed" end
    return true, nil, nil, { path = shown }
end

function P.user_binding_exists(base)
    return live_json((binding_file("user", base))) ~= nil
end

function P.tombstone_binding(base)
    return U.save_json((binding_file("user", base)), { deleted = true })
end

-- ---------------------------------------------------------------- sculpt presets
-- list entries: { id, name, source, folder (model or nil = general), path, target_part,
--                 channel_hash, values, overrides }; user before mods, general before folders
P.sculpt_list = {}

local function glob(rx)
    local ok, files = pcall(fs.glob, rx)
    return ok and type(files) == "table" and files or {}
end

function P.load_sculpt()
    local list = {}
    for _, source in ipairs({ "user", "mods" }) do
        local found = {}
        for _, p in ipairs(glob("ShapeKeySystem\\\\" .. source .. "\\\\sculpt\\\\[^\\\\]+\\.json")) do
            found[#found + 1] = { path = p, folder = nil }
        end
        for _, p in ipairs(glob("ShapeKeySystem\\\\" .. source .. "\\\\[^\\\\]+\\\\sculpt\\\\[^\\\\]+\\.json")) do
            local folder = p:match("ShapeKeySystem[\\/]" .. source .. "[\\/]([^\\/]+)[\\/]sculpt[\\/]")
            if folder and folder ~= "sculpt" then found[#found + 1] = { path = p, folder = folder } end
        end
        table.sort(found, function(a, b)
            if (a.folder or "") ~= (b.folder or "") then return (a.folder or "") < (b.folder or "") end
            return a.path < b.path
        end)
        for _, f in ipairs(found) do
            local data = live_json(f.path)
            if data and P.validate_sculpt(data) then
                local base = f.path:match("([^\\/]+)%.json$")
                local target = data.target or {}
                list[#list + 1] = {
                    id = base, name = data.name or base, source = source, folder = f.folder, path = f.path,
                    target_part = target.part, channel_hash = target.channel_hash,
                    values = data.values or {}, overrides = data.overrides or {},
                }
            end
        end
    end
    P.sculpt_list = list
    return list
end

-- by name (or file id). folder given: that model's presets first, then the general ones.
-- folder nil: the general ones only, unless any_folder is set (UI lookups by explicit choice).
function P.find_sculpt(name, folder, source, any_folder)
    if type(name) ~= "string" then return nil end
    local function match(e, want_folder)
        return (e.name == name or e.id == name) and e.folder == want_folder and (not source or e.source == source)
    end
    if folder then
        for _, e in ipairs(P.sculpt_list) do if match(e, folder) then return e end end
    end
    for _, e in ipairs(P.sculpt_list) do if match(e, nil) then return e end end
    if any_folder then
        for _, e in ipairs(P.sculpt_list) do
            if (e.name == name or e.id == name) and (not source or e.source == source) then return e end
        end
    end
    return nil
end

-- folder nil = general preset
function P.save_sculpt(name, folder, payload)
    local id = U.safe_id(name)
    if id == "" then return false, "E_BAD_ARGS", "empty name" end
    payload.schema = P.SCULPT_SCHEMA
    payload.name = name
    local ok, msg = P.validate_sculpt(payload)
    if not ok then return false, "E_SCHEMA", msg end
    if not U.save_json(sculpt_file("user", folder, id), payload) then return false, "E_IO", "write failed" end
    P.load_sculpt()
    return true, nil, nil, { id = id, folder = folder }
end

function P.tombstone_sculpt(folder, id)
    local ok = U.save_json(sculpt_file("user", folder, id), { deleted = true })
    P.load_sculpt()
    return ok
end

-- copy an external file into user/ after validation (kind: "bindings" / "sculpt" / "profiles")
function P.import(kind, path, base)
    local data = U.load_json(path)
    if not data then return false, "E_IO", "cannot read " .. tostring(path) end
    if kind == "bindings" then
        local ok, msg = P.validate_binding(data)
        if not ok then return false, "E_SCHEMA", msg end
        base = base or data.part or "default"
        return P.write_binding(base, data)
    elseif kind == "sculpt" then
        local ok, msg = P.validate_sculpt(data)
        if not ok then return false, "E_SCHEMA", msg end
        local folder = data.target and data.target.part and P.folder_of(data.target.part) or nil
        return P.save_sculpt(base or data.name or "imported", folder, data)
    elseif kind == "profiles" then
        if type(data.channels) ~= "table" then return false, "E_SCHEMA", "channels missing" end
        base = U.safe_id(base or data.id or data.name or "")
        if base == "" then return false, "E_BAD_ARGS", "no name for the imported file" end
        if not U.save_json(U.path("user", "profiles", base .. ".json"), data) then return false, "E_IO", "write failed" end
        return true, nil, nil, { id = base }
    end
    return false, "E_BAD_ARGS", "unknown kind " .. tostring(kind)
end

return P
