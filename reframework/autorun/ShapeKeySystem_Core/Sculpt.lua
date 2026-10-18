-- ShapeKeySystem: the sculpt layer — static weights on the channels the expression profile does
-- not drive (owner "self"). Written lazily like Female Body Sliders: once a part's mesh has stayed
-- ready for Guard.STABLE_FRAMES, again whenever a value changes, and every frame in edit mode.
--
-- Channels are merged by key: the name after the last '.', without a trailing _LODn. One key can
-- span several parts (same name on head and body) and all LOD copies; a per-part override wins
-- over the merged value.

local U = require("ShapeKeySystem_Core.Util")
local W = require("ShapeKeySystem_Core.Writer")
local G = require("ShapeKeySystem_Core.Guard")
local Ext = require("ShapeKeySystem_Core.External")
local CondExpr = require("ShapeKeySystem_Core.CondExpr")
local Touch = require("ShapeKeySystem_Core.Touch")
local NameHash = require("ShapeKeySystem_Core.NameHash")

local S = {}

S.RANGE = { 0.0, 1.0 }   -- upper end = settings.sculpt_max (S.set_max)
S.MAX_LIMIT = 5.0         -- highest cap the setting accepts (engine stores 2.0 verbatim, measured)
local UNDO_MAX = 50
local abs = math.abs

function S.key_of(channel_name)
    local short = channel_name:match("([^%.]+)$") or channel_name
    return (short:gsub("_[Ll][Oo][Dd]%d+$", ""))
end

-- K.keys: list of { name, group, parts = {ids}, value, default, overrides = {part = v},
--                   owner = "self" / "expression" }
-- Every channel is listed. A key whose every channel is driven by the expression profile has
-- owner "expression": still editable (2026-10-10), but the sculpt layer does not write it — its
-- value is the rest position the expression writer remaps the expression weight onto
-- (API.drive, S.mix: final = s + (1 - s) * e).
-- K.by_name: name -> key;  K.targets: per part { id, mesh, addr, items = {{key, idx}}, last, stable, dirty }
local K = { keys = {}, by_name = {}, targets = {}, undo = {}, redo = {}, last_push = nil, last_frame = -100 }
S.frame = 0          -- set by the caller every tick (drag detection)
local DRAG_GAP = 5   -- changes of one key at most this many frames apart are one drag
S.K = K

-- a preset's value for a key; one saved as "#XXXXXXXX" (the name was unknown then, NameHash)
-- still applies once the name is known
local function lookup(t, name)
    if not t then return nil end
    local v = t[name]
    if v == nil and name:sub(1, 1) ~= "#" then v = t[NameHash.label(NameHash.hash(name))] end
    return tonumber(v)
end

local function preset_value(preset, part, name)
    if not preset then return nil end
    local v = lookup(preset.overrides[part], name)
    if v ~= nil then return v end
    return lookup(preset.values, name)
end

local warm = {}   -- mesh address -> warm-up count of targets dropped by clear_targets

-- parts: Scene parts { id, mesh, names, n }; owned[mesh] = { [index] = true } (expression)
-- presets_of(part_id) -> active, mod: the sculpt preset the part's binding selects, and the one
-- its mod binding selects (the "default" for reset / A-B preview). Either may be nil.
-- A key the user changed keeps its value across rebuilds; untouched keys follow the presets.
function S.rebuild(parts, owned, presets_of)
    local old = K.by_name
    local keys, by_name, targets = {}, {}, {}
    local seen_part = {}
    local lo, hi = S.RANGE[1], S.RANGE[2]
    for _, part in ipairs(parts) do
        if not seen_part[part.id] then
            seen_part[part.id] = true
            local own = owned[part.mesh] or {}
            local active, mod = presets_of(part.id)
            local items = {}
            local item_of = {}
            for i, cn in ipairs(part.names) do
                local idx = i - 1
                if cn ~= "" then
                    local name = S.key_of(cn)
                    local key = by_name[name]
                    local dv = U.clamp(preset_value(mod, part.id, name) or 0, lo, hi)
                    local av = preset_value(active, part.id, name)
                    -- named by the mod's or the loaded sculpt preset ("preset key")
                    local named = av ~= nil or preset_value(mod, part.id, name) ~= nil
                    av = av and U.clamp(av, lo, hi) or dv
                    if not key then
                        local prev = old[name]
                        key = { name = name, group = part.id, parts = {}, default = dv, preset_value = av,
                                value = av, overrides = {}, preset_overrides = {}, free = 0, owned = 0 }
                        if prev and prev.touched then
                            key.value, key.touched = prev.value, true
                            for p, v in pairs(prev.overrides) do key.overrides[p] = v end
                        end
                        by_name[name] = key
                        keys[#keys + 1] = key
                    end
                    if named then key.in_preset = true end
                    if not item_of[name] then
                        key.parts[#key.parts + 1] = part.id
                        -- a later part whose own presets disagree with the merged key gets an override
                        if not key.touched and abs(av - key.preset_value) > 1e-6 then
                            key.overrides[part.id] = av
                        end
                        if abs(dv - key.default) > 1e-6 then key.preset_overrides[part.id] = dv end
                        item_of[name] = { key = key, idx = {} }
                        items[#items + 1] = item_of[name]
                    end
                    if own[idx] then
                        key.owned = key.owned + 1   -- the expression layer writes this one
                    else
                        key.free = key.free + 1
                        table.insert(item_of[name].idx, idx)
                    end
                end
            end
            local ok, addr = pcall(part.mesh.get_address, part.mesh)
            targets[#targets + 1] = { id = part.id, mesh = part.mesh, addr = ok and addr or nil, items = items,
                                      last = {}, stable = 0, dirty = true }
        else
            -- another copy of a part already seen (guild card / cutscene / save-select hunter):
            -- same keys and values, its own mesh
            local own = owned[part.mesh] or {}
            local items, item_of = {}, {}
            for i, cn in ipairs(part.names) do
                local idx = i - 1
                local key = cn ~= "" and by_name[S.key_of(cn)]
                if key and not own[idx] then
                    local it = item_of[key.name]
                    if not it then
                        it = { key = key, idx = {} }
                        item_of[key.name] = it; items[#items + 1] = it
                    end
                    it.idx[#it.idx + 1] = idx
                end
            end
            local ok, addr = pcall(part.mesh.get_address, part.mesh)
            targets[#targets + 1] = { id = part.id, mesh = part.mesh, addr = ok and addr or nil, items = items,
                                      last = {}, stable = 0, dirty = true, copy = true }
        end
    end
    -- a rebuilt target for the same mesh keeps its warm-up and last written values; one dropped
    -- by clear_targets keeps only its warm-up (every channel is read and written again)
    local prev_t = {}
    for _, t in ipairs(K.targets) do if t.addr then prev_t[t.addr] = t end end
    for _, t in ipairs(targets) do
        local o = t.addr and prev_t[t.addr]
        if o then t.stable, t.last = o.stable, o.last
        elseif t.addr and warm[t.addr] then t.stable = warm[t.addr] end
    end
    warm = {}
    for _, k in ipairs(keys) do k.owner = (k.free == 0) and "expression" or "self" end
    table.sort(keys, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.name < b.name
    end)
    K.keys, K.by_name, K.targets = keys, by_name, targets
    return keys
end

-- Rigs are dropped many times in combat (parts change on hits): without the warm-up surviving,
-- every drop paused all sculpt-only keys for STABLE_FRAMES.
function S.clear_targets()
    for _, t in ipairs(K.targets) do if t.addr then warm[t.addr] = t.stable end end
    K.targets = {}
end

-- ---------------------------------------------------------------- values
local function snapshot()
    local s = {}
    for _, k in ipairs(K.keys) do
        local o = {}
        for p, v in pairs(k.overrides) do o[p] = v end
        s[k.name] = { value = k.value, overrides = o, touched = k.touched }
    end
    return s
end

local function restore(s)
    for _, k in ipairs(K.keys) do
        local e = s[k.name]
        if e then
            k.value, k.touched = e.value, e.touched
            k.overrides = {}
            for p, v in pairs(e.overrides) do k.overrides[p] = v end
        end
    end
    S.mark_dirty()
end

-- one undo step per user action; changes of the same key a few frames apart (a slider drag,
-- which calls every frame) coalesce into one step
function S.push_undo(tag)
    local gap = S.frame - K.last_frame
    K.last_frame = S.frame
    if tag ~= nil and K.last_push == tag and gap <= DRAG_GAP then return end
    K.undo[#K.undo + 1] = snapshot()
    if #K.undo > UNDO_MAX then table.remove(K.undo, 1) end
    K.redo = {}
    K.last_push = tag
end

function S.end_gesture() K.last_push = nil end

function S.undo()
    if #K.undo == 0 then return false end
    K.redo[#K.redo + 1] = snapshot()
    restore(table.remove(K.undo))
    K.last_push = nil
    return true
end

function S.redo()
    if #K.redo == 0 then return false end
    K.undo[#K.undo + 1] = snapshot()
    restore(table.remove(K.redo))
    K.last_push = nil
    return true
end

function S.can_undo() return #K.undo > 0 end
function S.can_redo() return #K.redo > 0 end

S.version = 0   -- bumped on every value change: expression targets refresh their rest values
function S.mark_dirty()
    S.version = S.version + 1
    for _, t in ipairs(K.targets) do t.dirty = true end
end

-- expression + sculpt on one channel: the sculpt value s is the rest position, the expression
-- weight e moves it the rest of the way (s=0.4: rest 0.4, e=0.5 -> 0.7, e=1 -> 1.0). s >= 1
-- (cap raised above 1) is kept as is.
function S.mix(s, e)
    if s <= 0 then return e end
    if s >= 1 then return s end
    return s + (1 - s) * e
end

-- nil = fine; otherwise an error code + message for a key the sculpt layer may not change
function S.check_editable(name)
    local k = K.by_name[name]
    if not k then return "E_NOT_FOUND", "unknown sculpt key: " .. tostring(name) end
    return nil
end

-- global slider cap: values above it are clamped now (and written on the next tick)
function S.set_max(m)
    m = U.clamp(tonumber(m) or 1.0, 1.0, S.MAX_LIMIT) + 0.0   -- settings.json gives the integer 1
    S.RANGE[2] = m
    for _, k in ipairs(K.keys) do
        k.value = U.clamp(k.value, S.RANGE[1], m)
        k.default = U.clamp(k.default, S.RANGE[1], m)
        k.preset_value = U.clamp(k.preset_value, S.RANGE[1], m)
        for p, v in pairs(k.overrides) do k.overrides[p] = U.clamp(v, S.RANGE[1], m) end
        for p, v in pairs(k.preset_overrides) do k.preset_overrides[p] = U.clamp(v, S.RANGE[1], m) end
    end
    S.mark_dirty()
    return m
end

function S.set(name, value)
    local k = K.by_name[name]
    if not k then return false end
    S.push_undo("set:" .. name)
    k.value = U.clamp(value, S.RANGE[1], S.RANGE[2])
    k.touched = true
    S.mark_dirty()
    return true
end

function S.set_override(name, part, value)
    local k = K.by_name[name]
    if not k then return false, "E_NOT_FOUND", "unknown sculpt key: " .. tostring(name) end
    local found = false
    for _, p in ipairs(k.parts) do if p == part then found = true end end
    if not found then return false, "E_NOT_FOUND", tostring(name) .. " is not on part " .. tostring(part) end
    S.push_undo("ovr:" .. name .. "@" .. part)
    k.overrides[part] = value ~= nil and U.clamp(value, S.RANGE[1], S.RANGE[2]) or nil
    k.touched = true
    S.mark_dirty()
    return true
end

function S.reset(name)
    local k = K.by_name[name]
    if not k then return false end
    S.push_undo(nil)
    k.value, k.overrides, k.touched = k.default, {}, true
    for p, v in pairs(k.preset_overrides) do k.overrides[p] = v end
    S.mark_dirty()
    return true
end

-- every key to 0 (one undo step); false when everything already was 0
function S.clear_all()
    local changed = false
    for _, k in ipairs(K.keys) do
        if k.value ~= 0 or next(k.overrides) ~= nil then changed = true end
    end
    if not changed then return false end
    S.push_undo(nil)
    for _, k in ipairs(K.keys) do k.value, k.overrides, k.touched = 0.0, {}, true end
    S.mark_dirty()
    return true
end

-- every key back to the mod default (one undo step); false when nothing differed
function S.reset_all()
    local changed = false
    for _, k in ipairs(K.keys) do
        if abs(k.value - k.default) > 1e-9 or next(k.overrides) ~= nil or next(k.preset_overrides) ~= nil then changed = true end
    end
    if not changed then return false end
    S.push_undo(nil)
    for _, k in ipairs(K.keys) do
        k.value, k.overrides, k.touched = k.default, {}, true
        for p, v in pairs(k.preset_overrides) do k.overrides[p] = v end
    end
    S.mark_dirty()
    return true
end

-- load a sculpt preset (one undo step): its values for the keys it names, the mod default for
-- the rest (expression keys included: their value is the rest position under the expression)
function S.apply_preset(preset)
    S.push_undo(nil)
    local lo, hi = S.RANGE[1], S.RANGE[2]
    for _, k in ipairs(K.keys) do
        do
            local v = lookup(preset.values, k.name)
            k.value = v and U.clamp(v, lo, hi) or k.default
            k.overrides = {}
            if not v then for p, d in pairs(k.preset_overrides) do k.overrides[p] = d end end
            for _, p in ipairs(k.parts) do
                local o = lookup(preset.overrides[p], k.name)
                if o then k.overrides[p] = U.clamp(o, lo, hi) end
            end
            k.touched = true
        end
    end
    S.mark_dirty()
end

-- values a preset file stores: merged values, plus overrides that differ from them
function S.export_values()
    local values, overrides = {}, {}
    for _, k in ipairs(K.keys) do
      do
        values[k.name] = k.value
        for p, v in pairs(k.overrides) do
            overrides[p] = overrides[p] or {}
            overrides[p][k.name] = v
        end
      end
    end
    return values, overrides
end

-- unsaved = differs from the last save, or (never saved) from what the presets give
function S.is_dirty()
    for _, k in ipairs(K.keys) do
        if K.saved then
            local s = K.saved[k.name]
            if not s or abs(k.value - s.value) > 1e-6 then return true end
            for p, v in pairs(k.overrides) do
                if s.overrides[p] == nil or abs(v - s.overrides[p]) > 1e-6 then return true end
            end
            for p in pairs(s.overrides) do if k.overrides[p] == nil then return true end end
        elseif k.touched then
            return true
        end
    end
    return false
end

function S.mark_saved() K.saved = snapshot() end

-- ---------------------------------------------------------------- writing
-- preview: true = show the mod defaults instead of the current values (A/B)
-- the sculpt value of a key on a part, ignoring other plugins (rest position for expression keys)
local function base_value(key, part, preview)
    if preview then
        local d = key.preset_overrides[part]
        if d ~= nil then return d end
        return key.default
    end
    local o = key.overrides[part]
    if o ~= nil then return o end
    return key.value
end
S.base_value = base_value

local function value_for(key, part, preview)
    -- another plugin holds this key (External.lua): its value wins over everything here
    local xv = Ext.for_key(key.name)
    if xv ~= nil then return xv end
    -- conditional clips, then the face-navigator interactions (Touch.lua), form an expression
    -- value e for this key (0 when nothing plays), remapped onto the sculpt value like every
    -- expression-driven key: s + (1 - s) * e
    local base = base_value(key, part, preview)
    if not CondExpr.any() and not Touch.any() then return base end
    return S.mix(base, Touch.for_key(key.name, CondExpr.for_key(key.name, 0)))
end

-- returns writes, error string (mesh lost readiness)
function S.tick(edit_mode, preview, eps)
    local writes = 0
    for _, t in ipairs(K.targets) do
        if t.stable < G.STABLE_FRAMES then
            if G.mesh_ready(t.mesh) then t.stable = t.stable + 1 else t.stable = 0 end
        elseif not G.mesh_still_ready(t.mesh) then
            return writes, "sculpt mesh no longer ready: " .. t.id
        elseif t.dirty or edit_mode or W.adapter.rewrite_active_weights then
            local last = t.last
            for _, item in ipairs(t.items) do
                local w = value_for(item.key, t.id, preview)
                for _, i in ipairs(item.idx) do
                    local l = last[i]
                    -- first touch of this mesh (or after a rescan dropped our record): take the
                    -- engine's current value, so unchanged channels are not rewritten and a
                    -- value we wrote before the drop is still known for zeroing
                    if l == nil then
                        l = W.read_weight(t.mesh, i) or 0
                        last[i] = l
                    end
                    local active = W.adapter.rewrite_active_weights and (w ~= 0 or l ~= 0)
                    if active or abs(w - l) > eps then
                        if W.set_weight(t.mesh, i, w, item.key.name) then
                            last[i] = w
                            writes = writes + 1
                        end
                    end
                end
            end
            t.dirty = false
        end
    end
    return writes
end

-- writes 0 to every sculpt channel of ready meshes (disable / shutdown)
function S.zero_all()
    for _, t in ipairs(K.targets) do
        if t.stable >= G.STABLE_FRAMES and G.mesh_ready(t.mesh) then
            for _, item in ipairs(t.items) do
                for _, i in ipairs(item.idx) do
                    local l = t.last[i]
                    if l ~= nil and l ~= 0 then pcall(W.set_weight, t.mesh, i, 0.0, item.key.name) end
                    t.last[i] = 0.0
                end
            end
        end
        t.dirty = true
    end
end

return S
