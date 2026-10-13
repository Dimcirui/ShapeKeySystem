-- ShapeKeySystem: backend entry point. The UI reads SKS.state / SKS.live and changes things
-- only through SKS.call(cmd, args). Engine writes happen only in SKS.tick (LateUpdateBehavior).
-- Contract: docs/plans/shape-key-system-api.md (v0.1). M1: runtime, scene, expression, eyes,
-- mapping, debug. M2: parent presets (bindings, per part ID) and the sculpt layer.

local U       = require("ShapeKeySystem_Core.Util")
local Names   = require("ShapeKeySystem_Core.Names")
local Profile = require("ShapeKeySystem_Core.Profile")
local Scene   = require("ShapeKeySystem_Core.Scene")
local Writer  = require("ShapeKeySystem_Core.Writer")
local X       = require("ShapeKeySystem_Core.Expression")
local Guard   = require("ShapeKeySystem_Core.Guard")
local Probe   = require("ShapeKeySystem_Core.Probe")
local Trail   = require("ShapeKeySystem_Core.Trail")
local Presets = require("ShapeKeySystem_Core.Presets")
local Sculpt  = require("ShapeKeySystem_Core.Sculpt")
local Ext     = require("ShapeKeySystem_Core.External")
local Cnd     = require("ShapeKeySystem_Core.Conditions")
local CondExpr = require("ShapeKeySystem_Core.CondExpr")
local Touch   = require("ShapeKeySystem_Core.Touch")
local Facial  = require("ShapeKeySystem_Core.Facial")
local I18n    = require("ShapeKeySystem_Core.I18n")

local Version = require("ShapeKeySystem_Core.Version")
local SKS = { version = Version.number }

local SETTINGS_PATH = U.path("settings.json")
local LEGACY_PATH = "ArkitFaceDriver.json"
local clock, max, min = os.clock, math.max, math.min

-- ---------------------------------------------------------------- settings
local DEFAULTS = {
    enabled = true, advanced = false,
    -- Delete: Home opens ArmorVariantManager's panel (same audience), End is the game's pause key,
    -- Insert is REFramework's menu. hotkey_rev 2 = the End -> Delete move has been applied.
    hotkey = "Delete", hotkey_migrated = false, hotkey_rev = 2, ui_scale = 1.0, language = "zh",
    scene_search_always = false, periodic_scan_sec = 10, write_epsilon = 0.001, clamp = true,
    -- drive the hunter while a cutscene plays (released on skip / stop, re-armed per segment)
    cutscene_drive = true,
    -- sculpt slider upper end, for every key (1 = the authored shape; 2 = exaggerated)
    sculpt_max = 1.0,
    -- conditional expression set used when no parent preset names one ("" = none)
    conditions = "",
    -- face navigator art on the basic page: data/ShapeKeySystem/faces/<id>.json
    face_style = "chibi",
    -- facial preset sliders (Facial.lua): numbered key name -> 0..1
    facial = {},
    window = { x = 120, y = 120, w = 920, h = 640 },
    profile = "arkit",
    -- M1: expression gains live here until per-part bindings exist (M2)
    expression = { master_gain = 1.0, gaze_gain = 1.0, smoothing = 0.0,
                   region_gains = { brow = 1.0, eye = 1.0, nose_cheek = 1.0, mouth = 1.0 },
                   channel_gains = {} },
    eyes = { full_deg = { yaw = 25.0, pitch = 20.0 }, invert = { yaw = false, pitch = false },
             neutral = { L = { yaw = 0, pitch = 0 }, R = { yaw = 0, pitch = 0 } },
             sets = { eye_look = true, look = true } },
}

local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" and #v == 0 then merge(dst[k], v)
        elseif v ~= nil then dst[k] = v end
    end
    return dst
end

local cfg = U.copy(DEFAULTS)
local legacy_gains = nil

local hotkey_migrated_now = false
local function load_settings()
    local data = U.load_json(SETTINGS_PATH)
    if data then
        merge(cfg, data)
        if not I18n.set(cfg.language) then cfg.language = I18n.lang end
        -- once: the old defaults Home (ArmorVariantManager) and End (game pause) move to Delete
        if (tonumber(data.hotkey_rev) or 0) < 2 then
            if cfg.hotkey == "Home" or cfg.hotkey == "End" then
                cfg.hotkey = "Delete"
                hotkey_migrated_now = true
            end
            cfg.hotkey_migrated = true
            cfg.hotkey_rev = 2
        end
        return
    end
    -- first run: take over ArkitFaceDriver.json
    local old = U.load_json(LEGACY_PATH)
    if not old then return end
    cfg.enabled = old.enabled ~= false
    cfg.expression.master_gain = tonumber(old.gain) or 1.0
    if old.write_epsilon then cfg.write_epsilon = old.write_epsilon end
    if old.periodic_scan_sec then cfg.periodic_scan_sec = old.periodic_scan_sec end
    if old.scene_search_always ~= nil then cfg.scene_search_always = old.scene_search_always end
    cfg.eyes.full_deg.yaw = tonumber(old.eye_full_deg_yaw) or 25
    cfg.eyes.full_deg.pitch = tonumber(old.eye_full_deg_pitch) or 20
    cfg.eyes.invert.yaw = old.eye_invert_yaw == true
    cfg.eyes.invert.pitch = old.eye_invert_pitch == true
    if type(old.eye_neutral) == "table" then
        for _, s in ipairs({ "L", "R" }) do
            local n = old.eye_neutral[s]
            if type(n) == "table" then cfg.eyes.neutral[s] = { yaw = n[1] or 0, pitch = n[2] or 0 } end
        end
    end
    if old.eyes_enabled == false then cfg.eyes.sets = { eye_look = false, look = false } end
    legacy_gains = old.channel_gain   -- names resolved against the profile after compile
end

-- ---------------------------------------------------------------- state / live
local state = {
    runtime = { rev = 0, enabled = true, ui_open = false, advanced = false, notices = {} },
    scene = { rev = 0, last_scan = nil, rigs = {}, parts = {} },
    expression = { rev = 0, profile = nil, coverage = nil, binding_source = nil,
                   master_gain = 1, gaze_gain = 1, smoothing = 0,
                   regions = {}, groups = {}, channels = {} },
    eyes = { rev = 0 },
    mapping = { rev = 0, signals = {}, nodes = {}, edited = {} },
    sculpt = { rev = 0, scan = nil, edit_mode = false, ab_preview = false, dirty = false,
               can_undo = false, can_redo = false, preset = nil, groups = {}, keys = {} },
    presets = { rev = 0, binding = nil, expression = {}, sculpt = {}, pending_delete = nil },
    settings = { rev = 0 },
    -- keys other plugins hold through ShapeKeySystemAPI: held = {{name, owner, value}},
    -- by_norm[External.norm(name)] = owner
    external = { rev = 0, held = {}, by_norm = {} },
    -- conditional expressions: sets on disk, the set in effect (working copy), condition defs
    conditions = { rev = 0, sets = {}, current = nil, defs = {}, binding_name = nil },
    -- face-navigator interactions: zones = { forehead = bool, cheek = bool, eye = bool, mouth = bool }
    touch = { rev = 0, zones = {} },
    -- facial presets (Facial.lua): keys = {{name, value}} in number order; level = the highest value
    facial = { rev = 0, keys = {}, level = 0 },
    debug = { rev = 0, perf = { read = 0, compute = 0, write = 0, scan = 0, total = 0, writes = 0, skipped = 0 },
              log = {}, status = "" },
}
local live = {
    weight = {}, region_activity = { 0, 0, 0, 0 }, signal = {},
    eye_angle = { L = { yaw = 0, pitch = 0 }, R = { yaw = 0, pitch = 0 } },
}
SKS.state, SKS.live = state, live

-- ---------------------------------------------------------------- internal
local C = {
    prog = nil, resolved = nil, edits = {}, index = {},
    gains = {}, forced = {},
    rigs = {}, parts = {}, sig = "", cov_key = nil,
    frame = 0, scan_at = { 1 }, next_periodic = 0, gc_open = false,
    pending_zero = {}, save_at = nil,
    P = {}, Pbuf = {}, inv_full = 100, dict_params = {},
    want_signals = false,
    paused = nil,         -- reason string while the game gate is closed
    menu = false,         -- menu mode: master player not set up (title, save select, loading)
    prev_kind = nil,      -- Guard.game_stable kind of the previous frame (nil = stable)
    -- M2
    binding = nil,        -- the parent preset in effect (Presets.resolve_binding result)
    part_bindings = {},   -- part id -> resolve result
    -- per-part tuning (gains + gaze); stash_* = the settings.json fallback while a binding is loaded
    tuning = { source = "settings", path = nil, dirty = false, mismatch = false, stash_expression = nil, stash_eyes = nil },
    sculpt_preset = nil, sculpt_preset_manual = false,
    edit_mode = false, preview = false,
    pending_delete = nil,
    warned = {},          -- binding problems already reported (one notice each)
}
local prof = { read = 0, compute = 0, write = 0, scan = 0, writes = 0, skipped = 0, frames = 0, window = 60 }

local function bump(section) state[section].rev = state[section].rev + 1 end

-- a data name as a notice param: {zh = name, en = name_en or name}
local function pair(name, name_en) return { zh = name, en = name_en or name } end

local function log(fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Trail.event("%s", text)
    local l = state.debug.log
    l[#l + 1] = { time = os.date("%H:%M:%S"), text = text }
    if #l > 200 then table.remove(l, 1) end
    bump("debug")
end

-- notices carry a message id + params (I18n.lua); `text` is their rendering in the current
-- language, redone when the language changes. args may hold {zh, en} pairs (data names).
local notice_seq = 0
local function notice(level, key, args)
    notice_seq = notice_seq + 1
    local n = state.runtime.notices
    args = args or {}
    n[#n + 1] = { id = notice_seq, level = level, key = key, args = args, text = I18n.t(key, table.unpack(args)),
                  time = os.time() }
    if #n > 20 then table.remove(n, 1) end
    bump("runtime")
    return notice_seq
end

local function save_soon() C.save_at = C.frame + 60 end
-- gains as saved, for one trail line per save naming what changed (kevin, 2026-10-13: the master
-- and mouth gains were found at 0 with no idea how; a drag saves once, ~1 s after it stops)
local function gains_of(e)
    local g = { master = e.master_gain, gaze = e.gaze_gain }
    for k, v in pairs(e.region_gains or {}) do g[k] = v end
    return g
end
local function save_now()
    C.save_at = nil
    local out = cfg
    local t = C.tuning
    if t.source == "binding" and t.stash_expression then
        -- a binding's tuning is loaded: settings.json keeps the global fallback values
        out = {}
        for k, v in pairs(cfg) do out[k] = v end
        out.expression = t.stash_expression
        out.eyes = U.copy(cfg.eyes)
        for k, v in pairs(t.stash_eyes) do out.eyes[k] = v end
    end
    if not U.save_json(SETTINGS_PATH, out) then log("settings save failed") end
    local now, was, diff = gains_of(out.expression), C.saved_gains, {}
    if was then
        for k, v in pairs(now) do
            if was[k] and math.abs(was[k] - v) > 1e-6 then diff[#diff + 1] = string.format("%s %.2f -> %.2f", k, was[k], v) end
        end
    end
    table.sort(diff)
    if #diff > 0 then Trail.event("gains saved: %s", table.concat(diff, ", ")) end
    C.saved_gains = now
end

local function request_rescan(...)
    local delays = { ... }
    if #delays == 0 then delays = { 1 } end
    for _, d in ipairs(delays) do C.scan_at[#C.scan_at + 1] = C.frame + d end
end

-- Let go of every engine object we hold (no writes). Used when parts are rebuilt or a cutscene
-- takes over; references that outlive the objects crashed the game (SKS_Mocap investigation).
local MENU_SCAN_FRAMES = 180

local function drop_rigs(reason, rescan_after)
    if #C.rigs > 0 or #C.pending_zero > 0 then log("released rigs: %s", reason) end
    C.rigs, C.parts, C.instances, C.pending_zero = {}, {}, {}, {}
    Sculpt.clear_targets()
    Cnd.reset()
    Scene.no_targets = {}
    Guard.release_refs()
    if rescan_after then
        C.scan_at = { C.frame + rescan_after }
    end
end

-- bone signals among a list of signal ids (Profile.BONE_BASE and up)
local function bone_sigs(ids)
    local out = {}
    for _, p in ipairs(ids) do
        local sig = p >= Profile.BONE_BASE and Profile.signals.by_param[p]
        if sig then out[#out + 1] = sig end
    end
    return out
end

-- fcParam joints / bone signals / eye use per rig, limited to the channels its meshes actually have
local function refresh_rig_params()
    local prog = C.prog
    if not prog then return end
    for _, rig in ipairs(C.rigs) do
        local slots = {}
        for _, t in ipairs(rig.targets) do for k = 1, t.count do slots[t.slots[k]] = true end end
        local params, eyes = Profile.needs(prog, slots)
        rig.params = Scene.joints(rig.face, params)
        rig.bones = Scene.bone_reads(rig.face, bone_sigs(params))
        rig.use_eyes = eyes
        if rig.primary then
            local union, seen = {}, {}
            for _, list in ipairs({ C.dict_params, params }) do
                for _, p in ipairs(list) do if not seen[p] then seen[p] = true; union[#union + 1] = p end end
            end
            rig.dict_params = Scene.joints(rig.face, union)
            rig.dict_bones = Scene.bone_reads(rig.face, bone_sigs(union))
        end
        rig.n_reads = #rig.params / 2 + #rig.bones.list + (eyes and 2 or 0)
    end
end

local function queue_zero_all()
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do C.pending_zero[#C.pending_zero + 1] = t end
    end
end

-- sculpt + expression targets of ready meshes back to 0 (disable / script reset)
local function zero_sculpt() pcall(Sculpt.zero_all) end

-- effective gain per slot
local function recompute_gains()
    local prog = C.prog
    if not prog then return end
    local e = cfg.expression
    for s, c in ipairs(prog.channels) do
        local g = tonumber(e.channel_gains[c.name]) or 1.0
        if c.group == "gaze" or c.is_eye then
            local on = (c.gaze_set == nil) or cfg.eyes.sets[c.gaze_set] ~= false
            g = g * e.gaze_gain * (on and 1 or 0)
        else
            local r = X.REGION_OF[c.group]
            g = g * e.master_gain * (r and (e.region_gains[r] or 1) or 1)
        end
        C.gains[s] = g
    end
end

-- ---------------------------------------------------------------- state builders
local function build_settings_state()
    local st = state.settings
    for _, k in ipairs({ "hotkey", "ui_scale", "language", "scene_search_always", "periodic_scan_sec",
                         "write_epsilon", "clamp", "cutscene_drive", "sculpt_max", "face_style" }) do st[k] = cfg[k] end
    st.window = U.copy(cfg.window)
    state.runtime.enabled = cfg.enabled
    state.runtime.advanced = cfg.advanced
    bump("settings"); bump("runtime")
end

local function build_eyes_state()
    local e = state.eyes
    e.full_deg = U.copy(cfg.eyes.full_deg)
    e.invert = U.copy(cfg.eyes.invert)
    e.neutral = U.copy(cfg.eyes.neutral)
    e.sets = U.copy(cfg.eyes.sets)
    bump("eyes")
end

local build_preview_state   -- defined below
local function build_expression_state()
    local prog = C.prog
    local ex = state.expression
    local eg = cfg.expression
    ex.master_gain, ex.gaze_gain, ex.smoothing = eg.master_gain, eg.gaze_gain, eg.smoothing
    if not prog then ex.channels, ex.regions, ex.groups = {}, {}, {}; bump("expression"); return end
    ex.profile = { id = prog.id, name = prog.name, name_en = prog.name_en, source = prog.source, extends = prog.extends }
    local present = C.mesh_name_of or {}
    local channels = {}
    local by_group = {}
    for s, c in ipairs(prog.channels) do
        channels[s] = {
            slot = s, name = present[s] or c.name, canonical = c.name, group = c.group,
            source_text = c.source_text, has_signal = c.has_signal, guessed = c.guessed,
            extension = c.extension, gaze_set = c.gaze_set, note = c.note, note_en = c.note_en, edited = c.edited,
            gain = tonumber(eg.channel_gains[c.name]) or 1.0,
            forced = C.forced[s] == true, present = present[s] ~= nil,
            owner = "expression",
        }
        by_group[c.group] = by_group[c.group] or {}
        table.insert(by_group[c.group], s)
    end
    ex.channels = channels
    local regions = {}
    for i, r in ipairs(X.REGIONS) do
        local slots = {}
        for _, g in ipairs(X.GROUPS) do
            if g.region == r.key then for _, s in ipairs(by_group[g.key] or {}) do slots[#slots + 1] = s end end
        end
        regions[i] = { key = r.key, name = r.name, name_en = r.name_en, gain = eg.region_gains[r.key] or 1.0, channel_slots = slots }
    end
    ex.regions = regions
    local groups = {}
    local known = {}
    for _, g in ipairs(X.GROUPS) do
        known[g.key] = true
        if by_group[g.key] then
            groups[#groups + 1] = { key = g.key, name = g.name, name_en = g.name_en, region = g.region, channel_slots = by_group[g.key] }
        end
    end
    for key, slots in pairs(by_group) do
        if not known[key] then groups[#groups + 1] = { key = key, name = key, channel_slots = slots } end
    end
    ex.groups = groups
    bump("expression")
    if C.preview_profile then build_preview_state() end
end

-- read-only view of a profile that is not in effect (表情详情: choosing in the list shows it
-- before 应用). Channels matched against the worn parts' mesh names like apply_profile does.
function build_preview_state()
    local ex = state.expression
    local id = C.preview_profile
    if not id or (C.prog and C.prog.id == id) then
        if ex.preview ~= nil then ex.preview = nil; bump("expression") end
        C.preview_profile = nil
        return
    end
    local resolved = Profile.resolve(id)
    local prog = resolved and Profile.compile(resolved, {})
    if not prog then ex.preview = nil; C.preview_profile = nil; bump("expression"); return end
    local names = {}
    for i, c in ipairs(prog.channels) do names[i] = c.name end
    local idx = Names.build_index(names, resolved.aliases, resolved.channels)
    local present = {}
    for _, p in ipairs(C.parts or {}) do
        local ok, sel = pcall(Names.match_part, idx, p.names or {})
        if ok then
            for i, slot in ipairs(sel) do
                if slot and not present[slot] then present[slot] = p.names[i] end
            end
        end
    end
    local channels, by_group, hit = {}, {}, 0
    for sl, c in ipairs(prog.channels) do
        if present[sl] then hit = hit + 1 end
        channels[sl] = { slot = sl, name = present[sl] or c.name, canonical = c.name, group = c.group,
                         source_text = c.source_text, has_signal = c.has_signal, guessed = c.guessed,
                         extension = c.extension, note = c.note, note_en = c.note_en, present = present[sl] ~= nil }
        by_group[c.group] = by_group[c.group] or {}
        table.insert(by_group[c.group], sl)
    end
    local groups, known = {}, {}
    for _, g in ipairs(X.GROUPS) do
        known[g.key] = true
        if by_group[g.key] then groups[#groups + 1] = { key = g.key, name = g.name, name_en = g.name_en, channel_slots = by_group[g.key] } end
    end
    for key, slots in pairs(by_group) do
        if not known[key] then groups[#groups + 1] = { key = key, name = key, channel_slots = slots } end
    end
    ex.preview = { id = prog.id, name = prog.name, name_en = prog.name_en, source = prog.source, extends = prog.extends,
                   channels = channels, groups = groups, present = hit, total = prog.n }
    bump("expression")
end

local function build_mapping_state()
    local m = state.mapping
    local sigs = {}
    for i, s in ipairs(Profile.signals.list) do
        sigs[i] = { slot = s.slot, name = s.name, param = s.param, bone = s.bone, guessed = s.guessed, note = s.note, note_en = s.note_en }
    end
    m.signals = sigs
    local nodes, edited = {}, {}
    if C.prog then
        for _, c in ipairs(C.prog.channels) do
            nodes[c.name] = U.copy(c.node)
            if c.edited then edited[c.name] = true end
        end
    end
    m.nodes, m.edited = nodes, edited
    bump("mapping")
end

local function sculpt_entry_state(e)
    return { id = e.id, name = e.name, source = e.source, folder = e.folder, target_part = e.target_part }
end

-- readable name of a model ("ch03_032_501" -> "护锁刃龙 α/β", "Guardian Seregios α/β"),
-- builtin/armor_names.json (generated from Modding-Toolkit's mhws_armor_sets.json). Returns zh, en;
-- nil when unknown
local armor_names = nil
local function armor_name(model)
    if armor_names == nil then
        local d = U.load_json(U.path("builtin", "armor_names.json"))
        armor_names = d and type(d.models) == "table" and d.models or false
    end
    local e = armor_names and model and armor_names[model]
    if not e then return nil end
    return e.zh or e.en, e.en or e.zh
end

-- where "绑定到" writes: the binding in effect (its file base) or, without one, a model-wide
-- binding for the part with the most channels. Returns base, model, display name, data to start
-- from, English display name (a binding file's own `name` is shown as it is in both languages)
local function bind_target()
    local b = C.binding
    if b and b.base and b.base ~= "default" and b.data then
        local model = Presets.model_of(b.base) or b.base
        local zh, en = armor_name(model)
        if b.data.name then zh, en = b.data.name, b.data.name end
        return b.base, model, zh or model, U.copy(b.data), en or model
    end
    local best
    for _, p in ipairs(C.parts) do if not best or (p.n or 0) > (best.n or 0) then best = p end end
    if not best then return nil end
    local model = Presets.model_of(best.id) or best.id
    local zh, en = armor_name(model)
    return Presets.representative_of(best.id) or best.id, model, zh or model, { global = true }, en or model
end

local function build_presets_state()
    local list = {}
    for _, e in ipairs(Profile.list) do
        list[#list + 1] = { id = e.id, name = e.name, name_en = e.name_en, source = e.source, extends = e.extends }
    end
    state.presets.expression = list
    local sc = {}
    for _, e in ipairs(Presets.sculpt_list) do sc[#sc + 1] = sculpt_entry_state(e) end
    state.presets.sculpt = sc
    local b = C.binding
    if b then
        local d = b.data or {}
        local prof_entry = d.profile and Profile.registry[d.profile]
        local fp_ok = true
        local sp = d.sculpt and Presets.find_sculpt(d.sculpt, b.folder)
        if sp and sp.channel_hash then
            fp_ok = false
            for _, part in ipairs(C.parts) do if part.fingerprint == sp.channel_hash then fp_ok = true end end
        end
        state.presets.binding = {
            part = b.part, chain = b.chain, hit = b.hit, source = b.source, level = b.level,
            base = b.base, folder = b.folder,
            expression = prof_entry and prof_entry.name or d.profile,
            expression_en = prof_entry and (prof_entry.name_en or prof_entry.name) or d.profile,
            sculpt = d.sculpt, sculpt_found = sp ~= nil, fingerprint_ok = fp_ok,
            profile_id = d.profile, conditions = d.conditions,
        }
    else
        state.presets.binding = nil
    end
    -- "当前绑定": the name shown in the panel and where 绑定到 writes
    local base, model, display, _, display_en = bind_target()
    -- active: this outfit has its own binding in effect; global_default: only default.json applies
    local gd = C.binding ~= nil and C.binding.base == "default"
    state.presets.bind = base and { base = base, model = model, display = display, display_en = display_en,
                                    active = C.binding ~= nil and C.binding.base == base,
                                    global_default = gd } or nil
    state.presets.pending_delete = C.pending_delete and U.copy(C.pending_delete) or nil
    bump("presets")
end

local function build_facial_state()
    local fs = state.facial
    local keys = {}
    for i, n in ipairs(Facial.list) do keys[i] = { name = n, value = Facial.value(n) } end
    fs.keys, fs.level = keys, Facial.level
    bump("facial")
end

local function build_sculpt_state()
    local sc = state.sculpt
    local keys, groups, gi = {}, {}, {}
    for _, k in ipairs(Sculpt.K.keys) do
      if not Facial.present[k.name] then   -- facial preset keys have their own page
        local i = #keys + 1
        local o = {}
        for p, v in pairs(k.overrides) do o[p] = v end
        keys[i] = { name = k.name, group = k.group, parts = U.copy(k.parts), value = k.value,
                    default = k.default, overrides = o, owner = k.owner,
                    locked = false, mixed = k.owner == "expression", in_preset = k.in_preset == true,
                    range = { Sculpt.RANGE[1], Sculpt.RANGE[2] } }
        local g = gi[k.group]
        if not g then
            g = { key = k.group, name = k.group, key_indices = {} }
            gi[k.group] = g; groups[#groups + 1] = g
        end
        g.key_indices[#g.key_indices + 1] = i
      end
    end
    sc.keys, sc.groups = keys, groups
    sc.edit_mode, sc.ab_preview = C.edit_mode, C.preview
    sc.dirty = Sculpt.is_dirty()
    sc.can_undo, sc.can_redo = Sculpt.can_undo(), Sculpt.can_redo()
    sc.preset = C.sculpt_preset and sculpt_entry_state(C.sculpt_preset) or nil
    bump("sculpt")
end

-- ---------------------------------------------------------------- bindings (M2)
-- The binding in effect: the most specific hit over all worn parts (a model-wide global preset,
-- then a part's own file, then the model's slot-2 file, then default.json), ties broken by
-- channel count. Its profile replaces cfg.profile while it is in effect.
local LEVEL_RANK = { global = 3, own = 2, model = 1, default = 0 }
local function resolve_bindings(parts)
    C.part_bindings = {}
    local best, best_rank, best_n = nil, -1, -1
    for _, p in ipairs(parts) do
        local r = C.part_bindings[p.id]
        if not r then
            r = Presets.resolve_binding(p.id, nil, p.fingerprint)
            C.part_bindings[p.id] = r
            for _, e in ipairs(r.chain) do
                local key = e.error and (p.id .. "|" .. e.path .. "|" .. e.error)
                if key and not C.warned[key] then
                    C.warned[key] = true
                    notice("warn", "notice.binding_error",
                        { p.id, e.path, e.error_key and { k = e.error_key } or e.error })
                end
            end
        end
        if r.hit then
            local rank = LEVEL_RANK[r.level] or 0
            if rank > best_rank or (rank == best_rank and (p.n or 0) > best_n) then
                best, best_rank, best_n = r, rank, p.n or 0
            end
        end
    end
    C.binding = best
end

-- ---------------------------------------------------------------- tuning (M2)
-- Expression gains and the gaze settings (full_deg / invert / sets) follow the part: while a
-- binding is in effect, cfg.expression / cfg.eyes hold that part's working copy (the binding's
-- values over the settings fallback) and edits are saved into the part's user binding by
-- save_tuning. Without a binding they are the global fallback in settings.json, as in M1.
-- Eye neutral calibration stays global (it belongs to the hunter's face rig, not to a mesh).
-- gains.for_profile: channel gains were tuned for that profile; another profile ignores them.
local EYE_TUNING = { "full_deg", "invert", "sets" }

local function eyes_subset(e)
    local t = {}
    for _, k in ipairs(EYE_TUNING) do t[k] = U.copy(e[k]) end
    return t
end

-- the values settings.json keeps (the fallback), whatever is loaded right now
local function fallback_tuning()
    if C.tuning.source == "settings" then return cfg.expression, eyes_subset(cfg.eyes) end
    return C.tuning.stash_expression, C.tuning.stash_eyes
end

local function binding_profile_mismatch(g)
    return type(g) == "table" and g.for_profile ~= nil and C.prog ~= nil and g.for_profile ~= C.prog.id
end

local function build_tuning_state()
    local t = C.tuning
    state.expression.tuning = { source = t.source, path = t.path, dirty = t.dirty == true,
                                profile_mismatch = t.mismatch == true, for_profile = t.for_profile }
end

-- (re)load the working copy for the binding in effect; force: reload even if the path is the same
local function apply_tuning(force)
    local b = C.binding
    local path = b and b.hit or nil
    local t = C.tuning
    -- reload only when the file, its tuning content or the profile changed: a periodic rescan
    -- must not throw away unsaved edits
    local sig = b and (U.signature(b.data and b.data.gains) .. "|" .. U.signature(b.data and b.data.eyes)) or nil
    if not force and path == t.path and sig == t.sig and (not b or t.prog_id == (C.prog and C.prog.id)) then return end
    t.sig = sig
    if t.source == "settings" then
        t.stash_expression = U.copy(cfg.expression)
        t.stash_eyes = eyes_subset(cfg.eyes)
    end
    local e = U.copy(t.stash_expression)
    local eyes = U.copy(t.stash_eyes)
    t.mismatch, t.for_profile = false, nil
    if b then
        local g = b.data and b.data.gains
        if type(g) == "table" then
            for _, k in ipairs({ "master_gain", "gaze_gain", "smoothing" }) do
                if type(g[k]) == "number" then e[k] = g[k] end
            end
            if type(g.region_gains) == "table" then for k, v in pairs(g.region_gains) do e.region_gains[k] = v end end
            t.for_profile = g.for_profile
            if binding_profile_mismatch(g) then
                t.mismatch = true
                e.channel_gains = {}
                -- shown on the expression page (tuning.profile_mismatch), no notice
            elseif type(g.channel_gains) == "table" then
                e.channel_gains = U.copy(g.channel_gains)
            end
        end
        local be = b.data and b.data.eyes
        if type(be) == "table" then
            for _, k in ipairs(EYE_TUNING) do
                if type(be[k]) == "table" then
                    for kk, v in pairs(be[k]) do eyes[k][kk] = v end
                end
            end
        end
        t.source = "binding"
    else
        t.source = "settings"
    end
    t.path, t.prog_id, t.dirty = path, C.prog and C.prog.id, false
    e.channel_gains = e.channel_gains or {}
    cfg.expression = e
    for _, k in ipairs(EYE_TUNING) do cfg.eyes[k] = eyes[k] end
    recompute_gains()
    build_expression_state(); build_eyes_state(); build_tuning_state()
    if path then log("tuning from %s", path) end
end

-- an edit of gains / gaze: per part while a binding is in effect, else straight to settings
local function tuning_changed()
    if C.tuning.source == "binding" then
        C.tuning.dirty = true
        build_tuning_state()
    else
        save_soon()
    end
end

local function current_gains()
    local e = cfg.expression
    local g = { master_gain = e.master_gain, gaze_gain = e.gaze_gain, smoothing = e.smoothing,
                region_gains = U.copy(e.region_gains), channel_gains = U.copy(e.channel_gains or {}),
                for_profile = C.prog and C.prog.id or nil }
    if C.tuning.mismatch then
        -- channel gains of the stored binding are kept untouched for their own profile
        local stored = C.binding and C.binding.data and C.binding.data.gains
        g.channel_gains = stored and U.copy(stored.channel_gains or {}) or {}
        g.for_profile = stored and stored.for_profile or g.for_profile
    end
    return g
end

-- ---------------------------------------------------------------- sculpt presets (M2)
local function fingerprint_of(part_id)
    for _, p in ipairs(C.parts) do if p.id == part_id then return p.fingerprint end end
end

-- active: the preset the part's binding names; mod: the one its mods-only chain names (defaults).
-- Names are looked up in the binding's model folder first, then among the general presets.
local function sculpt_presets_of(part_id)
    local r = C.part_bindings[part_id]
    local active = r and r.data and r.data.sculpt and Presets.find_sculpt(r.data.sculpt, r.folder) or nil
    local m = Presets.resolve_binding(part_id, "mods", fingerprint_of(part_id))
    local mod = m.data and m.data.sculpt and Presets.find_sculpt(m.data.sculpt, m.folder, "mods") or nil
    return active, mod
end

local link_base_keys   -- defined with the expression writer below

local function rebuild_sculpt()
    local owned = {}
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do
            local o = owned[t.mesh] or {}
            for k = 1, t.count do o[t.idxs[k]] = true end
            owned[t.mesh] = o
        end
    end
    Sculpt.rebuild(C.instances or C.parts, owned, sculpt_presets_of)
    local names = {}
    for i, k in ipairs(Sculpt.K.keys) do names[i] = k.name end
    Facial.set_present(names)
    build_facial_state()
    link_base_keys()
    C.update_touch_map()
    -- the preset shown as "current": the one loaded by hand (until the worn parts change), else
    -- the binding's
    local b = C.binding
    local ids_sig = {}
    for _, p in ipairs(C.parts) do ids_sig[#ids_sig + 1] = p.id .. ":" .. tostring(p.fingerprint) end
    ids_sig = table.concat(ids_sig, "|")
    if ids_sig ~= C.sculpt_parts_sig then C.sculpt_parts_sig, C.sculpt_preset_manual = ids_sig, false end
    if not C.sculpt_preset_manual then
        C.sculpt_preset = b and b.data and b.data.sculpt and Presets.find_sculpt(b.data.sculpt, b.folder) or nil
    end
    local sc = state.sculpt
    local ids = {}
    for _, p in ipairs(C.parts) do ids[#ids + 1] = p.id end
    local expr = 0
    for _, k in ipairs(Sculpt.K.keys) do if k.owner == "expression" then expr = expr + 1 end end
    sc.scan = { time = os.time(), parts = ids, keys = #Sculpt.K.keys, expression_keys = expr }
    build_sculpt_state()
end

-- ---------------------------------------------------------------- profile
local function apply_profile(id, keep_targets)
    local resolved, code, msg = Profile.resolve(id)
    if not resolved then return false, code, msg end
    local prog, code2, msg2 = Profile.compile(resolved, {})
    if not prog then return false, code2, msg2 end
    if not keep_targets then queue_zero_all() end
    C.resolved, C.prog, C.edits = resolved, prog, {}
    local names = {}
    for i, c in ipairs(prog.channels) do names[i] = c.name end
    C.index = Names.build_index(names, resolved.aliases, resolved.channels)
    C.forced = {}
    C.cov_key = nil
    if legacy_gains then
        local by_norm = {}
        for k, v in pairs(legacy_gains) do by_norm[U.norm(k)] = v end
        for _, c in ipairs(prog.channels) do
            local g = by_norm[U.norm(c.name)]
            if g and g ~= 1 then cfg.expression.channel_gains[c.name] = g end
        end
        legacy_gains = nil
        save_soon()
    end
    recompute_gains()
    -- per-part channel gains depend on the profile they were tuned for
    if C.binding then apply_tuning(true) end
    build_expression_state(); build_mapping_state()
    if not keep_targets then request_rescan(1) end
    log("profile: %s (%s, %d channels)", prog.name, prog.source, prog.n)
    return true
end

local function recompile(edits)
    local prog, code, msg = Profile.compile(C.resolved, edits)
    if not prog then return false, code, msg end
    C.prog, C.edits = prog, edits
    refresh_rig_params()   -- an edited node may read other fcParams
    recompute_gains()
    build_expression_state(); build_mapping_state()
    return true
end

-- ---------------------------------------------------------------- scan
local function update_coverage(parts)
    local fps = {}
    for _, p in ipairs(parts) do fps[#fps + 1] = p.id .. ":" .. p.fingerprint end
    table.sort(fps)
    local key = table.concat(fps, "|") .. "#" .. (C.prog and C.prog.id or "")
    if key == C.cov_key then return end
    C.cov_key = key
    local all, ark = {}, {}
    local arkit_hit = 0
    for _, p in ipairs(parts) do
        for _, cn in ipairs(p.names) do
            all[#all + 1] = cn
            local a = Names.arkit_of(cn)
            if a and not ark[a] then ark[a] = true; arkit_hit = arkit_hit + 1 end
        end
    end
    local present = C.mesh_name_of or {}
    local extra = 0
    if C.prog then
        for s, c in ipairs(C.prog.channels) do
            if present[s] and not Names.ARKIT_BY_NORM[U.norm(c.name)] then extra = extra + 1 end
        end
    end
    local best, best_n = C.prog and C.prog.id, -1
    for _, e in ipairs(Profile.list) do
        local n = Profile.match_count(e.id, all, Names)
        if n > best_n or (n == best_n and C.prog and e.id == C.prog.id) then best, best_n = e.id, n end
    end
    state.expression.coverage = { arkit_hit = arkit_hit, arkit_total = #Names.ARKIT52, extra = extra,
                                  recommended = (#parts > 0) and best or nil, recommended_hits = best_n }
end

local function do_scan()
    if not C.prog then return end
    local res = Scene.scan({ index = C.index, scene_search = C.gc_open or C.menu or cfg.scene_search_always or C.cs_scene_search, min_hits = 3 })
    -- the same mesh found again keeps its warm-up count and last written values, so periodic
    -- rescans neither pause writing nor rewrite every channel
    local old = {}
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do if t.addr then old[t.addr] = t end end
    end
    for _, r in ipairs(res.rigs) do
        for _, t in ipairs(r.targets) do
            local o = t.addr and old[t.addr]
            if o then
                t.stable, t.ready = o.stable, o.ready
                if o.count == t.count then t.last = o.last end
            end
        end
    end
    old = nil
    C.rigs, C.parts, C.sig, C.mesh_name_of = res.rigs, res.parts, res.sig, res.mesh_name_of
    C.instances = res.instances or res.parts
    refresh_rig_params()
    -- menus spawn their preview hunters late: look again every 3 s there
    C.next_periodic = C.frame + (C.menu and MENU_SCAN_FRAMES or max(1, cfg.periodic_scan_sec) * 60)
    prof.scan = prof.scan + res.ms / 1000
    local sc = state.scene
    sc.last_scan = { time = os.time(), ms = res.ms, faces = res.faces, cached_skip = res.skipped, guild_card = C.gc_open }
    local rigs = {}
    for i, r in ipairs(res.rigs) do
        local ts = {}
        for j, t in ipairs(r.targets) do ts[j] = { name = t.name, channels = t.distinct, writes = t.count } end
        rigs[i] = { label = r.label, primary = r.primary, targets = ts, reads = r.n_reads }
    end
    sc.rigs = rigs
    resolve_bindings(res.parts)
    local parts = {}
    for i, p in ipairs(res.parts) do
        local r = C.part_bindings[p.id]
        parts[i] = { id = p.id, slot = nil, channels = p.n, fingerprint = p.fingerprint, binding = r and r.hit or nil }
    end
    sc.parts = parts
    update_coverage(res.parts)
    -- a parent preset picks the expression profile while its part is worn
    local b = C.binding
    local want = b and b.data and b.data.profile
    local man = C.profile_manual
    if man and man.hit ~= (b and b.hit or nil) then C.profile_manual, man = nil, nil end   -- other parts / preset
    if man and want and Profile.registry[man.id] then want = nil end                     -- the user's choice stands
    if want and not Profile.registry[want] then
        if C.missing_profile ~= want then
            C.missing_profile = want
            notice("warn", "notice.missing_profile", { tostring(b.hit), want })
        end
        want = nil
    end
    state.expression.binding_source = want and b.hit or nil
    if want and want ~= C.prog.id then
        if apply_profile(want, false) then
            C.profile_from_binding = true
            log("profile %s from %s", want, b.hit)
            return
        end
    elseif not want and C.profile_from_binding and C.prog.id ~= cfg.profile and Profile.registry[cfg.profile] then
        C.profile_from_binding = false
        if apply_profile(cfg.profile, false) then return end
    end
    if want then C.profile_from_binding = true end
    apply_tuning(false)
    C.select_conditions()
    rebuild_sculpt()
    build_presets_state()
    -- the current profile drives nothing on these parts but another one would: switch. Only
    -- without a parent preset that names a profile.
    local cov = state.expression.coverage
    if not want and #res.rigs == 0 and cov and cov.recommended and cov.recommended ~= C.prog.id and (cov.recommended_hits or 0) >= 3 then
        local from = pair(C.prog.name, C.prog.name_en)
        if apply_profile(cov.recommended, false) then
            cfg.profile = cov.recommended; save_soon()
            notice("info", "notice.auto_switched", { from, pair(C.prog.name, C.prog.name_en) })
            return
        end
    end
    bump("scene")
    build_expression_state()
    local tn = {}
    for _, r in ipairs(rigs) do
        local t = {}
        for _, x in ipairs(r.targets) do t[#t + 1] = x.name .. ":" .. x.channels end
        tn[#tn + 1] = (r.primary and "*" or "") .. r.label .. "[" .. table.concat(t, ",") .. "]"
    end
    state.debug.status = string.format("faces=%d (cached-skip %d)%s%s driven=%s  hunters=%s  scan %.2f ms", res.faces, res.skipped,
        C.gc_open and " [guild card]" or "", C.menu and " [menu]" or "", #tn > 0 and table.concat(tn, "  ") or "none",
        (res.parents and #res.parents > 0) and table.concat(res.parents, " ") or "none", res.ms)
    -- the master hunter's parts, when they change (kevin, 2026-10-13: once the body vanished after
    -- a gear switch and never came back; this shows whether the part was there at all)
    if res.sig ~= C.parts_logged then
        C.parts_logged = res.sig
        Trail.event("master parts: %s", res.sig ~= "" and (res.sig:gsub("|", " ")) or "none")
    end
    Trail.event("scan: %s", state.debug.status)
    C.fire("scan")
end

-- ---------------------------------------------------------------- per frame
local function prof_flush()
    local n = prof.frames
    if n < prof.window then return end
    local a = state.debug.perf
    a.read, a.compute, a.write, a.scan = prof.read / n * 1000, prof.compute / n * 1000, prof.write / n * 1000, prof.scan / n * 1000
    a.total = a.read + a.compute + a.write + a.scan
    a.writes, a.skipped = prof.writes / n, prof.skipped / n
    prof.read, prof.compute, prof.write, prof.scan, prof.writes, prof.skipped, prof.frames = 0, 0, 0, 0, 0, 0, 0
end

-- rest values (sculpt) of the expression channels of a target, refreshed when sculpt changes
local function refresh_base(t)
    local base, any = t.base or {}, false
    for k = 1, t.count do
        local key = t.base_keys[k]
        local b = key and Sculpt.base_value(key, t.name, C.preview) or 0
        base[k] = b
        if b > 0 then any = true end
    end
    t.base = any and base or nil
    t.base_ver = Sculpt.version
end

-- after a sculpt rebuild: which sculpt key each expression channel belongs to
function link_base_keys()
    local names_of = {}
    for _, p in ipairs(C.instances or C.parts) do names_of[p.mesh] = p.names end
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do
            local names = names_of[t.mesh]
            local keys = {}
            if names then
                for k = 1, t.count do
                    local cn = names[t.idxs[k] + 1]
                    keys[k] = cn and Sculpt.K.by_name[Sculpt.key_of(cn)] or false
                end
            end
            t.base_keys, t.base_ver = keys, nil
        end
    end
end

local function drive(rig, primary)
    local prog = C.prog
    local t0 = clock()
    local P = primary and C.P or C.Pbuf
    X.read(rig, P, C.inv_full, primary and C.want_signals and state.runtime.ui_open, cfg.eyes, rig.use_eyes)
    -- panel gaze drag: both eyes look at the held angle instead of following the game
    local gh = C.gaze_hold
    if gh then
        if C.frame > gh.until_frame then
            C.gaze_hold = nil
        elseif rig.use_eyes then
            local a = rig.angles
            a.L[1], a.L[2], a.R[1], a.R[2] = gh.yaw, gh.pitch, gh.yaw, gh.pitch
        end
    end
    local t1 = clock()
    local s = cfg.expression.smoothing
    local alpha = (s > 0) and (1 - min(s, 1) * 0.9) or 1
    X.compute(prog, rig, P, C.gains, C.forced, cfg.clamp, alpha, cfg.eyes.full_deg.yaw, cfg.eyes.full_deg.pitch)
    -- conditional clips and other plugins change a copy of the expression weights: rig.W is also
    -- the smoothing state of the next frame and must stay the pure expression
    local out, ext_skip = rig.W, nil
    local cond_on = rig.primary and C.cond_live and CondExpr.any()
    local touch_on = Touch.any()
    -- a facial preset fades the driven face (gaze excepted), after the clips, before other plugins
    local facial_on = Facial.any()
    if cond_on or touch_on or facial_on or Ext.any() then
        out = rig.O or {}
        rig.O = out
        local Wt = rig.W
        for s = 1, prog.n do out[s] = Wt[s] end
        if cond_on then CondExpr.apply(prog, C.resolve_slot, out) end
        if touch_on then Touch.apply(prog, C.resolve_slot, out) end
        if facial_on then Facial.fade(prog, out) end
        if Ext.any() then ext_skip = Ext.apply(prog, C.resolve_slot, out) end
    end
    local t2 = clock()
    local eps = cfg.write_epsilon
    local bad
    for _, t in ipairs(rig.targets) do
        if t.stable >= Guard.STABLE_FRAMES then
            if Guard.mesh_still_ready(t.mesh) then
                if t.base_keys and t.base_ver ~= Sculpt.version then refresh_base(t) end
                local w, sk = Writer.write_target(t, out, false, eps, t.base, Sculpt.mix, ext_skip)
                prof.writes, prof.skipped = prof.writes + w, prof.skipped + sk
            else
                bad = "mesh no longer ready: " .. t.name
                break
            end
        elseif Guard.mesh_ready(t.mesh) then
            t.stable = t.stable + 1
            if t.stable == Guard.STABLE_FRAMES then Trail.event("start writing %s on %s", t.name, rig.label) end
        else
            if t.stable > 0 then Trail.event("warm-up reset %s on %s", t.name, rig.label) end
            t.stable = 0
        end
    end
    local t3 = clock()
    prof.read, prof.compute, prof.write = prof.read + (t1 - t0), prof.compute + (t2 - t1), prof.write + (t3 - t2)
    return bad
end

local function update_live()
    local prog = C.prog
    local rig = C.rigs[1]
    local lw = live.weight
    if rig then
        local W = rig.W
        for s = 1, prog.n do lw[s] = W[s] or 0 end
        local a, la = rig.angles, live.eye_angle
        la.L.yaw, la.L.pitch, la.R.yaw, la.R.pitch = a.L[1], a.L[2], a.R[1], a.R[2]
    else
        for s = 1, prog.n do lw[s] = 0 end
    end
    for s = prog.n + 1, #lw do lw[s] = nil end
    if state.runtime.ui_open then
        local ra = live.region_activity
        for i, r in ipairs(state.expression.regions) do
            local m = 0
            for _, s in ipairs(r.channel_slots) do local w = lw[s]; if w > m then m = w end end
            ra[i] = m
        end
        if C.want_signals then
            local sig = live.signal
            for i, sd in ipairs(Profile.signals.list) do sig[i] = C.P[sd.param] or 0 end
        end
    end
end

-- ---------------------------------------------------------------- experimental cutscene mode
-- While a cutscene plays (IsBusy, not IsBusyLoad) and cfg.cutscene_drive is on, the hunter is
-- driven like in gameplay. Segment boundaries come from app.DemoMediator hooks (Guard):
--   onPlayStartTimeline(i)            a segment starts: drop everything, settle, search the whole
--                                     scene (the visible hunter is often the cutscene copy Pl000_00)
--   requestSkip / requestStop / unload  drop everything at once (pre-hook, before the game tears
--                                     the actors down) and stay off until the next segment starts
-- The timeline length is not used: one timeline can span several segments and some CGs have none.
local CS = { active = false, released = false, released_at = nil, seg_t0 = nil, seg = nil, scanned = false, status = "" }
-- after a skip / stop the next segment does not always report onPlayStartTimeline (multi-part
-- CGs keep IsBusy true straight through): re-arm once the cutscene is still playing this long
-- after the last release hook
local CS_REARM_FRAMES = 90

local function zero_ready_targets(why)
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do
            if t.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(t.mesh) then
                Writer.zero_target(t)
                Trail.event("zeroed %s on %s (%s)", t.name, r.label, tostring(why))
            end
        end
    end
end

-- a non-primary rig (guild card / save select / cutscene hunter) whose parent's children changed:
-- its parts are being rebuilt or torn down
local function parents_changed()
    for _, r in ipairs(C.rigs) do
        if not r.primary and r.parent then
            local ok, sig = pcall(Scene.children_signature, r.parent)
            if not ok or sig ~= r.psig then return true end
        end
    end
    return false
end

local function cs_end()
    if not CS.active then return end
    CS.active, CS.seg_t0, CS.scanned = false, nil, false
    C.cs_scene_search = false
end

-- true when the experimental mode may drive on this frame
local function cutscene_gate(f)
    if not CS.active then
        CS.active = true
        C.cs_scene_search = true
        -- no segment hook seen recently: treat the start of playback as the segment start
        if not CS.seg_t0 or f - CS.seg_t0 > 600 then
            CS.seg_t0, CS.released, CS.scanned = f, false, false
            drop_rigs("cutscene started", nil)
            C.scan_at = {}
        end
    end
    if CS.released then
        if not CS.released_at or f - CS.released_at < CS_REARM_FRAMES then return false end
        Trail.event("cutscene still playing %d frames after release: re-arm", f - CS.released_at)
        CS.seg, CS.seg_t0, CS.released, CS.scanned = "?", f, false, false
        drop_rigs("cutscene re-arm", nil)
        C.scan_at = {}
    end
    if f - CS.seg_t0 < Guard.SETTLE_FRAMES then CS.status = "segment settling"; return false end
    if not CS.scanned then
        CS.scanned = true
        C.scan_at = { f }
    end
    CS.status = string.format("driving segment %s", tostring(CS.seg or "?"))
    return true
end

function SKS.tick()
    C.frame = C.frame + 1
    local f = C.frame
    if Ext.expire() then Sculpt.mark_dirty(); C.build_external_state() end
    Sculpt.frame = f
    local stable, why, kind = Guard.game_stable(f)
    if not stable and C.cond_live ~= false then
        C.cond_live = false
        CondExpr.reset(); Cnd.reset(); Touch.reset()
    end
    Trail.frame = f
    local gate_now = stable and "stable" or why
    if gate_now ~= C.last_gate then
        Trail.event("gate: %s -> %s", tostring(C.last_gate), gate_now)
        C.last_gate = gate_now
    end
    local prev_kind = C.prev_kind
    C.prev_kind = (not stable) and kind or nil
    local menu = (not stable) and kind == "setup"
    if not stable and kind == "playing" and cfg.cutscene_drive then
        -- a load finished: a new segment starts, whatever the hooks said before
        if prev_kind == "load" and CS.active then
            Trail.event("cutscene load -> playing: new segment")
            CS.seg, CS.seg_t0, CS.released, CS.scanned = "?", f, false, false
            drop_rigs("cutscene loaded", nil)
            C.scan_at = {}
        end
        local go = cutscene_gate(f)
        state.debug.status = "cutscene: " .. CS.status
        if not go then
            prof.frames = prof.frames + 1
            prof_flush()
            return
        end
    elseif not stable and not menu then
        -- after cutscene driving the hunter is about to be rebuilt: only let go, never write
        local was_cs = CS.active and not CS.released
        cs_end()
        if C.paused ~= why then
            C.paused = why
            if not was_cs then zero_ready_targets(why) end
            drop_rigs(why, nil)
            C.scan_at = {}
            state.debug.status = "paused: " .. why
        end
        prof.frames = prof.frames + 1
        prof_flush()
        return
    elseif CS.active then
        cs_end()
        drop_rigs("cutscene over", Guard.SETTLE_FRAMES)
    end
    -- menu mode (player not set up: title screen, save select, loading) drives whatever hunters
    -- the scene holds; entering or leaving it lets go of everything (the player is being built)
    if menu ~= C.menu then
        C.menu = menu
        Trail.event(menu and "menu mode on" or "menu mode off")
        drop_rigs(menu and "menu mode" or "player set up", nil)
        C.scan_at = {}
        if not C.paused then request_rescan(Guard.SETTLE_FRAMES) end
    end
    local ev = C.menu_event
    if ev then
        C.menu_event = nil
        if ev ~= C.last_menu_event then
            C.last_menu_event = ev
            Trail.event("hook %s (rigs %d)", ev, #C.rigs)
            drop_rigs("menu " .. ev, nil)
            C.scan_at = {}
            request_rescan(Guard.SETTLE_FRAMES, 60, 120, 240)
        end
    end
    if C.paused then
        C.paused = nil
        request_rescan(Guard.SETTLE_FRAMES)
        state.debug.status = "resuming"
    end
    if #C.pending_zero > 0 then
        for _, t in ipairs(C.pending_zero) do
            if t.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(t.mesh) then Writer.zero_target(t) end
        end
        C.pending_zero = {}
    end
    -- parts changed (load screen, equipment): stop touching the old meshes at once
    local now_sig = (f % 5 == 0 and #C.rigs > 0) and Scene.children_signature(Scene.master_root()) or nil
    if now_sig and now_sig ~= C.sig then
        drop_rigs("hunter parts changed (" .. Scene.signature_diff(C.sig, now_sig) .. ")", Guard.SETTLE_FRAMES)
    elseif f % 30 == 15 and #C.rigs > 0 and parents_changed() then
        drop_rigs("preview hunter changed", Guard.SETTLE_FRAMES)
    elseif f % 30 == 0 and #C.rigs == 0 and #C.scan_at == 0 and Scene.children_signature(Scene.master_root()) ~= C.sig then
        request_rescan(Guard.SETTLE_FRAMES)
    end
    local due = false
    for i = #C.scan_at, 1, -1 do
        if f >= C.scan_at[i] then due = true; table.remove(C.scan_at, i) end
    end
    if due or ((C.menu or cfg.periodic_scan_sec > 0) and f >= C.next_periodic) then do_scan() end
    if C.probe_pending then
        C.probe_pending = false
        state.debug.probe = Probe.run("ShapeKeySystem\\hash_probe.txt")
        bump("debug")
    end

    -- conditional expressions: master hunter in gameplay only
    C.cond_live = not C.menu and (CondExpr.current ~= nil or state.runtime.ui_open)
    if C.cond_live then Cnd.sample(f) end
    if CondExpr.update(C.cond_live and CondExpr.current ~= nil) then Sculpt.mark_dirty() end
    if Touch.update() then Sculpt.mark_dirty() end
    if state.runtime.ui_open then C.update_cond_live() end
    if cfg.enabled and C.prog then
        for i, rig in ipairs(C.rigs) do
            local ok, err = pcall(drive, rig, i == 1)
            if not ok or err then
                drop_rigs(string.format("%s: %s", rig.label, tostring(err)), Guard.SETTLE_FRAMES)
                break
            end
        end
        update_live()
    end
    -- sculpt layer: lazy static weights on the channels the profile does not drive
    if cfg.enabled and #Sculpt.K.targets > 0 then
        local t0 = clock()
        local ok, w, err = pcall(Sculpt.tick, C.edit_mode, C.preview, cfg.write_epsilon)
        if not ok or err then
            drop_rigs("sculpt: " .. tostring(ok and err or w), Guard.SETTLE_FRAMES)
        else
            prof.writes = prof.writes + w
        end
        prof.write = prof.write + (clock() - t0)
    end
    prof.frames = prof.frames + 1
    prof_flush()
    if C.save_at and f >= C.save_at then save_now() end
end

-- ---------------------------------------------------------------- commands
local cmds = {}

local function num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return U.clamp(v, lo, hi)
end

local function slot_of(name)
    return C.prog and type(name) == "string" and C.prog.slot_of[name] or nil
end

-- general
function cmds.set_enabled(a)
    if type(a.on) ~= "boolean" then return false, "E_BAD_ARGS", "on must be boolean" end
    cfg.enabled = a.on
    if not a.on then queue_zero_all(); zero_sculpt() else Sculpt.mark_dirty(); request_rescan(1) end
    build_settings_state(); save_soon()
    return true
end

local SETTING_TYPES = {
    hotkey = "string", language = "string", ui_scale = { 0.5, 3 },
    scene_search_always = "boolean", periodic_scan_sec = { 0, 120 }, write_epsilon = { 0, 0.05 },
    clamp = "boolean", window = "table", advanced = "boolean",
    cutscene_drive = "boolean", sculpt_max = { 1, Sculpt.MAX_LIMIT }, face_style = "string",
}
function cmds.set_setting(a)
    local t = SETTING_TYPES[a.key]
    if not t then return false, "E_BAD_ARGS", "unknown setting: " .. tostring(a.key) end
    local v = a.value
    if type(t) == "table" then
        v = num(v, t[1], t[2]); if not v then return false, "E_BAD_ARGS", "number expected" end
    elseif type(v) ~= t then
        return false, "E_BAD_ARGS", t .. " expected"
    end
    if a.key == "window" then v = { x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, w = tonumber(v.w) or 900, h = tonumber(v.h) or 640 } end
    if a.key == "language" then
        if not I18n.set(v) then return false, "E_BAD_ARGS", "language: " .. table.concat(I18n.LANGS, " / ") end
        -- notices keep their message id: re-render them. State sections carry both languages
        -- (name / name_en ...); their revs move so a UI that caches by rev rebuilds its labels
        for _, n in ipairs(state.runtime.notices) do if n.key then n.text = I18n.notice_text(n) end end
        for _, sec in ipairs({ "expression", "presets", "conditions", "sculpt", "mapping" }) do bump(sec) end
    end
    cfg[a.key] = v
    if a.key == "scene_search_always" or a.key == "periodic_scan_sec" then request_rescan(1) end
    if a.key == "sculpt_max" then cfg.sculpt_max = Sculpt.set_max(v); build_sculpt_state() end
    build_settings_state(); save_soon()
    return true
end

function cmds.rescan()
    request_rescan(1)
    return true
end

function cmds.dismiss_notice(a)
    local n = state.runtime.notices
    for i = #n, 1, -1 do
        if n[i].id == a.id then table.remove(n, i); bump("runtime"); return true end
    end
    return false, "E_NOT_FOUND", "no such notice"
end

-- expression
-- show a profile read-only without applying it; {} or the active id clears the view
function cmds.preview_profile(a)
    if a.id ~= nil and not Profile.registry[a.id] then return false, "E_NOT_FOUND", "profile not found: " .. tostring(a.id) end
    C.preview_profile = a.id
    build_preview_state()
    return true
end

function cmds.set_profile(a)
    if not Profile.registry[a.id] then return false, "E_NOT_FOUND", "profile not found: " .. tostring(a.id) end
    local ok, code, msg = apply_profile(a.id, false)
    if not ok then return false, code, msg end
    cfg.profile = a.id; save_soon()
    -- a choice made by hand wins over the parent preset's profile while that preset stays in effect
    -- (before, the rescan after apply_profile switched straight back to the preset's profile)
    C.profile_manual = { id = a.id, hit = C.binding and C.binding.hit or nil }
    return true
end

local function gain_cmd(field, lo, hi)
    return function(a)
        local v = num(a.value, lo, hi)
        if not v then return false, "E_BAD_ARGS", "value must be a number" end
        cfg.expression[field] = v
        recompute_gains(); build_expression_state(); tuning_changed()
        return true
    end
end
cmds.set_master_gain = gain_cmd("master_gain", 0, 2)
cmds.set_gaze_gain = gain_cmd("gaze_gain", 0, 2)
cmds.set_smoothing = gain_cmd("smoothing", 0, 1)

function cmds.set_region_gain(a)
    local v = num(a.value, 0, 2)
    if not v then return false, "E_BAD_ARGS", "value must be a number" end
    if cfg.expression.region_gains[a.region] == nil then return false, "E_NOT_FOUND", "unknown region" end
    cfg.expression.region_gains[a.region] = v
    recompute_gains(); build_expression_state(); tuning_changed()
    return true
end

function cmds.set_channel_gain(a)
    local s = slot_of(a.name)
    if not s then return false, "E_NOT_FOUND", "unknown channel: " .. tostring(a.name) end
    local v = num(a.value, 0, 3)
    if not v then return false, "E_BAD_ARGS", "value must be a number" end
    cfg.expression.channel_gains[a.name] = (v ~= 1) and v or nil
    recompute_gains()
    state.expression.channels[s].gain = v
    bump("expression"); tuning_changed()
    return true
end

function cmds.force_channel(a)
    local s = slot_of(a.name)
    if not s then return false, "E_NOT_FOUND", "unknown channel: " .. tostring(a.name) end
    C.forced[s] = a.on and true or nil
    state.expression.channels[s].forced = a.on and true or false
    bump("expression")
    return true
end

-- gaze drag from the panel. Angles in degrees after invert (+yaw = the face's own right, +pitch =
-- up; full_deg = full weight). Held for `frames` (default 15) unless renewed: the panel sends it
-- every draw while the mouse is down, so a lost release cannot leave the eyes stuck.
function cmds.gaze_hold(a)
    local yaw, pitch = num(a.yaw, -90, 90), num(a.pitch, -90, 90)
    if not yaw or not pitch then return false, "E_BAD_ARGS", "yaw / pitch must be numbers" end
    local frames = num(a.frames, 1, 600) or 15
    C.gaze_hold = { yaw = yaw, pitch = pitch, until_frame = C.frame + frames }
    return true
end

function cmds.gaze_release()
    C.gaze_hold = nil
    return true
end

function cmds.set_eye_cfg(a)
    local p = a.patch
    if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
    local e = cfg.eyes
    if type(p.full_deg) == "table" then
        e.full_deg.yaw = num(p.full_deg.yaw, 1, 90) or e.full_deg.yaw
        e.full_deg.pitch = num(p.full_deg.pitch, 1, 90) or e.full_deg.pitch
    end
    if type(p.invert) == "table" then
        if type(p.invert.yaw) == "boolean" then e.invert.yaw = p.invert.yaw end
        if type(p.invert.pitch) == "boolean" then e.invert.pitch = p.invert.pitch end
    end
    if type(p.sets) == "table" then
        if type(p.sets.eye_look) == "boolean" then e.sets.eye_look = p.sets.eye_look end
        if type(p.sets.look) == "boolean" then e.sets.look = p.sets.look end
    end
    recompute_gains(); build_eyes_state(); tuning_changed()
    return true
end

function cmds.calibrate_eye_neutral()
    local rig = C.rigs[1]
    if not rig then return false, "E_NOT_FOUND", "no driven rig" end
    local e = cfg.eyes
    local iy, ip = e.invert.yaw and -1 or 1, e.invert.pitch and -1 or 1
    for _, s in ipairs({ "L", "R" }) do
        local a, n = rig.angles[s], e.neutral[s]
        e.neutral[s] = { yaw = n.yaw + a[1] * iy, pitch = n.pitch + a[2] * ip }
    end
    build_eyes_state(); save_soon()
    return true
end

-- mapping
function cmds.edit_node(a)
    if not slot_of(a.name) then return false, "E_NOT_FOUND", "unknown channel: " .. tostring(a.name) end
    if type(a.node) ~= "table" then return false, "E_BAD_ARGS", "node must be a table" end
    local edits = U.copy(C.edits)
    edits[a.name] = U.copy(a.node)
    return recompile(edits)
end

function cmds.revert_node(a)
    if not slot_of(a.name) then return false, "E_NOT_FOUND", "unknown channel: " .. tostring(a.name) end
    local edits = U.copy(C.edits)
    edits[a.name] = nil
    return recompile(edits)
end

function cmds.save_profile(a)
    local prog = C.prog
    if not prog then return false, "E_NOT_FOUND", "no profile" end
    local id, name
    if a.as_name ~= nil then
        id = U.safe_id(a.as_name)
        if id == "" then return false, "E_BAD_ARGS", "empty name" end
        name = tostring(a.as_name)
    else
        if prog.source ~= "user" then return false, "E_READONLY", "builtin / mod profiles cannot be overwritten" end
        id, name = prog.id, prog.name
    end
    local data = Profile.to_json(C.resolved, C.edits, id, name)
    if not U.save_json(U.path("user", "profiles", id .. ".json"), data) then
        return false, "E_IO", "write failed"
    end
    Profile.load_all()
    build_presets_state()
    local ok, code, msg = apply_profile(id, true)
    if not ok then return false, code, msg end
    cfg.profile = id; save_soon()
    notice("info", "notice.profile_saved", { name })
    return true, nil, nil, { id = id }
end

-- sculpt (M2)
local function scanned()
    if #Sculpt.K.keys == 0 and not state.sculpt.scan then return false, "E_NOT_SCANNED", "no sculpt scan yet" end
    return true
end

function cmds.sculpt_scan()
    Presets.load_sculpt()
    request_rescan(1)
    return true
end

function cmds.set_edit_mode(a)
    if type(a.on) ~= "boolean" then return false, "E_BAD_ARGS", "on must be boolean" end
    C.edit_mode = a.on
    Sculpt.end_gesture()
    Sculpt.mark_dirty()   -- turning it off writes the final values once
    build_sculpt_state()
    return true
end

function cmds.set_sculpt_key(a)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local v = num(a.value, Sculpt.RANGE[1], Sculpt.RANGE[2])
    if not v then return false, "E_BAD_ARGS", "value must be a number" end
    local c, m = Sculpt.check_editable(a.name)
    if c then return false, c, m end
    Sculpt.set(a.name, v)
    build_sculpt_state()
    return true
end

function cmds.set_sculpt_override(a)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local v = nil
    if a.value ~= nil then
        v = num(a.value, Sculpt.RANGE[1], Sculpt.RANGE[2])
        if not v then return false, "E_BAD_ARGS", "value must be a number or nil" end
    end
    local r1, r2, r3 = Sculpt.set_override(a.name, a.part, v)
    if not r1 then return false, r2, r3 end
    build_sculpt_state()
    return true
end

-- every sculpt key back to its mod default; one undo step (sculpt_undo brings the values back)
function cmds.reset_sculpt_all()
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local done = Sculpt.reset_all()
    build_sculpt_state()
    return true, nil, nil, { done = done }
end

-- every sculpt key to 0; one undo step
function cmds.zero_sculpt_all()
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local done = Sculpt.clear_all()
    build_sculpt_state()
    return true, nil, nil, { done = done }
end

function cmds.reset_sculpt_key(a)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local c, m = Sculpt.check_editable(a.name)
    if c then return false, c, m end
    Sculpt.reset(a.name)
    build_sculpt_state()
    return true
end

-- take keys back from other plugins: {owner?, name?}; nothing given = everything
function cmds.external_release(a)
    local n = 0
    if a.name then
        if Ext.release(a.owner, a.name) then n = 1 end
    else
        n = Ext.release_all(a.owner)
    end
    if n > 0 then
        Sculpt.mark_dirty(); C.build_external_state()
        log("external control released by the user: %s %s", tostring(a.owner or "*"), tostring(a.name or "*"))
    end
    return true, nil, nil, { released = n }
end

-- facial presets (Facial.lua): {name, value 0..1} for a numbered key of the worn parts
function cmds.set_facial(a)
    local v = tonumber(a.value)
    if not v or v ~= v then return false, "E_BAD_ARGS", "value must be a number" end
    if not Facial.present[a.name] then
        return false, "E_NOT_FOUND", "not a facial preset key of the worn parts: " .. tostring(a.name)
    end
    if Facial.set(a.name, v) then
        Sculpt.mark_dirty(); save_soon()
        build_facial_state()
    end
    return true
end

-- every facial slider to 0
function cmds.clear_facial()
    local done = Facial.clear()
    if done then Sculpt.mark_dirty(); save_soon() end
    build_facial_state()
    return true, nil, nil, { done = done }
end

function cmds.sculpt_undo()
    -- nothing to undo is not an error: report it as a no-op
    if not Sculpt.undo() then return true, nil, nil, { done = false } end
    build_sculpt_state()
    return true, nil, nil, { done = true }
end

function cmds.sculpt_redo()
    if not Sculpt.redo() then return true, nil, nil, { done = false } end
    build_sculpt_state()
    return true, nil, nil, { done = true }
end

function cmds.set_ab_preview(a)
    if type(a.on) ~= "boolean" then return false, "E_BAD_ARGS", "on must be boolean" end
    C.preview = a.on
    Sculpt.mark_dirty()
    build_sculpt_state()
    return true
end

-- the part a preset is "for": the binding in effect, else the part with the most channels
local function primary_part()
    if C.binding and C.binding.part then
        for _, p in ipairs(C.parts) do if p.id == C.binding.part then return p end end
    end
    local best
    for _, p in ipairs(C.parts) do if not best or (p.n or 0) > (best.n or 0) then best = p end end
    return best
end

-- the model folder new user presets go to (nil = general)
local function current_folder()
    local part = primary_part()
    return part and Presets.folder_of(part.id) or nil
end

-- args: name, folder? (a model folder; nil = the current model's, then the general presets)
-- Loads the preset's values without writing any binding.
function cmds.load_sculpt(a)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local e = Presets.find_sculpt(a.name, a.folder or current_folder(), nil, true)
    if not e then return false, "E_NOT_FOUND", "sculpt preset not found: " .. tostring(a.name) end
    Sculpt.apply_preset(e)
    C.sculpt_preset, C.sculpt_preset_manual = e, true
    build_sculpt_state()
    notice("info", "notice.sculpt_loaded", { e.name })
    return true
end

-- args: name, general? (true = a general preset in <src>/sculpt/, else the current model's folder)
function cmds.save_sculpt(a)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    if type(a.name) ~= "string" or a.name == "" then return false, "E_BAD_ARGS", "name required" end
    local values, overrides = Sculpt.export_values()
    local part = primary_part()
    local folder = (a.general ~= true) and current_folder() or nil
    local r1, r2, r3, r4 = Presets.save_sculpt(a.name, folder, {
        target = part and { part = part.id, channel_hash = part.fingerprint } or nil,
        values = values, overrides = overrides,
    })
    if not r1 then return false, r2, r3 end
    Sculpt.mark_saved()
    C.sculpt_preset = Presets.find_sculpt(a.name, folder, "user")
    C.sculpt_preset_manual = true
    build_presets_state(); build_sculpt_state()
    notice("info", "notice.sculpt_saved", { a.name })
    return true, nil, nil, r4
end

-- presets (M2)
local function resolve_profile_arg(v)
    if Profile.registry[v] then return v end
    for _, e in ipairs(Profile.list) do if e.name == v then return e.id end end
    return nil
end

-- args: part, expression (profile id or name), sculpt (preset name), gains (table, or true =
-- the current gains + gaze settings). Writes user/<model>/<part>.json.
function cmds.write_binding(a)
    if type(a.part) ~= "string" or a.part == "" then return false, "E_BAD_ARGS", "part required" end
    local data = {}
    if a.expression ~= nil then
        local id = resolve_profile_arg(a.expression)
        if not id then return false, "E_NOT_FOUND", "profile not found: " .. tostring(a.expression) end
        data.profile = id
    end
    if a.sculpt ~= nil then
        if not Presets.find_sculpt(a.sculpt, Presets.folder_of(a.part)) then
            return false, "E_NOT_FOUND", "sculpt preset not found: " .. tostring(a.sculpt)
        end
        data.sculpt = a.sculpt
    end
    if a.conditions ~= nil then
        if a.conditions ~= "" and not CondExpr.find(a.conditions) then
            return false, "E_NOT_FOUND", "condition set not found: " .. tostring(a.conditions)
        end
        data.conditions = a.conditions ~= "" and a.conditions or nil
    elseif C.binding and C.binding.part == a.part and C.binding.data then
        data.conditions = C.binding.data.conditions   -- callers that do not know it keep it
    end
    if a.gains == true then
        data.gains, data.eyes = current_gains(), eyes_subset(cfg.eyes)
    elseif type(a.gains) == "table" then
        data.gains = U.copy(a.gains)
    end
    local ok, code, msg, res = Presets.write_binding(a.part, data)
    if not ok then return false, code, msg end
    request_rescan(1)
    notice("info", "notice.binding_written", { res.path })
    return true, nil, nil, res
end

-- save the tuning in effect (gains + gaze) into the user copy of the binding it came from;
-- keeps the binding's other fields (profile, sculpt, global, fingerprints)
-- bind_config {kind = "sculpt" | "expression" | "conditions", name}: make a config the default of
-- the outfit worn ("绑定到 ..."). Only that field changes; the binding's other fields are kept and
-- the result goes to user/ (a mod's binding is copied, never modified).
function cmds.bind_config(a)
    local base, model, display, data, display_en = bind_target()
    if not base then return false, "E_NOT_FOUND", "no parts with shape keys worn" end
    data.schema, data.part = nil, nil
    if a.kind == "sculpt" then
        local e = Presets.find_sculpt(a.name, Presets.folder_of(base), nil, true)
        if not e then return false, "E_NOT_FOUND", "sculpt preset not found: " .. tostring(a.name) end
        data.sculpt = e.name
    elseif a.kind == "expression" then
        local id = resolve_profile_arg(a.name)
        if not id then return false, "E_NOT_FOUND", "profile not found: " .. tostring(a.name) end
        data.profile = id
        C.profile_manual = nil
    elseif a.kind == "conditions" then
        if not CondExpr.find(a.name) then return false, "E_NOT_FOUND", "condition set not found: " .. tostring(a.name) end
        data.conditions = a.name
    else
        return false, "E_BAD_ARGS", "kind"
    end
    local ok, code, msg, res = Presets.write_binding(base, data)
    if not ok then return false, code, msg end
    request_rescan(1)
    build_presets_state()
    notice("info", "notice.bound_to", { pair(display, display_en) })
    return true, nil, nil, res
end

function cmds.save_tuning()
    local b = C.binding
    if not b then return false, "E_NOT_FOUND", "no binding in effect: the global settings are saved automatically" end
    local data = U.copy(b.data or {})
    data.deleted = nil
    data.gains, data.eyes = current_gains(), eyes_subset(cfg.eyes)
    local ok, code, msg, res = Presets.write_binding(b.base, data)
    if not ok then return false, code, msg end
    C.tuning.dirty = false
    build_tuning_state()
    request_rescan(1)
    notice("info", "notice.tuning_saved", { res.path })
    return true, nil, nil, res
end

-- args: part (or "default"): drop the user file so the mods one (or nothing) applies again
function cmds.restore_mod_binding(a)
    if type(a.part) ~= "string" then return false, "E_BAD_ARGS", "part required" end
    if not Presets.user_binding_exists(a.part) then return false, "E_NOT_FOUND", "no user binding for " .. a.part end
    if not Presets.tombstone_binding(a.part) then return false, "E_IO", "write failed" end
    request_rescan(1)
    return true
end

local DELETE_KINDS = { binding = true, sculpt = true, profile = true, conditions = true }

-- args: kind, name, folder? (sculpt: the model folder; nil = the current model's, then general)
function cmds.request_delete(a)
    if not DELETE_KINDS[a.kind] or type(a.name) ~= "string" then return false, "E_BAD_ARGS", "kind / name" end
    if a.kind == "sculpt" then
        local e = Presets.find_sculpt(a.name, a.folder or current_folder(), "user", true)
        if not e then return false, "E_READONLY", "only user sculpt presets can be deleted" end
        C.pending_delete = { kind = a.kind, name = a.name, base = e.id, folder = e.folder }
    elseif a.kind == "conditions" then
        local e = CondExpr.find(a.name)
        if not e or e.source ~= "user" then return false, "E_READONLY", "only user condition sets can be deleted" end
        C.pending_delete = { kind = a.kind, name = e.name, base = e.id }
    elseif a.kind == "binding" then
        if not Presets.user_binding_exists(a.name) then return false, "E_READONLY", "only user bindings can be deleted" end
        C.pending_delete = { kind = a.kind, name = a.name, base = a.name }
    else
        local e = Profile.registry[a.name]
        if not e or e.source ~= "user" then return false, "E_READONLY", "only user profiles can be deleted" end
        -- the file name need not equal the profile id
        local base = tostring(e.path or ""):match("([^\\/]+)%.json$") or a.name
        C.pending_delete = { kind = a.kind, name = a.name, base = base }
    end
    build_presets_state()
    return true
end

function cmds.confirm_delete()
    local d = C.pending_delete
    if not d then return false, "E_NOT_FOUND", "nothing pending" end
    C.pending_delete = nil
    local ok
    if d.kind == "sculpt" then
        ok = Presets.tombstone_sculpt(d.folder, d.base)
        if C.sculpt_preset and C.sculpt_preset.id == d.base and C.sculpt_preset.folder == d.folder then
            C.sculpt_preset, C.sculpt_preset_manual = nil, false
        end
    elseif d.kind == "conditions" then
        ok = U.save_json(U.path("user", "conditions", d.base .. ".json"), { deleted = true })
        CondExpr.load_all()
        if CondExpr.current and CondExpr.current.id == d.base then CondExpr.current = nil end
        C.build_cond_state()
    elseif d.kind == "binding" then
        ok = Presets.tombstone_binding(d.base)
    else
        ok = U.save_json(U.path("user", "profiles", d.base .. ".json"), { deleted = true })
        Profile.load_all()
    end
    if not ok then return false, "E_IO", "write failed" end
    request_rescan(1)
    build_presets_state()
    notice("info", "notice.deleted", { d.name })
    return true
end

function cmds.cancel_delete()
    C.pending_delete = nil
    build_presets_state()
    return true
end

local IMPORT_KINDS = { binding = "bindings", sculpt = "sculpt", profile = "profiles" }
function cmds.import_preset(a)
    local kind = IMPORT_KINDS[a.kind]
    if not kind or type(a.path) ~= "string" then return false, "E_BAD_ARGS", "kind / path" end
    local ok, code, msg, res = Presets.import(kind, a.path, a.name)
    if not ok then return false, code, msg end
    if kind == "profiles" then Profile.load_all() end
    build_presets_state()
    request_rescan(1)
    return true, nil, nil, res
end

function SKS.call(cmd, args)
    local f = cmds[cmd]
    if not f then return false, "E_BAD_ARGS", "unknown command: " .. tostring(cmd) end
    local ok, r1, r2, r3, r4 = pcall(f, args or {})
    if not ok then
        log("command %s crashed: %s", cmd, tostring(r1))
        return false, "E_BAD_ARGS", tostring(r1)
    end
    if not r1 then log("command %s -> %s %s", cmd, tostring(r2), tostring(r3)) end
    return r1, r2, r3, r4
end

-- want_signals: compute live.signal (mapping editor / debug page open)
function SKS.set_ui_open(open, want_signals)
    open = open and true or false
    if state.runtime.ui_open ~= open then state.runtime.ui_open = open; bump("runtime") end
    C.want_signals = want_signals and true or false
end

-- ---------------------------------------------------------------- init / hooks
function SKS.init()
    Trail.open()
    load_settings()
    if hotkey_migrated_now then
        notice("info", "notice.hotkey_moved")
        save_soon()
    end
    cfg.sculpt_max = Sculpt.set_max(cfg.sculpt_max)
    if type(cfg.facial) ~= "table" then cfg.facial = {} end
    Facial.bind(cfg.facial)
    Names.load_aliases()
    local sig = Profile.load_signals()
    C.inv_full = 1 / sig.full
    for _, s in ipairs(sig.list) do C.dict_params[#C.dict_params + 1] = s.param end
    Profile.load_all()
    Presets.load_sculpt()
    CondExpr.load_all()
    if cfg.conditions ~= "" then CondExpr.select(cfg.conditions) end
    build_settings_state(); build_eyes_state(); build_presets_state()
    C.build_cond_state()
    local ok, code, msg = apply_profile(cfg.profile, false)
    if not ok and cfg.profile ~= "arkit" then
        notice("warn", "notice.profile_fallback", { tostring(msg) })
        ok, code, msg = apply_profile("arkit", false)
        if ok then cfg.profile = "arkit" end
    end
    if not ok then
        notice("error", "notice.no_profile", { tostring(code), tostring(msg) })
    end
    if not U.load_json(SETTINGS_PATH) then save_now() end
    C.saved_gains = gains_of(cfg.expression)
    C.publish_api()
end

-- skip / stop / unload (pre-hook): let go before the game destroys the cutscene actors
function SKS.on_cutscene_stop(reason)
    Trail.event("hook %s (cs active %s, released %s, rigs %d)", tostring(reason), tostring(CS.active), tostring(CS.released), #C.rigs)
    zero_ready_targets(reason)   -- the meshes are still valid in the pre-hook
    CS.released, CS.released_at = true, C.frame
    CS.status = tostring(reason) .. ": released until the next segment"
    drop_rigs("cutscene " .. tostring(reason), nil)
    C.scan_at = {}
    -- in case the game never reports the cutscene as busy afterwards
    if not CS.active then request_rescan(Guard.SETTLE_FRAMES * 4) end
end

-- a cutscene segment starts (pre-hook of onPlayStartTimeline)
function SKS.on_cutscene_segment(index)
    Trail.event("hook onPlayStartTimeline(%s) (cs active %s, released %s, rigs %d)", tostring(index), tostring(CS.active), tostring(CS.released), #C.rigs)
    zero_ready_targets("segment start")
    CS.seg, CS.seg_t0, CS.released, CS.scanned = index, C.frame, false, false
    drop_rigs("cutscene segment " .. tostring(index), nil)
    C.scan_at = {}
end

function SKS.on_equip_build()
    Trail.event("hook onEquipBuildEnd (rigs %d)", #C.rigs)
    if #C.rigs > 0 then drop_rigs("equipment rebuilt", Guard.SETTLE_FRAMES)
    else request_rescan(Guard.SETTLE_FRAMES) end
end

-- debug: run the blendshape hash-table probe on the next stable frame
function SKS.request_probe() C.probe_pending = true end

-- title / save-select GUI opened or closed: the preview hunters are (re)built around it.
-- Only a flag here: the game calls some of these every frame, many times per frame (GUI010100
-- onClose froze the title screen when each call dropped refs + ran a full GC). tick() handles
-- the flag at most once per frame and only when it changes.
function SKS.on_menu(name, open)
    C.menu_event = name .. (open and " open" or " close")
end

function SKS.on_guild_card(open)
    if C.gc_open == open then return end   -- repeated calls: nothing new
    C.gc_open = open
    if open then request_rescan(10, 30, 60, 120, 240, 480) else request_rescan(5, 60) end
end

function SKS.shutdown()
    Trail.event("script reset")
    C.unpublish_api()
    if not C.paused then
        for _, r in ipairs(C.rigs) do
            for _, t in ipairs(r.targets) do
                if t.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(t.mesh) then Writer.zero_target(t) end
            end
        end
        zero_sculpt()
    end
    if C.save_at then save_now() end
end

-- ---------------------------------------------------------------- conditional expressions
-- CondExpr.lua / Conditions.lua. The binding in effect names the set ("conditions"); without one
-- the global settings.conditions is used. Edits go to a working copy until cond_save.

function C.build_cond_state()
    local cs = state.conditions
    local sets = {}
    for i, e in ipairs(CondExpr.list) do sets[i] = { id = e.id, name = e.name, source = e.source } end
    cs.sets = sets
    local cur = CondExpr.current
    cs.current = cur and { id = cur.id, name = cur.name, source = cur.source, dirty = cur.dirty,
                           data = U.copy(cur.data) } or nil
    local defs = {}
    for i, d in ipairs(Cnd.order) do
        defs[i] = { id = d.id, label = d.label, label_en = d.label_en, kind = d.kind, options = d.options, min = d.min, max = d.max }
    end
    cs.defs = defs
    local b = C.binding
    cs.binding_name = b and b.data and b.data.conditions or nil
    cs.binding_part = b and b.part or nil
    cs.global_name = cfg.conditions ~= "" and cfg.conditions or nil
    bump("conditions")
    if C.update_touch_map then C.update_touch_map() end   -- a set may carry its own interactions
end

-- live values for the panel (only while it is open)
live.cond = { values = {}, status = {}, playing = nil, alpha = {}, sampled = false }
function C.update_cond_live()
    local lc = live.cond
    for k in pairs(lc.values) do lc.values[k] = nil end
    for k, v in pairs(Cnd.V) do lc.values[k] = v end
    for k in pairs(lc.status) do lc.status[k] = nil end
    for k, v in pairs(CondExpr.status) do lc.status[k] = v end
    lc.playing = CondExpr.playing
    for k in pairs(lc.alpha) do lc.alpha[k] = nil end
    local data = CondExpr.current and CondExpr.current.data
    if data then for id in pairs(data.clips) do lc.alpha[id] = CondExpr.alpha(id) end end
    lc.sampled = C.cond_live == true
end

function C.select_conditions()
    local b = C.binding
    local want = b and b.data and b.data.conditions or (cfg.conditions ~= "" and cfg.conditions or nil)
    local cur = CondExpr.current
    local cs = state.conditions
    if cs.binding_name ~= (b and b.data and b.data.conditions or nil) or cs.binding_part ~= (b and b.part or nil) then
        C.build_cond_state()                        -- the binding in effect changed
    end
    if cur and cur.dirty then return end            -- never drop unsaved edits
    if want then
        if not cur or cur.id ~= want then
            if not CondExpr.select(want) then
                local key = "cond:" .. want
                if not C.warned[key] then C.warned[key] = true; notice("warn", "notice.cond_missing", { want }) end
            end
            C.build_cond_state()
        end
    elseif cur then
        CondExpr.current = nil
        CondExpr.reset()
        C.build_cond_state()
    end
end

function cmds.cond_select(a)
    if a.name == nil or a.name == "" then
        if CondExpr.current and CondExpr.current.dirty and not a.discard then return false, "E_BAD_ARGS", "unsaved edits" end
        CondExpr.current = nil; CondExpr.reset()
        cfg.conditions = ""; save_soon()
    else
        if CondExpr.current and CondExpr.current.dirty and CondExpr.current.id ~= a.name and not a.discard then
            return false, "E_BAD_ARGS", "unsaved edits"
        end
        if CondExpr.current and CondExpr.current.id ~= a.name then CondExpr.current = nil end
        if not CondExpr.select(a.name) then return false, "E_NOT_FOUND", "condition set not found: " .. tostring(a.name) end
        if not (C.binding and C.binding.data and C.binding.data.conditions) then cfg.conditions = CondExpr.current.id; save_soon() end
    end
    C.build_cond_state()
    return true
end

function cmds.cond_new(a)
    if type(a.name) ~= "string" then return false, "E_BAD_ARGS", "name" end
    local ok, code, msg = CondExpr.new_set(a.name)
    if not ok then return false, code, msg end
    C.build_cond_state()
    return true
end

function cmds.cond_edit(a)
    local ok, code, msg = CondExpr.edit(a.data)
    if not ok then return false, code, msg end
    C.update_touch_map()
    Sculpt.mark_dirty()
    C.build_cond_state()
    return true
end

function cmds.cond_save(a)
    local ok, code, msg, res = CondExpr.save(a.as_name)
    if not ok then return false, code, msg end
    if not (C.binding and C.binding.data and C.binding.data.conditions) then cfg.conditions = res.id; save_soon() end
    C.build_cond_state()
    notice("info", "notice.cond_saved", { CondExpr.current.name })
    return true, nil, nil, res
end

function cmds.cond_revert()
    CondExpr.revert()
    C.build_cond_state()
    return true
end

-- force one clip to play (panel preview); nil stops the preview
function cmds.cond_preview(a)
    CondExpr.preview = (type(a.clip) == "string" and a.clip ~= "") and a.clip or nil
    return true
end

-- ---------------------------------------------------------------- face interactions (Touch.lua)
-- mapping: the condition set's "interactions" section, zones it leaves out auto-detected from
-- the worn keys
function C.update_touch_map()
    local names = {}
    for i, k in ipairs(Sculpt.K.keys) do names[i] = k.name end
    local m = Touch.detect(names)
    local data = CondExpr.current and CondExpr.current.data
    local own = data and type(data.interactions) == "table" and data.interactions or nil
    if own then
        for _, z in ipairs({ "forehead", "cheek", "eye" }) do
            if type(own[z]) == "table" and type(own[z].values) == "table" and next(own[z].values) then m[z] = own[z] end
        end
        if type(own.mouth) == "table" then
            for _, d in ipairs({ "left", "right", "up", "down" }) do
                if type(own.mouth[d]) == "table" and next(own.mouth[d]) then m.mouth[d] = own.mouth[d] end
            end
        end
    end
    Touch.set_map(m)
    local z = {}
    for _, k in ipairs({ "forehead", "cheek", "eye" }) do z[k] = next(m[k].values) ~= nil end
    z.mouth = next(m.mouth.left) ~= nil or next(m.mouth.right) ~= nil or next(m.mouth.up) ~= nil or next(m.mouth.down) ~= nil
    state.touch.zones = z
    state.touch.map = U.copy(m)
    bump("touch")
end

function cmds.touch_poke(a)
    if type(a.zone) ~= "string" then return false, "E_BAD_ARGS", "zone" end
    return true, nil, nil, { played = Touch.poke(a.zone) }
end

-- x, y in -1..1 (viewer's right / down); call every frame while dragging
function cmds.touch_drag(a)
    local x, y = tonumber(a.x), tonumber(a.y)
    if not x or not y then return false, "E_BAD_ARGS", "x, y" end
    Touch.drag(U.clamp(x, -1, 1), U.clamp(y, -1, 1))
    return true
end

function cmds.touch_release()
    Touch.release()
    return true
end

-- ---------------------------------------------------------------- public API for other plugins
-- _G.ShapeKeySystemAPI (docs/plans/shape-key-system-api.md §11). Values override the expression
-- and sculpt layers; each set() is a lease (External.lua). Writes still go through the same
-- warm-up / cutscene / rebuild guards as everything else: nothing here touches the engine.

-- expression slot for an external key name: canonical name, else the profile's alias index
function C.resolve_slot(name)
    local prog = C.prog
    if not prog then return nil end
    local s = prog.slot_of[name]
    if s then return s end
    local ok, m = pcall(Names.match, C.index, name)
    return ok and m or nil
end

function C.build_external_state()
    local ex = state.external
    local held, by = {}, {}
    for k, e in pairs(Ext.entries) do
        held[#held + 1] = { name = e.name, owner = e.owner, value = e.value }
        by[k] = e.owner
    end
    table.sort(held, function(a, b) return a.name < b.name end)
    ex.held, ex.by_norm = held, by
    bump("external")
end

local listeners = { scan = {} }
local listener_seq = 0
function C.fire(event, ...)
    local l = listeners[event]
    if not l then return end
    for id, fn in pairs(l) do
        local ok, e = pcall(fn, ...)
        if not ok then log("API listener %s/%s failed: %s", event, tostring(id), tostring(e)) end
    end
end

local PUB = { version = "1.0", plugin_version = Version.number }   -- version = this API

local function bad(msg) return false, "E_BAD_ARGS", msg end
local function check_owner(owner)
    return type(owner) == "string" and owner ~= "" and #owner <= 64
end

-- set(owner, name, value, opts?) -> ok, err, msg.  opts.ttl: seconds the value stays without a
-- new set (default 0.5, 0 = until release, max 60). value is clamped to 0..settings.sculpt_max.
function PUB.set(owner, name, value, opts)
    if not check_owner(owner) then return bad("owner: non-empty string up to 64 chars") end
    if type(name) ~= "string" or name == "" then return bad("name: string") end
    value = tonumber(value)
    if not value or value ~= value then return bad("value: number") end
    local ttl = Ext.DEFAULT_TTL
    if type(opts) == "table" and opts.ttl ~= nil then
        ttl = tonumber(opts.ttl)
        if not ttl or ttl < 0 then return bad("opts.ttl: number >= 0") end
        ttl = math.min(ttl, Ext.MAX_TTL)
    end
    value = U.clamp(value, 0, Sculpt.RANGE[2])
    local old = Ext.get(name)
    local structural = Ext.set(owner, name, value, ttl)
    if structural or old ~= value then Sculpt.mark_dirty() end
    if structural then C.build_external_state() end
    return true
end

-- release(owner, name): give the key back to expression / sculpt
function PUB.release(owner, name)
    if not check_owner(owner) or type(name) ~= "string" then return bad("owner, name") end
    if Ext.release(owner, name) then Sculpt.mark_dirty(); C.build_external_state() end
    return true
end

function PUB.release_all(owner)
    if not check_owner(owner) then return bad("owner") end
    if Ext.release_all(owner) > 0 then Sculpt.mark_dirty(); C.build_external_state() end
    return true
end

-- value written (or about to be written) for a key, and who controls it:
-- returns value, controller ("external:<owner>" | "facial" | "expression" | "sculpt") or nil when unknown
function PUB.get(name)
    if type(name) ~= "string" then return nil end
    local xv, owner = Ext.get(name)
    if xv ~= nil then return xv, "external:" .. owner end
    local fv = Facial.for_key(name)
    if fv ~= nil then return fv, "facial" end
    local s = C.resolve_slot(name)
    if s and live.weight[s] ~= nil and #C.rigs > 0 then return live.weight[s], "expression" end
    local k = Sculpt.K.by_name[name]
    if not k then
        local n = Ext.norm(name)
        for _, kk in ipairs(Sculpt.K.keys) do if Ext.norm(kk.name) == n then k = kk; break end end
    end
    if k then return k.value, (k.owner == "expression") and "expression" or "sculpt" end
    return nil
end

-- every shape key on the worn parts (merged by name), after the latest scan:
-- { {name, parts = {ids}, value, controller, expression = bool} }
function PUB.channels()
    local out = {}
    for _, k in ipairs(Sculpt.K.keys) do
        local v, ctl = PUB.get(k.name)
        local parts = {}
        for i, p in ipairs(k.parts) do parts[i] = p end
        out[#out + 1] = { name = k.name, parts = parts, value = v, controller = ctl,
                          expression = k.owner == "expression" }
    end
    return out
end

-- on("scan", fn) -> id: fn() after every scan (equipment change, rescan). off(id) removes it.
function PUB.on(event, fn)
    if not listeners[event] or type(fn) ~= "function" then return nil end
    listener_seq = listener_seq + 1
    listeners[event][listener_seq] = fn
    return listener_seq
end

function PUB.off(id)
    for _, l in pairs(listeners) do l[id] = nil end
end

function PUB.is_ready() return #Sculpt.K.keys > 0 end

-- publish: _G.ShapeKeySystemAPI, and run callbacks other plugins queued before SKS loaded
-- (_G.ShapeKeySystemAPI_pending = { fn, ... }, each called with the API table)
function C.publish_api()
    rawset(_G, "ShapeKeySystemAPI", PUB)
    local pending = rawget(_G, "ShapeKeySystemAPI_pending")
    rawset(_G, "ShapeKeySystemAPI_pending", nil)
    if type(pending) == "table" then
        for _, fn in ipairs(pending) do
            local ok, e = pcall(fn, PUB)
            if not ok then log("API ready callback failed: %s", tostring(e)) end
        end
    end
end

function C.unpublish_api()
    if rawget(_G, "ShapeKeySystemAPI") == PUB then rawset(_G, "ShapeKeySystemAPI", nil) end
end

SKS.public = PUB
SKS.log = log
return SKS
