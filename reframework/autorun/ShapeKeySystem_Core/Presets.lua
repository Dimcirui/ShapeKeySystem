-- ShapeKeySystem: parent presets (bindings) and sculpt presets on disk.
-- Layout (reframework/data/ShapeKeySystem), mods/ read-only, user/ the only place we write:
--   <src>/default.json                     global default binding
--   <src>/sculpt/*.json                    general sculpt presets (not tied to one model)
--   <src>/<model>/<representative>.json    the model's binding, e.g. mods/ch03_012_001/ch03_012_0012.json
--   <src>/<model>/sculpt/*.json            sculpt presets that belong to that model
-- Profiles stay global (builtin/, mods/profiles, user/profiles; see Profile.lua).
--
-- A character has one binding: the one of its primary model (P.primary_part; the body's model when
-- parts of several models are worn). Lookup for model M with representative R (Wilds: the slot-2
-- part, ch03_012_0012): 1. R's file, 2. default.json; each step tries user/ then mods/.
-- A mods binding may carry "fingerprints": {part: hash}; when a worn mesh's channel fingerprint
-- differs, the file is stale (left by a mod whose mesh was later overwritten by another mod) and
-- is skipped. user/ files are never skipped for that. "global" is ignored.
-- A binding's sculpt name is looked up in its own model folder first, then among the general ones.
-- REFramework Lua cannot delete files reliably, so "deleting" a user file writes a tombstone
-- { "deleted": true }; tombstoned files are treated as missing.

local U = require("ShapeKeySystem_Core.Util")

local P = {}

P.BINDING_SCHEMA = "sks.binding/1"
P.SCULPT_SCHEMA = "sks.sculpt/1"

-- 一次扫描内按路径记住读过的绑定文件（含不存在的）：扫描要按部件把同几个位置查好几遍，逐个
-- 读盘会多花几十毫秒。只在 begin_batch / end_batch 之间生效，扫描之外每次都读盘，玩家在游戏
-- 运行时改的文件下次扫描就能看到。调用方拿到的是副本。
local json_cache

function P.begin_batch() json_cache = {} end
function P.end_batch() json_cache = nil end

local function live_json(path)
    local data = json_cache and json_cache[path]
    if data == nil then
        data = U.load_json(path)
        if not data or data.deleted == true then data = false end
        if json_cache then json_cache[path] = data end
    end
    return data and U.copy(data) or nil
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
    for _, k in ipairs({ "part", "profile", "sculpt", "conditions", "drivers" }) do
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
        if e.neutral ~= nil then
            if type(e.neutral) ~= "table" then return false, "eyes.neutral must be an object" end
            for side, pose in pairs(e.neutral) do
                if (side ~= "L" and side ~= "R") or type(pose) ~= "table" then return false, "invalid eye neutral side" end
                for axis, value in pairs(pose) do
                    if (axis ~= "yaw" and axis ~= "pitch") or type(value) ~= "number"
                        or value ~= value or math.abs(value) == math.huge then return false, "invalid eye neutral angle" end
                end
            end
        end
    end
    return true
end

-- key groups of a sculpt preset (Sculpt.lua "key groups"); empty tables come back from REFramework's
-- json as null. Options of one group may share a key, and so may groups (the higher one wins).
P.MAX_KEY_OPTIONS = 8
local function check_key_groups(groups)
    if groups == nil then return true end
    if type(groups) ~= "table" then return false, "key_groups must be a list" end
    local names = {}
    for gi, g in ipairs(groups) do
        if type(g) ~= "table" or type(g.name) ~= "string" or g.name == "" then return false, "key_groups[" .. gi .. "] needs a name" end
        if names[g.name] then return false, "key group named twice: " .. g.name end
        names[g.name] = true
        local options = g.options or {}
        if type(options) ~= "table" or #options > P.MAX_KEY_OPTIONS then
            return false, string.format("key group %s: options must be a list of at most %d", g.name, P.MAX_KEY_OPTIONS)
        end
        local v = math.tointeger(g.value or 0)
        if not v or v < 0 or v > #options then return false, "key group " .. g.name .. ": value out of range" end
        for oi, o in ipairs(options) do
            if type(o) ~= "table" or type(o.name) ~= "string" then return false, "key group " .. g.name .. ": option " .. oi .. " needs a name" end
            local ok, msg = check_values(o.values, "key group " .. g.name .. "." .. o.name); if not ok then return false, msg end
        end
    end
    return true
end

-- the groups as Sculpt keeps them: every list and value present, value an integer
local function normal_key_groups(groups)
    local out = {}
    for _, g in ipairs(groups or {}) do
        local options = {}
        for i, o in ipairs(g.options or {}) do
            local values = {}
            for key, v in pairs(o.values or {}) do values[key] = v + 0.0 end
            options[i] = { name = o.name, values = values }
        end
        out[#out + 1] = { name = g.name, value = math.tointeger(g.value or 0), options = options }
    end
    return out
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
    ok, msg = check_key_groups(d.key_groups); if not ok then return false, msg end
    return true
end

-- ---------------------------------------------------------------- bindings
-- One binding covers a whole model: its file is the representative part's
-- (<src>/<model>/<representative>.json), or the part's own when the adapter names no model.
-- Files of other parts (<model>/<part>.json, written by earlier versions) take no part in the lookup.

-- the file base that binds a part: its model's representative, else the part itself
function P.binding_base(part)
    return P.representative_of(part) or part
end

-- Returns { part, chain = {{path, exists, hit, level, error?}}, hit = shown path?, source?, data?,
--           base? (representative part ID, or "default"), level?, folder? }
-- level: "model" / "default".
-- only_source = "mods": the chain a mod alone defines (the defaults for reset / A-B preview).
-- fingerprint: the worn mesh's channel fingerprint for this part; siblings: the other worn parts
-- ({id, fingerprint}). A mods file whose fingerprints disagree with any worn part of the model is stale.
function P.resolve_binding(part, only_source, fingerprint, siblings)
    local base = P.binding_base(part)
    local steps = { { base = base, level = "model" }, { base = "default", level = "default" } }
    local worn = { [part] = fingerprint }
    local folder = P.folder_of(part)
    for _, s in ipairs(siblings or {}) do
        if s.id ~= part and P.folder_of(s.id) == folder then worn[s.id] = s.fingerprint end
    end
    local res = { part = part, chain = {} }
    local sources = only_source and { only_source } or { "user", "mods" }
    local checks = {}
    -- scoped adapters (several actors) let any user file win over a mod's
    if P.adapter.scoped_bindings then
        for _, source in ipairs(sources) do
            for _, step in ipairs(steps) do checks[#checks+1] = {step, source} end
        end
    else
        for _, step in ipairs(steps) do
            for _, source in ipairs(sources) do checks[#checks+1] = {step, source} end
        end
    end
    for _, check in ipairs(checks) do
        local step, source = check[1], check[2]
        local path, shown = binding_file(source, step.base)
        local data = live_json(path)
        local entry = { path = shown, exists = data ~= nil, hit = false, level = step.level }
        if data and not res.hit then
            local ok, msg = P.validate_binding(data)
            local fps = type(data.fingerprints) == "table" and data.fingerprints or nil
            if ok and source == "mods" and fps then
                for id, fp in pairs(worn) do
                    if fp and fps[id] and fps[id] ~= fp then
                        ok, msg = false, "通道指纹不符（可能是被覆盖的旧 mod 留下的），已跳过"
                    end
                end
            end
            if ok then
                entry.hit = true
                res.hit, res.source, res.data, res.base, res.level = shown, source, data, step.base, step.level
                res.folder = step.base ~= "default" and P.folder_of(step.base) or nil
            else
                entry.error = msg
            end
        end
        res.chain[#res.chain + 1] = entry
    end
    return res
end

-- The part whose model binds the whole character: a worn representative part (the one with the
-- most channels when several are worn), else a part of the model with the most channels in total.
-- parts: {id, n}; nil when empty.
function P.primary_part(parts)
    local rep_best
    local total, best_of = {}, {}
    for _, p in ipairs(parts or {}) do
        local n = p.n or 0
        if P.representative_of(p.id) == p.id and (not rep_best or n > (rep_best.n or 0)) then rep_best = p end
        local f = P.folder_of(p.id)
        total[f] = (total[f] or 0) + n
        if not best_of[f] or n > (best_of[f].n or 0) then best_of[f] = p end
    end
    if rep_best then return rep_best end
    local pick, most
    for _, p in ipairs(parts or {}) do
        local f = P.folder_of(p.id)
        if not most or total[f] > most then pick, most = best_of[f], total[f] end
    end
    return pick
end

-- Part files left by earlier versions for the worn parts: {part, source, path (shown)}, user first.
function P.legacy_bindings(parts)
    local out, seen = {}, {}
    for _, source in ipairs({ "user", "mods" }) do
        for _, p in ipairs(parts or {}) do
            local id = p.id
            if not seen[source .. id] and P.binding_base(id) ~= id then
                seen[source .. id] = true
                local path, shown = binding_file(source, id)
                if live_json(path) then out[#out + 1] = { part = id, source = source, path = shown } end
            end
        end
    end
    return out
end

function P.read_binding(source, base)
    return live_json((binding_file(source, base)))
end

-- base: a part ID (written to user/<model>/<part>.json) or "default" (user/default.json)
function P.write_binding(base, data)
    data.schema = P.BINDING_SCHEMA
    if base ~= "default" then data.part = base end
    local ok, msg = P.validate_binding(data)
    if not ok then return false, "E_SCHEMA", msg end
    local path, shown = binding_file("user", base)
    if json_cache then json_cache[path] = nil end
    if not U.save_json(path, data) then return false, "E_IO", "write failed" end
    return true, nil, nil, { path = shown }
end

function P.user_binding_exists(base)
    return live_json((binding_file("user", base))) ~= nil
end

function P.tombstone_binding(base)
    local path = binding_file("user", base)
    if json_cache then json_cache[path] = nil end
    return U.save_json(path, { deleted = true })
end

-- ---------------------------------------------------------------- sculpt presets
-- list entries: { id, name, source, folder (model or nil = general), path, target_part,
--                 channel_hash, values, overrides }; user before mods, general before folders
P.sculpt_list = {}

local function glob(rx)
    local ok, files = pcall(fs.glob, rx)
    return ok and type(files) == "table" and files or {}
end

-- P.sculpt_errors: { path, id, msg } of the files left out of the list because they are invalid
function P.load_sculpt()
    local list, errors = {}, {}
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
            local valid, why = false, nil
            if data then valid, why = P.validate_sculpt(data) end
            if data and not valid then
                errors[#errors + 1] = { path = f.path, id = f.path:match("([^\\/]+)%.json$"), msg = why }
            end
            if valid then
                local base = f.path:match("([^\\/]+)%.json$")
                local target = data.target or {}
                list[#list + 1] = {
                    id = base, name = data.name or base, source = source, folder = f.folder, path = f.path,
                    target_part = target.part, channel_hash = target.channel_hash,
                    values = data.values or {}, overrides = data.overrides or {},
                    key_groups = normal_key_groups(data.key_groups),
                }
            end
        end
    end
    P.sculpt_list, P.sculpt_errors = list, errors
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
-- A preset of this name already in the folder keeps its file (user) or its file id (mods, so the
-- user copy hides it); a new one gets an ASCII file id.
function P.save_sculpt(name, folder, payload)
    if U.safe_id(name) == "" then return false, "E_BAD_ARGS", "empty name" end
    local id, path = U.file_id(name), nil
    for _, e in ipairs(P.sculpt_list) do
        if e.name == name and e.folder == folder then
            id = e.id
            if e.source == "user" then path = e.path end
            break
        end
    end
    payload.schema = P.SCULPT_SCHEMA
    payload.name = name
    local ok, msg = P.validate_sculpt(payload)
    if not ok then return false, "E_SCHEMA", msg end
    if not U.save_json(path or sculpt_file("user", folder, id), payload) then return false, "E_IO", "write failed" end
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
        base = U.file_id(base or data.id or data.name or "")
        if base == "" then return false, "E_BAD_ARGS", "no name for the imported file" end
        if not U.save_json(U.path("user", "profiles", base .. ".json"), data) then return false, "E_IO", "write failed" end
        return true, nil, nil, { id = base }
    end
    return false, "E_BAD_ARGS", "unknown kind " .. tostring(kind)
end

return P
