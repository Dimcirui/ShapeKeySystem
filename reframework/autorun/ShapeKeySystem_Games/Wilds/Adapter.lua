-- ShapeKeySystem: MH Wilds adapter. Interface: docs/plans/multi-game-adapter.md.
--
-- Constraints:
-- - Nothing here calls sdk at load: type and method lookups happen in `A.init`, which only runs
--   for the adapter that was picked.
-- - Cutscene hooks are pre-hooks, so `events.release` drops every reference before the game acts.
-- - Title GUIs hook onOpen only: GUI010100 onClose runs many times per frame and froze the title
--   screen when each call dropped references.

local Cond  = require("ShapeKeySystem_Games.Wilds.Conditions")
local Input = require("ShapeKeySystem_Games.Wilds.Input")
local Probe = require("ShapeKeySystem_Games.Wilds.Probe")

local Playback = require("ShapeKeySystem_Games.Wilds.Playback")
local FaceMirror = require("ShapeKeySystem_Games.FaceMirror")
local Recorder = require("ShapeKeySystem_Games.Wilds.Recorder")
local B = require("ShapeKeySystem_Core.BoneSignals")
local BoneReads = require("ShapeKeySystem_Core.BoneReads")
local FaceHold = require("ShapeKeySystem_Core.FaceHold")
local L = require("ShapeKeySystem_Core.I18n")

local A = {
    id = "mhwilds",
    name = "Monster Hunter Wilds",
    -- ShapeKeySystem_Native.dll writes each mesh's queued weights in one call
    native_write = true,
    conditions = Cond,
    input = Input,
    playback = Playback,
    -- the GUI is a one-texture library GUI nothing else in the scene uses; Hip sits on COG
    face_mirror = FaceMirror.new({
        rtex = "GUI/ui_texture/tex_render/rtt_facemirror_00.rtex",
        gui_asset = "GUI/ui000000/ui000200/lib000204.gui", gui_elem = "tex_saleMark", gui_folder = "GUIHud",
        main_camera = "Main Camera",
        binds = { { id = "Head", name = "头部（Head）" }, { id = "Neck_0", name = "脖子（Neck_0）" }, { id = "Spine_2", name = "胸部（Spine_2）" },
                  { id = "COG", name = "重心（COG）" } },
        rigs = {
            Head = { dist = 0.6, aim = { x = 0, y = 0.07, z = 0.08 }, rot = { x = -6, y = 0, z = 0 } },
            Neck_0 = { dist = 0.6, aim = { x = 0, y = 0.12, z = 0.08 }, rot = { x = -6, y = 0, z = 0 } },
            Spine_2 = { dist = 0.6, aim = { x = 0, y = 0.2, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
            COG = { dist = 0.6, aim = { x = 0, y = 0.45, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
        },
        parts = { { id = "helm", name = "头盔" }, { id = "body", name = "躯干" }, { id = "arm", name = "腕部" },
                  { id = "waist", name = "腰部" }, { id = "legs", name = "腿部" }, { id = "acc", name = "挂件" },
                  { id = "weapon", name = "武器", hide = true } },
        -- the face with its hair is the head; armour parts by the last digit of their id (slot 6 goes
        -- with the body); accessories, weapons, the carving knife and the slinger
        part = function(top)
            if top:find("Player_Face", 1, true) == 1 then return "head" end
            local slot = top:match("^ch0[23]_%d+_%d%d%d(%d)$")
            if slot then
                return ({ ["1"] = "arm", ["2"] = "body", ["3"] = "helm", ["4"] = "legs", ["5"] = "waist" })[slot] or "body"
            end
            if top:find("Acc", 1, true) == 1 then return "acc" end
            if top:find("Wp", 1, true) == 1 or top:find("HunterKnife", 1, true) == 1 or top == "SlingerRope" then
                return "weapon"
            end
            return "other"
        end,
        isolate = false, clip = { 0.2, 0.3 },
    }),
    -- in-game recordings are saved straight into the face animation test format
    native_snapshot = Recorder.snapshot,
    native_sample = Recorder.sample,
    native_export = Recorder.export,
}

local M_JBN, M_DEMO_BUSY, M_DEMO_LOAD

-- looked up on first use, so Scene lookups also work without A.init (toys/SKS_Mocap)
local function jbn(tr, name)
    M_JBN = M_JBN or sdk.find_type_definition("via.Transform"):get_method("getJointByName(System.String)")
    return M_JBN:call(tr, name)
end

local function call(m, obj)
    if not m then return nil end
    local ok, v = pcall(m.call, m, obj)
    if ok then return v end
    return nil
end

local function go_name(transform)
    local ok, n = pcall(function() return transform:call("get_GameObject"):call("get_Name") end)
    return ok and n or "?"
end

-- ---------------------------------------------------------------- characters and parts
function A.primary_root()
    local ok, tr = pcall(function()
        return sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Object"):call("get_Transform")
    end)
    return ok and tr or nil
end

function A.primary_ready()
    local ok = false
    pcall(function()
        ok = sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer")
            :get_field("<Character>k__BackingField"):call("get_IsSetUp") == true
    end)
    return ok
end

function A.is_face(tr) return jbn(tr, "fcParam_001") ~= nil end

-- a cutscene actor carries several transforms with fcParam joints; the Player_Face* child wins
function A.face_rank(tr) return go_name(tr):find("Player_Face", 1, true) == 1 and 1 or 0 end

-- NPC faces carry fcParam too: only hunter armour (ch02 / ch03) is driven
function A.is_part(name) return (name:find("ch02", 1, true) or name:find("ch03", 1, true)) ~= nil end

-- Only faces and armour parts count: the game hangs props and effects on the hunter during
-- emotes, and a signature that changed with them dropped and re-armed the rigs every few frames.
function A.signature(root)
    local parts, c = {}, root:call("get_Child")
    while c do
        local name = go_name(c)
        if name:find("Player_Face", 1, true) == 1 or A.is_part(name) then parts[#parts + 1] = name end
        c = c:call("get_Next")
    end
    return table.concat(parts, "|")
end

function A.eye_joints(face)
    return { L = jbn(face, "L_EyeJ_LOD02"), R = jbn(face, "R_EyeJ_LOD02") }
end

-- Bones held by the "hold face bones" option: every joint under HeadAll_SCL except the eyeballs
-- (gaze is read from them), the charamake scale joints and the helmet attach points.
local HOLD_SKIP = { HeadAll_SCL = true, Ear_SCL = true, Head_SCL = true, L_EyeJ_LOD02 = true, R_EyeJ_LOD02 = true }

local function under_head(j)
    local p = j:call("get_Parent")
    for _ = 1, 16 do
        if not p then return false end
        if p:call("get_Name") == "HeadAll_SCL" then return true end
        p = p:call("get_Parent")
    end
    return false
end

function A.expression_joints(face)
    local arr = face:call("get_Joints")
    local out = {}
    for _, j in ipairs(arr and arr:get_elements() or {}) do
        local name = j:call("get_Name")
        if name and not HOLD_SKIP[name] and name:find("HelmJoint_", 1, true) ~= 1 and under_head(j) then
            out[#out + 1] = { joint = j, name = name }
        end
    end
    return out
end

-- 必须取到全部面部动画层；初始化中的空层或缺层不能作为可采集中性脸的依据。
function A.face_layers(face)
    local motion = face:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if not motion then return nil end
    local count = motion:call("getLayerCount")
    if not count or count <= 0 then return nil end
    local out = {}
    for i = 0, count - 1 do
        local layer = motion:call("getLayer(System.UInt32)", i)
        if not layer then return nil end
        out[#out + 1] = layer
    end
    return out
end

-- ---------------------------------------------------------------- signals
-- Raw channels are fcParam numbers 0..200; a channel's value is the z of its fcParam_NNN joint's
-- local position, normalised by the dictionary's `full`. `bone.<name>` names a bone signal
-- (BoneReads), keyed above the fcParam range.
local bone_sigs

A.raw = {
    term = "fcParam",
    slider = { min = 0, max = 200, fmt = "%03d" },
    parse = function(v)
        local key, why = BoneReads.parse(bone_sigs, v)
        if key or why then return key, why end
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "p 必须是有限数值" end
        if n < 0 or n > 200 then return nil, "fcParam out of range: " .. tostring(v) end
        return math.floor(n)
    end,
    label = function(n)
        return BoneReads.label(bone_sigs, n) or string.format("fcParam_%03d", n)
    end,
}

local M_LPOS, M_LROT

-- Bone fallback: gestures and shouts can leave every fcParam at 0 while the face joints still move.
-- builtin/mhwilds/face.json projects a few face joints onto ARKit keys, and each rule's `raw` names
-- the fcParam channel it backs up. read keeps the larger of the two in P, so profiles, the
-- procedural layer and the signal display all see one merged channel. Without A.init (toys) or with
-- an invalid file there is no fallback.
local bones

local function load_bones()
    local ok, data = pcall(json.load_file, "ShapeKeySystem/builtin/mhwilds/face.json")
    if not ok or type(data) ~= "table" then return nil, "荒野面部骨骼标定文件无法读取" end
    local sigs, sig_why = BoneReads.load(data.signals, L.tr("荒野"))
    bone_sigs = sigs
    if not sigs then return nil, sig_why end
    local valid, why = B.validate(data, { label = L.tr("荒野") })
    if not valid then return nil, why end
    local names = {}
    for id, spec in pairs(data.joints) do names[#names + 1] = spec.bone or id end
    FaceHold.watch(names)
    local raw_of = {}
    for _, rule in ipairs(data.rules) do
        local n = A.raw.parse(rule.raw)
        if not n or (raw_of[rule.key] and raw_of[rule.key] ~= n) then return nil, "荒野骨骼标定的 raw 通道无效" end
        raw_of[rule.key] = n
    end
    return { calibration = data, raw_of = raw_of }
end

-- Only rules whose fcParam channel is bound and whose joint exists on this face; nil when none.
local function bind_bones(face, keys)
    if not bones then return nil end
    local wanted, joints, rules, raw_of = {}, {}, {}, {}
    for _, n in ipairs(keys) do wanted[n] = true end
    for _, rule in ipairs(bones.calibration.rules) do
        local n = bones.raw_of[rule.key]
        if wanted[n] then
            local spec = bones.calibration.joints[rule.joint]
            if joints[rule.joint] == nil then joints[rule.joint] = jbn(face, spec.bone or rule.joint) or false end
            if joints[rule.joint] then rules[#rules + 1] = rule; raw_of[rule.key] = n end
        end
    end
    if #rules == 0 then return nil end
    local specs = bones.calibration.joints
    local addr = face:get_address()
    return {
        calibration = { joints = specs, rules = rules },
        raw_of = raw_of,
        -- one engine call per joint: position for pos joints, rotation for rot joints. While
        -- FaceHold holds the face the joints read neutral; its copy of the animated pose is used.
        sample = function(name)
            local spec = specs[name]
            local hp, hr = FaceHold.pose(addr, spec.bone or name)
            if hp then
                if spec.kind == "pos" then return hp end
                return nil, hr
            end
            local j = joints[name]
            if spec.kind == "pos" then return M_LPOS:call(j) end
            return nil, M_LROT:call(j)
        end,
    }
end

-- Returns { n1, joint1, n2, joint2, ... } and the number of joints found; missing joints are skipped.
-- `bones` and `signals` ride on the same handle (hash fields, so #handle still counts fcParam pairs).
function A.bind(face, keys)
    M_LPOS = M_LPOS or sdk.find_type_definition("via.Joint"):get_method("get_LocalPosition")
    M_LROT = M_LROT or sdk.find_type_definition("via.Joint"):get_method("get_LocalRotation")
    local out = {}
    for _, n in ipairs(keys) do
        local j = n <= 200 and jbn(face, string.format("fcParam_%03d", n))
        if j then out[#out + 1] = n; out[#out + 1] = j end
    end
    -- the fcParam joints' addresses, for one ShapeKeySystem_Native.dll call per read
    local addresses = {}
    for k = 2, #out, 2 do
        local ok, address = pcall(function() return out[k]:get_address() end)
        if not (ok and address) then addresses = nil; break end
        addresses[#addresses + 1] = address
    end
    out.addresses = addresses
    out.bones = bind_bones(face, keys)
    out.signals = BoneReads.bind(face, keys, bone_sigs, jbn)
    return out, #out // 2 + (out.signals and #out.signals.list or 0)
end

function A.read(handle, P, inv_full)
    local native = rawget(_G, "sks_native")
    local flat = handle.addresses and #handle.addresses > 0 and type(native) == "table"
        and type(native.joint_positions) == "function" and select(2, pcall(native.joint_positions, handle.addresses))
    if type(flat) == "table" then
        for k = 1, #handle, 2 do
            local z = flat[(k + 1) // 2 * 3]
            P[handle[k]] = type(z) == "number" and z * inv_full or 0
        end
    else
        for k = 1, #handle, 2 do
            local p = M_LPOS:call(handle[k + 1])
            P[handle[k]] = p and p.z * inv_full or 0
        end
    end
    if handle.signals then BoneReads.read(handle.signals, P) end
    local b = handle.bones
    if not b then return end
    -- bone values are already 0..1, the same scale as P (fcParam z normalised by full)
    local values = B.evaluate(b.calibration, b.sample)
    for key, v in pairs(values) do
        local n = b.raw_of[key]
        if v > (P[n] or 0) then P[n] = v end
    end
end

A.model_names = "armor_names.json"   -- in builtin/mhwilds/
-- the last digit of a part id (Arm, Body, Helmet, Leg, Waist)
A.slot_names = { ["1"] = "腕部", ["2"] = "躯干", ["3"] = "头部", ["4"] = "腿部", ["5"] = "腰部" }

-- ch03_012_0014 -> "ch03_012_001", "4"; the representative is the slot-2 part of the model
function A.model_of(part)
    if type(part) ~= "string" then return nil end
    local model, slot = part:match("^(ch%d+_%d+_%d+)(%d)$")
    return model, slot
end

function A.representative_of(part)
    local model = A.model_of(part)
    return model and (model .. "2") or nil
end

A.probe = Probe.run

-- ---------------------------------------------------------------- lifecycle
-- Returns ok, reason, kind; kind is "load", "playing" or "setup" when not ok. The player is only
-- looked at every 10 frames while it is not set up (it may be mid-rebuild).
local setup = false
function A.gate(frame)
    local dm = sdk.get_managed_singleton("app.DemoMediator")   -- persistent manager, safe to poll
    local busy = dm and call(M_DEMO_BUSY, dm) or false
    local load = dm and call(M_DEMO_LOAD, dm) or false
    dm = nil
    if busy or load then
        setup = false
        if load then return false, "cutscene loading", "load" end
        return false, "cutscene playing", "playing"
    end
    if setup or frame % 10 == 0 then setup = A.primary_ready() end
    if not setup then return false, "player not set up", "setup" end
    return true
end

local function hook_post(type_name, method, fn)
    pcall(function()
        local t = sdk.find_type_definition(type_name)
        local m = t and t:get_method(method)
        if m then sdk.hook(m, nil, function(r) pcall(fn); return r end) end
    end)
end

local function hook_cutscene(T_DEMO, events)
    if not T_DEMO then return end
    for _, name in ipairs({ "requestSkip", "execSkip", "requestStop(ace.DemoMediatorBase.cParamBase)",
                            "requestForceStop", "unload(ace.DemoMediatorBase.cParamBase)" }) do
        pcall(function()
            local m = T_DEMO:get_method(name)
            if m then sdk.hook(m, function() pcall(events.release, name:match("^[%w_]+")) end, nil) end
        end)
    end
    pcall(function()
        local m = T_DEMO:get_method("onPlayStartTimeline(System.Int32)")
        if m then
            sdk.hook(m, function(args)
                local idx
                pcall(function() idx = sdk.to_int64(args[3]) & 0xFFFFFFFF end)
                pcall(events.segment, idx)
            end, nil)
        end
    end)
end

-- types without which nothing works (the primary character); the rest degrade on their own
local REQUIRED = { "app.PlayerManager" }

function A.init(events)
    for _, t in ipairs(REQUIRED) do
        if not sdk.find_type_definition(t) then return false, L.f("找不到类型 %s（游戏更新后改名了？）", t) end
    end
    local T_DEMO = sdk.find_type_definition("app.DemoMediator")
    M_DEMO_BUSY = T_DEMO and T_DEMO:get_method("get_IsBusy")
    M_DEMO_LOAD = T_DEMO and T_DEMO:get_method("get_IsBusyLoad")

    -- a missing or invalid calibration only disables the bone fallback
    bones, A.bones_error = load_bones()

    hook_cutscene(T_DEMO, events)
    -- any hunter rebuilt its equipment: the meshes may be new even when the part names are not
    hook_post("app.HunterCharacter", "onEquipBuildEnd", events.rebuilt)
    for _, e in ipairs({ { "app.GUI010100", "onOpen" }, { "app.GUI010101", "onOpen" },
                         { "app.GUI010102", "onOpen" }, { "app.GUI010102", "onClose" } }) do
        local name, open = e[1]:sub(5), e[2] == "onOpen"
        hook_post(e[1], e[2], function() events.menu(name, open) end)
    end
    -- the guild card preview hunter spawns some time after onOpen
    hook_post("app.GUI040200", "onOpen", function() events.preview(true) end)
    hook_post("app.GUI040200", "onClose", function() events.preview(false) end)
    return true
end

return A
