-- SKS_Mocap: drive the hunter's ARKit shape keys from iFacialMocap (iPhone face tracking).
-- Personal toy on top of ShapeKeySystem_Core (Scene / Names / Writer); no SKS settings touched.
-- Input: reframework/data/SKS_Mocap/live.json, written by ifm_bridge.py in the same folder.
-- Loads after ShapeKeySystem.lua (file order), so in LateUpdateBehavior our writes land last.
-- Head turn (head# from the phone) is added onto Neck_0 / Neck_1 / Head after UpdateMotion.

local U      = require("ShapeKeySystem_Core.Util")
local Names  = require("ShapeKeySystem_Core.Names")
local Scene  = require("ShapeKeySystem_Core.Scene")
local Writer = require("ShapeKeySystem_Core.Writer")

local LIVE_PATH = "SKS_Mocap\\live.json"
local CFG_PATH  = "SKS_Mocap\\config.json"
local clock, max, min = os.clock, math.max, math.min

local cfg = {
    enabled = true, mirror = false, gain = 1.0, smoothing = 0.3,
    timeout = 0.5, fade_sec = 0.25,
    cutscene = true,     -- drive the cutscene actor's face during cutscene playback
    cutscene_tail = 120, -- let go this many timeline frames before the cutscene timeline ends
    neutral = {},        -- canonical name -> resting value subtracted before gain
    channel_gains = {},  -- canonical name -> extra gain
    -- head turn, added onto the animation in character space (yaw about up, pitch about side,
    -- roll about forward). order = which iFacialMocap head# value feeds each axis.
    head = { enabled = false, gain = 1.0, max_deg = 45, smoothing = 0.6,
             order = { pitch = 1, yaw = 2, roll = 3 },
             invert = { pitch = false, yaw = false, roll = false },
             neutral = { 0, 0, 0 } },
}
do
    local saved = U.load_json(CFG_PATH)
    if saved then
        for k, v in pairs(saved) do
            if k == "head" and type(v) == "table" then
                for hk, hv in pairs(v) do cfg[k][hk] = hv end
            else
                cfg[k] = v
            end
        end
    end
    cfg.nr_off = nil   -- leftover from the removed normal-recalculation guard
    -- empty tables are saved as JSON null; give them back their table
    for _, k in ipairs({ "neutral", "channel_gains" }) do
        if type(cfg[k]) ~= "table" then cfg[k] = {} end
    end
    local h = cfg.head
    if type(h.order) ~= "table" then h.order = { pitch = 1, yaw = 2, roll = 3 } end
    if type(h.invert) ~= "table" then h.invert = { pitch = false, yaw = false, roll = false } end
    if type(h.neutral) ~= "table" then h.neutral = { 0, 0, 0 } end
end
local function save() U.save_json(CFG_PATH, cfg) end

local ARKIT = Names.ARKIT52
local N = #ARKIT
local MIRROR = {}   -- slot -> slot of the opposite side
do
    local slot = {}
    for i, n in ipairs(ARKIT) do slot[n] = i end
    for i, n in ipairs(ARKIT) do
        -- jawLeft / mouthLeft swap too: the whole face is mirrored
        local o = n:match("Left$") and n:sub(1, -5) .. "Right" or n:match("Right$") and n:sub(1, -6) .. "Left" or n
        MIRROR[i] = slot[o] or i
    end
end

local st = {
    raw = {}, out = {}, W = {}, seq = nil, last_rx = -1, fade = 0, was_driving = false,
    rig = nil, sig = "", frame = 0, next_scan = 1,
    rx_hz = 0, rx_n = 0, rx_t0 = clock(), ms = 0, status = "", read_fail = 0,
    head_raw = { 0, 0, 0 }, head_out = { pitch = 0, yaw = 0, roll = 0 },
    body = nil, head_chain = nil, head_status = "", head_ms = 0,
    test = { on = false, pitch = 0, yaw = 0, roll = 0 },
}
for i = 1, N do st.raw[i], st.out[i], st.W[i] = 0, 0, 0 end

local index
local function build_index()
    if next(Names.alias_sets) == nil then Names.load_aliases() end
    local sets = {}
    for k in pairs(Names.alias_sets) do sets[#sets + 1] = k end
    index = Names.build_index(ARKIT, sets)
    -- iris-only gaze keys (LookUpLeft ...) follow the matching ARKit eyeLook* channel
    for _, dir in ipairs({ "Up", "Down", "In", "Out" }) do
        for _, side in ipairs({ "Left", "Right" }) do
            local look = U.norm("Look" .. dir .. side)
            if index[look] == nil then index[look] = index[U.norm("eyeLook" .. dir .. side)] end
        end
    end
end
build_index()

local function sks()
    local api = package.loaded["ShapeKeySystem_Core.API"]
    return type(api) == "table" and api or nil
end

-- share of the head turn each joint takes, root -> tip
local HEAD_JOINTS = { { "Neck_0", 0.25 }, { "Neck_1", 0.25 }, { "Head", 0.5 } }

-- joint path from the skeleton root down to Head, with the driven joints' shares
local function build_head_chain(body)
    local head = body and Writer.M_JBN:call(body, "Head")
    if not head then return nil end
    local share = {}
    for _, e in ipairs(HEAD_JOINTS) do share[e[1]] = e[2] end
    local path, j = {}, head
    while j and #path < 64 do table.insert(path, 1, j); j = j:call("get_Parent") end
    local chain = {}
    for i, jt in ipairs(path) do chain[i] = { joint = jt, share = share[jt:call("get_Name")] } end
    return chain
end

-- ---------------------------------------------------------------- model reload safety
-- Hunter parts are rebuilt on load screens and after cutscenes. Nothing is read or written on a
-- part until its mesh is ready, and every cached target is re-checked before each write.
-- Crash dump (2026-10-09): writing weights while a part reloads (entering the game, end of a
-- cutscene) crashes a game worker thread on a null blendshape buffer. So weights are only written
-- to a mesh whose blendshape state has been steady for STABLE_FRAMES, and never while the player
-- character is being set up or a cutscene is loading.
local T_RMESH = sdk.find_type_definition("via.render.Mesh")
local M_READY    = T_RMESH:get_method("get_MeshReady")
local M_BS_ON    = T_RMESH:get_method("get_BlendShapeEnable")
local M_BS_REL   = T_RMESH:get_method("get_BlendShapeReleasedBuffers")
local M_BS_RELF  = T_RMESH:get_method("get_BlendShapeReleasedFixBuffers")
local M_DRAWABLE = T_RMESH:get_method("get_ReadyToDraw")
local M_CN, M_WC = Writer.M_CN, Writer.M_WC
local RESCAN_DELAY = 30    -- frames to let a reload settle before rescanning
local STABLE_FRAMES = 60   -- frames a mesh must stay steady before it is written to

local function call(m, obj)
    local ok, v = pcall(m.call, m, obj)
    if ok then return v end
    return nil
end

-- mesh loaded, blendshape buffers allocated and not released; returns ok, channel count
-- (or false, the name of the first check that failed)
-- (BlendShapeReleasedFixBuffers is not checked: it is true on the drawn, working hunter face too)
local function mesh_ready(mesh)
    if not call(M_READY, mesh) then return false, "MeshReady=false" end
    if not call(M_BS_ON, mesh) then return false, "BlendShapeEnable=false" end
    if call(M_BS_REL, mesh) then return false, "BlendShapeReleasedBuffers" end
    local cn, wc = call(M_CN, mesh), call(M_WC, mesh)
    if not cn or not wc then return false, "channel count unreadable" end
    if wc < cn then return false, string.format("weights %d < channels %d", wc, cn) end
    return true, cn
end

-- game-level state: player character set up, no cutscene load in progress
local T_DEMO = sdk.find_type_definition("app.DemoMediator")
local M_DEMO_BUSY = T_DEMO and T_DEMO:get_method("get_IsBusy")
local M_DEMO_LOAD = T_DEMO and T_DEMO:get_method("get_IsBusyLoad")
local gate = { setup = false, demo_busy = false, demo_load = false }

-- Lua keeps every game object it touched alive (REFramework add_ref) until the userdata is
-- garbage collected. A reference that outlives the object's destruction (hunter rebuilt after a
-- cutscene) crashed the game even with no weights written, so references are dropped promptly.
local function release_refs() collectgarbage("collect") end

-- measured: cutscene load sets demoLoad, playback sets demoBusy, and the end of a cutscene clears
-- demoBusy, rebuilds the player (IsSetUp false) and sets demoLoad again
local function game_stable()
    local dm = sdk.get_managed_singleton("app.DemoMediator")   -- persistent manager, safe to poll
    gate.demo_busy = (dm and M_DEMO_BUSY and call(M_DEMO_BUSY, dm)) or false
    gate.demo_load = (dm and M_DEMO_LOAD and call(M_DEMO_LOAD, dm)) or false
    dm = nil
    if gate.demo_busy or gate.demo_load then
        gate.setup = false
        return false   -- never touch the player object while a cutscene owns it
    end
    -- the player object may be mid-rebuild: look at it only every 10 frames, and let go of the
    -- temporary references straight away if it is not set up
    if st.frame % 10 == 0 or gate.setup then
        local setup = false
        pcall(function()
            setup = sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer")
                :get_field("<Character>k__BackingField"):call("get_IsSetUp") == true
        end)
        gate.setup = setup
        if not setup then release_refs() end
    end
    return gate.setup
end

-- every hunter armour mesh is loaded (the same filter Scene.scan uses)
local function parts_ready(root)
    local c = root and root:call("get_Child")
    while c do
        local name = Scene.go_name(c)
        if name:find("ch02", 1, true) or name:find("ch03", 1, true) then
            local mesh
            pcall(function() mesh = c:call("get_GameObject"):call("getComponent(System.Type)", Writer.MESH_TYPE) end)
            if mesh and not mesh_ready(mesh) then return false end
        end
        c = c:call("get_Next")
    end
    return true
end

local function drop_rig(reason)
    local had = st.rig or st.head_chain or st.body
    st.rig, st.head_chain, st.body = nil, nil, nil
    st.next_scan = st.frame + RESCAN_DELAY
    st.status = reason
    if had then release_refs() end
end

local M_GO_DRAW = sdk.find_type_definition("via.GameObject"):get_method("get_Draw")

-- cached targets still describe live meshes with the channel count seen at scan time;
-- also advances each target's steady-frame counter (only drawn meshes count as steady).
-- Returns ok, reason, zero_now: a part that has been written to and stops being drawn (the black
-- screen before a cutscene ends, a part being swapped out) is still a valid mesh at that moment,
-- so the caller zeroes it right then. Waiting until the game rebuilds it is what crashed.
local function rig_valid(rig, ignore_draw)
    for _, t in ipairs(rig.targets) do
        local ok, cn = mesh_ready(t.mesh)
        if not ok then return false, t.name .. ": " .. tostring(cn), false end
        if cn ~= t.cn then return false, string.format("%s: channels %s -> %s", t.name, tostring(t.cn), tostring(cn)), false end
        -- cutscenes cull the hunter whenever the camera looks away: there drawn state is ignored
        -- (the end of the cutscene is handled by cutscene_update instead)
        local drawn = ignore_draw or (call(M_DRAWABLE, t.mesh) and (t.go == nil or call(M_GO_DRAW, t.go) == true))
        if drawn then
            t.stable = (t.stable or 0) + 1
        elseif (t.stable or 0) >= STABLE_FRAMES then
            return false, t.name .. ": stopped being drawn", true
        else
            t.stable = 0
        end
    end
    return true
end

local function zero_rig(rig)
    for _, t in ipairs(rig.targets) do
        if mesh_ready(t.mesh) then Writer.zero_target(t) end
    end
end

local M_COMP_GO = sdk.find_type_definition("via.Component"):get_method("get_GameObject")
local function cache_targets(rig)
    for _, t in ipairs(rig.targets) do
        t.cn = M_CN:call(t.mesh); t.stable = 0
        t.go = call(M_COMP_GO, t.mesh)
    end
end

local function scan()
    local root = Scene.master_root()
    if not root or not parts_ready(root) then
        root = nil
        drop_rig("waiting for hunter meshes to finish loading")
        release_refs()   -- parts_ready touched every part: do not keep them alive
        return
    end
    st.body = root
    st.head_chain = build_head_chain(st.body)
    st.head_status = st.head_chain and string.format("head chain: %d joints", #st.head_chain) or "no Head joint"
    local res = Scene.scan({ index = index, params = {}, dict_params = {}, scene_search = false, min_hits = 3 })
    local rig = res.rigs[1]
    st.rig = (rig and rig.primary) and rig or nil
    st.sig = res.sig
    st.next_scan = st.frame + 600
    if st.rig then
        cache_targets(st.rig)
        local t = {}
        for _, x in ipairs(st.rig.targets) do t[#t + 1] = x.name .. ":" .. x.distinct end
        st.status = "driving " .. table.concat(t, ", ")
    else
        st.status = "no ARKit mesh on the hunter"
    end
end

local function read_live()
    local data = U.load_json(LIVE_PATH)
    if not data or type(data.w) ~= "table" then st.read_fail = st.read_fail + 1; return end
    if data.seq == st.seq then return end
    local first = st.seq == nil
    st.seq = data.seq
    if first then return end   -- a live.json left over from an earlier session is not live
    local w, raw = data.w, st.raw
    for i = 1, N do raw[i] = tonumber(w[i]) or 0 end
    if type(data.head) == "table" then
        for i = 1, 3 do st.head_raw[i] = tonumber(data.head[i]) or 0 end
    end
    st.last_rx = clock()
    st.rx_n = st.rx_n + 1
end

local function compute(dt)
    local live = st.last_rx >= 0 and (clock() - st.last_rx) < cfg.timeout
    local step = dt / max(cfg.fade_sec, 0.01)
    st.fade = live and min(1, st.fade + step) or max(0, st.fade - step)
    local alpha = 1 - min(cfg.smoothing, 1) * 0.9
    local raw, out, W = st.raw, st.out, st.W
    local neutral, cg, g = cfg.neutral, cfg.channel_gains, cfg.gain
    for i = 1, N do
        local src = cfg.mirror and MIRROR[i] or i
        local name = ARKIT[i]
        local n0 = tonumber(neutral[ARKIT[src]]) or 0
        local v = raw[src]
        v = (n0 < 0.99) and (v - n0) / (1 - n0) or 0
        v = v * g * (tonumber(cg[name]) or 1)
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        out[i] = out[i] + (v - out[i]) * alpha
        W[i] = out[i] * st.fade
    end
    local h, ho = cfg.head, st.head_out
    local lim = h.max_deg
    -- head input arrives in steps (~25 Hz through live.json), which shows far more on a turning
    -- head than on the face: its own time-based smoothing, 0..1 -> time constant 0..0.2 s
    local tau = (tonumber(h.smoothing) or 0.6) * 0.2
    local ha = tau > 0 and (1 - math.exp(-dt / tau)) or 1
    for _, ax in ipairs({ "pitch", "yaw", "roll" }) do
        local k = tonumber(h.order[ax]) or 1
        local v = ((st.head_raw[k] or 0) - (tonumber(h.neutral[k]) or 0)) * h.gain
        if h.invert[ax] then v = -v end
        if v < -lim then v = -lim elseif v > lim then v = lim end
        ho[ax] = ho[ax] + (v - ho[ax]) * ha
    end
end

-- ---------------------------------------------------------------- head turn
local sin, cos, rad = math.sin, math.cos, math.rad

-- character space: yaw about +Y, pitch about +X, roll about +Z (degrees)
local function euler_q(pitch, yaw, roll)
    local p, y, r = rad(pitch) * 0.5, rad(yaw) * 0.5, rad(roll) * 0.5
    return Quaternion.new(cos(y), 0, sin(y), 0)
         * Quaternion.new(cos(p), sin(p), 0, 0)
         * Quaternion.new(cos(r), 0, 0, sin(r))
end

-- Runs after UpdateMotion (same slot as Eyelid Rotation Fix / Lua Bone System), so the
-- animation has written this frame's local rotations and constraints still follow ours.
-- The extra turn D (character space) is split over Neck_0 / Neck_1 / Head: each joint's
-- local rotation L becomes L * (W^-1 * D_share * W), W = its world rotation from the chain.
local function drive_head()
    -- gameplay chain, or the master player's chain while a cutscene shows it
    local in_cg = st.head_chain == nil and st.cg_head ~= nil
    local chain, body = st.head_chain or st.cg_head, st.body or st.cg_body
    if not (cfg.enabled and cfg.head.enabled and chain and body) then return end
    if in_cg then
        -- only while the cutscene is playing; cutscene_update lets these go when it ends
        if not (gate.demo_busy and not gate.demo_load) then return end
    else
        local root = Scene.master_root()
        if not root or root:get_address() ~= body:get_address() then st.head_chain = nil; return end   -- hunter object was rebuilt
    end
    local ho, f = st.head_out, st.fade
    if st.test.on then ho, f = st.test, 1 end   -- fixed pose from the panel, no phone needed
    if f <= 0 then return end
    local t0 = clock()
    local C = body:call("get_Rotation")
    local Ci = C:inverse()
    local q = C
    for _, e in ipairs(chain) do
        local j = e.joint
        local L = j:call("get_LocalRotation")
        if e.share then
            -- if nothing re-posed the joint since our last write, start from the pose we saw
            -- then instead of stacking the turn again
            if e.wrote and math.abs(L:dot(e.wrote)) > 0.9999999 then L = e.base else e.base = L end
            local s = e.share * f
            local D = C * euler_q(ho.pitch * s, ho.yaw * s, ho.roll * s) * Ci
            local W = q * L
            L = (L * (W:inverse() * D * W)):normalized()
            j:call("set_LocalRotation", L)
            e.wrote = L
        end
        q = q * L
    end
    st.head_ms = st.head_ms * 0.95 + (clock() - t0) * 1000 * 0.05
end

re.on_application_entry("UpdateMotion", function()
    local ok, err = pcall(drive_head)
    if not ok then st.head_status = "head error: " .. tostring(err); st.head_chain, st.cg_head = nil, nil; st.next_scan = st.frame + 60 end
end)

-- ---------------------------------------------------------------- cutscene actor
-- During cutscene playback (demoBusy, not demoLoad) the hunter on screen is a separate actor the
-- cutscene spawns. It is found with a whole-scene face search, driven with the same steady-frame
-- rule, and zeroed + released on the first frame playback ends, before the game rebuilds things.
st.cg_rig, st.cg_next, st.cg_status = nil, 0, "-"
st.prof = { gate = 0, scan = 0, read = 0, write = 0 }   -- per-section ms, smoothed

local function cg_release(reason, zero)
    if st.cg_rig and zero then
        for _, t in ipairs(st.cg_rig.targets) do
            if mesh_ready(t.mesh) then Writer.zero_target(t) end
        end
    end
    st.cg_rig, st.cg_head, st.cg_body = nil, nil, nil
    st.cg_status = reason
    -- the scene search caches parent transforms of every face it saw; drop them with our refs
    Scene.no_targets = {}
    release_refs()
end

local function cg_scan()
    local res = Scene.scan({ index = index, params = {}, dict_params = {}, scene_search = true, min_hits = 3 })
    -- a cutscene can hold several copies of the hunter (evc*/chara/Pl000_00 is hidden while the
    -- master player itself is on screen): drive the copy whose parts are actually drawn
    local function drawn(t)
        local ok, d = pcall(function() return t.mesh:call("get_GameObject"):call("get_Draw") end)
        return ok and d == true
    end
    local pick
    for _, r in ipairs(res.rigs) do
        local all = #r.targets > 0
        for _, t in ipairs(r.targets) do if not drawn(t) then all = false; break end end
        if all then pick = r; break end
    end
    res = nil
    st.cg_next = st.frame + 60
    if not pick then
        cg_release("no drawn ARKit face in the cutscene", false)
        return
    end
    local names = {}
    cache_targets(pick)
    for _, t in ipairs(pick.targets) do names[#names + 1] = t.name .. ":" .. t.distinct end
    st.cg_rig = pick
    -- the master player on screen also gets the head turn; its joints are let go with the face
    if pick.primary then
        st.cg_body = Scene.master_root()
        st.cg_head = build_head_chain(st.cg_body)
    end
    st.cg_status = "driving " .. (pick.primary and "master player" or pick.label) .. " [" .. table.concat(names, ", ") .. "]"
    Scene.no_targets = {}
    release_refs()
end

-- The game tears the cutscene's actors down right after a skip / stop request, well before
-- demoBusy clears; holding references to them then crashed the game even with all weights at 0.
-- So everything is let go the moment a skip or stop is requested, or when the playing timeline is
-- within cfg.cutscene_tail frames of its end, and nothing is picked up again until playback is over.
local T_SCENEMGR = sdk.find_type_definition("via.SceneManager")
local TL_TYPE = sdk.typeof("via.timeline.Timeline")
local T_TL = sdk.find_type_definition("via.timeline.Timeline")
local M_TL_FRAME, M_TL_END = T_TL:get_method("get_Frame"), T_TL:get_method("get_EndFrame")
st.cg_done, st.cg_tl, st.cg_tl_info = false, nil, nil

local function cg_end_early(reason)
    if st.cg_done then return end
    st.cg_done = true
    if st.cg_rig then st.fade, st.was_driving = 0, false end
    st.cg_tl = nil
    cg_release("stopped before the end: " .. reason, true)
end

for _, name in ipairs({ "requestSkip", "execSkip", "requestStop(ace.DemoMediatorBase.cParamBase)", "requestForceStop" }) do
    pcall(function()
        local m = T_DEMO:get_method(name)
        if m then sdk.hook(m, function() pcall(cg_end_early, name:match("^[%w_]+")) end, nil) end
    end)
end

-- the longest timeline that is currently between its start and end frame
local function find_timeline()
    local best, best_end
    pcall(function()
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), T_SCENEMGR, "get_CurrentScene")
        local arr = scene:call("findComponents(System.Type)", TL_TYPE)
        for i = 0, (arr:call("get_Length") or 0) - 1 do
            local tl = arr:call("GetValue(System.Int32)", i)
            local f, e = tl and call(M_TL_FRAME, tl), tl and call(M_TL_END, tl)
            if f and e and f > 0 and f < e and (best_end == nil or e > best_end) then best, best_end = tl, e end
        end
    end)
    return best
end

local function cutscene_update()
    local playing = cfg.cutscene and gate.demo_busy and not gate.demo_load
    if not playing then
        if st.cg_rig then
            cg_release("released at cutscene end", true)
            st.fade, st.was_driving = 0, false
        end
        st.cg_done, st.cg_tl, st.cg_tl_info = false, nil, nil
        return
    end
    if st.cg_done then return end
    -- natural end: let go cfg.cutscene_tail timeline frames early
    if st.cg_tl == nil and st.frame % 30 == 0 then
        st.cg_tl = find_timeline()
        if not st.cg_tl then release_refs() end   -- the search touched every timeline in the scene
    end
    if st.cg_tl then
        local f, e = call(M_TL_FRAME, st.cg_tl), call(M_TL_END, st.cg_tl)
        if not f or not e then
            st.cg_tl = nil
        else
            st.cg_tl_info = string.format("timeline %.0f / %.0f (%.0f left)", f, e, e - f)
            if e - f <= (tonumber(cfg.cutscene_tail) or 120) then cg_end_early("near timeline end"); return end
        end
    end
    -- read back what we wrote last frame: different = someone else drives these weights
    local pr = st.cg_probe
    if pr and st.cg_rig and pr.t.mesh then
        local got = Writer.read_weight(pr.t.mesh, pr.idx)
        st.cg_readback = string.format("readback %s / wrote %.3f (%s)", got and string.format("%.3f", got) or "nil",
            pr.wrote, ARKIT[pr.slot] or tostring(pr.slot))
    end
    st.cg_probe = nil
    if st.cg_rig then
        local ok, why, zero_now = rig_valid(st.cg_rig, true)
        if not ok then
            st.cg_label = st.cg_status
            if zero_now then st.fade, st.was_driving = 0, false end
            cg_release("rescanning, last check failed: " .. tostring(why), zero_now)
            st.cg_next = st.frame + RESCAN_DELAY
        end
    end
    if not st.cg_rig and st.frame >= st.cg_next then cg_scan() end
end

local last_t = clock()
re.on_application_entry("LateUpdateBehavior", function()
    local t0 = clock()
    local dt = min(t0 - last_t, 0.1); last_t = t0
    st.frame = st.frame + 1
    local ok, err = pcall(function()
        -- player being set up / cutscene loading: let go of every cached object until it settles
        local stable = game_stable()
        if not stable then
            if st.rig then
                -- leave the meshes with zero weights before letting go: weights left on a part that
                -- the game later rebuilds (end of a cutscene) crash its blendshape worker
                for _, t in ipairs(st.rig.targets) do
                    if mesh_ready(t.mesh) then Writer.zero_target(t) end
                end
                st.fade, st.was_driving = 0, false
            end
            if st.rig or st.head_chain then drop_rig("paused: player setup / cutscene") end
            st.next_scan = math.max(st.next_scan, st.frame + RESCAN_DELAY)
        end
        -- parts changed (load screen, cutscene, equipment): stop touching the old meshes at once
        if st.frame % 5 == 0 and (st.rig or st.head_chain) and Scene.children_signature(Scene.master_root()) ~= st.sig then
            drop_rig("hunter parts changed, rescanning")
        end
        if st.rig then
            local ok, why, zero_now = rig_valid(st.rig)
            if not ok then
                if zero_now then zero_rig(st.rig); st.fade, st.was_driving = 0, false end
                drop_rig("rescanning: " .. tostring(why))
            end
        end
        local ta = clock()
        if stable and st.frame >= st.next_scan then scan() end
        cutscene_update()
        local tb = clock()
        if not cfg.enabled then
            if st.was_driving then st.fade = 0 end
        else
            -- every frame: ~0.08 ms once the data folder is excluded from Windows Defender
            -- (5 ms per read with real-time scanning on)
            read_live()
        end
        local tc = clock()
        compute(dt)
        local p = st.prof
        p.gate = p.gate * 0.95 + (ta - t0) * 50
        p.scan = p.scan * 0.95 + (tb - ta) * 50
        p.read = p.read * 0.95 + (tc - tb) * 50
        local driving = cfg.enabled and st.fade > 0
        local rig = st.rig or st.cg_rig
        local td = clock()
        if rig and (driving or st.was_driving) then
            -- SKS writes the same channels earlier in this entry and only writes what changed,
            -- so while it runs every channel is rewritten each frame to stay on top
            local api = sks()
            local force = api and api.state and api.state.runtime.enabled or false
            -- the cutscene actor is rewritten every frame: something else may set its weights
            if rig == st.cg_rig then force = true end
            for _, t in ipairs(rig.targets) do
                if (t.stable or 0) >= STABLE_FRAMES then Writer.write_target(t, st.W, force, 0.0005) end
            end
            -- remember the strongest written channel so the next frame can read it back
            local t1 = rig.targets[1]
            if rig == st.cg_rig and t1 and (t1.stable or 0) >= STABLE_FRAMES then
                local best, bk = -1, nil
                for k = 1, t1.count do
                    local w = st.W[t1.slots[k]] or 0
                    if w > best then best, bk = w, k end
                end
                st.cg_probe = bk and { t = t1, idx = t1.idxs[bk], wrote = best, slot = t1.slots[bk] } or nil
            end
            if st.was_driving and not driving and api then api.call("rescan") end  -- hand back to SKS
        end
        st.was_driving = driving
        st.prof.write = st.prof.write * 0.95 + (clock() - td) * 50
    end)
    if not ok then st.status = "error: " .. tostring(err); st.next_scan = st.frame + 60 end
    local now = clock()
    if now - st.rx_t0 >= 1 then
        st.rx_hz = st.rx_n / (now - st.rx_t0); st.rx_n = 0; st.rx_t0 = now
        st.fail_hz = st.read_fail - (st.fail_mark or 0); st.fail_mark = st.read_fail
    end
    st.ms = st.ms * 0.95 + (now - t0) * 1000 * 0.05
end)

-- ---------------------------------------------------------------- debug panel (REF menu)
local function slider(label, key, lo, hi)
    local c, v = imgui.slider_float(label, cfg[key], lo, hi)
    if c then cfg[key] = v; save() end
end

re.on_draw_ui(function()
    if not imgui.tree_node("SKS Mocap (iFacialMocap)") then return end
    local age = st.last_rx >= 0 and (clock() - st.last_rx) or nil
    imgui.text(string.format("input: %s  %.0f Hz  fade %.2f  %.3f ms/frame",
        age == nil and "no data yet" or (age < cfg.timeout and "LIVE" or string.format("stale %.1fs", age)),
        st.rx_hz, st.fade, st.ms))
    local p = st.prof
    imgui.text(string.format("  ms: gate %.3f  scan %.3f  read %.3f  write %.3f   bad reads/s %d", p.gate, p.scan, p.read, p.write, st.fail_hz or 0))
    imgui.text(st.status)
    local stab = {}
    for _, t in ipairs(st.rig and st.rig.targets or {}) do stab[#stab + 1] = string.format("%s:%d", t.name, math.min(t.stable or 0, STABLE_FRAMES)) end
    imgui.text(string.format("safety: setup=%s  demoBusy=%s  demoLoad=%s  steady %s",
        tostring(gate.setup), tostring(gate.demo_busy), tostring(gate.demo_load), #stab > 0 and table.concat(stab, " ") or "-"))
    local cgs = {}
    for _, t in ipairs(st.cg_rig and st.cg_rig.targets or {}) do cgs[#cgs + 1] = string.format("%d", math.min(t.stable or 0, STABLE_FRAMES)) end
    imgui.text(string.format("cutscene: %s%s", st.cg_status, #cgs > 0 and ("  steady " .. table.concat(cgs, "/")) or ""))
    if st.cg_label and not st.cg_rig then imgui.text("  last found: " .. st.cg_label) end
    if st.cg_tl_info then imgui.text("  " .. st.cg_tl_info .. (st.cg_done and "  [released]" or "")) end
    if st.cg_rig and st.cg_readback then imgui.text("  " .. st.cg_readback) end
    if st.cg_rig then
        local a = {}
        for _, t in ipairs(st.cg_rig.targets) do
            local ok, addr = pcall(function() return t.mesh:get_address() end)
            a[#a + 1] = string.format("%s @ 0x%X", t.name, ok and addr or 0)
        end
        imgui.text("  mesh: " .. table.concat(a, "  "))
    end
    local c, v = imgui.checkbox("enabled", cfg.enabled)
    if c then cfg.enabled = v; save() end
    imgui.same_line()
    c, v = imgui.checkbox("cutscene actor", cfg.cutscene)
    if c then cfg.cutscene = v; save() end
    imgui.same_line()
    c, v = imgui.checkbox("mirror L/R", cfg.mirror)
    if c then cfg.mirror = v; save() end
    slider("gain", "gain", 0, 3)
    slider("smoothing", "smoothing", 0, 1)
    if imgui.button("calibrate neutral (relax your face)") then
        cfg.neutral = {}
        for i = 1, N do if st.raw[i] > 0.01 then cfg.neutral[ARKIT[i]] = st.raw[i] end end
        save()
    end
    imgui.same_line()
    if imgui.button("clear neutral") then cfg.neutral = {}; save() end
    imgui.same_line()
    if imgui.button("rescan") then st.next_scan = st.frame + 1 end
    if imgui.tree_node("channels") then
        for i = 1, N do
            local n = ARKIT[i]
            local g = tonumber(cfg.channel_gains[n]) or 1
            local ch, nv = imgui.slider_float(string.format("%-20s raw %.2f out %.2f", n, st.raw[i], st.W[i]), g, 0, 3)
            if ch then cfg.channel_gains[n] = (math.abs(nv - 1) > 0.001) and nv or nil; save() end
        end
        imgui.tree_pop()
    end
    if imgui.tree_node("head") then
        local h = cfg.head
        imgui.text(string.format("%s  %.3f ms/frame", st.head_status, st.head_ms))
        imgui.text(string.format("raw head#  %.1f  %.1f  %.1f   ->  pitch %.1f  yaw %.1f  roll %.1f",
            st.head_raw[1], st.head_raw[2], st.head_raw[3], st.head_out.pitch, st.head_out.yaw, st.head_out.roll))
        c, v = imgui.checkbox("head enabled", h.enabled)
        if c then h.enabled = v; save() end
        c, v = imgui.slider_float("head gain", h.gain, 0, 2)
        if c then h.gain = v; save() end
        c, v = imgui.slider_float("max deg", h.max_deg, 5, 90)
        if c then h.max_deg = v; save() end
        c, v = imgui.slider_float("head smoothing", tonumber(h.smoothing) or 0.6, 0, 1)
        if c then h.smoothing = v; save() end
        for _, ax in ipairs({ "pitch", "yaw", "roll" }) do
            c, v = imgui.checkbox("invert " .. ax, h.invert[ax])
            if c then h.invert[ax] = v; save() end
            imgui.same_line()
            c, v = imgui.slider_int(ax .. " <- head# value", tonumber(h.order[ax]) or 1, 1, 3)
            if c then h.order[ax] = v; save() end
        end
        if imgui.button("calibrate head (look straight at the phone)") then
            h.neutral = { st.head_raw[1], st.head_raw[2], st.head_raw[3] }; save()
        end
        imgui.separator()
        c, v = imgui.checkbox("test pose (ignores the phone)", st.test.on)
        if c then st.test.on = v end
        for _, ax in ipairs({ "pitch", "yaw", "roll" }) do
            c, v = imgui.slider_float("test " .. ax, st.test[ax], -60, 60)
            if c then st.test[ax] = v end
        end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    if st.rig then for _, t in ipairs(st.rig.targets) do Writer.zero_target(t) end end
end)
