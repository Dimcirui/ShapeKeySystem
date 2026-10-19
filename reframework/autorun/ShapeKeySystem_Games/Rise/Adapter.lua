-- ShapeKeySystem: Monster Hunter Rise character discovery and bone-projected expression signals.
-- The game has no shape key driver joints. Expression signals come from face_base's face joints
-- (Core BoneSignals with builtin/mhrise/face.json): face_base keeps animating while a mod head in an
-- armor part hides it, and mod parts carry no face joints of their own.
-- The primary character is the cutscene's hunter copy while one plays, else the master player, else
-- the first player slot with a face.
--
-- Constraints:
-- - Channel names come from get_ChannelNameHash through get_Item (`hash_item_only`).
--   getBlendShapeChannelName returns "" from Lua and crashed the game when called from C#.
-- - Mod meshes in armor slots come with a weight count of 0 (no weight buffer), so Core never
--   writes them. prepare_parts raises the count to the channel count, and only when the managed
--   weight list is already that long: writing past the buffer can freeze the game.
-- - face_base (the player's face) only anchors the rig and is not a part: Core zeroes parts when it
--   lets go, which would wipe the character's face sculpt values.
-- - The player face never blinks; eyeBlink only follows expression eyelids, and the idle mouth
--   breathing stays below jawOpen's `lo`. `procedural` lets Core's procedural layer supply the
--   blinking and the idle mouth opening in its default (fallback) mode; gaze follows from the
--   missing eye joints.
local B = require("ShapeKeySystem_Core.BoneSignals")
local A = {
    id = "mhrise",
    name = "Monster Hunter Rise",
    terms = { primary = "猎人", part = "防具" },
    hash_names = true, hash_item_only = true,
    scene_search = false,
    raw = B.raw, read = B.read,
    procedural = { blink = true, breath = true },
}

local M_JBN, T_MOTION
local calibration
local EVENT_OK, LIST_OK = false, false
local disabled = {}   -- optional sources that init turned off, with the missing type or method

-- A face is any transform carrying these joints, not only face_base: cutscene actors name theirs
-- DummyFace, and mod armor heads stop at Head_00.
local FACE_SIG = { "Head_00", "L_Up_Eyelib", "L_Lo_Eyelib", "Jaw_00", "L_Cheek_00", "L_Eye" }
local FACE_NAMES = { "face_base", "DummyFace" }

local function q(obj, method, ...)
    if obj == nil then return nil end
    local ok, v = pcall(obj.call, obj, method, ...)
    if ok then return v end
    return nil
end

local function array_len(arr)
    local n = q(arr, "get_Length")
    if type(n) ~= "number" then n = q(arr, "get_Count") end
    return type(n) == "number" and n or 0
end

local function go_name(tr)
    local ok, name = pcall(function() return tr:call("get_GameObject"):call("get_Name") end)
    return ok and name or nil
end

function A.is_face(tr)
    if not tr or not M_JBN then return false end
    for _, bone in ipairs(FACE_SIG) do
        local ok, joint = pcall(M_JBN.call, M_JBN, tr, bone)
        if not ok or joint == nil then return false end
    end
    return true
end

function A.face_rank(tr) return A.is_face(tr) and 1 or 0 end

local function face_of(root)
    if not root then return nil end
    local ok, face = pcall(function()
        local c, n = root:call("get_Child"), 0
        while c and n < 64 do
            if A.is_face(c) then return c end
            c, n = c:call("get_Next"), n + 1
        end
    end)
    return ok and face or nil
end

local function root_of(player)
    return q(q(player, "get_GameObject"), "get_Transform")
end

-- Sources, first hit wins. Each returns { kind, root, ready, face? } and is resolved again on every
-- call, so no transform outlives a cutscene teardown here (Guard rules).
-- 1. A cutscene plays its own copy of the hunter (snow.eventcut.EventPlayer); the master player
--    stays loaded but off screen.
local function from_event()
    if not EVENT_OK then return nil end
    local em = sdk.get_managed_singleton("snow.eventcut.EventManager")
    if not em or not (q(em, "get_Playing") == true or q(em, "get_PlayingOrCheckScene") == true
        or q(em, "get_HoldingHandler") == true) then return nil end
    local handlers = q(em, "get_LoadHandlerStack")
    for i = 0, math.min(array_len(handlers), 8) - 1 do
        local players = q(q(q(handlers, "get_Item", i), "get_Manager"), "get_EventPlayerList")
        for j = 0, math.min(array_len(players), 8) - 1 do
            local ep = q(players, "get_Item", j)
            if ep and q(ep, "get_Valid") == true then
                local face
                for _, name in ipairs(FACE_NAMES) do
                    local tr = q(q(ep, "findGameObjectChild", name), "get_Transform")
                    if A.is_face(tr) then face = tr; break end
                end
                local root = q(ep, "getTransform")
                face = face or face_of(root)
                if root and face then return { kind = "event", root = root, face = face, ready = true } end
            end
        end
    end
    return nil
end

-- 2. The master player.
local function from_master()
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    local root = root_of(q(pm, "findMasterPlayer"))
    if not root then return nil end
    return { kind = "master", root = root, ready = q(pm, "isReadyPlayerLoad") == true }
end

-- 3. Any player slot with a face, for scenes where findMasterPlayer answers nil (title, character
--    edit).
local function from_player_list()
    if not LIST_OK then return nil end
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not pm then return nil end
    local list
    for _, name in ipairs({ "PlayerList", "PlayerListPrivate" }) do
        local ok, v = pcall(pm.get_field, pm, name)
        if ok and v then list = v; break end
    end
    for i = 0, math.min(array_len(list), 16) - 1 do
        local root = root_of(q(list, "get_Item", i))
        local face = face_of(root)
        if face then return { kind = "list", root = root, face = face, ready = true } end
    end
    return nil
end

local function source()
    local src = from_event() or from_master() or from_player_list()
    A.primary_source = src and src.kind or nil
    return src
end

function A.primary_root()
    local src = source()
    return src and src.root or nil
end

function A.primary_ready()
    local src = source()
    return src ~= nil and src.ready == true
end

-- armor slots: f_ / m_ (sex) + slot + equipment number, e.g. f_body279
local SLOTS = { arm = "腕甲", body = "铠甲", helm = "头盔", leg = "腿甲", wst = "腰甲" }
function A.is_part(name)
    local slot = type(name) == "string" and name:match("^[fm]_(%a+)%d+$")
    return slot ~= nil and SLOTS[slot] ~= nil
end

A.slot_names = SLOTS

-- f_body279 -> "f_279", "body": the parts of one equipment number share a binding; the body part
-- represents the set
function A.model_of(part)
    if not A.is_part(part) then return nil end
    local sex, slot, number = part:match("^([fm])_(%a+)(%d+)$")
    return sex .. "_" .. number, slot
end

function A.representative_of(part)
    local model = A.model_of(part)
    if not model then return nil end
    local sex, number = model:match("^([fm])_(%d+)$")
    return sex .. "_body" .. number
end

function A.eye_joints() return {} end

function A.bind(face, keys) return B.bind(face, keys, calibration) end

-- every face_base joint, so recordings can recalibrate any rule (tools/rise_calibrate.py)
local FACE_JOINTS = {
    "L_Up_Eyelib", "L_Lo_Eyelib", "L_Corner_Eyelib", "L_Eye", "R_Up_Eyelib", "R_Lo_Eyelib", "R_Corner_Eyelib", "R_Eye",
    "L_Nose", "R_Nose", "L_Cheek_00", "R_Cheek_00", "L_Cheek_01", "R_Cheek_01", "L_Cheek_02", "R_Cheek_02",
    "L_Corner_Mouth", "R_Corner_Mouth", "Up_Mouth", "L_Up_Mouth_00", "R_Up_Mouth_00", "L_Up_Mouth_01", "R_Up_Mouth_01",
    "Lo_Mouth", "L_Lo_Mouth_00", "R_Lo_Mouth_00", "L_Lo_Mouth_01", "R_Lo_Mouth_01",
    "L_SmileLine_00", "R_SmileLine_00", "L_SmileLine_01", "R_SmileLine_01",
    "UnderMouth", "L_UnderMouth_00", "R_UnderMouth_00", "L_UnderMouth_01", "R_UnderMouth_01",
    "Jaw_00", "Jaw_01", "Chin", "Throat", "Brow", "L_Brow_00", "R_Brow_00", "L_Brow_01", "R_Brow_01",
}

-- face motion layer 1 as "bank/id": idle is 12/30 and 12/1, gesture visemes 12/140..146
local function motion_of(face)
    local ok, id = pcall(function()
        local layer = face:call("get_GameObject"):call("getComponent(System.Type)", T_MOTION):call("getLayer", 1)
        return tostring(layer:call("get_MotionBankID")) .. "/" .. tostring(layer:call("get_MotionID"))
    end)
    return ok and id or nil
end

function A.native_snapshot()
    local src = source()
    if not src or not src.ready then return nil, "猎人尚未就绪" end
    local face = src.face or face_of(src.root)
    if not face then return nil, "找不到面部骨架" end
    local h = A.bind(face, {})
    local outputs, measured = B.read(h, {}, 1)
    local result = { outputs = outputs, measurements = {}, taps = {}, calibration = calibration,
        motion = motion_of(face), driver = src.kind, disabled = disabled }
    result.joints, result.status = B.snapshot_joints(face, calibration, FACE_JOINTS)
    for name, value in pairs(measured) do
        if B.finite(value) then result.measurements[name] = value end
    end
    local ok, addr = pcall(face.get_address, face)
    result.source = tostring(go_name(face)) .. "@" .. tostring(ok and addr or "-")
    return result
end

local function call(obj, method, ...)
    local ok, v = pcall(obj.call, obj, method, ...)
    if ok then return v end
    return nil
end

-- Per scanned part: allocate the weight buffer.
function A.prepare_parts(parts)
    for _, part in ipairs(parts) do
        local m, n = part.mesh, part.n
        local wc = call(m, "get_BlendShapeChannelWeightCount")
        if type(wc) == "number" and wc < n and call(m, "get_MeshReady") == true then
            local list = call(m, "get_ChannelWeightList")
            local length = list and call(list, "get_Length")
            if type(length) == "number" and length >= n and call(m, "get_BlendShapeChannelNum") == n then
                call(m, "set_BlendShapeChannelWeightCount", n)
            end
        end
    end
end

function A.gate()
    if not A.primary_ready() then return false, "player not ready" end
    return true
end

function A.init()
    for _, spec in ipairs({
        { "snow.player.PlayerManager", "findMasterPlayer()", "isReadyPlayerLoad()" },
        { "via.Transform", "getJointByName(System.String)" },
        { "via.render.Mesh", "set_BlendShapeChannelWeightCount(System.UInt64)", "get_ChannelWeightList()", "get_MeshReady()" },
    }) do
        local t = sdk.find_type_definition(spec[1])
        if not t then return false, "找不到类型 " .. spec[1] end
        for i = 2, #spec do
            if not t:get_method(spec[i]) then return false, "找不到方法 " .. spec[1] .. "." .. spec[i] end
        end
    end
    M_JBN = sdk.find_type_definition("via.Transform"):get_method("getJointByName(System.String)")
    T_MOTION = sdk.typeof("via.motion.Motion")
    local ok, data = pcall(json.load_file, "ShapeKeySystem/builtin/mhrise/face.json")
    if not ok then return false, "崛起面部标定文件无法读取" end
    local valid, why = B.validate(data, { label = "崛起" })
    if not valid then return false, why end
    calibration = data

    -- optional sources: a missing type or method turns that source off, not the adapter
    -- (findGameObjectChild and getTransform are declared on snow.BehaviorRoot, get_Valid on via.Component)
    local function has(specs)
        for _, spec in ipairs(specs) do
            local t = sdk.find_type_definition(spec[1])
            if not t then return false, spec[1] end
            for i = 2, #spec do
                if not t:get_method(spec[i]) then return false, spec[1] .. "." .. spec[i] end
            end
        end
        return true
    end
    local missing
    EVENT_OK, missing = has({
        { "snow.eventcut.EventManager", "get_LoadHandlerStack()", "get_Playing()", "get_PlayingOrCheckScene()",
            "get_HoldingHandler()" },
        { "snow.eventcut.EventcutHandler", "get_Manager()" },
        { "snow.eventcut.UniqueEventManager", "get_EventPlayerList()" },
        { "snow.BehaviorRoot", "getTransform()", "findGameObjectChild(System.String)" },
        { "via.Component", "get_Valid()" },
    })
    if not EVENT_OK then disabled.event = missing end
    local pmt = sdk.find_type_definition("snow.player.PlayerManager")
    for _, name in ipairs({ "PlayerList", "PlayerListPrivate" }) do
        local ok, f = pcall(pmt.get_field, pmt, name)
        LIST_OK = LIST_OK or (ok and f ~= nil)
    end
    if not LIST_OK then disabled.list = "snow.player.PlayerManager.PlayerList" end
    return true
end

return A
