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
local Trail = require("ShapeKeySystem_Core.Trail")
local Labels = require("ShapeKeySystem_Core.Labels")

local S = {}

-- upper end = settings.sculpt_max (S.set_max). It limits only values set by hand (slider, typed);
-- values from presets, mod defaults and key groups go up to MAX_LIMIT.
S.RANGE = { 0.0, 1.0 }
S.MAX_LIMIT = 5.0         -- highest cap the setting accepts (engine stores 2.0 verbatim, measured)
local UNDO_MAX = 50
local abs = math.abs

function S.key_of(channel_name)
    local short = channel_name:match("([^%.]+)$") or channel_name
    return (short:gsub("_[Ll][Oo][Dd]%d+$", ""))
end

-- K.keys: list of { name, group, parts = {ids}, value, default, overrides = {part = v},
--                   owner = "self" / "expression", held = v or nil }
-- value / overrides are the key's own (free) values; held is the fixed value of the key group option
-- in effect, which replaces them while it is set (S.effective).
-- Every channel is listed. A key whose every channel is driven by the expression profile has
-- owner "expression": still editable (2026-10-10), but the sculpt layer does not write it — its
-- value is the rest position the expression writer remaps the expression weight onto
-- (API.drive, S.mix: final = s + (1 - s) * e).
-- K.by_name: name -> key;  K.targets: per part { id, mesh, addr, items = {{key, idx}}, last, stable, dirty }
-- K.groups: key groups of the loaded preset (see "key groups" below); K.member: key name ->
-- { group, option } for every key a group holds
local K = { keys = {}, by_name = {}, targets = {}, undo = {}, redo = {}, last_push = nil, last_frame = -100,
            groups = {}, member = {} }
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
local refresh_held   -- key groups section

-- parts: Scene parts { id, mesh, names, n }; owned[mesh] = { [index] = true } (expression)
-- presets_of(part_id) -> active, mod, fill: the sculpt preset the character's binding selects, the
-- one its mod binding selects (the "default" for reset / A-B preview), and for a part of another
-- model the preset that model's mod selects (defaults for keys neither of the others names).
-- Any may be nil.
-- A key the user changed keeps its value across rebuilds; untouched keys follow the presets.
function S.rebuild(parts, owned, presets_of)
    local old = K.by_name
    local keys, by_name, targets = {}, {}, {}
    local seen_part = {}
    local group_source
    local lo, hi = S.RANGE[1], S.MAX_LIMIT
    for _, part in ipairs(parts) do
        if not seen_part[part.id] then
            seen_part[part.id] = true
            local own = owned[part.mesh] or {}
            local active, mod, fill = presets_of(part.id)
            group_source = group_source or active
            local items = {}
            local item_of = {}
            -- a "=====XXX=====" channel is a section title for the keys after it, never a key
            local section
            for i, cn in ipairs(part.names) do
                local idx = i - 1
                local sep = cn ~= "" and Labels.separator_title(S.key_of(cn))
                if sep then
                    section = sep
                elseif cn ~= "" then
                    local name = S.key_of(cn)
                    local key = by_name[name]
                    local av = preset_value(active, part.id, name)
                    local mv = preset_value(mod, part.id, name)
                    if mv == nil and av == nil then mv = preset_value(fill, part.id, name) end
                    local dv = U.clamp(mv or 0, lo, hi)
                    -- named by the mod's or the loaded sculpt preset ("preset key")
                    local named = av ~= nil or mv ~= nil
                    av = av and U.clamp(av, lo, hi) or dv
                    if not key then
                        local prev = old[name]
                        -- pos: channel index in its first part, the list order (Blender's key order)
                        key = { name = name, group = part.id, parts = {}, default = dv, preset_value = av,
                                value = av, overrides = {}, preset_overrides = {}, free = 0, owned = 0,
                                pos = idx, section = section or Labels.section_before(name) }
                        section = nil
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
            targets[#targets + 1] = { id = part.id, mesh = part.mesh, addr = ok and addr or nil, items = items, layout = part.layout or part.fingerprint,
                                      last = {}, stable = 0, dirty = true }
        else
            -- another copy of a part already seen (guild card / cutscene / save-select hunter):
            -- same keys and values, its own mesh
            local own = owned[part.mesh] or {}
            local items, item_of = {}, {}
            for i, cn in ipairs(part.names) do
                local idx = i - 1
                local key = cn ~= "" and not Labels.separator_title(S.key_of(cn)) and by_name[S.key_of(cn)]
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
            targets[#targets + 1] = { id = part.id, mesh = part.mesh, addr = ok and addr or nil, items = items, layout = part.layout or part.fingerprint,
                                      last = {}, stable = 0, dirty = true, copy = true }
        end
    end
    -- a rebuilt target for the same mesh keeps its warm-up and last written values; one dropped
    -- by clear_targets keeps only its warm-up (every channel is read and written again)
    local prev_t = {}
    for _, t in ipairs(K.targets) do if t.addr then prev_t[t.addr] = t end end
    for _, t in ipairs(targets) do
        local o = t.addr and prev_t[t.addr]
        if o and o.layout == t.layout then t.stable, t.last = o.stable, o.last
        elseif t.addr and warm[t.addr] then t.stable = warm[t.addr] end
    end
    warm = {}
    -- dynamic keys (other plugins, drivers, mocap, conditional clips, touch) by normalised name
    for _, t in ipairs(targets) do
        t.dyn_by_norm, t.dyn_prev = {}, {}
        for i, item in ipairs(t.items) do
            if #item.idx > 0 then
                local name = Ext.norm(item.key.name)
                local bucket = t.dyn_by_norm[name] or {}
                bucket[#bucket + 1], t.dyn_by_norm[name] = i, bucket
            end
        end
    end
    if W.adapter.active_sculpt then
        for _, t in ipairs(targets) do
            t.active, t.active_pos, t.pending, t.pending_set = {}, {}, {}, {}
            t.by_key, t.by_norm, t.work, t.work_seen = {}, {}, {}, {}
            t.dynamic, t.next_dynamic, t.work_epoch, t.all_dirty = {}, {}, 0, true
            for i, item in ipairs(t.items) do
                t.by_key[item.key.name] = i
                if #item.idx > 0 then
                    local name = Ext.norm(item.key.name)
                    local bucket = t.by_norm[name] or {}
                    bucket[#bucket + 1], t.by_norm[name] = i, bucket
                end
            end
        end
    end
    for _, k in ipairs(keys) do k.owner = (k.free == 0) and "expression" or "self" end
    table.sort(keys, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.pos ~= b.pos then return a.pos < b.pos end
        return a.name < b.name
    end)
    K.keys, K.by_name, K.targets = keys, by_name, targets
    -- the binding's preset brings its key groups until they are edited or another preset is loaded
    if not K.groups_touched then K.groups = U.copy(group_source and group_source.key_groups or {}) end
    refresh_held(false)
    return keys
end

-- Rigs are dropped many times in combat (parts change on hits): without the warm-up surviving,
-- every drop paused all sculpt-only keys for STABLE_FRAMES.
function S.clear_targets()
    for _, t in ipairs(K.targets) do if t.addr then warm[t.addr] = t.stable end end
    K.targets = {}
end

-- ---------------------------------------------------------------- key groups
-- A key group switches between up to MAX_OPTIONS sets of keys, like an integer parameter: value n
-- holds the keys of option n at their fixed values (key.held); every other key of the group, and
-- all of them at 0, are free and show their own values (2026-11-02: before, they went back to the
-- mod default and could not be edited). Options of one group may share a key with different values
-- (one key, several steps). A key may be in several groups: the highest group in the list whose
-- selected option names it sets its value.
-- Groups belong to the loaded sculpt preset (key_groups); a held key ignores its per-part values.
-- K.groups = { { name, value = 0..#options, options = { { name, values = { key = value } } } } }
S.MAX_OPTIONS = 8
local GROUPS = {}   -- snapshot field (a table key: never a key name)

-- K.member from K.groups. Keys saved as "#XXXXXXXX" (name unknown then) take their name once known.
local function index_groups()
    local label_of
    K.member = {}
    for _, g in ipairs(K.groups) do
        for i, o in ipairs(g.options) do
            local renamed = {}
            for n in pairs(o.values) do
                if not K.by_name[n] and n:sub(1, 1) == "#" then
                    if not label_of then
                        label_of = {}
                        for _, k in ipairs(K.keys) do label_of[NameHash.label(NameHash.hash(k.name))] = k.name end
                    end
                    local real = label_of[n]
                    if real and o.values[real] == nil then renamed[n] = real end
                end
            end
            for n, real in pairs(renamed) do o.values[real], o.values[n] = o.values[n], nil end
            -- K.member[n]: the groups the key is in, in list order, each with the options naming it
            for n in pairs(o.values) do
                local list = K.member[n]
                if not list then list = {}; K.member[n] = list end
                local m = list[#list]
                if not m or m.group ~= g then m = { group = g, options = {} }; list[#list + 1] = m end
                m.options[i] = true
            end
        end
    end
end

-- sets key.held from the groups. keep: a key that left its group altogether keeps the value it was
-- held at (it stays where it was on screen); undo / redo restore the free values as they were.
function refresh_held(keep)
    index_groups()
    local lo, hi = S.RANGE[1], S.MAX_LIMIT
    local changed = false
    for _, k in ipairs(K.keys) do
        local m = K.member[k.name]
        local v = nil
        for _, g in ipairs(m or {}) do
            if g.options[g.group.value] then
                v = U.clamp(tonumber(g.group.options[g.group.value].values[k.name]) or 0, lo, hi)
                break
            end
        end
        if keep and not m and k.held ~= nil then
            k.value, k.overrides, k.touched = k.held, {}, true
        end
        if v ~= k.held then k.held, changed = v, true end
    end
    if changed then S.mark_dirty() end
end

function S.apply_groups() refresh_held(true) end

-- the value a key shows and writes (part nil: its merged value)
function S.effective(k, part)
    if k.held ~= nil then return k.held end
    local o = part and k.overrides[part]
    if o ~= nil then return o end
    return k.value
end

-- the group holding the key now, else the first group it is in (nil: in no group)
function S.group_of(name)
    local m = K.member[name]
    if not m then return nil end
    for _, g in ipairs(m) do
        if g.options[g.group.value] then return g.group end
    end
    return m[1].group
end

local function find_group(ref, groups)
    groups = groups or K.groups
    if math.type(ref) == "integer" then return groups[ref], ref end
    for i, g in ipairs(groups) do if g.name == ref then return g, i end end
end

-- Group and option of a list of groups (K.groups, or a preset's key_groups) by name or 1-based
-- index; option 0 = off. Returns group, option index, or nil, error code, message.
function S.resolve_option(groups, ref, option)
    local g = find_group(ref, groups)
    if not g then return nil, "E_NOT_FOUND", "unknown key group: " .. tostring(ref) end
    if math.type(option) == "integer" then
        if option >= 0 and option <= #g.options then return g, option end
    elseif type(option) == "string" then
        for i, o in ipairs(g.options) do if o.name == option then return g, i end end
    end
    return nil, "E_NOT_FOUND", "unknown option of key group " .. tostring(g.name) .. ": " .. tostring(option)
end

-- Changes when the user edits or undoes anything; compared by identity.
function S.edit_mark() return K.undo[#K.undo] or K end

local function group_edit(tag)
    S.push_undo(tag)
    K.groups_touched = true
end

local function bad_group(ref) return false, "E_NOT_FOUND", "unknown key group: " .. tostring(ref) end

function S.group_new(name)
    if find_group(name) then return false, "E_EXISTS", "key group exists: " .. name end
    group_edit(nil)
    K.groups[#K.groups + 1] = { name = name, value = 0, options = {} }
    return true
end

function S.group_rename(ref, name)
    local g = find_group(ref)
    if not g then return bad_group(ref) end
    local other = find_group(name)
    if other and other ~= g then return false, "E_EXISTS", "key group exists: " .. name end
    group_edit(nil)
    g.name = name
    return true
end

-- its keys stay at their current values and return to the key list
function S.group_delete(ref)
    local g, gi = find_group(ref)
    if not g then return bad_group(ref) end
    group_edit(nil)
    table.remove(K.groups, gi)
    S.apply_groups()
    S.mark_dirty()
    return true
end

-- value: 0 (every key of the group at its default) .. #options. The switch other code turns
-- (conditions, drivers) goes through here too.
function S.group_set(ref, value)
    local g = find_group(ref)
    if not g then return bad_group(ref) end
    if math.type(value) ~= "integer" or value < 0 or value > #g.options then
        return false, "E_BAD_ARGS", string.format("value must be an integer 0..%d", #g.options)
    end
    if g.value == value then return true end
    group_edit("group:" .. g.name)
    g.value = value
    S.apply_groups()
    return true
end

function S.option_add(ref, name)
    local g = find_group(ref)
    if not g then return bad_group(ref) end
    if #g.options >= S.MAX_OPTIONS then return false, "E_LIMIT", string.format("at most %d options", S.MAX_OPTIONS) end
    group_edit(nil)
    g.options[#g.options + 1] = { name = name, values = {} }
    return true, #g.options
end

local function find_option(ref, i)
    local g = find_group(ref)
    if not g then return nil, bad_group(ref) end
    if math.type(i) ~= "integer" or not g.options[i] then
        return nil, false, "E_NOT_FOUND", "unknown option " .. tostring(i) .. " of " .. g.name
    end
    return g, g.options[i]
end

function S.option_rename(ref, i, name)
    local g, o, code, msg = find_option(ref, i)
    if not g then return o, code, msg end
    group_edit(nil)
    o.name = name
    return true
end

-- its keys return to the key list; the options after it move down by one
function S.option_delete(ref, i)
    local g, o, code, msg = find_option(ref, i)
    if not g then return o, code, msg end
    group_edit(nil)
    table.remove(g.options, i)
    if g.value == i then g.value = 0 elseif g.value > i then g.value = g.value - 1 end
    S.apply_groups()
    return true
end

-- names: keys to put into option i with their fixed value (values[name], else the key's current
-- value when it differs from the default, else 1). A key may be in other groups too.
function S.option_assign(ref, i, names, values)
    local g, o, code, msg = find_option(ref, i)
    if not g then return o, code, msg end
    for _, n in ipairs(names) do
        if not K.by_name[n] then return false, "E_NOT_FOUND", "unknown sculpt key: " .. tostring(n) end
    end
    group_edit(nil)
    local lo, hi = S.RANGE[1], S.MAX_LIMIT
    for _, n in ipairs(names) do
        local k = K.by_name[n]
        local v = values and tonumber(values[n])
        local cur = S.effective(k)
        if not v then v = abs(cur - k.default) > 1e-6 and cur or 1.0 end
        o.values[n] = U.clamp(v, lo, hi) + 0.0
    end
    S.apply_groups()
    return true
end

-- the keys leave option i of group ref (ref nil: every option of every group). A key that leaves
-- its groups keeps its current value and returns to the key list.
function S.unassign(names, ref, i)
    local g, o, code, msg
    if ref ~= nil then
        g, o, code, msg = find_option(ref, i)
        if not g then return o, code, msg end
    end
    for _, n in ipairs(names) do
        if not K.member[n] or (o and o.values[n] == nil) then
            return false, "E_NOT_FOUND", "key is not in that key group: " .. tostring(n)
        end
    end
    group_edit(nil)
    for _, n in ipairs(names) do
        if o then o.values[n] = nil
        else
            for _, m in ipairs(K.member[n]) do
                for _, opt in ipairs(m.group.options) do opt.values[n] = nil end
            end
        end
    end
    S.apply_groups()
    return true
end

-- the fixed value a key has in option i of group ref
function S.option_set_value(ref, i, name, value)
    local g, o, code, msg = find_option(ref, i)
    if not g then return o, code, msg end
    if o.values[name] == nil then return false, "E_NOT_FOUND", "key is not in that option: " .. tostring(name) end
    group_edit("gv:" .. g.name .. ":" .. i .. ":" .. name)
    o.values[name] = U.clamp(value, S.RANGE[1], S.RANGE[2]) + 0.0
    S.apply_groups()
    return true
end

-- what a preset file stores (nil without groups)
function S.export_groups()
    if #K.groups == 0 then return nil end
    return U.copy(K.groups)
end

local function groups_sig(groups)
    local out = {}
    for _, g in ipairs(groups) do
        out[#out + 1] = g.name .. "=" .. g.value
        for _, o in ipairs(g.options) do
            local names = {}
            for n in pairs(o.values) do names[#names + 1] = n end
            table.sort(names)
            out[#out + 1] = ">" .. o.name
            for _, n in ipairs(names) do out[#out + 1] = string.format("%s:%.4f", n, o.values[n]) end
        end
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- values
local function snapshot()
    local s = {}
    for _, k in ipairs(K.keys) do
        local o = {}
        for p, v in pairs(k.overrides) do o[p] = v end
        s[k.name] = { value = k.value, overrides = o, touched = k.touched }
    end
    s[GROUPS] = { groups = U.copy(K.groups), touched = K.groups_touched }
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
    local g = s[GROUPS]
    if g then K.groups, K.groups_touched = U.copy(g.groups), g.touched end
    refresh_held(false)
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
function S.mark_dirty(name)
    S.version = S.version + 1
    for _, t in ipairs(K.targets) do
        t.dirty = true
        if W.adapter.active_sculpt then
            if not name then t.all_dirty = true
            else
                local i = t.by_key[name]
                if i and #t.items[i].idx > 0 and not t.pending_set[i] then
                    t.pending_set[i] = true
                    t.pending[#t.pending + 1] = i
                end
            end
        end
    end
end

-- A dynamic source changed: the lazy mode rewrites only the keys such sources name now or named
-- on the previous rewrite (a released key goes back to its sculpt value).
function S.mark_dynamic()
    if W.adapter.active_sculpt then return end
    S.version = S.version + 1
    for _, t in ipairs(K.targets) do t.dynamic_dirty = true end
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
    if k.held ~= nil then return "E_IN_GROUP", "key is held by a key group: " .. tostring(name) end
    return nil
end

-- global slider cap for values set by hand; values already above it stay
function S.set_max(m)
    m = U.clamp(tonumber(m) or 1.0, 1.0, S.MAX_LIMIT) + 0.0   -- settings.json gives the integer 1
    S.RANGE[2] = m
    return m
end

function S.set(name, value)
    local k = K.by_name[name]
    if not k then return false end
    S.push_undo("set:" .. name)
    k.value = U.clamp(value, S.RANGE[1], S.RANGE[2])
    k.touched = true
    S.mark_dirty(name)
    return true
end

function S.set_override(name, part, value)
    local k = K.by_name[name]
    if not k then return false, "E_NOT_FOUND", "unknown sculpt key: " .. tostring(name) end
    if k.held ~= nil then return false, "E_IN_GROUP", "key is held by a key group: " .. tostring(name) end
    local found = false
    for _, p in ipairs(k.parts) do if p == part then found = true end end
    if not found then return false, "E_NOT_FOUND", tostring(name) .. " is not on part " .. tostring(part) end
    S.push_undo("ovr:" .. name .. "@" .. part)
    k.overrides[part] = value ~= nil and U.clamp(value, S.RANGE[1], S.RANGE[2]) or nil
    k.touched = true
    S.mark_dirty(name)
    return true
end

function S.reset(name)
    local k = K.by_name[name]
    if not k then return false end
    S.push_undo(nil)
    k.value, k.overrides, k.touched = k.default, {}, true
    for p, v in pairs(k.preset_overrides) do k.overrides[p] = v end
    S.mark_dirty(name)
    return true
end

-- every key to 0 (one undo step); false when everything already was 0
function S.clear_all()
    local changed = false
    for _, k in ipairs(K.keys) do
        if k.value ~= 0 or next(k.overrides) ~= nil then changed = true end
    end
    for _, g in ipairs(K.groups) do if g.value ~= 0 then changed = true end end
    if not changed then return false end
    S.push_undo(nil)
    for _, g in ipairs(K.groups) do if g.value ~= 0 then g.value, K.groups_touched = 0, true end end
    for _, k in ipairs(K.keys) do k.value, k.overrides, k.touched = 0.0, {}, true end
    refresh_held(false)
    S.mark_dirty()
    return true
end

-- every key back to the mod default and every key group off (one undo step); false when nothing differed
function S.reset_all()
    local changed = false
    for _, k in ipairs(K.keys) do
        if abs(k.value - k.default) > 1e-9 or next(k.overrides) ~= nil or next(k.preset_overrides) ~= nil then changed = true end
    end
    for _, g in ipairs(K.groups) do if g.value ~= 0 then changed = true end end
    if not changed then return false end
    S.push_undo(nil)
    for _, g in ipairs(K.groups) do if g.value ~= 0 then g.value, K.groups_touched = 0, true end end
    for _, k in ipairs(K.keys) do
        k.value, k.overrides, k.touched = k.default, {}, true
        for p, v in pairs(k.preset_overrides) do k.overrides[p] = v end
    end
    refresh_held(false)
    S.mark_dirty()
    return true
end

-- load a sculpt preset (one undo step): its values for the keys it names, the mod default for
-- the rest (expression keys included: their value is the rest position under the expression),
-- and its key groups in place of the current ones
function S.apply_preset(preset)
    S.push_undo(nil)
    K.groups, K.groups_touched = U.copy(preset.key_groups or {}), true
    local lo, hi = S.RANGE[1], S.MAX_LIMIT
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
    refresh_held(false)
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
    if K.saved then
        if groups_sig(K.groups) ~= groups_sig(K.saved[GROUPS].groups) then return true end
    elseif K.groups_touched then
        return true
    end
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
    return S.effective(key, part)
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

local function activate(t, i, want)
    local pos = t.active_pos[i]
    if want and not pos then
        t.active[#t.active + 1] = i
        t.active_pos[i] = #t.active
    elseif not want and pos then
        local last = t.active[#t.active]
        t.active[pos], t.active_pos[last] = last, pos
        t.active[#t.active], t.active_pos[i] = nil, nil
    end
end

local function queue(t, i)
    if t.work_seen[i] ~= t.work_epoch then
        t.work_seen[i] = t.work_epoch
        t.work[#t.work + 1] = i
    end
end

local dynamic_names = {}
local function tick_active(preview, eps)
    for name in pairs(dynamic_names) do dynamic_names[name] = nil end
    for name in pairs(Ext.entries) do dynamic_names[name] = true end
    CondExpr.targets(dynamic_names)
    Touch.targets(dynamic_names)
    local writes = 0
    for _, t in ipairs(K.targets) do
        if t.stable < G.STABLE_FRAMES then
            if G.mesh_ready(t.mesh) then t.stable = t.stable + 1 else t.stable = 0 end
        elseif not G.mesh_still_ready(t.mesh) then
            return writes, "sculpt mesh no longer ready: " .. t.id
        else
            local full = t.all_dirty or t.preview ~= preview
            t.work_epoch = t.work_epoch + 1
            for i = #t.work, 1, -1 do t.work[i] = nil end
            local current = t.next_dynamic
            for i in pairs(current) do current[i] = nil end
            for name in pairs(dynamic_names) do
                for _, i in ipairs(t.by_norm[name] or {}) do current[i] = true end
            end
            if full then
                for i, item in ipairs(t.items) do if #item.idx > 0 then queue(t, i) end end
            else
                for _, i in ipairs(t.active) do queue(t, i) end
                for _, i in ipairs(t.pending) do queue(t, i) end
                for i in pairs(t.dynamic) do queue(t, i) end
                for i in pairs(current) do queue(t, i) end
            end
            local batch
            for _, item_index in ipairs(t.work) do
                local item = t.items[item_index]
                if full or item.weight == nil or t.pending_set[item_index] or current[item_index] or t.dynamic[item_index] then
                    item.weight = value_for(item.key, t.id, preview)
                end
                local w, keep = item.weight, false

                for _, i in ipairs(item.idx) do
                    local last = t.last[i]
                    if last == nil then
                        batch = batch or W.begin_batch(t.mesh)
                        last = W.read_weight(t.mesh, i, batch) or 0
                        t.last[i] = last
                    end
                    local active = W.adapter.rewrite_active_weights and (w ~= 0 or last ~= 0)

                    if active or abs(w - last) > eps then
                        batch = batch or W.begin_batch(t.mesh)
                        if W.set_weight(t.mesh, i, w, item.key.name, batch) then
                            t.last[i] = w
                            writes = writes + 1
                        end
                    end
                    if w ~= 0 or t.last[i] ~= 0 then keep = true end
                end
                -- Failed zero writes remain scheduled; a released override also restores its base.
                activate(t, item_index, keep)
            end
            W.flush(batch)
            for i = #t.pending, 1, -1 do t.pending[i] = nil end
            for i in pairs(t.pending_set) do t.pending_set[i] = nil end
            t.dynamic, t.next_dynamic = current, t.dynamic
            t.all_dirty, t.dirty, t.preview = false, false, preview
        end
    end
    return writes
end

-- returns writes, error string (mesh lost readiness)
local function write_item(t, item, preview, eps, batch)
    local last, writes = t.last, 0
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
            if W.set_weight(t.mesh, i, w, item.key.name, batch) then
                last[i] = w
                writes = writes + 1
            elseif not t.refused then
                -- the adapter's channel check turned the channel down
                t.refused = true
                Trail.event("sculpt: %s channel %d (%s) refused by the game adapter", t.id, i, item.key.name)
            end
        end
    end
    return writes
end

local lazy_dynamic = {}
function S.tick(edit_mode, preview, eps)
    if W.adapter.active_sculpt then return tick_active(preview, eps) end
    local writes = 0
    local names_ready = false
    for _, t in ipairs(K.targets) do
        if t.stable < G.STABLE_FRAMES then
            local ready, why = G.mesh_ready(t.mesh)
            if ready then
                t.stable = t.stable + 1
                if t.stable == G.STABLE_FRAMES and not t.logged then
                    t.logged = true
                    local n = 0
                    for _, item in ipairs(t.items) do n = n + #item.idx end
                    Trail.event("sculpt: writing %s (%d keys, %d channels)", t.id, #t.items, n)
                end
            else
                t.stable = 0
                -- a part that never becomes ready says why once, after about ten seconds
                t.waited = (t.waited or 0) + 1
                if t.waited == 600 then Trail.event("sculpt: %s not ready: %s", t.id, tostring(why)) end
            end
        elseif not G.mesh_still_ready(t.mesh) then
            return writes, "sculpt mesh no longer ready: " .. t.id
        elseif t.dirty or edit_mode or W.adapter.rewrite_active_weights then
            local batch = W.adapter.native_write and W.begin_batch(t.mesh) or nil
            for _, item in ipairs(t.items) do writes = writes + write_item(t, item, preview, eps, batch) end
            W.flush(batch)
            t.dirty, t.dynamic_dirty = false, false
        elseif t.dynamic_dirty then
            if not names_ready then
                names_ready = true
                for name in pairs(lazy_dynamic) do lazy_dynamic[name] = nil end
                for name in pairs(Ext.entries) do lazy_dynamic[name] = true end
                CondExpr.targets(lazy_dynamic)
                Touch.targets(lazy_dynamic)
            end
            local current = {}
            for name in pairs(lazy_dynamic) do
                for _, i in ipairs(t.dyn_by_norm[name] or {}) do current[i] = true end
            end
            for i in pairs(t.dyn_prev) do current[i] = true end
            local batch = W.adapter.native_write and W.begin_batch(t.mesh) or nil
            for i in pairs(current) do writes = writes + write_item(t, t.items[i], preview, eps, batch) end
            W.flush(batch)
            local now = {}
            for name in pairs(lazy_dynamic) do
                for _, i in ipairs(t.dyn_by_norm[name] or {}) do now[i] = true end
            end
            t.dyn_prev, t.dynamic_dirty = now, false
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
