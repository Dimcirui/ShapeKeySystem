-- ShapeKeySystem: drive additional actors with their own bindings, profiles and signal handles.
--
-- The player's editable profile stays in API.lua. Additional actors own their compiled program,
-- smoothing, eye settings and sculpt bases. Lifecycle events discard handles before actor teardown.
-- With Core/Actors.lua the faces are every character but the edited one (`M.faces`), and the
-- drivers of a rig's character (`Drivers.actor_values`) override its channels.
local U = require("ShapeKeySystem_Core.Util")
local L = require("ShapeKeySystem_Core.I18n")
local Scene = require("ShapeKeySystem_Core.Scene")
local Names = require("ShapeKeySystem_Core.Names")
local Profile = require("ShapeKeySystem_Core.Profile")
local Presets = require("ShapeKeySystem_Core.Presets")
local X = require("ShapeKeySystem_Core.Expression")
local Guard = require("ShapeKeySystem_Core.Guard")
local Writer = require("ShapeKeySystem_Core.Writer")
local Sculpt = require("ShapeKeySystem_Core.Sculpt")
local Drivers = require("ShapeKeySystem_Core.Drivers")
local Ext = require("ShapeKeySystem_Core.External")
local M = { state = { rev = 0, instances = {}, errors = {} } }
M.faces = nil   -- function returning the faces to drive (API sets it with Core/Actors.lua)
local adapter, rigs, frame, next_scan = nil, {}, 0, 0
local RANK = { global = 3, own = 2, model = 1, default = 0 }

function M.init(game)
    adapter = game
    rigs, frame, next_scan = {}, 0, 0
    M.state.instances, M.state.errors = {}, {}
end

function M.release(reason)
    rigs = {}
    next_scan = frame + Guard.SETTLE_FRAMES
    M.state.instances, M.state.reason = {}, reason
    M.state.rev = M.state.rev + 1
end

local function ready(options)
    if not adapter or not adapter.additional_faces then return false end
    return options.enabled and adapter.instances_ready(options.cutscene_drive) == true
end

local function identity(rig)
    return tostring(rig.face:get_address()) .. ":" .. tostring(rig.parent:get_address())
end

local function binding_of(parts)
    local bindings, best, rank, count, warnings = {}, nil, -1, -1, {}
    for _, part in ipairs(parts) do
        local r = Presets.resolve_binding(part.id, nil, part.fingerprint, parts)
        bindings[part.id] = r
        for _, entry in ipairs(r.chain) do
            local detail = entry.error or entry.warning
            if detail then warnings[#warnings+1] = part.id .. " · " .. entry.path .. " · " .. detail end
        end
        local score = (RANK[r.level] or 0) + (r.source == "user" and 10 or 0)
        if r.hit and (score > rank or score == rank and part.n > count) then
            best, rank, count = r, score, part.n
        end
    end
    return best, bindings, warnings
end

local function tuning(prog, binding, options)
    local e = U.copy(options.expression)
    local eyes = U.copy(options.eyes)
    -- The player's saved neutral pose must not become another actor's calibration.
    eyes.neutral = { L = {yaw = 0, pitch = 0}, R = {yaw = 0, pitch = 0} }
    local data = binding and binding.data or {}
    local g = data.gains or {}
    for _, k in ipairs({"master_gain", "gaze_gain", "smoothing"}) do
        if type(g[k]) == "number" then e[k] = g[k] end
    end
    for k, v in pairs(g.region_gains or {}) do e.region_gains[k] = v end
    e.channel_gains = g.for_profile and g.for_profile ~= prog.id and {} or U.copy(g.channel_gains or e.channel_gains or {})
    for k, values in pairs(data.eyes or {}) do
        if type(eyes[k]) == "table" and type(values) == "table" then
            for key, value in pairs(values) do
                if type(value) == "table" then
                    for axis, number in pairs(value) do eyes[k][key][axis] = number end
                else eyes[k][key] = value end
            end
        end
    end
    local gains = {}
    for slot, c in ipairs(prog.channels) do
        local gain = tonumber(e.channel_gains[c.name]) or 1
        if c.group == "gaze" or c.is_eye then
            gain = gain * e.gaze_gain * ((not c.gaze_set or eyes.sets[c.gaze_set] ~= false) and 1 or 0)
        else
            local region = X.REGION_OF[c.group]
            gain = gain * e.master_gain * (region and e.region_gains[region] or 1)
        end
        gains[slot] = gain
    end
    return e, eyes, gains
end

local function sculpt_values(part, binding)
    local data = binding and binding.data or {}
    local preset = Presets.find_sculpt(data.sculpt, binding and binding.folder)
    local values = {}
    if not preset then return values end
    -- `target` names the part the preset was made on, not the only part it applies to: like
    -- Sculpt.rebuild for the edited character, its values reach every part of the binding's model
    for name, value in pairs(preset.values) do values[Sculpt.key_of(name)] = value end
    for name, value in pairs(preset.overrides[part.id] or {}) do values[Sculpt.key_of(name)] = value end
    return values
end

local function build(raw, options, old)
    local binding, bindings, warnings = binding_of(raw.parts)
    local id = binding and binding.data.profile or options.profile
    local resolved, _, message = Profile.resolve(id)
    if not resolved then error(L.f("实例 Profile %s：%s", tostring(id), L.tr(tostring(message))), 0) end
    local program, _, why = Profile.compile(resolved, {})
    if not program then error(why, 0) end
    local e, eyes, gains = tuning(program, binding, options)
    local token = raw.psig .. U.signature({profile = id, binding = binding and binding.data,
        bindings = bindings, expression = e, eyes = eyes}) .. tostring(Profile.registry) .. tostring(Presets.sculpt_list)
    if old and old.token == token then return old end
    raw.token, raw.prog, raw.binding, raw.bindings = token, program, binding, bindings
    raw.warnings = warnings
    raw.expression, raw.eye_settings, raw.gains = e, eyes, gains
    raw.P, raw.W, raw.V, raw.forced = {}, {}, {}, {}
    local index = Names.build_index(program.names, resolved.aliases, resolved.channels)
    raw.index, raw.driven = index, {}
    raw.actor = adapter.actor_of and adapter.actor_of(raw.face) or nil
    raw.targets, raw.manual = {}, {}
    local slots = {}
    for _, part in ipairs(raw.parts) do
        local own = bindings[part.id]
        local base = sculpt_values(part, own.hit and own or binding)
        local target = Scene.build_target(part, index, 1, {})
        local owned = {}
        if target then
            target.base = {}
            for k, slot in ipairs(target.slots) do
                local idx = target.idxs[k]
                owned[idx], slots[slot] = true, true
                target.base[k] = base[Sculpt.key_of(part.names[idx + 1])] or 0
            end
            raw.targets[#raw.targets + 1] = target
        end
        local manual = {mesh = part.mesh, n = part.n, stable = 0, values = {}, last = {}}
        for i, name in ipairs(part.names) do
            local value = base[Sculpt.key_of(name)]
            if not owned[i-1] and name ~= "" and value ~= nil then
                manual.values[#manual.values + 1] = {idx = i-1, name = name, value = value}
            end
        end
        if #manual.values > 0 then raw.manual[#raw.manual + 1] = manual end
    end
    local keys, use_eyes = Profile.needs(program, slots)
    raw.params = adapter.bind(raw.face, keys)
    raw.use_eyes = use_eyes
    return raw
end

local function publish()
    local rows = {}
    for _, rig in ipairs(rigs) do
        local count, stable = 0, true
        for _, target in ipairs(rig.targets) do
            count = count + target.count
            stable = stable and target.stable >= Guard.STABLE_FRAMES
        end
        for _, target in ipairs(rig.manual) do
            count = count + #target.values
            stable = stable and target.stable >= Guard.STABLE_FRAMES
        end
        rows[#rows + 1] = {id = rig.id, label = rig.label, profile = rig.prog.id,
            binding = rig.binding and rig.binding.hit, channels = count, ready = stable,
            status = rig.status, warnings = U.copy(rig.warnings), eyes = U.copy(rig.eye_settings), gains = U.copy(rig.gains)}
    end
    M.state.instances, M.state.rev = rows, M.state.rev + 1
end

local function scan(options)
    local old = {}
    for _, rig in ipairs(rigs) do old[rig.id] = rig end
    local result = Scene.scan({faces = M.faces and M.faces() or adapter.additional_faces(), include_empty = true,
        index = Names.build_index({}), known = options.known, min_hits = 1})
    local found, errors = {}, {}
    for _, raw in ipairs(result.rigs) do
        if not raw.primary then
            local ok, rig = pcall(function()
                raw.id = identity(raw)
                if adapter.prepare_parts then adapter.prepare_parts(raw.parts) end
                return build(raw, options, old[raw.id])
            end)
            if ok then found[#found + 1] = rig else errors[#errors+1] = tostring(rig) end
        end
    end
    rigs, M.state.errors = found, errors
end

-- Where a driven key lands on this rig: { slot } for a profile channel, { mesh, idx } for another
-- channel of the same name, false when the rig has neither. Cached per rig.
local function driver_target(rig, norm, name)
    local hit = rig.driven[norm]
    if hit ~= nil then return hit end
    local slot = rig.prog.slot_of[name]
    if not slot then
        local ok, m = pcall(Names.match, rig.index, name)
        slot = ok and m or nil
    end
    if slot then hit = { slot = slot }
    else
        hit = false
        for _, part in ipairs(rig.parts) do
            for i, n in ipairs(part.names) do
                if n ~= "" and Ext.norm(n) == norm then hit = { mesh = part.mesh, idx = i - 1, name = n, stable = 0, base = 0 }; break end
            end
            if hit then break end
        end
    end
    if hit and hit.mesh then
        for _, m in ipairs(rig.manual) do
            if m.mesh == hit.mesh then
                for _, v in ipairs(m.values) do if v.idx == hit.idx then hit.base = v.value end end
            end
        end
    end
    rig.driven[norm] = hit
    return hit
end

local function valid(rig)
    return Scene.children_signature(rig.parent) == rig.psig
end

local function drive(rig, options)
    if not valid(rig) then return false end
    for key in pairs(rig.P) do rig.P[key] = nil end
    X.read(rig, rig.P, options.inv_full, false, rig.eye_settings, rig.use_eyes)
    local smoothing = rig.expression.smoothing
    local alpha = smoothing > 0 and 1 - math.min(smoothing, 1) * 0.9 or 1
    X.compute(rig.prog, rig, rig.P, rig.gains, rig.forced, options.clamp, alpha,
        rig.eye_settings.full_deg.yaw, rig.eye_settings.full_deg.pitch)
    local out = rig.W
    if options.expression_enabled == false then
        rig.O = rig.O or {}
        for slot = 1, rig.prog.n do rig.O[slot] = 0 end
        out = rig.O
    end
    -- this character's drivers: a profile channel is overridden (not mixed with its sculpt base),
    -- another channel is written directly; one no driver holds any more goes back to its base once
    local skip, raws = nil, nil
    local values = rig.actor and Drivers.actor_values[rig.actor]
    if values then
        for norm, e in pairs(values) do
            local hit = driver_target(rig, norm, e.name)
            if hit and hit.slot then
                if out ~= rig.O then rig.O = rig.O or {}; for s = 1, rig.prog.n do rig.O[s] = out[s] end; out = rig.O end
                out[hit.slot] = e.value
                skip = skip or {}; skip[hit.slot] = true
            elseif hit then
                raws = raws or {}; raws[hit] = e.value
            end
        end
    end
    for _, target in ipairs(rig.targets) do
        if not Guard.mesh_ready(target.mesh) then target.stable = 0
        elseif target.stable < Guard.STABLE_FRAMES then target.stable = target.stable + 1
        else Writer.write_target(target, out, false, options.epsilon, target.base, Sculpt.mix, skip) end
    end
    for _, target in ipairs(rig.manual) do
        if not Guard.mesh_ready(target.mesh) then target.stable = 0
        elseif target.stable < Guard.STABLE_FRAMES then target.stable = target.stable + 1
        else
            for _, value in ipairs(target.values) do
                local previous = target.last[value.idx] or 0
                if adapter.rewrite_active_weights and (value.value ~= 0 or previous ~= 0)
                    or math.abs(value.value - previous) > options.epsilon then
                    if Writer.set_weight(target.mesh, value.idx, value.value, value.name) then
                        target.last[value.idx] = value.value
                    end
                end
            end
        end
    end
    -- after the sculpt values, every frame: those are rewritten while active on some games
    for _, hit in pairs(rig.driven) do
        if hit and hit.mesh then
            local v = raws and raws[hit]
            local restore = v == nil and hit.held
            if restore then v = hit.base end
            if v ~= nil then
                if not Guard.mesh_ready(hit.mesh) then hit.stable = 0
                elseif hit.stable < Guard.STABLE_FRAMES then hit.stable = hit.stable + 1
                elseif Writer.set_weight(hit.mesh, hit.idx, v, hit.name) then hit.held = not restore end
            end
        end
    end
    return true
end

function M.tick(current_frame, options)
    if not adapter or not adapter.additional_faces then return end
    frame = current_frame
    if not options.enabled and #rigs > 0 then
        for _, rig in ipairs(rigs) do
            pcall(function()
                if not valid(rig) then return end
                for _, target in ipairs(rig.targets) do
                    if target.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(target.mesh) then Writer.zero_target(target) end
                end
                for _, target in ipairs(rig.manual) do
                    if target.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(target.mesh) then
                        for _, value in ipairs(target.values) do Writer.set_weight(target.mesh, value.idx, 0, value.name) end
                    end
                end
            end)
        end
        M.release("总开关关闭")
    end
    local ok, allowed = pcall(ready, options)
    if not ok or not allowed then
        if #rigs > 0 then M.release("实例驱动暂停") end
        return
    end
    if frame >= next_scan then
        next_scan = frame + 60
        local scanned, why = pcall(scan, options)
        if not scanned then M.release("实例扫描中断"); M.state.errors = {tostring(why)}; return end
    end
    for i = #rigs, 1, -1 do
        local driven, alive = pcall(drive, rigs[i], options)
        if not driven or not alive then
            if not driven then M.state.errors[#M.state.errors+1] = tostring(alive) end
            table.remove(rigs, i)
            next_scan = math.min(next_scan, frame + Guard.SETTLE_FRAMES)
        end
    end
    if frame % 15 == 0 then publish() end
end

function M.prepare()
    if not adapter or not adapter.prepare_mesh then return end
    for i = #rigs, 1, -1 do
        local ok, alive = pcall(function()
            if not valid(rigs[i]) then return false end
            for _, part in ipairs(rigs[i].parts) do
                if Guard.mesh_ready(part.mesh) then adapter.prepare_mesh(part.mesh) end
            end
            return true
        end)
        if not ok or not alive then table.remove(rigs, i) end
    end
end

return M
