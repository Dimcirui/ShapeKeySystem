-- ShapeKeySystem: conditional expressions. Game-state rules pick an expression clip that
-- replaces the fcParam expression on the keys it names, with fades.
--
-- File: <src>/conditions/<id>.json (src = user | mods), schema "sks.conditions/1":
--   { name, auto = true,
--     clips  = { <clip id> = { values = { <key> = weight }, fade_in = s, fade_out = s } },
--     states = [ { clip = <clip id>, rules = [ { logic = "AND"|"OR", hold = s,
--                                                conditions = [ {type, op, value, band} ] } ] } ] }
-- states are in priority order: the first state with a matching rule (or still inside its hold
-- time) plays its clip. A state with clip = "" is switched off: it is skipped and never outranks
-- the states below it. auto = false pauses the rules. A binding names the set ("conditions").
--
-- Blending: every clip has a weight a (0..1). The playing clip fades in over its fade_in, all
-- others fade out over their own fade_out. A key named by a clip becomes
--   e' = e * (1 - a) + target * a        (e = the fcParam expression weight)
-- applied fading clips first, the playing one last. e' then goes through the usual sculpt mix
-- (Sculpt.mix: s + (1 - s) * e') and can still be overridden by other plugins (External). Keys
-- that are not driven by the expression profile count as e = 0 (E.for_key) and go through the
-- same mix, so a clip always remaps on top of the sculpt value (user decision 2026-10-10).
-- Only the master hunter in gameplay; everything fades out while the game gate is closed.

local U = require("ShapeKeySystem_Core.Util")
local Cnd = require("ShapeKeySystem_Core.Conditions")
local TargetIndex = require("ShapeKeySystem_Core.TargetIndex")

local E = {}

E.SCHEMA = "sks.conditions/1"
E.list = {}             -- { id, name, source, path, data }
E.current = nil         -- the set in effect: { id, name, source, data (working copy), dirty }
E.preview = nil         -- clip id forced by the panel ("预览"), or nil

local alpha = {}        -- clip id -> weight
local hold_until = setmetatable({}, { __mode = "k" })   -- rule table -> os.clock deadline
E.playing = nil         -- clip id the rules (or the preview) selected
E.status = {}           -- per state index: "active" | "outranked" | "idle" | "off"
E.animating = false     -- some weight is moving (sculpt keys need rewriting)
local last_clock = nil
local slot_cache, slot_cache_for = nil, nil

local active_list, active_data, active_dirty = {}, nil, true
local target_indexes = {}

-- ---------------------------------------------------------------- files
function E.validate(d)
    if type(d) ~= "table" then return false, "not an object" end
    if d.schema ~= nil and d.schema ~= E.SCHEMA then return false, "unsupported schema " .. tostring(d.schema) end
    if d.clips ~= nil and type(d.clips) ~= "table" then return false, "clips must be an object" end
    for id, c in pairs(d.clips or {}) do
        if type(id) ~= "string" or type(c) ~= "table" then return false, "clip " .. tostring(id) end
        for k, v in pairs(c.values or {}) do
            if type(k) ~= "string" or type(v) ~= "number" then return false, "clip " .. id .. ": values must map keys to numbers" end
        end
        for _, f in ipairs({ "fade_in", "fade_out" }) do
            if c[f] ~= nil and type(c[f]) ~= "number" then return false, "clip " .. id .. ": " .. f .. " must be a number" end
        end
    end
    if d.states ~= nil and type(d.states) ~= "table" then return false, "states must be a list" end
    for i, s in ipairs(d.states or {}) do
        if type(s) ~= "table" or type(s.clip) ~= "string" then return false, "state " .. i .. ": clip must be a string" end
        for j, r in ipairs(s.rules or {}) do
            if type(r) ~= "table" then return false, "state " .. i .. " rule " .. j end
            for _, c in ipairs(r.conditions or {}) do
                if type(c) ~= "table" or type(c.type) ~= "string" then return false, "state " .. i .. " rule " .. j .. ": condition type" end
            end
        end
    end
    return true
end

-- REFramework's json writes empty tables as null: rebuild the shape after loading
local function normalize(d)
    d.clips = type(d.clips) == "table" and d.clips or {}
    for _, c in pairs(d.clips) do
        c.values = type(c.values) == "table" and c.values or {}
        c.fade_in = tonumber(c.fade_in) or 0.15
        c.fade_out = tonumber(c.fade_out) or 0.3
    end
    d.states = type(d.states) == "table" and d.states or {}
    for _, s in ipairs(d.states) do
        s.rules = type(s.rules) == "table" and s.rules or {}
        for _, r in ipairs(s.rules) do
            r.conditions = type(r.conditions) == "table" and r.conditions or {}
            r.logic = (r.logic == "OR") and "OR" or "AND"
            r.hold = tonumber(r.hold) or 0
        end
    end
    if d.auto == nil then d.auto = true end
    return d
end
E.normalize = normalize

function E.load_all()
    local list = {}
    for _, src in ipairs({ "user", "mods" }) do
        for _, f in ipairs(U.list_json(src .. "\\conditions")) do
            local d = U.load_json(f.path)
            if d and d.deleted ~= true and E.validate(d) then
                local taken = false
                for _, e in ipairs(list) do if e.id == f.base then taken = true end end   -- user wins
                if not taken then
                    list[#list + 1] = { id = f.base, name = d.name or f.base, source = src, path = f.path, data = normalize(d) }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    E.list = list
    return list
end

function E.find(name)
    if type(name) ~= "string" then return nil end
    for _, e in ipairs(E.list) do if e.id == name or e.name == name then return e end end
end

-- make a set the one in effect (nil = none). keep_edits: same set, keep the working copy
function E.select(name)
    local e = E.find(name)
    if not e then
        if E.current and not E.current.dirty then E.current = nil end
        return false
    end
    if E.current and E.current.id == e.id and E.current.source == e.source then return true end
    E.current = { id = e.id, name = e.name, source = e.source, data = U.copy(e.data), dirty = false }
    slot_cache = nil
    return true
end

function E.new_set(name)
    local id = U.safe_id(name)
    if id == "" then return false, "E_BAD_ARGS", "empty name" end
    E.current = { id = id, name = name, source = "user", data = normalize({ name = name, auto = true }), dirty = true }
    slot_cache = nil
    return true
end

-- replace the working copy (panel edits); validated
function E.edit(data)
    if not E.current then return false, "E_NOT_FOUND", "no condition set" end
    local ok, msg = E.validate(data)
    if not ok then return false, "E_SCHEMA", msg end
    E.current.data = normalize(U.copy(data))
    E.current.dirty = true
    slot_cache = nil
    return true
end

function E.save(as_name)
    local cur = E.current
    if not cur then return false, "E_NOT_FOUND", "no condition set" end
    local name = as_name or cur.name
    local id = U.safe_id(name)
    if id == "" then return false, "E_BAD_ARGS", "empty name" end
    local d = U.copy(cur.data)
    d.schema, d.name = E.SCHEMA, name
    if not U.save_json(U.path("user", "conditions", id .. ".json"), d) then return false, "E_IO", "write failed" end
    E.load_all()
    cur.id, cur.name, cur.source, cur.dirty = id, name, "user", false
    return true, nil, nil, { id = id }
end

function E.revert()
    if not E.current then return false end
    local id = E.current.id
    E.current = nil
    return E.select(id)
end

-- ---------------------------------------------------------------- runtime
local function rule_hits(rule, now)
    if Cnd.eval_rule(rule) then
        if rule.hold > 0 then hold_until[rule] = now + rule.hold end
        return true
    end
    local t = hold_until[rule]
    if t then
        if now < t then return true end
        hold_until[rule] = nil
    end
    return false
end

-- once per update. live: conditions may be evaluated (gameplay, gate open, master hunter);
-- otherwise everything fades out. Returns true when any weight changed.
function E.update(live)
    active_dirty = true
    local now = os.clock()
    local dt = last_clock and math.min(0.1, math.max(0, now - last_clock)) or 0
    last_clock = now
    local cur = E.current
    local data = cur and cur.data
    local pick = nil
    local status = E.status
    for i in pairs(status) do status[i] = nil end
    if data and live then
        for i, s in ipairs(data.states) do
            local hit = false
            if s.clip == "" then
                status[i] = "off"
            else
                if data.auto ~= false then
                    for _, r in ipairs(s.rules) do if rule_hits(r, now) then hit = true end end
                end
                if hit and not pick then pick = s.clip; status[i] = "active"
                elseif hit then status[i] = "outranked"
                else status[i] = "idle" end
            end
        end
    end
    if E.preview and data and data.clips[E.preview] then pick = E.preview end
    E.playing = pick
    local changed = false
    local clips = data and data.clips or {}
    for id, c in pairs(clips) do
        local a = alpha[id] or 0
        local want = (id == pick) and 1 or 0
        if a ~= want then
            local t = (want > a) and c.fade_in or c.fade_out
            local step = (t and t > 0) and (dt / t) or 1
            if want > a then a = math.min(1, a + step) else a = math.max(0, a - step) end
            alpha[id] = a
            changed = true
        end
    end
    for id in pairs(alpha) do
        if not clips[id] then alpha[id] = nil; changed = true end
    end
    E.animating = changed
    return changed
end

function E.reset()
    active_dirty = true
    for k in pairs(alpha) do alpha[k] = nil end
    E.playing = nil
    last_clock = nil
end

function E.alpha(id) return alpha[id] or 0 end

-- clips with weight, fading ones first, the playing one last
-- 更新回调内复用活跃顺序；配置工作副本替换时同时放掉旧名称索引。
local function active_clips()
    local data = E.current and E.current.data
    if active_data ~= data then
        active_data, target_indexes, active_dirty = data, {}, true
    end
    if not active_dirty then return active_list end
    active_dirty = false
    for i = #active_list, 1, -1 do active_list[i] = nil end
    if not data then return active_list end
    for id, a in pairs(alpha) do
        if a > 0 and id ~= E.playing and data.clips[id] then active_list[#active_list + 1] = id end
    end
    if E.playing and (alpha[E.playing] or 0) > 0 and data.clips[E.playing] then active_list[#active_list + 1] = E.playing end
    return active_list
end

function E.any()
    for _, a in pairs(alpha) do if a > 0 then return true end end
    return false
end

-- expression output: blend clip targets into W (slot weights). resolve(name) -> slot or nil
function E.apply(prog, resolve, W)
    local data = E.current and E.current.data
    if not data then return end
    if slot_cache_for ~= prog then slot_cache, slot_cache_for = nil, prog end
    slot_cache = slot_cache or {}
    for _, id in ipairs(active_clips()) do
        local a = alpha[id]
        for key, target in pairs(data.clips[id].values) do
            local s = slot_cache[key]
            if s == nil then s = resolve(key) or false; slot_cache[key] = s end
            if s then
                local e = W[s] or 0
                W[s] = e * (1 - a) + target * a
            end
        end
    end
end

-- 捏脸键复用归一化目标索引；渐出片段先混合，当前片段最后混合。
function E.for_key(key_name, e)
    local ids = active_clips()
    if #ids == 0 then return e end
    local n, v = TargetIndex.norm(key_name), e
    for _, id in ipairs(ids) do
        local index = target_indexes[id]
        if not index then
            index = TargetIndex.build(active_data.clips[id].values)
            target_indexes[id] = index
        end
        v = TargetIndex.blend(index, n, v, alpha[id])
    end
    return v
end

return E
