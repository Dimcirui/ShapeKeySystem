-- ShapeKeySystem: Onimusha character discovery and bsControl / face_joint expression signals.
-- Engine objects are resolved per call; none are kept across character rebuilds.
-- A head mod that reuses the body skeleton has no bsControl joints, only the translated
-- face_joint* bones; such a head is recognised by face_joint340 and read through the bone signals
-- of builtin/onimusha_wots/face.json (BoneReads), so only profiles naming those signals move it.
-- Cutscenes show a copy of the player (Pl000_00, face ch001_00_10_event); Core finds it by searching
-- the scene. The DemoMediator hooks are the Wilds ones (same names here) and are pre-hooks, so
-- `events.release` drops every reference before the game skips, stops or unloads.
-- Part names stay Head / Body across outfit changes, so child_tag adds each part's mesh address
-- to Core's children signature. The demon form (OniHead / OniBody) is hidden until the player
-- turns; the drawn head is the face, and child_tag adds the draw state so the switch rescans.
-- Every part of the player belongs to one model, "musashi": one binding for the whole character.
local BoneReads = require("ShapeKeySystem_Core.BoneReads")

local A = {
    id = "onimusha_wots",
    name = "Onimusha: Way of the Sword",
    terms = { primary = "主角色", part = "部件" },
    input = require("ShapeKeySystem_Games.Onimusha.Input"),
}

local M_JBN, M_BUSY, M_LOAD, M_LPOS
-- direct children of the player root (Hair hangs under Head and is not one)
local PARTS = { Head = true, Body = true, Cloak = true, Gauntlet = true, Amulet = true,
                OniHead = true, OniBody = true }
local HEADS = { Head = true, OniHead = true }
local PLAYER_MESH = "/ch001_"   -- the player character's meshes (mods replace the same files)
local T_MESH
local bone_sigs   -- BoneReads table from face.json, loaded on first use

local function sigs()
    if bone_sigs == nil then
        -- an unreadable calibration only leaves face_joint heads without signals
        local ok, data = pcall(json.load_file, "ShapeKeySystem/builtin/onimusha_wots/face.json")
        bone_sigs, A.bones_error = BoneReads.load(ok and type(data) == "table" and data.signals or nil, "鬼武者")
        bone_sigs = bone_sigs or false
    end
    return bone_sigs or nil
end

function A.primary_root()
    local ok, tr = pcall(function()
        return sdk.get_managed_singleton("app.PlayerManager"):call("getControllingPlayer")
            :call("get_Object"):call("get_Transform")
    end)
    return ok and tr or nil
end

function A.primary_ready()
    local ok, ready = pcall(function()
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        if not pm or pm:call("isPlayerReady(System.Boolean)", false) ~= true then return false end
        local player = pm:call("getControllingPlayer")
        return player ~= nil and player:call("get_Valid") == true and player:call("get_CharacterValid") == true
    end)
    return ok and ready == true
end

local function go_name(tr)
    local ok, name = pcall(function() return tr:call("get_GameObject"):call("get_Name") end)
    return ok and name or nil
end

-- nil (unknown) counts as drawn
local function drawn(tr)
    local ok, v = pcall(function() return tr:call("get_GameObject"):call("get_DrawSelf") end)
    return not ok or v ~= false
end

-- the player's face only: NPC heads carry bsControl too; a body skeleton's face_joint340 counts
-- only on a head, since Body shares that skeleton
function A.is_face(tr)
    if not M_JBN then return false end
    local ok, joint = pcall(M_JBN.call, M_JBN, tr, "bsControl_000")
    if not ok or joint == nil then
        if not HEADS[go_name(tr)] then return false end
        ok, joint = pcall(M_JBN.call, M_JBN, tr, "face_joint340")
        if not ok or joint == nil then return false end
    end
    local ok2, path = pcall(function()
        return tr:call("get_GameObject"):call("getComponent(System.Type)", T_MESH)
            :call("getMesh"):call("get_ResourcePath")
    end)
    return ok2 and type(path) == "string" and path:find(PLAYER_MESH, 1, true) ~= nil
end

-- the drawn head wins: Head normally, OniHead in the demon form
function A.face_rank(tr)
    if not HEADS[go_name(tr)] then return 0 end
    return drawn(tr) and 2 or 1
end

-- gameplay parts by slot name; the cutscene copy's parts are named after their mesh (ch001_00_10_event)
function A.is_part(name) return PARTS[name] == true or name:find("^ch001_%d+_%d+") ~= nil end

-- the mesh behind a part: a rebuild keeps the name but not the mesh
function A.child_tag(tr, name)
    if not A.is_part(name) then return nil end
    local ok, addr = pcall(function()
        return tr:call("get_GameObject"):call("getComponent(System.Type)", T_MESH):get_address()
    end)
    local tag = ok and addr and ("@" .. tostring(addr)) or "@-"
    if HEADS[name] and not drawn(tr) then tag = tag .. "~hidden" end
    return tag
end

A.slot_names = { Head = "头部", Body = "身体", Cloak = "披风", Gauntlet = "护手", Amulet = "护身符",
                 OniHead = "鬼化头部", OniBody = "鬼化身体" }

function A.model_of(part)
    if type(part) ~= "string" or not A.is_part(part) then return nil end
    return "musashi", part
end

function A.representative_of(part)
    return A.model_of(part) and "musashi" or nil
end
function A.eye_joints(face)
    local eyes = {}
    for side, name in pairs({ L = "eye_Lt", R = "eye_Rt" }) do
        local ok, joint = pcall(M_JBN.call, M_JBN, face, name)
        if ok then eyes[side] = joint end
    end
    return eyes
end

local AXES = { x = 0, y = 1, z = 2 }
local AXIS_NAMES = { [0] = "x", "y", "z" }
A.raw = {
    term = "bsControl",
    parse = function(value)
        local key, why = BoneReads.parse(sigs(), value)
        if key or why then return key, why end
        if type(value) ~= "string" then return nil, "bsControl 必须是编号和轴，如 bsControl_012.y" end
        local n, axis = value:match("^bsControl_(%d+)%.([xyz])$")
        if not n then n, axis = value:match("^(%d+)%.([xyz])$") end
        n = tonumber(n)
        if not n or n > 135 then return nil, "bsControl 编号必须为 0..135，轴必须为 x/y/z" end
        return n * 3 + AXES[axis]
    end,
    label = function(key)
        return BoneReads.label(sigs(), key) or string.format("bsControl_%03d.%s", key // 3, AXIS_NAMES[key % 3])
    end,
}

function A.bind(face, keys)
    local out, joints = {}, {}
    for _, key in ipairs(keys) do
        local number = key <= BoneReads.BASE and key // 3 or nil
        local joint = number and joints[number]
        if number and joint == nil then
            joint = M_JBN:call(face, string.format("bsControl_%03d", number))
            joints[number] = joint or false
        end
        if joint then
            out[#out + 1] = key
            out[#out + 1] = joint
            out[#out + 1] = AXIS_NAMES[key % 3]
        end
    end
    out.signals = BoneReads.bind(face, keys, sigs(), function(tr, name) return M_JBN:call(tr, name) end)
    return out, #out // 3 + (out.signals and #out.signals.list or 0)
end

function A.read(handle, P, inv_full)
    for i = 1, #handle, 3 do
        local position = M_LPOS:call(handle[i + 1])
        P[handle[i]] = position and position[handle[i + 2]] * inv_full or 0
    end
    if handle.signals then BoneReads.read(handle.signals, P) end
end

function A.gate()
    local ok, reason, kind = pcall(function()
        local dm = sdk.get_managed_singleton("app.DemoMediator")
        if not dm then return "cutscene state unavailable" end
        if M_LOAD:call(dm) then return "cutscene loading", "load" end
        if M_BUSY:call(dm) then return "cutscene playing", "playing" end
        if not A.primary_ready() then return "player not ready" end
    end)
    -- "playing" lets Core drive the cutscene copy (settings.cutscene_drive); not ready has no
    -- kind, so menus are not searched for preview characters
    if not ok then return false, "game state unavailable" end
    if reason then return false, reason, kind end
    return true
end

local function hook_cutscene(T_DEMO, events)
    for _, name in ipairs({ "requestSkip", "requestStop(ace.DemoMediatorBase.cParamBase)",
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

function A.init(events)
    local methods = {}
    for _, spec in ipairs({
        { "app.PlayerManager", "getControllingPlayer()", "isPlayerReady(System.Boolean)" },
        { "via.Transform", "getJointByName(System.String)" },
        { "via.Joint", "get_LocalPosition()" },
        { "app.DemoMediator", "get_IsBusy()", "get_IsBusyLoad()" },
    }) do
        local t = sdk.find_type_definition(spec[1])
        if not t then return false, "找不到类型 " .. spec[1] end
        for i = 2, #spec do
            local m = t:get_method(spec[i])
            if not m then return false, "找不到方法 " .. spec[1] .. "." .. spec[i] end
            methods[spec[i]] = m
        end
    end
    M_JBN = methods["getJointByName(System.String)"]
    M_LPOS = methods["get_LocalPosition()"]
    M_BUSY, M_LOAD = methods["get_IsBusy()"], methods["get_IsBusyLoad()"]
    T_MESH = sdk.typeof("via.render.Mesh")
    if events then hook_cutscene(sdk.find_type_definition("app.DemoMediator"), events) end
    return true
end

return A
