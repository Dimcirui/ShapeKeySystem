-- 管理运行状态、配置和形态键驱动。
--
-- UI 读取 `SKS.state` / `SKS.live`，通过 `SKS.call` 提交修改，不直接写引擎。
-- 网格权重在 `SKS.tick`（LateUpdateBehavior）写入；录制 raw 输入由游戏适配器的更新和面部回调注入。
-- 接口与文件格式见 docs/plans/shape-key-system-api.md。

local U       = require("ShapeKeySystem_Core.Util")
local I18n    = require("ShapeKeySystem_Core.I18n")
local Names   = require("ShapeKeySystem_Core.Names")
local Profile = require("ShapeKeySystem_Core.Profile")
local Scene   = require("ShapeKeySystem_Core.Scene")
local Writer  = require("ShapeKeySystem_Core.Writer")
local X       = require("ShapeKeySystem_Core.Expression")
local Guard   = require("ShapeKeySystem_Core.Guard")
local Trail   = require("ShapeKeySystem_Core.Trail")
local Presets = require("ShapeKeySystem_Core.Presets")
local Sculpt  = require("ShapeKeySystem_Core.Sculpt")
local Ext     = require("ShapeKeySystem_Core.External")
local Cnd     = require("ShapeKeySystem_Core.Conditions")
local CondExpr = require("ShapeKeySystem_Core.CondExpr")
local Touch   = require("ShapeKeySystem_Core.Touch")
local Playback = require("ShapeKeySystem_Core.Playback")
local NameHash = require("ShapeKeySystem_Core.NameHash")
local Labels  = require("ShapeKeySystem_Core.Labels")
local NativeSignals = require("ShapeKeySystem_Core.NativeSignals")
local ActorInstances = require("ShapeKeySystem_Core.ActorInstances")
local Proc    = require("ShapeKeySystem_Core.Procedural")
local Mocap   = require("ShapeKeySystem_Core.Mocap")
local Drivers = require("ShapeKeySystem_Core.Drivers")
local Actors  = require("ShapeKeySystem_Core.Actors")
local FaceHold = require("ShapeKeySystem_Core.FaceHold")

local Version = require("ShapeKeySystem_Core.Version")
local SKS = { version = Version.number }

local SETTINGS_PATH = U.path("settings.json")
local LEGACY_PATH = "ArkitFaceDriver.json"
local Perf = require("ShapeKeySystem_Core.Perf")
local clock, max, min = os.clock, math.max, math.min

-- ---------------------------------------------------------------- settings
local DEFAULTS = {
    enabled = true, advanced = false,
    -- Delete: Home opens ArmorVariantManager's panel (same audience), End is the game's pause key,
    -- Insert is REFramework's menu. hotkey_rev 2 = the End -> Delete move has been applied.
    hotkey = "Delete", hotkey_migrated = false, hotkey_rev = 2, ui_scale = 1.0, language = "zh",
    -- Delete alone by default; with hotkey_combo the modifier must be held too
    hotkey_combo = false, hotkey_mod = "Ctrl",
    -- panel text size on top of ui_scale (ImGui draws small by default)
    font_scale = 1.0,
    -- block the game's controls while the panel is open
    block_input = true,
    -- show shape key labels (builtin/labels.json) instead of mesh names; Chinese only for now
    translate_keys = false,
    scene_search_always = true, periodic_scan_sec = 5, write_epsilon = 0.001, clamp = true,
    -- drive the hunter while a cutscene plays (released on skip / stop, re-armed per segment)
    cutscene_drive = true,
    -- off: the game's expression no longer reaches the shape keys (sculpt, conditions, touch and
    -- other plugins still do)
    expression_enabled = true,
    -- hold the face's expression bones at the neutral pose so only the shape keys show expression
    hold_face_bones = false,
    -- sculpt slider upper end, for every key (1 = the authored shape; 2 = exaggerated)
    sculpt_max = 1.0,
    -- conditional expression set used when no parent preset names one ("" = none)
    conditions = "",
    -- face navigator art on the basic page: data/ShapeKeySystem/faces/<id>.json
    face_style = "portrait",
    -- panel drawing: "auto" (reframework-d2d when installed, else REFramework's ImGui) / "d2d" / "imgui"
    ui_backend = "auto",
    window = { x = 120, y = 120, w = 920, h = 640 },
    profile = "arkit",
    -- M1: expression gains live here until per-part bindings exist (M2)
    expression = { master_gain = 1.0, gaze_gain = 1.0, smoothing = 0.0,
                   region_gains = { brow = 1.0, eye = 1.0, nose_cheek = 1.0, mouth = 1.0 },
                   channel_gains = {} },
    -- automatic blinking, merged into the dictionary signals (Procedural.lua); not part of a binding's tuning
    procedural = U.copy(Proc.DEFAULTS),
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
    procedural = { rev = 0 },
    -- keys other plugins hold through ShapeKeySystemAPI: held = {{name, owner, value}},
    -- by_norm[External.norm(name)] = owner
    external = { rev = 0, held = {}, by_norm = {} },
    -- conditional expressions: sets on disk, the set in effect (working copy), condition defs
    conditions = { rev = 0, sets = {}, current = nil, defs = {}, binding_name = nil },
    -- face-navigator interactions: zones = { forehead = bool, cheek = bool, eye = bool, mouth = bool }
    touch = { rev = 0, zones = {} },
    debug = { rev = 0, perf = { timings = Perf.metrics, read = 0, compute = 0, write = 0, scan = 0, total = 0, writes = 0, skipped = 0 },
              log = {}, status = "" },
}
local live = {
    weight = {}, region_activity = { 0, 0, 0, 0 }, signal = {},
    eye_angle = { L = { yaw = 0, pitch = 0 }, R = { yaw = 0, pitch = 0 } },
    procedural = { blink = 0, mouth = 0, gaze = { 0, 0 } },
}
SKS.state, SKS.live = state, live
state.playback = Playback.state
state.native_signals = NativeSignals.state
state.scene.additional = ActorInstances.state
NativeSignals.on_export = function() Playback.refresh() end
state.mocap = Mocap.view
state.drivers = Drivers.view
Drivers.clip_progress = CondExpr.alpha
-- characters by person (Actors.lua): list = {{id, name, player, copies}}, selected (being edited),
-- wanted (picked in the panel, may be absent), player_id (the player's character), enabled (the
-- game tells people apart)
state.actors = { rev = 0, list = {}, selected = "", wanted = nil, player_id = "", enabled = false }

-- ---------------------------------------------------------------- internal
local C = {
    prog = nil, resolved = nil, original_resolved = nil, edits = {}, index = {},
    gains = {}, forced = {},
    rigs = {}, parts = {}, sig = "", cov_key = nil,
    frame = 0, scan_at = { 1 }, next_periodic = 0, preview_open = false,
    pending_zero = {}, save_at = nil,
    P = {}, Pbuf = {}, inv_full = 100, dict_params = {},
    want_signals = false,
    menu = false,         -- menu mode: master player not set up (title, save select, loading)
    prev_kind = nil,      -- Guard.game_stable kind of the previous frame (nil = stable)
    -- M2
    binding = nil,        -- the parent preset in effect (Presets.resolve_binding result)
    part_bindings = {},   -- part id -> resolve result
    legacy_bindings = {}, -- part files left by earlier versions (Presets.legacy_bindings)
    -- per-part tuning (gains + gaze); stash_* = the settings.json fallback while a binding is loaded
    tuning = { source = "settings", path = nil, dirty = false, mismatch = false, stash_expression = nil, stash_eyes = nil },
    sculpt_preset = nil, sculpt_preset_manual = false,
    edit_mode = false, preview = false,
    pending_delete = nil,
    warned = {},          -- binding problems already reported (one notice each)
}
local prof = { read = 0, compute = 0, write = 0, scan = 0, writes = 0, skipped = 0, frames = 0, window = 60 }

local function bump(section) state[section].rev = state[section].rev + 1 end

local function log(fmt, ...)
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Trail.event("%s", text)
    local l = state.debug.log
    l[#l + 1] = { time = os.date("%H:%M:%S"), text = text }
    if #l > 200 then table.remove(l, 1) end
    bump("debug")
end

local notice_seq = 0
local function notice(level, text)
    notice_seq = notice_seq + 1
    local n = state.runtime.notices
    n[#n + 1] = { id = notice_seq, level = level, text = text, time = os.time() }
    if #n > 20 then table.remove(n, 1) end
    bump("runtime")
    return notice_seq
end

local function save_soon() C.save_at = C.frame + 60 end
-- gains as last saved: each save trails the gains that changed (a slider drag saves once, ~1 s
-- after it stops)
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
    C.scan_force = true
    for _, d in ipairs(delays) do
        local at, found = C.frame + d, false
        for _, existing in ipairs(C.scan_at) do if existing == at then found = true; break end end
        if not found then C.scan_at[#C.scan_at + 1] = at end
    end
end

-- Let go of every engine object we hold (no writes). Used when parts are rebuilt or a cutscene
-- takes over; references that outlive the objects crashed the game (SKS_Mocap investigation).
local MENU_SCAN_FRAMES = 180
-- rescan delay after a part or mesh change while driving: meshes found again resume writing at once
-- (their warm-up survives the drop in C.warm), new ones still warm up
local QUICK_RESCAN = 2

local function drop_rigs(reason, rescan_after)
    C.scan_force = true
    Scene.clear_channel_cache()
    ActorInstances.release(reason)
    -- the character faces go with the rigs; they are collected again before the rescan
    Actors.clear(); Scene.override = nil; C.actors_at = C.frame
    Playback.stop(false, I18n.f("角色或场景变化，录制播放已停止：%s", tostring(reason)))
    if #C.rigs > 0 or #C.pending_zero > 0 then log("released rigs: %s", reason) end
    -- warm-up by mesh address only (numbers, no engine references); the next scan consumes it
    C.warm = C.warm or {}
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do
            if t.addr then C.warm[t.addr] = { stable = t.stable, ready = t.ready } end
        end
    end
    C.rigs, C.parts, C.instances, C.pending_zero = {}, {}, {}, {}
    Sculpt.clear_targets()
    Cnd.reset()
    Scene.no_targets = {}
    Mocap.drop_refs()
    if SKS.adapter and SKS.adapter.face_mirror then SKS.adapter.face_mirror.drop_refs() end
    FaceHold.release()
    C.driven_frame, C.held_frame = nil, nil
    Guard.release_refs()
    if rescan_after then
        C.scan_after_frame = C.frame + rescan_after
        C.scan_at = { C.scan_after_frame }
    end
end

-- raw channel handles (the adapter's bind) / eye use per rig, limited to the channels its meshes
-- actually have
local function bind_raw(face, keys)
    local bind = SKS.adapter.bind
    if not bind then return {}, 0 end
    return bind(face, keys)
end

local function refresh_rig_params()
    local prog = C.prog
    if not prog then return end
    for _, rig in ipairs(C.rigs) do
        local slots = {}
        for _, t in ipairs(rig.targets) do for k = 1, t.count do slots[t.slots[k]] = true end end
        local params, eyes = Profile.needs(prog, slots)
        local n
        rig.params, n = bind_raw(rig.face, params)
        rig.use_eyes = eyes
        if rig.primary then
            local union, seen = {}, {}
            for _, list in ipairs({ C.dict_params, params }) do
                for _, p in ipairs(list) do if not seen[p] then seen[p] = true; union[#union + 1] = p end end
            end
            rig.dict_params = bind_raw(rig.face, union)
        end
        rig.n_reads = (n or 0) + (eyes and 2 or 0)
    end
end

local function queue_zero_all()
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do C.pending_zero[#C.pending_zero + 1] = t end
    end
end

-- sculpt + expression targets of ready meshes back to 0 (disable / script reset)
local function zero_sculpt()
    if SKS.adapter.strict_bounds and Scene.runtime_signature(Scene.primary_root()) ~= C.sig then return end
    pcall(Sculpt.zero_all)
end

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
-- display label for a key while "translate shape keys" is on; the label tables are Chinese, so
-- another UI language keeps the mesh names
local function label_of(name)
    if cfg.translate_keys and cfg.language == "zh" then return Labels.of(name) end
    return nil
end

local function build_settings_state()
    local st = state.settings
    for _, k in ipairs({ "hotkey", "hotkey_combo", "hotkey_mod", "ui_scale", "language", "scene_search_always", "periodic_scan_sec",
                         "write_epsilon", "clamp", "cutscene_drive", "sculpt_max", "face_style", "ui_backend",
                         "translate_keys", "expression_enabled", "hold_face_bones", "font_scale", "block_input" }) do st[k] = cfg[k] end
    st.hold_available = SKS.adapter.expression_joints ~= nil and SKS.adapter.face_layers ~= nil
    st.hold_status = FaceHold.status
    st.scene_search_available = SKS.adapter.scene_search ~= false
    st.window = U.copy(cfg.window)
    state.runtime.enabled = cfg.enabled
    state.runtime.advanced = cfg.advanced
    bump("settings"); bump("runtime")
end

-- settings.json values out of range or of the wrong type fall back to the defaults
local function sanitize_procedural()
    local c, d = cfg.procedural, Proc.DEFAULTS
    if type(c.enabled) ~= "boolean" then c.enabled = d.enabled end
    if not Proc.MODE_NAMES[c.mode] then c.mode = d.mode end
    for grp, limits in pairs(Proc.LIMITS) do
        local t, dt = c, d
        if grp ~= "top" then
            if type(c[grp]) ~= "table" then c[grp] = U.copy(d[grp]) end
            t, dt = c[grp], d[grp]
            if type(t.enabled) ~= "boolean" then t.enabled = dt.enabled end
        end
        for k, lim in pairs(limits) do
            local v = tonumber(t[k])
            t[k] = v and v == v and U.clamp(v, lim[1], lim[2]) or dt[k]
        end
    end
end

local function build_procedural_state()
    local st, c = state.procedural, cfg.procedural
    st.enabled, st.mode, st.frequency, st.speed = c.enabled, c.mode, c.frequency, c.speed
    for _, grp in ipairs(Proc.GROUPS) do st[grp] = U.copy(c[grp]) end
    st.modes, st.mode_names = Proc.MODES, Proc.MODE_NAMES
    -- groups the game has no usable signal for: fallback mode fills them
    local lacking = {}
    for name in pairs(Proc.SIGNALS) do
        local sig = Profile.signals.by_name[name]
        lacking[name] = Proc.lacking(name, sig == nil or sig.no_signal)
    end
    -- gaze is decided per rig (eye joints): the panel shows the primary rig's, rebuilt on every scan
    local rig = C.rigs[1]
    lacking.gaze = Proc.lacking_group("gaze") or (rig ~= nil and Proc.gaze_lacking(rig))
    st.lacking = lacking
    bump("procedural")
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
    ex.profile = { id = prog.id, name = prog.name, source = prog.source, extends = prog.extends }
    local present = C.mesh_name_of or {}
    local channels = {}
    local by_group = {}
    for s, c in ipairs(prog.channels) do
        channels[s] = {
            slot = s, name = present[s] or c.name, canonical = c.name, group = c.group,
            label = label_of(present[s] or c.name) or label_of(c.name),
            source_text = c.source_text, has_signal = c.has_signal, no_signal = c.no_signal, guessed = c.guessed,
            extension = c.extension, gaze_set = c.gaze_set, note = c.note, edited = c.edited,
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
        regions[i] = { key = r.key, name = r.name, gain = eg.region_gains[r.key] or 1.0, channel_slots = slots }
    end
    ex.regions = regions
    local groups = {}
    local known = {}
    for _, g in ipairs(X.GROUPS) do
        known[g.key] = true
        if by_group[g.key] then
            groups[#groups + 1] = { key = g.key, name = g.name, region = g.region, channel_slots = by_group[g.key] }
        end
    end
    for key, slots in pairs(by_group) do
        if not known[key] then groups[#groups + 1] = { key = key, name = key, channel_slots = slots } end
    end
    ex.groups = groups
    bump("expression")
    if C.preview_profile then build_preview_state() end
end

-- read-only view of a profile that is not in effect (表情 → 映射配置: choosing in the list shows it
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
                         label = label_of(present[sl] or c.name) or label_of(c.name),
                         source_text = c.source_text, has_signal = c.has_signal, no_signal = c.no_signal, guessed = c.guessed,
                         extension = c.extension, note = c.note, present = present[sl] ~= nil }
        by_group[c.group] = by_group[c.group] or {}
        table.insert(by_group[c.group], sl)
    end
    local groups, known = {}, {}
    for _, g in ipairs(X.GROUPS) do
        known[g.key] = true
        if by_group[g.key] then groups[#groups + 1] = { key = g.key, name = g.name, channel_slots = by_group[g.key] } end
    end
    for key, slots in pairs(by_group) do
        if not known[key] then groups[#groups + 1] = { key = key, name = key, channel_slots = slots } end
    end
    ex.preview = { id = prog.id, name = prog.name, source = prog.source, extends = prog.extends,
                   channels = channels, groups = groups, present = hit, total = prog.n }
    bump("expression")
end

local function build_mapping_state()
    local m = state.mapping
    local sigs = {}
    for i, s in ipairs(Profile.signals.list) do
        sigs[i] = { slot = s.slot, name = s.name, label = s.label, no_signal = s.no_signal,
                    guessed = s.guessed, note = s.note }
    end
    m.signals = sigs
    local raw = SKS.adapter.raw
    m.raw = raw and { term = raw.term or "原始通道", slider = U.copy(raw.slider) } or nil
    local nodes, edited, entries, originals = {}, {}, {}, {}
    for _, e in ipairs(C.original_resolved and C.original_resolved.channels or {}) do originals[e.name] = e end
    if C.prog then
        local data = Profile.to_json(C.resolved, C.edits, C.prog.id, C.prog.name)
        for i, c in ipairs(C.prog.channels) do
            nodes[c.name] = U.copy(c.node)
            entries[c.name] = U.copy(data.channels[i])
            if U.signature(entries[c.name]) ~= U.signature(originals[c.name]) then edited[c.name] = true end
        end
    end
    m.nodes, m.edited, m.entries = nodes, edited, entries
    m.dirty = next(edited) ~= nil
    for name in pairs(originals) do if not entries[name] then m.dirty = true end end
    m.profile_id = C.prog and C.prog.id or nil
    bump("mapping")
end

local function sculpt_entry_state(e)
    return { id = e.id, name = e.name, source = e.source, folder = e.folder, target_part = e.target_part }
end

-- readable name of a model ("ch03_032_501" -> "护锁刃龙 α/β") from builtin/<adapter id>/<A.model_names>
-- (Wilds: armor_names.json, generated from Modding-Toolkit's mhws_armor_sets.json); nil when unknown
local armor_names = nil
local function armor_name(model)
    if armor_names == nil then
        local A = SKS.adapter
        local d = A.id and A.model_names and U.load_json(U.path("builtin", A.id, A.model_names))
        armor_names = d and type(d.models) == "table" and d.models or false
    end
    local e = armor_names and model and armor_names[model]
    return e and (I18n.lang == "en" and e.en or e.zh or e.en) or nil
end

-- "ch03_032_5012" -> "护锁刃龙 α/β", "躯干" (A.slot_names; the slot number without one); nil when
-- the model has no readable name
local function part_name(part)
    local model, slot = Presets.model_of(part)
    local name = model and armor_name(model)
    if not name then return nil end
    local sn = SKS.adapter.slot_names
    return name, sn and sn[slot] and I18n.tr(sn[slot]) or slot
end

local function part_display(part)
    local name, slot = part_name(part)
    return name and (name .. (slot and (" · " .. slot) or "")) or part
end

-- labels for a key's parts: only the slots when they all belong to one named model
local function part_labels(parts)
    local names, slots, same = {}, {}, true
    for i, p in ipairs(parts) do
        local name, slot = part_name(p)
        names[i], slots[i] = name, slot
        if not name or name ~= names[1] then same = false end
    end
    local out = {}
    for i, p in ipairs(parts) do
        if same and slots[i] then out[i] = slots[i]
        elseif names[i] then out[i] = names[i] .. (slots[i] and (" · " .. slots[i]) or "")
        else out[i] = p end
    end
    return out
end

-- where "绑定到" writes: the primary model's binding file. Returns base, model, display name, data
-- to start from (the binding in effect when it is that file)
local function bind_target()
    local b = C.binding
    if b and b.base and b.base ~= "default" and b.data then
        local model = Presets.model_of(b.base) or b.base
        return b.base, model, b.data.name or armor_name(model) or model, U.copy(b.data)
    end
    local best = Presets.primary_part(C.parts)
    if not best then return nil end
    local model = Presets.model_of(best.id) or best.id
    return Presets.binding_base(best.id), model, armor_name(model) or model, {}
end

local function build_presets_state()
    local list = {}
    for _, e in ipairs(Profile.list) do
        list[#list + 1] = { id = e.id, name = e.name, source = e.source, extends = e.extends }
    end
    state.presets.expression = list
    -- a user preset hides the mod's preset of the same name and folder (it is the one that loads);
    -- sculpt_list has user entries first
    local sc, taken = {}, {}
    for _, e in ipairs(Presets.sculpt_list) do
        local k = (e.folder or "") .. "\0" .. e.name
        if not taken[k] then taken[k] = true; sc[#sc + 1] = sculpt_entry_state(e) end
    end
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
            sculpt = d.sculpt, sculpt_found = sp ~= nil, fingerprint_ok = fp_ok,
            profile_id = d.profile, conditions = d.conditions,
        }
    else
        state.presets.binding = nil
    end
    -- "当前绑定": the name shown in the panel and where 绑定到 writes
    local base, model, display = bind_target()
    -- active: this outfit has its own binding in effect; global_default: only default.json applies
    local gd = C.binding ~= nil and C.binding.base == "default"
    state.presets.bind = base and { base = base, model = model, display = display,
                                    active = C.binding ~= nil and C.binding.base == base,
                                    global_default = gd } or nil
    state.presets.legacy = U.copy(C.legacy_bindings or {})
    state.presets.pending_delete = C.pending_delete and U.copy(C.pending_delete) or nil
    bump("presets")
end

local function build_sculpt_state()
    local sc = state.sculpt
    local keys, groups, gi = {}, {}, {}
    for i, k in ipairs(Sculpt.K.keys) do
        local o = {}
        for p, v in pairs(k.overrides) do o[p] = v end
        keys[i] = { name = k.name, label = label_of(k.name), group = k.group, parts = U.copy(k.parts), part_labels = part_labels(k.parts), value = k.value,
                    default = k.default, overrides = o, owner = k.owner,
                    locked = false, mixed = k.owner == "expression", in_preset = k.in_preset == true,
                    in_group = Sculpt.group_of(k.name) ~= nil,
                    range = { Sculpt.RANGE[1], Sculpt.RANGE[2] } }
        local g = gi[k.group]
        if not g then
            local name, slot = part_name(k.group)
            g = { key = k.group, name = name and (name .. (slot and (" · " .. slot) or "")) or k.group, key_indices = {} }
            gi[k.group] = g; groups[#groups + 1] = g
        end
        g.key_indices[#g.key_indices + 1] = i
    end
    -- two keys of one part with the same label: both show their mesh name too
    for _, g in ipairs(groups) do
        local seen = {}
        for _, i in ipairs(g.key_indices) do
            local l = keys[i].label
            if l then seen[l] = (seen[l] or 0) + 1 end
        end
        for _, i in ipairs(g.key_indices) do
            local k = keys[i]
            if k.label and seen[k.label] > 1 then k.label = I18n.f("%s（%s）", I18n.tr(k.label), k.name) end
        end
    end
    sc.keys, sc.groups = keys, groups
    -- key groups: options list their keys (missing = not on the worn parts)
    local index = {}
    for i, k in ipairs(keys) do index[k.name] = i end
    local kg = {}
    for gi2, g in ipairs(Sculpt.K.groups) do
        local options = {}
        for oi, o in ipairs(g.options) do
            local list = {}
            for n, v in pairs(o.values) do
                local k = index[n] and keys[index[n]]
                list[#list + 1] = { name = n, label = k and k.label or label_of(n), value = v,
                                    mixed = k and k.mixed or false, missing = k == nil }
            end
            table.sort(list, function(a, b) return a.name < b.name end)
            options[oi] = { name = o.name, keys = list }
        end
        kg[gi2] = { name = g.name, value = g.value, options = options }
    end
    sc.key_groups, sc.max_options = kg, Sculpt.MAX_OPTIONS
    sc.edit_mode, sc.ab_preview = C.edit_mode, C.preview
    sc.dirty = Sculpt.is_dirty()
    sc.can_undo, sc.can_redo = Sculpt.can_undo(), Sculpt.can_redo()
    sc.preset = C.sculpt_preset and sculpt_entry_state(C.sculpt_preset) or nil
    bump("sculpt")
end

-- ---------------------------------------------------------------- bindings (M2)
-- The binding in effect: the primary model's (Presets.primary_part), else default.json. Its profile
-- replaces cfg.profile while it is in effect. C.part_bindings keeps every worn part's own model
-- lookup; parts of other models only lend their mods sculpt preset as defaults (sculpt_presets_of).
local function resolve_bindings(parts)
    C.part_bindings = {}
    for _, p in ipairs(parts) do
        local r = C.part_bindings[p.id]
        if not r then
            r = Presets.resolve_binding(p.id, nil, p.fingerprint, parts)
            C.part_bindings[p.id] = r
            for _, e in ipairs(r.chain) do
                local detail = e.error or e.warning
                local key = detail and (p.id .. "|" .. e.path .. "|" .. detail)
                if key and not C.warned[key] then
                    C.warned[key] = true
                    notice("warn", I18n.f("%s：%s %s", p.id, e.path, I18n.tr(detail)))
                end
            end
        end
    end
    local primary = Presets.primary_part(parts)
    local r = primary and C.part_bindings[primary.id]
    C.binding = r and r.hit and r or nil
    C.legacy_bindings = Presets.legacy_bindings(parts)
    for _, e in ipairs(C.legacy_bindings) do
        local key = "legacy|" .. e.path
        if not C.warned[key] then
            C.warned[key] = true
            notice("warn", I18n.f("%s 是旧的部件绑定，已不再生效", e.path))
        end
    end
end

-- ---------------------------------------------------------------- tuning (M2)
-- Expression gains and the gaze settings (full_deg / invert / sets) follow the part: while a
-- binding is in effect, cfg.expression / cfg.eyes hold that part's working copy (the binding's
-- values over the settings fallback) and edits are saved into the part's user binding by
-- save_tuning. Without a binding they are the global fallback in settings.json, as in M1.
-- Scoped actor bindings also carry their eye neutral pose; other adapters keep it global.
-- gains.for_profile: channel gains were tuned for that profile; another profile ignores them.
local EYE_TUNING = { "full_deg", "invert", "sets" }

local function eyes_subset(e)
    local t = {}
    for _, k in ipairs(EYE_TUNING) do t[k] = U.copy(e[k]) end
    if SKS.adapter.scoped_bindings then t.neutral = U.copy(e.neutral) end
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
        if SKS.adapter.scoped_bindings and type(be) == "table" and type(be.neutral) == "table" then
            for side, pose in pairs(be.neutral) do
                for axis, value in pairs(pose) do eyes.neutral[side][axis] = value end
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
    if SKS.adapter.scoped_bindings then cfg.eyes.neutral = eyes.neutral end
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

local function mods_sculpt_of(part_id)
    local m = Presets.resolve_binding(part_id, "mods", fingerprint_of(part_id), C.parts)
    return m.data and m.data.sculpt and Presets.find_sculpt(m.data.sculpt, m.folder, "mods") or nil
end

-- active: the preset the character's binding names; mod: the one the primary model's mods-only
-- chain names (defaults); fill: for a part of another model, the preset its own mod names, which
-- supplies defaults only for keys neither of the others names.
-- Names are looked up in the binding's model folder first, then among the general presets.
local function sculpt_presets_of(part_id)
    local r = C.binding
    local active = r and r.data and r.data.sculpt and Presets.find_sculpt(r.data.sculpt, r.folder) or nil
    local primary = r and r.part or part_id
    local mod = mods_sculpt_of(primary)
    local fill
    if Presets.folder_of(part_id) ~= Presets.folder_of(primary) then fill = mods_sculpt_of(part_id) end
    return active, mod, fill
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
    C.resolved, C.original_resolved, C.prog, C.edits = U.copy(resolved), U.copy(resolved), prog, {}
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
    -- 节点由自动信号改为手动时，旧 V 值不能继续驱动网格；变更只在下一次 tick 写入。
    for _, rig in ipairs(C.rigs) do rig.V, rig.W = {}, {} end
    refresh_rig_params()   -- an edited node may read other raw channels
    recompute_gains()
    build_expression_state(); build_mapping_state()
    return true
end

-- ---------------------------------------------------------------- scan
local function update_coverage(parts)
    local fps = {}
    for _, p in ipairs(parts) do fps[#fps + 1] = p.id .. ":" .. p.fingerprint end
    table.sort(fps)
    C.outfit = table.concat(fps, "|")
    local key = C.outfit .. "#" .. (C.prog and C.prog.id or "")
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
    local hits = {}
    for _, e in ipairs(Profile.list) do
        local n = Profile.match_count(e.id, all, Names)
        hits[e.id] = n
        if n > best_n or (n == best_n and C.prog and e.id == C.prog.id) then best, best_n = e.id, n end
    end
    C.cov_hits = hits
    state.expression.coverage = { arkit_hit = arkit_hit, arkit_total = #Names.ARKIT52, extra = extra,
                                  recommended = (#parts > 0) and best or nil, recommended_hits = best_n }
end

-- Automatic match for an outfit without a binding profile: only when the global profile drives
-- none of the worn channels, so it never overrides a profile that works. Below 2 channels a
-- match is too likely a coincidence of generic names ("blink"); ties go to ARKit.
local AUTO_MIN_HITS = 2
local function auto_profile()
    local hits = C.cov_hits
    if not hits or C.outfit == "" then return nil end
    if (hits[cfg.profile] or 0) > 0 and Profile.registry[cfg.profile] then return nil end
    local best, best_n = nil, AUTO_MIN_HITS - 1
    for _, e in ipairs(Profile.list) do
        local n = hits[e.id] or 0
        if n > best_n or (n == best_n and e.id == "arkit") then best, best_n = e.id, n end
    end
    return best
end

-- a profile picked by hand; `outfit` keeps automatic matching off while those parts stay worn
local function mark_manual(id)
    C.profile_manual = { id = id, hit = C.binding and C.binding.hit or nil, outfit = C.outfit }
end

-- hash -> name for engines that only keep channel-name hashes: every name SKS knows (ARKit, the
-- alias tables, every profile's channels and "any" lists, sculpt preset and condition clip keys)
-- plus the user / mod name tables. Rebuilt when one of those lists was reloaded.
local function known_names()
    local key = tostring(Profile.list) .. tostring(Presets.sculpt_list) .. tostring(Names.alias_sets) .. tostring(CondExpr.list) .. tostring(Labels.names)
    if C.known and C.known_key == key then return C.known end
    local list = {}
    local function add(n) if type(n) == "string" and n ~= "" and n:sub(1, 1) ~= "#" then list[#list + 1] = n end end
    local function add_keys(t) for k in pairs(type(t) == "table" and t or {}) do add(k) end end
    for _, n in ipairs(Names.ARKIT52) do add(n) end
    for _, n in ipairs(Names.alias_names) do add(n) end
    for _, e in ipairs(Profile.list) do
        for _, ch in ipairs(e.data and e.data.channels or {}) do
            if type(ch) == "table" then
                add(ch.name)
                for _, a in ipairs(type(ch.any) == "table" and ch.any or {}) do add(a) end
            end
        end
    end
    for _, e in ipairs(Presets.sculpt_list) do
        add_keys(e.values)
        for _, o in pairs(e.overrides or {}) do add_keys(o) end
    end
    for _, e in ipairs(CondExpr.list) do
        for _, c in pairs(e.data and e.data.clips or {}) do add_keys(c.values) end
    end
    for _, n in ipairs(NameHash.table_names()) do add(n) end
    for _, n in ipairs(Labels.names) do add(n) end
    C.known, C.known_key = NameHash.table(list), key
    return C.known
end

local function scan_full()
    local scan_start = clock()
    if not C.prog then return end
    local res = Scene.scan({ index = C.index, scene_search = C.preview_open or C.menu or cfg.scene_search_always or C.cs_scene_search, min_hits = 3,
                             known = (not Writer.M_CNAME or SKS.adapter.hash_names) and known_names() or nil })
    if cfg.enabled and SKS.adapter.prepare_parts then SKS.adapter.prepare_parts(res.instances or res.parts) end
    -- the same mesh found again keeps its warm-up count and last written values, so periodic
    -- rescans neither pause writing nor rewrite every channel. A mesh that was dropped keeps only
    -- its warm-up: every channel is written again.
    local old, warm = {}, C.warm or {}
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do if t.addr then old[t.addr] = t end end
    end
    for _, r in ipairs(res.rigs) do
        for _, t in ipairs(r.targets) do
            local o = t.addr and (old[t.addr] or warm[t.addr])
            if o then
                t.stable, t.ready = o.stable, o.ready
                if o.count == t.count and o.layout == t.layout then t.last = o.last end
            end
        end
    end
    old, C.warm = nil, nil
    C.rigs, C.parts, C.sig, C.mesh_name_of = res.rigs, res.parts, res.sig, res.mesh_name_of
    C.instances = res.instances or res.parts
    refresh_rig_params()
    -- menus spawn their preview hunters late: look again every 3 s there
    C.next_periodic = C.frame + (C.menu and MENU_SCAN_FRAMES or max(1, cfg.periodic_scan_sec) * 60)
    prof.scan = prof.scan + res.ms / 1000
    local sc = state.scene
    sc.last_scan = { time = os.time(), ms = res.ms, faces = res.faces, cached_skip = res.skipped, preview = C.preview_open }
    local rigs = {}
    for i, r in ipairs(res.rigs) do
        local ts = {}
        for j, t in ipairs(r.targets) do
            ts[j] = { name = t.name, display = part_display(t.name), channels = t.distinct, writes = t.count }
        end
        rigs[i] = { label = r.label, primary = r.primary, targets = ts, reads = r.n_reads }
    end
    sc.rigs = rigs
    build_procedural_state()
    resolve_bindings(res.parts)
    local parts = {}
    for i, p in ipairs(res.parts) do
        local r = C.part_bindings[p.id]
        parts[i] = { id = p.id, display = part_display(p.id), slot = nil, channels = p.n, fingerprint = p.fingerprint, binding = r and r.hit or nil,
                     weights = p.weights }
    end
    sc.parts = parts
    update_coverage(res.parts)
    -- a parent preset picks the expression profile while its part is worn
    local b = C.binding
    local want = b and b.data and b.data.profile
    local man = C.profile_manual
    -- other parts / preset. A scan that finds no binding (loading, menus, an equipment rebuild in
    -- progress) keeps the user's choice: only a different binding replaces it.
    if man and b and man.hit ~= b.hit then C.profile_manual, man = nil, nil end
    if man and want and Profile.registry[man.id] then want = nil end                     -- the user's choice stands
    if want and not Profile.registry[want] then
        if C.missing_profile ~= want then
            C.missing_profile = want
            notice("warn", I18n.f("绑定 %s 指定的表情配置 %s 不存在", tostring(b.hit), want))
        end
        want = nil
    end
    state.expression.binding_source = want and b.hit or nil
    -- without one, an outfit the global profile cannot drive gets the best matching profile, unless
    -- the user picked a profile for these parts. A scan without parts (loading, menus) keeps it.
    local auto
    if not want and not (man and man.outfit == C.outfit) then
        auto = auto_profile()
        if not auto and C.outfit == "" and C.auto_profile == C.prog.id then auto = C.auto_profile end
    end
    local pick = want or auto
    -- 未保存的映射修改优先：换装或绑定不切换配置，提示一次，保存或恢复后下次扫描再切换。
    local switch = (pick and pick ~= C.prog.id) or
        (not pick and C.profile_override and C.prog.id ~= cfg.profile and Profile.registry[cfg.profile])
    if switch and state.mapping.dirty then
        if want and not C.unsaved_switch_noticed then
            C.unsaved_switch_noticed = true
            notice("warn", "映射修改未保存，暂不切换到绑定的表情配置：先保存或恢复配置")
        end
        pick, auto = nil, nil
    elseif not state.mapping.dirty then
        C.unsaved_switch_noticed = nil
    end
    C.auto_profile = auto
    state.expression.auto_source = auto ~= nil or nil
    -- C.profile_override: the profile in effect came from a binding or the automatic match, not cfg.profile
    if pick and pick ~= C.prog.id then
        if apply_profile(pick, false) then
            C.profile_override = true
            if want then log("profile %s from %s", want, b.hit) else log("profile %s matched automatically", auto) end
            return
        end
    elseif not pick and not state.mapping.dirty and C.profile_override and C.prog.id ~= cfg.profile and Profile.registry[cfg.profile] then
        C.profile_override = false
        if apply_profile(cfg.profile, false) then return end
    end
    if pick then C.profile_override = true end
    apply_tuning(false)
    C.select_conditions()
    rebuild_sculpt()
    build_presets_state()
    bump("scene")
    build_expression_state()
    local tn = {}
    for _, r in ipairs(rigs) do
        local t = {}
        for _, x in ipairs(r.targets) do t[#t + 1] = x.name .. ":" .. x.channels end
        tn[#tn + 1] = (r.primary and "*" or "") .. r.label .. "[" .. table.concat(t, ",") .. "]"
    end
    state.debug.status = string.format("faces=%d (cached-skip %d)%s%s driven=%s  chars=%s  scan %.2f ms", res.faces, res.skipped,
        C.preview_open and " [preview]" or "", C.menu and " [menu]" or "", #tn > 0 and table.concat(tn, "  ") or "none",
        (res.parents and #res.parents > 0) and table.concat(res.parents, " ") or "none", res.ms)
    -- the primary character's parts whenever they change, so a part that later vanishes can be
    -- told apart from one that was never there
    if res.sig ~= C.parts_logged then
        C.parts_logged = res.sig
        Trail.event("primary parts: %s", res.sig ~= "" and (res.sig:gsub("|", " ")) or "none")
    end
    Trail.event("scan: %s", state.debug.status)
    C.fire("scan")
    Perf.record("scan", clock() - scan_start)
end

local function root_address(root)
    local ok, addr = pcall(function() return root:get_address() end)
    return ok and addr or nil
end

local function do_scan()
    local A = SKS.adapter
    if not C.prog then return end
    if A.inspect_before_scan and not C.scan_force and #C.rigs > 0 then
        local root = Scene.primary_root()
        local addr = root_address(root)
        local same = addr ~= nil and addr == C.scan_root_addr and Scene.children_signature(root) == C.sig
        if same and cfg.enabled and A.prepare_parts then A.prepare_parts(C.instances) end
        if same then
            C.next_periodic_at = clock() + (C.menu and 3 or max(1, cfg.periodic_scan_sec))
            return
        end
    end
    C.scan_force = false
    local ok, err = pcall(scan_full)
    if not ok then C.scan_force = true; error(err) end
    local root = Scene.primary_root()
    C.scan_root_addr = root_address(root)
    C.next_periodic_at = clock() + (C.menu and 3 or max(1, cfg.periodic_scan_sec))
end

-- ---------------------------------------------------------------- per frame
local function prof_flush()
    local n = prof.frames
    if n < prof.window then return end
    local a = state.debug.perf
    a.read, a.compute, a.write, a.scan = prof.read / n * 1000, prof.compute / n * 1000, prof.write / n * 1000, prof.scan / n * 1000
    a.stages = a.read + a.compute + a.write + a.scan
    a.total = Perf.metrics.tick and Perf.metrics.tick.avg or 0
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
    if primary then Mocap.drive_signals(rig, P, cfg.eyes.full_deg.yaw, cfg.eyes.full_deg.pitch) end
    -- 播放、循环和跳转改变 `Playback.epoch`，主角色不得沿用此前的平滑缓存。
    if rig.primary and rig.playback_epoch ~= Playback.epoch then
        rig.W, rig.V, rig.playback_epoch = {}, {}, Playback.epoch
    end
    -- panel gaze drag: both eyes look at the held angle instead of following the game
    Proc.apply_gaze(rig)
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
    Playback.apply(rig, P, C.inv_full, cfg.eyes)
    local s = cfg.expression.smoothing
    local alpha = (s > 0) and (1 - min(s, 1) * 0.9) or 1
    X.compute(prog, rig, P, C.gains, C.forced, cfg.clamp, alpha, cfg.eyes.full_deg.yaw, cfg.eyes.full_deg.pitch)
    -- conditional clips and other plugins change a copy of the expression weights: rig.W is also
    -- the smoothing state of the next frame and must stay the pure expression
    local out, ext_skip = rig.W, nil
    local expr_on = cfg.expression_enabled ~= false
    local cond_on = rig.primary and C.cond_live and CondExpr.any()
    local touch_on = Touch.any()
    if not expr_on or cond_on or touch_on or Ext.any() then
        out = rig.O or {}
        rig.O = out
        local Wt = rig.W
        for s = 1, prog.n do out[s] = expr_on and Wt[s] or 0 end
        if cond_on then CondExpr.apply(prog, C.resolve_slot, out) end
        if touch_on then Touch.apply(prog, C.resolve_slot, out) end
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
            for i, sd in ipairs(Profile.signals.list) do
                sig[i] = sd.key ~= nil and ((C.P[sd.key] or 0) * sd.a + sd.b) or 0
            end
        end
    end
end

-- ---------------------------------------------------------------- experimental cutscene mode
-- While a cutscene plays (IsBusy, not IsBusyLoad) and cfg.cutscene_drive is on, the hunter is
-- driven like in gameplay. Segment boundaries come from the adapter events (MH Wilds hooks):
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

-- a non-primary rig (preview / save select / cutscene character) whose parent's children changed:
-- its parts are being rebuilt or torn down
local function parents_changed()
    for _, r in ipairs(C.rigs) do
        if not r.primary and r.parent then
            local ok, sig = pcall(Scene.runtime_signature, r.parent)
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

-- segment bookkeeping for the cutscene mode: when to rescan for the cutscene copy
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

-- a mocap channel reaches the hunter: its expression slot drives a mesh key on the primary rig,
-- or a sculpt key carries its name (External.for_key matches those by normalised name)
local function mocap_reaches(name, slot)
    local r = C.rigs[1]
    if slot and r then
        for _, t in ipairs(r.targets) do
            for k = 1, t.count do if t.slots[k] == slot then return true end end
        end
    end
    local n = Ext.norm(name)
    for _, k in ipairs(Sculpt.K.keys) do
        if k.owner ~= "expression" and Ext.norm(k.name) == n then return true end
    end
    return false
end
C.mocap_ctx = { resolve = function(name) return C.resolve_slot(name) end, reaches = mocap_reaches,
                expr = live.weight }

-- Collects the characters again; the edited one's faces become the primary scan
local function refresh_actors()
    local changed = Actors.refresh(armor_name)
    Scene.override = Actors.override()
    Drivers.current_actor, Drivers.default_actor = Actors.selected, Actors.player
    local a = state.actors
    a.list, a.selected, a.wanted, a.player_id, a.enabled = Actors.list, Actors.selected, Actors.wanted, Actors.player, true
    bump("actors")
    if changed then request_rescan(1) end
end

local function tick()
    Playback.tick(false)
    C.frame = C.frame + 1
    local f = C.frame
    if Ext.expire() then Sculpt.mark_dynamic(); C.build_external_state() end
    local now = clock()
    local dt = min(now - (C.last_tick or now), 0.1)
    C.last_tick = now
    local ext_rev = Ext.rev
    local mc = C.mocap_ctx
    mc.prog, mc.gen = C.prog, state.scene.rev
    -- mocap first: a key it holds this tick is left alone by the drivers
    local held_changed = Mocap.tick(dt, mc)
    if Drivers.tick(dt, Sculpt.RANGE[2], SKS.adapter.channel_writable) then held_changed = true end
    if held_changed then
        Sculpt.mark_dynamic()
        if Ext.rev ~= ext_rev then C.build_external_state() end
    end
    Sculpt.frame = f
    -- The gate pauses nothing: loading, rebuilds and cutscenes keep driving whatever rigs exist.
    -- Its kind only picks who is driven: "playing" searches the scene for the cutscene copy,
    -- "setup" (title / save select) drives the preview hunters.
    local stable, why, kind = Guard.game_stable(f, cfg.cutscene_drive)
    if SKS.adapter.strict_bounds and #(C.instances or {}) > 0
        and Scene.runtime_signature(Scene.primary_root()) ~= C.sig then
        drop_rigs("part signature changed", QUICK_RESCAN)
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
    local cutscene = (not stable) and kind == "playing" and cfg.cutscene_drive
    if cutscene then
        -- a load finished: a new segment starts, whatever the hooks said before
        if prev_kind == "load" and CS.active then
            Trail.event("cutscene load -> playing: new segment")
            CS.seg, CS.seg_t0, CS.released, CS.scanned = "?", f, false, false
            drop_rigs("cutscene loaded", nil)
            C.scan_at = {}
        end
        cutscene_gate(f)
        state.debug.status = "cutscene: " .. CS.status
    elseif CS.active then
        cs_end()
        drop_rigs("cutscene over", QUICK_RESCAN)
    end
    -- the recorder follows the driven face; in a cutscene between segments there is none yet
    -- (rigs are dropped at each segment start), so the take waits instead of ending
    local face = C.rigs[1] and C.rigs[1].face
    NativeSignals.tick(SKS.adapter, (face or not cutscene) and true or "hold", { face = face })
    if Actors.enabled() and f >= (C.actors_at or 0) then
        C.actors_at = f + 60
        refresh_actors()
    end
    local fallback_expression, fallback_eyes = fallback_tuning()
    ActorInstances.tick(f, { enabled = cfg.enabled, cutscene_drive = cfg.cutscene_drive,
        profile = cfg.profile, expression = fallback_expression, eyes = fallback_eyes,
        expression_enabled = cfg.expression_enabled,
        inv_full = C.inv_full, clamp = cfg.clamp, epsilon = cfg.write_epsilon, known = known_names() })
    -- menu mode (player not set up: title screen, save select, loading) drives whatever hunters
    -- the scene holds; entering or leaving it lets go of everything (the player is being built)
    if menu ~= C.menu then
        C.menu = menu
        Trail.event(menu and "menu mode on" or "menu mode off")
        drop_rigs(menu and "menu mode" or "player set up", nil)
        C.scan_at = {}
        request_rescan(Guard.SETTLE_FRAMES)
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
    if #C.pending_zero > 0 then
        for _, t in ipairs(C.pending_zero) do
            if t.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(t.mesh) then Writer.zero_target(t) end
        end
        C.pending_zero = {}
    end
    -- parts changed (load screen, equipment): stop touching the old meshes at once
    local now_sig = (f % 5 == 0 and #C.rigs > 0) and Scene.runtime_signature(Scene.primary_root()) or nil
    if now_sig and now_sig ~= C.sig then
        drop_rigs("hunter parts changed (" .. Scene.signature_diff(C.sig, now_sig) .. ")", QUICK_RESCAN)
    elseif f % 30 == 15 and #C.rigs > 0 and parents_changed() then
        drop_rigs("preview hunter changed", QUICK_RESCAN)
    elseif f % 30 == 0 and #C.rigs == 0 and #C.scan_at == 0 and Scene.runtime_signature(Scene.primary_root()) ~= C.sig then
        request_rescan(Guard.SETTLE_FRAMES)
    end
    local due = false
    for i = #C.scan_at, 1, -1 do
        if f >= C.scan_at[i] then due = true; table.remove(C.scan_at, i) end
    end
    local periodic = SKS.adapter.inspect_before_scan and now >= (C.next_periodic_at or 0)
        or not SKS.adapter.inspect_before_scan and f >= C.next_periodic
    if due or ((C.menu or cfg.periodic_scan_sec > 0) and periodic) then
        if C.scan_after_frame and f < C.scan_after_frame then
            C.scan_at = {C.scan_after_frame}
        else C.scan_after_frame = nil; do_scan() end
    end
    if C.probe_pending then
        C.probe_pending = false
        local probe = SKS.adapter.probe
        state.debug.probe = probe and probe("ShapeKeySystem\\hash_probe.txt") or { "no probe for this game" }
        bump("debug")
    end

    -- conditional expressions: master hunter in gameplay only
    C.cond_live = not C.menu and (CondExpr.current ~= nil or state.runtime.ui_open)
    if C.cond_live then Cnd.sample(f) end
    if CondExpr.update(C.cond_live and CondExpr.current ~= nil) then Sculpt.mark_dynamic() end
    if Touch.update() then Sculpt.mark_dynamic() end
    if state.runtime.ui_open then C.update_cond_live() end
    local lp = live.procedural
    lp.blink = Proc.tick(clock(), f)
    lp.mouth = Proc.out.jawOpen or 0
    lp.gaze[1], lp.gaze[2] = Proc.gaze[1], Proc.gaze[2]
    if cfg.enabled and C.prog then
        -- the head turn after the next UpdateMotion may touch the master player only if this
        -- tick drove it (drop_rigs clears the mark)
        local r1 = C.rigs[1]
        C.driven_frame = (r1 and r1.primary) and f or nil
        C.held_frame = f
        -- while the face bones' neutral pose is captured fcParam reads 0: the meshes keep last
        -- frame's weights instead
        if not FaceHold.capturing() then
            for i, rig in ipairs(C.rigs) do
                local ok, err = pcall(drive, rig, i == 1)
                if not ok or err then
                    drop_rigs(string.format("%s: %s", rig.label, tostring(err)), QUICK_RESCAN)
                    break
                end
            end
        end
        update_live()
    end
    -- sculpt layer: lazy static weights on the channels the profile does not drive
    if cfg.enabled and #Sculpt.K.targets > 0 then
        local t0 = clock()
        local ok, w, err = pcall(Sculpt.tick, C.edit_mode, C.preview, cfg.write_epsilon)
        if not ok or err then
            drop_rigs("sculpt: " .. tostring(ok and err or w), QUICK_RESCAN)
        else
            prof.writes = prof.writes + w
        end
        prof.write = prof.write + (clock() - t0)
    end
    if C.save_at and f >= C.save_at then save_now() end
end

local function update_hold()
    local want = cfg.enabled and cfg.hold_face_bones and C.held_frame and C.held_frame == C.frame
    if want then
        local faces = {}
        for _, rig in ipairs(C.rigs) do faces[#faces + 1] = rig.face end
        FaceHold.update(SKS.adapter, faces)
    elseif FaceHold.active() then
        FaceHold.release()
    end
    if state.settings.hold_status ~= FaceHold.status then build_settings_state() end
end

-- re.on_application_entry("UpdateMotion"): face bone hold on every driven rig, mocap head turn on
-- the master player
function SKS.update_motion()
    local ok, err = pcall(update_hold)
    if not ok then
        FaceHold.release()
        FaceHold.status = I18n.f("禁用骨骼表情出错：%s", tostring(err))
    end
    if not (C.driven_frame and C.driven_frame == C.frame and Mocap.wants_head()) then return end
    Mocap.update_motion(Scene.primary_root(), Writer.M_JBN)
end

-- 计时覆盖提前返回和延迟保存；游戏动画回调与面板绘制另行计量。
function SKS.tick()
    local started = clock()
    tick()
    Perf.record("tick", clock() - started)
    prof.frames = prof.frames + 1
    prof_flush()
end

-- ---------------------------------------------------------------- commands
local cmds = {}

function cmds.native_signals(a)
    return NativeSignals.command(SKS.adapter, a)
end

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
    if not a.on then Playback.request("stop") end
    if not a.on then queue_zero_all(); zero_sculpt(); FaceHold.release() else Sculpt.mark_dirty(); request_rescan(1) end
    build_settings_state(); save_soon()
    return true
end

-- 绘制回调只提交播放命令，引擎操作由更新回调执行。
function cmds.playback(a)
    if a.action == "play" and not cfg.enabled then return false, "E_BAD_ARGS", "请先启用 ShapeKeySystem" end
    return Playback.request(a.action, a)
end

local SETTING_TYPES = {
    hotkey = "string", language = "string", ui_scale = { 0.5, 3 },
    scene_search_always = "boolean", periodic_scan_sec = { 0, 120 }, write_epsilon = { 0, 0.05 },
    clamp = "boolean", window = "table", advanced = "boolean",
    cutscene_drive = "boolean", sculpt_max = { 1, Sculpt.MAX_LIMIT }, face_style = "string",
    ui_backend = "string", translate_keys = "boolean",
    expression_enabled = "boolean", hold_face_bones = "boolean",
    font_scale = { 0.8, 1.6 }, block_input = "boolean",
    hotkey_combo = "boolean", hotkey_mod = "string",
}
local HOTKEY_MODS = { Ctrl = true, Shift = true, Alt = true }
local UI_BACKENDS = { auto = true, d2d = true, imgui = true }
function cmds.set_setting(a)
    local t = SETTING_TYPES[a.key]
    if not t then return false, "E_BAD_ARGS", "unknown setting: " .. tostring(a.key) end
    local v = a.value
    if type(t) == "table" then
        v = num(v, t[1], t[2]); if not v then return false, "E_BAD_ARGS", "number expected" end
    elseif type(v) ~= t then
        return false, "E_BAD_ARGS", t .. " expected"
    end
    if a.key == "hotkey_mod" and not HOTKEY_MODS[v] then return false, "E_BAD_ARGS", "hotkey_mod: Ctrl / Shift / Alt" end
    if a.key == "ui_backend" and not UI_BACKENDS[v] then return false, "E_BAD_ARGS", "ui_backend: auto / d2d / imgui" end
    if a.key == "language" and not I18n.set(v) then return false, "E_BAD_ARGS", "language: zh / en" end
    if a.key == "window" then v = { x = tonumber(v.x) or 0, y = tonumber(v.y) or 0, w = tonumber(v.w) or 900, h = tonumber(v.h) or 640 } end
    cfg[a.key] = v
    if a.key == "scene_search_always" or a.key == "periodic_scan_sec" then request_rescan(1) end
    if a.key == "sculpt_max" then cfg.sculpt_max = Sculpt.set_max(v); build_sculpt_state() end
    if a.key == "hold_face_bones" and not v then FaceHold.release(); FaceHold.status = "" end
    if a.key == "translate_keys" or a.key == "language" then
        build_sculpt_state(); build_expression_state()   -- the expression build refreshes a preview too
    end
    build_settings_state(); save_soon()
    return true
end

function cmds.rescan()
    Scene.clear_channel_cache()
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

-- 「自动匹配」: the profile with the most channels on the worn parts (coverage.recommended); scans
-- switch on their own only when the global profile drives none of them (auto_profile)
function cmds.auto_match_profile()
    local cov = state.expression.coverage
    local id = cov and cov.recommended
    if not id or (cov.recommended_hits or 0) <= 0 then return false, "E_NOT_FOUND", "当前部件没有能匹配的表情配置" end
    if C.prog and id == C.prog.id then return true, nil, nil, { id = id, changed = false } end
    local ok, code, msg = cmds.set_profile({ id = id })
    if not ok then return false, code, msg end
    notice("info", I18n.f("已切换到匹配度最高的表情配置：%s", C.prog.name))
    return true, nil, nil, { id = id, changed = true }
end

function cmds.set_profile(a)
    if not Profile.registry[a.id] then return false, "E_NOT_FOUND", "profile not found: " .. tostring(a.id) end
    if state.mapping.dirty and not a.discard then return false, "E_UNSAVED", "映射尚未保存，请先保存或恢复配置" end
    local ok, code, msg = apply_profile(a.id, false)
    if not ok then return false, code, msg end
    cfg.profile = a.id; save_soon()
    -- a choice made by hand wins over the parent preset's profile while that preset stays in effect
    -- (before, the rescan after apply_profile switched straight back to the preset's profile)
    mark_manual(a.id)
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

-- patch = { enabled, mode, frequency, speed, blink = { interval_min, ... } }; unknown keys are ignored
-- face mocap (Mocap.lua): settings patch; user/mocap.json is written shortly after, unless only
-- the test pose moved
function cmds.mocap(a)
    local ok, err, msg = Mocap.patch(a.patch)
    if not ok then return ok, err, msg end
    local p = a.patch
    if next(p) ~= "test" or next(p, "test") ~= nil then Mocap.save_soon() end
    return true
end

-- look up this PC's LAN IPs again (state.mocap.native.ips, shown in the 基础配置 box)
function cmds.mocap_refresh_ips()
    Mocap.refresh_ips()
    return true
end

-- what = "face" (neutral face from the current frame) / "head" (straight-ahead head) / "clear"
function cmds.mocap_calibrate(a)
    if a.what == "face" then Mocap.calibrate_face()
    elseif a.what == "head" then Mocap.calibrate_head()
    elseif a.what == "clear" then Mocap.cfg.neutral = {}
    else return false, "E_BAD_ARGS", "what: face / head / clear" end
    if not Mocap.save() then return false, "E_IO", "mocap.json save failed" end
    return true
end

-- face mirror (adapter.face_mirror, MH Wilds only): settings patch; user/face_mirror.json is written
-- shortly after
function cmds.face_mirror(a)
    local F = SKS.adapter.face_mirror
    if not F then return false, "E_BAD_ARGS", "this game has no face mirror" end
    local ok, err, msg = F.patch(a.patch)
    if not ok then return ok, err, msg end
    F.save_soon()
    return true
end

-- what = "aim" (aim at the anchor joint itself) / "rig" (current joint's defaults) / "all"
function cmds.face_mirror_reset(a)
    local F = SKS.adapter.face_mirror
    if not F then return false, "E_BAD_ARGS", "this game has no face mirror" end
    local ok, err, msg = F.reset(a.what)
    if not ok then return ok, err, msg end
    F.save_soon()
    return true
end

-- character to edit (Actors.lua): id from state.actors.list. Refused while sculpt, mapping or
-- tuning edits are unsaved: they belong to the character being edited now.
function cmds.select_actor(a)
    if not Actors.enabled() then return false, "E_BAD_ARGS", "this game has one character" end
    if type(a.id) ~= "string" or not Actors.has(a.id) then return false, "E_NOT_FOUND", "no such character" end
    if a.id == Actors.selected then Actors.wanted = a.id; return true end
    if Sculpt.is_dirty() or state.mapping.dirty or (C.tuning and C.tuning.dirty) then
        return false, "E_UNSAVED", "当前角色有未保存的修改，请先保存或撤销"
    end
    Actors.wanted = a.id
    Trail.event("edit character %s", a.id)
    drop_rigs("character switched", QUICK_RESCAN)
    refresh_actors()
    return true
end

-- shape key drivers (Drivers.lua): add / remove / patch; user/drivers.json is written shortly after
function cmds.drivers(a)
    return Drivers.command(a)
end

function cmds.set_procedural(a)
    local p = a.patch
    if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
    if p.mode ~= nil and not Proc.MODE_NAMES[p.mode] then return false, "E_BAD_ARGS", "mode: game / fallback / add" end
    if p.enabled ~= nil and type(p.enabled) ~= "boolean" then return false, "E_BAD_ARGS", "enabled must be boolean" end
    local c = cfg.procedural
    -- validate everything before changing anything
    local writes, switched = {}, p.enabled ~= nil or p.mode ~= nil
    for grp, limits in pairs(Proc.LIMITS) do
        local src, dst = p, c
        if grp ~= "top" then
            src, dst = type(p[grp]) == "table" and p[grp] or {}, c[grp]
            if src.enabled ~= nil then
                if type(src.enabled) ~= "boolean" then return false, "E_BAD_ARGS", grp .. ".enabled must be boolean" end
                writes[#writes + 1] = { dst, "enabled", src.enabled }
                switched = true
            end
        end
        for k, lim in pairs(limits) do
            if src[k] ~= nil then
                local v = num(src[k], lim[1], lim[2])
                if not v then return false, "E_BAD_ARGS", k .. ": number expected" end
                writes[#writes + 1] = { dst, k, v }
            end
        end
    end
    if p.enabled ~= nil then c.enabled = p.enabled end
    if p.mode ~= nil then c.mode = p.mode end
    for _, w in ipairs(writes) do w[1][w[2]] = w[3] end
    -- the schedules restart on a switch; slider drags keep a motion in progress
    if switched then Proc.reset() else Proc.retime() end
    build_procedural_state(); save_soon()
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
    build_eyes_state()
    if SKS.adapter.scoped_bindings then tuning_changed() else save_soon() end
    return true
end

-- mapping
-- 结构变更先完整编译，成功才替换运行配置；旧写入目标仅在 tick 清零并重新扫描。
local function replace_mapping(resolved)
    local prog, code, msg = Profile.compile(resolved, {})
    if not prog then return false, code, msg end
    queue_zero_all()
    C.resolved, C.prog, C.edits = resolved, prog, {}
    local names = {}
    for i, c in ipairs(prog.channels) do names[i] = c.name end
    C.index = Names.build_index(names, resolved.aliases, resolved.channels)
    C.rigs, C.mesh_name_of, C.forced, C.cov_key = {}, {}, {}, nil
    live.weight = {}
    recompute_gains()
    build_expression_state(); build_mapping_state()
    request_rescan(1)
    return true
end

-- 页面提交一个完整映射；保留未编辑的元数据，不改变磁盘上的内置或 mod 配置。
function cmds.set_mapping(a)
    if not C.resolved then return false, "E_NOT_FOUND", "no profile" end
    local e = a.entry
    if type(e) ~= "table" or type(e.name) ~= "string" or e.name:match("^%s*$") then
        return false, "E_BAD_ARGS", "形态键名称不能为空"
    end
    local group_ok = false
    for _, g in ipairs(X.GROUPS) do if g.key == e.group then group_ok = true end end
    local slot = slot_of(e.name)
    if slot and C.prog.channels[slot].group == e.group then group_ok = true end
    if not group_ok then return false, "E_BAD_ARGS", "未知的面部类型" end
    if a.create and slot_of(e.name) then return false, "E_EXISTS", "该形态键已有映射，请展开编辑" end
    if a.create and Names.match(C.index, e.name) then return false, "E_EXISTS", "该网格名称已匹配另一条映射，请编辑已有映射" end
    if not a.create and not slot_of(e.name) then return false, "E_NOT_FOUND", "unknown channel" end
    local data = Profile.to_json(C.resolved, C.edits, C.prog.id, C.prog.name)
    local candidate = U.copy(C.resolved)
    candidate.channels = data.channels
    for i, other in ipairs(candidate.channels) do
        if other.name ~= e.name and U.norm(other.name) == U.norm(e.name) then
            return false, "E_EXISTS", I18n.f("存在名称匹配冲突：%s", other.name)
        end
        if other.name == e.name then candidate.channels[i] = U.copy(e) end
    end
    if a.create then candidate.channels[#candidate.channels + 1] = U.copy(e) end
    return replace_mapping(candidate)
end

-- 删除会编译校验引用关系；仍被其他映射引用时拒绝，运行中的配置保持原样。
function cmds.remove_mapping(a)
    if not slot_of(a.name) then return false, "E_NOT_FOUND", "unknown channel" end
    local candidate = U.copy(C.resolved)
    candidate.channels = Profile.to_json(C.resolved, C.edits, C.prog.id, C.prog.name).channels
    for i, e in ipairs(candidate.channels) do if e.name == a.name then table.remove(candidate.channels, i); break end end
    return replace_mapping(candidate)
end

-- 恢复整个配置到加载时的版本，包含被删除的通道；不读写任何玩家文件。
function cmds.revert_mappings()
    if not C.original_resolved then return false, "E_NOT_FOUND", "no profile" end
    return replace_mapping(U.copy(C.original_resolved))
end

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
    local original
    for _, e in ipairs(C.original_resolved.channels) do if e.name == a.name then original = e; break end end
    edits[a.name] = original and Profile.node_of(original) or {}
    return recompile(edits)
end

-- 创建独立的空白用户配置；先校验重名和未保存修改，旧网格权重仅在 tick 清零。
function cmds.create_profile(a)
    if state.mapping.dirty then return false, "E_UNSAVED", "映射尚未保存，请先保存或恢复配置" end
    if type(a.name) ~= "string" then return false, "E_BAD_ARGS", "配置名称不能为空" end
    local id = U.safe_id(a.name)
    if id == "" or id == "." or id == ".." or id:match("[%.%s]$") then
        return false, "E_BAD_ARGS", "配置名称不能为空或以点结尾"
    end
    if Profile.registry[id] then return false, "E_EXISTS", "配置名称已存在，请使用新的名称" end
    local data = { schema = "sks.profile/1", id = id, name = a.name, aliases = {}, channels = {} }
    if not U.save_json(U.path("user", "profiles", id .. ".json"), data) then
        return false, "E_IO", "write failed"
    end
    Profile.load_all()
    build_presets_state()
    local ok, code, msg = apply_profile(id, false)
    if not ok then return false, code, msg end
    cfg.profile = id; save_soon()
    mark_manual(id)
    notice("info", I18n.f("已新建表情配置：%s", a.name))
    return true, nil, nil, { id = id }
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
    if id == "." or id == ".." or id:match("[%.%s]$") then return false, "E_BAD_ARGS", "配置名称不能以点或空白结尾" end
    local existing = Profile.registry[id]
    if existing and (existing.source ~= "user" or id ~= prog.id) then
        return false, "E_EXISTS", "配置名称已存在，请使用新的名称"
    end
    local data = Profile.to_json(C.resolved, C.edits, id, name)
    local path = existing and existing.source == "user" and existing.path or U.path("user", "profiles", id .. ".json")
    if not U.save_json(path, data) then
        return false, "E_IO", "write failed"
    end
    Profile.load_all()
    build_presets_state()
    local ok, code, msg = apply_profile(id, true)
    if not ok then return false, code, msg end
    cfg.profile = id; save_soon()
    mark_manual(id)
    notice("info", I18n.f("已保存表情配置：%s", name))
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

-- ---------------------------------------------------------------- key groups (Sculpt.lua)
-- `group` is a key group's name or its 1-based index; `option` a 1-based option index.
local function group_ref(v)
    if type(v) == "string" and v ~= "" then return v end
    if math.type(v) == "integer" then return v end
    return nil
end

local function name_arg(v)
    local t = type(v) == "string" and v:match("^%s*(.-)%s*$") or ""
    return t ~= "" and t or nil
end

-- runs a Sculpt key group edit for the commands below
local function group_cmd(fn, ...)
    local ok, code, msg = scanned(); if not ok then return false, code, msg end
    local r1, r2, r3, r4 = fn(...)
    if not r1 then
        if r2 == "E_CONFLICT" then
            return false, r2, I18n.f("形态键 %s 已在键组「%s」里，不同键组不能共用形态键", tostring(r3), tostring(r4))
        end
        return false, r2, r3
    end
    build_sculpt_state()
    return true, nil, nil, r2 ~= nil and { option = r2 } or nil
end

function cmds.key_group_new(a)
    local name = name_arg(a.name)
    if not name then return false, "E_BAD_ARGS", "name required" end
    return group_cmd(Sculpt.group_new, name)
end

function cmds.key_group_rename(a)
    local g, name = group_ref(a.group), name_arg(a.name)
    if not g or not name then return false, "E_BAD_ARGS", "group and name required" end
    return group_cmd(Sculpt.group_rename, g, name)
end

function cmds.key_group_delete(a)
    local g = group_ref(a.group)
    if not g then return false, "E_BAD_ARGS", "group required" end
    return group_cmd(Sculpt.group_delete, g)
end

-- {group, value}: 0 = off, n = option n. Conditions and drivers will switch groups through this.
function cmds.key_group_set(a)
    local g = group_ref(a.group)
    local v = type(a.value) == "number" and math.tointeger(a.value) or nil
    if not g or not v then return false, "E_BAD_ARGS", "group and an integer value required" end
    return group_cmd(Sculpt.group_set, g, v)
end

function cmds.key_group_option_add(a)
    local g, name = group_ref(a.group), name_arg(a.name)
    if not g or not name then return false, "E_BAD_ARGS", "group and name required" end
    return group_cmd(Sculpt.option_add, g, name)
end

function cmds.key_group_option_rename(a)
    local g, name = group_ref(a.group), name_arg(a.name)
    if not g or not name then return false, "E_BAD_ARGS", "group, option and name required" end
    return group_cmd(Sculpt.option_rename, g, a.option, name)
end

function cmds.key_group_option_delete(a)
    local g = group_ref(a.group)
    if not g then return false, "E_BAD_ARGS", "group and option required" end
    return group_cmd(Sculpt.option_delete, g, a.option)
end

-- {group, option, names, values?}: names given = those keys; "modified" = every key outside the
-- groups whose value differs from its default (the panel's 收入已修改的键)
function cmds.key_group_assign(a)
    local g = group_ref(a.group)
    if not g then return false, "E_BAD_ARGS", "group and option required" end
    local names = a.names
    if names == "modified" then
        names = {}
        for _, k in ipairs(Sculpt.K.keys) do
            if not Sculpt.group_of(k.name) and math.abs(k.value - k.default) > 1e-6 then names[#names + 1] = k.name end
        end
        if #names == 0 then return false, "E_EMPTY", "没有可收入的已修改形态键" end
    elseif type(names) ~= "table" or #names == 0 then
        return false, "E_BAD_ARGS", "names must be a list of key names or \"modified\""
    end
    local values = type(a.values) == "table" and a.values or nil
    return group_cmd(Sculpt.option_assign, g, a.option, names, values)
end

-- {name | names, group?, option?}: out of that option, or (no group) out of the key group altogether
function cmds.key_group_unassign(a)
    local names = type(a.names) == "table" and a.names or (type(a.name) == "string" and { a.name }) or nil
    if not names or #names == 0 then return false, "E_BAD_ARGS", "name or names required" end
    local g = group_ref(a.group)
    if a.group ~= nil and not g then return false, "E_BAD_ARGS", "group must be a name or an index" end
    return group_cmd(Sculpt.unassign, names, g, a.option)
end

-- {group, option, name, value}: the fixed value of a key in one option
function cmds.key_group_set_key(a)
    local g = group_ref(a.group)
    local v = num(a.value, Sculpt.RANGE[1], Sculpt.RANGE[2])
    if not g or type(a.name) ~= "string" or not v then
        return false, "E_BAD_ARGS", "group, option, name and a number value required"
    end
    return group_cmd(Sculpt.option_set_value, g, a.option, a.name, v)
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

-- the part a preset is "for": the primary model's (Presets.primary_part)
local function primary_part()
    return Presets.primary_part(C.parts)
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
    notice("info", I18n.f("已加载捏脸配置：%s", e.name))
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
        values = values, overrides = overrides, key_groups = Sculpt.export_groups(),
    })
    if not r1 then return false, r2, r3 end
    Sculpt.mark_saved()
    C.sculpt_preset = Presets.find_sculpt(a.name, folder, "user")
    C.sculpt_preset_manual = true
    build_presets_state(); build_sculpt_state()
    notice("info", I18n.f("已保存捏脸配置：%s", a.name))
    return true, nil, nil, r4
end

-- presets (M2)
local function resolve_profile_arg(v)
    if Profile.registry[v] then return v end
    for _, e in ipairs(Profile.list) do if e.name == v then return e.id end end
    return nil
end

-- args: part, expression (profile id or name), sculpt (preset name), gains (table, or true =
-- the current gains + gaze settings). Writes the binding of the part's model,
-- user/<model>/<representative>.json.
function cmds.write_binding(a)
    if type(a.part) ~= "string" or a.part == "" then return false, "E_BAD_ARGS", "part required" end
    local base = Presets.binding_base(a.part)
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
    elseif C.binding and C.binding.base == base and C.binding.data then
        data.conditions = C.binding.data.conditions   -- callers that do not know it keep it
    end
    if a.gains == true then
        data.gains, data.eyes = current_gains(), eyes_subset(cfg.eyes)
    elseif type(a.gains) == "table" then
        data.gains = U.copy(a.gains)
    end
    local ok, code, msg, res = Presets.write_binding(base, data)
    if not ok then return false, code, msg end
    request_rescan(1)
    notice("info", I18n.f("已写入绑定：%s", res.path))
    return true, nil, nil, res
end

-- save the tuning in effect (gains + gaze) into the user copy of the binding it came from;
-- keeps the binding's other fields (profile, sculpt, global, fingerprints)
-- bind_config {kind = "sculpt" | "expression" | "conditions", name}: make a config the default of
-- the outfit worn ("绑定到 ..."). Only that field changes; the binding's other fields are kept and
-- the result goes to user/ (a mod's binding is copied, never modified).
function cmds.bind_config(a)
    local base, model, display, data = bind_target()
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
    notice("info", I18n.f("已绑定到 %s", display))
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
    notice("info", I18n.f("已保存到绑定：%s", res.path))
    return true, nil, nil, res
end

-- args: part (or "default"): drop the user file of the part's model so the mods one (or nothing)
-- applies again
function cmds.restore_mod_binding(a)
    if type(a.part) ~= "string" then return false, "E_BAD_ARGS", "part required" end
    local base = a.part == "default" and "default" or Presets.binding_base(a.part)
    if not Presets.user_binding_exists(base) then return false, "E_NOT_FOUND", "no user binding for " .. base end
    if not Presets.tombstone_binding(base) then return false, "E_IO", "write failed" end
    request_rescan(1)
    return true
end

-- args: part, source ("user" default): a part file left by an earlier version becomes the binding of
-- its model; a user part file is then tombstoned
function cmds.adopt_legacy_binding(a)
    if type(a.part) ~= "string" then return false, "E_BAD_ARGS", "part required" end
    local source = a.source == "mods" and "mods" or "user"
    local base = Presets.binding_base(a.part)
    if base == a.part then return false, "E_BAD_ARGS", "not a part file: " .. a.part end
    local data = Presets.read_binding(source, a.part)
    if not data then return false, "E_NOT_FOUND", "no " .. source .. " part binding for " .. a.part end
    data = U.copy(data)
    data.global, data.part = nil, nil
    local ok, code, msg, res = Presets.write_binding(base, data)
    if not ok then return false, code, msg end
    if source == "user" and not Presets.tombstone_binding(a.part) then return false, "E_IO", "write failed" end
    request_rescan(1)
    notice("info", I18n.f("已写入绑定：%s", res.path))
    return true, nil, nil, res
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
    notice("info", I18n.f("已删除：%s", d.name))
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
    NativeSignals.viewing = open and want_signals == true
    if state.runtime.ui_open ~= open then state.runtime.ui_open = open; bump("runtime") end
    C.want_signals = want_signals and true or false
end

-- ---------------------------------------------------------------- init / hooks
-- adapter: the game adapter (ShapeKeySystem_Games/<Game>/Adapter.lua). Its init runs first: when it
-- returns false, reason (a type it needs is missing), nothing else starts and the data folder is
-- not touched. Returns true, or false, reason.
function SKS.init(adapter)
    -- the language before the adapter's init: a failed init returns a message for the menu
    local saved = U.load_json(SETTINGS_PATH)
    if type(saved) == "table" then I18n.set(saved.language) end
    ActorInstances.init(adapter)
    Actors.init(adapter)
    if Actors.enabled() then ActorInstances.faces = Actors.instance_faces end
    if adapter.init then
        local ok, why = adapter.init({ release = SKS.on_release, segment = SKS.on_segment, rebuilt = SKS.on_rebuilt,
                                       menu = SKS.on_menu, preview = SKS.on_preview })
        if ok == false then return false, why end
    end
    SKS.adapter = adapter
    Writer.adapter = adapter
    Scene.adapter, Guard.adapter, Presets.adapter, Profile.adapter, X.adapter = adapter, adapter, adapter, adapter, adapter
    Proc.adapter = adapter
    -- no raw channels: rigs read nothing from the game; sculpt, presets and the external API still write
    state.expression.no_signals = adapter.raw == nil
    Cnd.install(adapter.conditions)
    Trail.open()
    load_settings()
    if not I18n.set(cfg.language) then cfg.language = "zh"; I18n.set("zh") end
    Playback.init(adapter, log, function() return C.prog and C.prog.params or {} end, function()
        return C.prog, Profile.signals.list, state.expression.channels,
            state.mapping.rev .. ":" .. state.expression.rev .. ":" .. state.scene.rev
    end)
    if hotkey_migrated_now then
        notice("info", "打开面板的按键改成了 Delete（End 是游戏的暂停键，Home 和 ArmorVariantManager 冲突），可在设置里修改")
        save_soon()
    end
    cfg.sculpt_max = Sculpt.set_max(cfg.sculpt_max)
    sanitize_procedural()
    Proc.seed(os.time())
    Proc.configure(cfg.procedural)
    Names.load_aliases()
    Labels.load()
    Mocap.load()
    Drivers.load()
    if adapter.face_mirror then
        state.face_mirror = adapter.face_mirror.view
        adapter.face_mirror.attach({ stable = function() return C.last_gate == "stable" end,
                                     root = adapter.primary_root, log = log })
    end
    local sig = Profile.load_signals()
    C.inv_full = 1 / sig.full
    for _, s in ipairs(sig.list) do
        if s.key ~= nil then C.dict_params[#C.dict_params + 1] = s.key end
    end
    Profile.load_all()
    Presets.load_sculpt()
    CondExpr.load_all()
    if cfg.conditions ~= "" then CondExpr.select(cfg.conditions) end
    build_settings_state(); build_eyes_state(); build_presets_state(); build_procedural_state()
    C.build_cond_state()
    local ok, code, msg = apply_profile(cfg.profile, false)
    if not ok and cfg.profile ~= "arkit" then
        notice("warn", I18n.f("表情配置加载失败，改用 ARKit：%s", I18n.tr(tostring(msg))))
        ok, code, msg = apply_profile("arkit", false)
        if ok then cfg.profile = "arkit" end
    end
    if not ok then
        notice("error", I18n.f("没有可用的表情配置：%s %s", tostring(code), I18n.tr(tostring(msg))))
    end
    if not U.load_json(SETTINGS_PATH) then save_now() end
    C.saved_gains = gains_of(cfg.expression)
    C.publish_api()
    return true
end

-- skip / stop / unload (pre-hook): let go before the game destroys the cutscene actors
function SKS.on_release(reason)
    Trail.event("hook %s (cs active %s, released %s, rigs %d)", tostring(reason), tostring(CS.active), tostring(CS.released), #C.rigs)
    -- MH Wilds calls requestStop on every monster hit, cutscene or not (HP loss from equipment
    -- skills does not); releasing there blanked the face for a full rescan delay. With no
    -- cutscene and only the master hunter driven nothing is torn down, so stop / skip are ignored.
    -- unload still releases: it follows a cutscene while the gate already reads stable, with the
    -- cutscene copy still driven.
    if reason ~= "unload" and C.last_gate == "stable" then
        local all_primary = true
        for _, r in ipairs(C.rigs) do if not r.primary then all_primary = false end end
        if all_primary then Trail.event("hook %s ignored: no cutscene", tostring(reason)); return end
    end
    zero_ready_targets(reason)   -- the meshes are still valid in the pre-hook
    CS.released, CS.released_at = true, C.frame
    CS.status = tostring(reason) .. ": released until the next segment"
    drop_rigs("cutscene " .. tostring(reason), nil)
    C.scan_at = {}
    -- in case the game never reports the cutscene as busy afterwards
    if not CS.active then request_rescan(Guard.SETTLE_FRAMES * 4) end
end

-- a cutscene segment starts (pre-hook)
function SKS.on_segment(index)
    Trail.event("hook segment(%s) (cs active %s, released %s, rigs %d)", tostring(index), tostring(CS.active), tostring(CS.released), #C.rigs)
    zero_ready_targets("segment start")
    CS.seg, CS.seg_t0, CS.released, CS.scanned = index, C.frame, false, false
    drop_rigs("cutscene segment " .. tostring(index), nil)
    C.scan_at = {}
end

function SKS.on_rebuilt()
    ActorInstances.release("actor lifecycle changed")
    Actors.clear(); Scene.override = nil; C.actors_at = C.frame
    Trail.event("hook rebuilt (rigs %d)", #C.rigs)
    if #C.rigs > 0 then drop_rigs("equipment rebuilt", Guard.SETTLE_FRAMES)
    else C.scan_after_frame = C.frame + Guard.SETTLE_FRAMES; request_rescan(Guard.SETTLE_FRAMES) end
end

-- display name of a raw channel value (a `p` node), nil when the game has no such channel
function SKS.raw_label(v)
    local raw = SKS.adapter.raw
    local key = raw and raw.parse(v)
    return key ~= nil and raw.label(key) or nil
end

-- debug: run the blendshape hash-table probe on the next stable frame
function SKS.request_probe() C.probe_pending = true end

-- title / save-select GUI opened or closed: the preview characters are (re)built around it.
-- Only a flag here: the game may call these many times per frame (a hook that dropped refs and
-- ran a full GC on every call froze the title screen). tick() handles
-- the flag at most once per frame and only when it changes.
function SKS.on_menu(name, open)
    C.menu_event = name .. (open and " open" or " close")
end

-- the preview character screen (guild card) opened or closed
function SKS.on_preview(open)
    if C.preview_open == open then return end   -- repeated calls: nothing new
    C.preview_open = open
    if open then request_rescan(10, 30, 60, 120, 240, 480) else request_rescan(5, 60) end
end

function SKS.shutdown()
    ActorInstances.release("脚本重置")
    NativeSignals.finish("脚本重置")
    Playback.stop(true, "脚本重置，录制播放已停止")
    Trail.event("script reset")
    FaceHold.release()
    C.unpublish_api()
    if SKS.adapter.strict_bounds and Scene.runtime_signature(Scene.primary_root()) ~= C.sig then
        drop_rigs("shutdown after rebuild", nil)
    end
    for _, r in ipairs(C.rigs) do
        for _, t in ipairs(r.targets) do
            if t.stable >= Guard.STABLE_FRAMES and Guard.mesh_ready(t.mesh) then Writer.zero_target(t) end
        end
    end
    zero_sculpt()
    if C.save_at then save_now() end
    Mocap.flush()
    Drivers.flush()
    if SKS.adapter.face_mirror then SKS.adapter.face_mirror.shutdown() end
end

-- Optional pre-animation/render preparation uses the current scan only; it keeps no second
-- target cache and never touches a mesh after a changed signature.
function SKS.prepare_targets()
    ActorInstances.prepare()
    local A = SKS.adapter
    if not A.prepare_mesh or not cfg.enabled or #(C.instances or {}) == 0 then return end
    local changed = Scene.runtime_signature(Scene.primary_root()) ~= C.sig
    if changed then
        drop_rigs("preparation after rebuild", Guard.SETTLE_FRAMES)
        return
    end
    for _, part in ipairs(C.instances) do
        if Guard.mesh_ready(part.mesh) then A.prepare_mesh(part.mesh) end
    end
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
        defs[i] = { id = d.id, label = d.label, kind = d.kind, options = d.options, min = d.min, max = d.max }
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
                if not C.warned[key] then C.warned[key] = true; notice("warn", I18n.f("条件规则配置不存在：%s", want)) end
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

-- a sculpt preset's non-zero values into one clip of the working copy
function cmds.cond_import_sculpt(a)
    if type(a.clip) ~= "string" or type(a.name) ~= "string" then return false, "E_BAD_ARGS", "clip, name" end
    local e = Presets.find_sculpt(a.name, a.folder or current_folder(), nil, true)
    if not e then return false, "E_NOT_FOUND", "sculpt preset not found: " .. tostring(a.name) end
    local ok, code, msg, n = CondExpr.import_values(a.clip, e.values)
    if not ok then return false, code, msg end
    if n > 0 then
        C.update_touch_map()
        Sculpt.mark_dirty()
    end
    C.build_cond_state()
    notice("info", I18n.f("已从捏脸配置「%s」导入 %d 个形态键", e.name, n))
    return true, nil, nil, { count = n }
end

function cmds.cond_save(a)
    local ok, code, msg, res = CondExpr.save(a.as_name)
    if not ok then return false, code, msg end
    if not (C.binding and C.binding.data and C.binding.data.conditions) then cfg.conditions = res.id; save_soon() end
    C.build_cond_state()
    notice("info", I18n.f("已保存条件规则：%s", CondExpr.current.name))
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
    if SKS.adapter.channel_writable and not SKS.adapter.channel_writable(name) then
        return bad("channel is read-only or unresolved")
    end
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
    if structural or old ~= value then Sculpt.mark_dynamic() end
    if structural then C.build_external_state() end
    return true
end

-- release(owner, name): give the key back to expression / sculpt
function PUB.release(owner, name)
    if not check_owner(owner) or type(name) ~= "string" then return bad("owner, name") end
    if Ext.release(owner, name) then Sculpt.mark_dynamic(); C.build_external_state() end
    return true
end

function PUB.release_all(owner)
    if not check_owner(owner) then return bad("owner") end
    if Ext.release_all(owner) > 0 then Sculpt.mark_dynamic(); C.build_external_state() end
    return true
end

-- value written (or about to be written) for a key, and who controls it:
-- returns value, controller ("external:<owner>" | "expression" | "sculpt") or nil when unknown
function PUB.get(name)
    if type(name) ~= "string" then return nil end
    local xv, owner = Ext.get(name)
    if xv ~= nil then return xv, "external:" .. owner end
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
