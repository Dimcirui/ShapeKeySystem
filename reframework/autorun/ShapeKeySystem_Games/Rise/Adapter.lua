-- ShapeKeySystem: Monster Hunter Rise character discovery and bone-projected expression signals.
-- The game has no shape key driver joints. Expression signals come from face_base's face joints
-- (Core BoneSignals with builtin/mhrise/face.json): face_base keeps animating while a mod head in an
-- armor part hides it, and mod parts carry no face joints of their own.
--
-- Constraints:
-- - Channel names come from get_ChannelNameHash through get_Item (`hash_item_only`).
--   getBlendShapeChannelName returns "" from Lua and crashed the game when called from C#.
-- - Mod meshes in armor slots come with a weight count of 0 (no weight buffer), so Core never
--   writes them. prepare_parts raises the count to the channel count, and only when the managed
--   weight list is already that long: writing past the buffer can freeze the game.
-- - face_base (the player's face) only anchors the rig and is not a part: Core zeroes parts when it
--   lets go, which would wipe the character's face sculpt values.
-- - The player face never blinks; eyeBlink only follows expression eyelids.
local B = require("ShapeKeySystem_Core.BoneSignals")
local A = {
    id = "mhrise",
    name = "Monster Hunter Rise",
    terms = { primary = "猎人", part = "防具" },
    hash_names = true, hash_item_only = true,
    scene_search = false,
    raw = B.raw, read = B.read,
}

local M_JBN, T_MOTION
local FACE = "face_base"
local calibration

local function master()
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    return pm, pm and pm:call("findMasterPlayer")
end

function A.primary_root()
    local ok, tr = pcall(function()
        local _, pl = master()
        return pl:call("get_GameObject"):call("get_Transform")
    end)
    return ok and tr or nil
end

function A.primary_ready()
    local ok, ready = pcall(function()
        local pm, pl = master()
        return pl ~= nil and pm:call("isReadyPlayerLoad") == true
    end)
    return ok and ready == true
end

local function go_name(tr)
    local ok, name = pcall(function() return tr:call("get_GameObject"):call("get_Name") end)
    return ok and name or nil
end

function A.is_face(tr)
    if go_name(tr) ~= FACE or not M_JBN then return false end
    local ok, joint = pcall(M_JBN.call, M_JBN, tr, "Head_00")
    return ok and joint ~= nil
end

function A.face_rank(tr) return go_name(tr) == FACE and 1 or 0 end

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

local function face_of(root)
    local ok, face = pcall(function()
        local c, n = root:call("get_Child"), 0
        while c and n < 64 do
            if A.is_face(c) then return c end
            c, n = c:call("get_Next"), n + 1
        end
    end)
    return ok and face or nil
end

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
    if not A.primary_ready() then return nil, "猎人尚未就绪" end
    local face = face_of(A.primary_root())
    if not face then return nil, "找不到 face_base" end
    local h = A.bind(face, {})
    local outputs, measured = B.read(h, {}, 1)
    local result = { outputs = outputs, measurements = {}, taps = {}, calibration = calibration,
        motion = motion_of(face) }
    result.joints, result.status = B.snapshot_joints(face, calibration, FACE_JOINTS)
    for name, value in pairs(measured) do
        if B.finite(value) then result.measurements[name] = value end
    end
    local ok, addr = pcall(face.get_address, face)
    result.source = FACE .. "@" .. tostring(ok and addr or "-")
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
    return true
end

return A
