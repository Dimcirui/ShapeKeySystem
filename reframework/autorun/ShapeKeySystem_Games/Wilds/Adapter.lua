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

local A = {
    id = "mhwilds",
    name = "Monster Hunter Wilds",
    conditions = Cond,
    input = Input,
    playback = Playback,
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

function A.eye_joints(face)
    return { L = jbn(face, "L_EyeJ_LOD02"), R = jbn(face, "R_EyeJ_LOD02") }
end

-- ---------------------------------------------------------------- signals
-- Raw channels are fcParam numbers 0..200; a channel's value is the z of its fcParam_NNN joint's
-- local position, normalised by the dictionary's `full`.
A.raw = {
    term = "fcParam",
    slider = { min = 0, max = 200, fmt = "%03d" },
    parse = function(v)
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "p 必须是有限数值" end
        if n < 0 or n > 200 then return nil, "fcParam out of range: " .. tostring(v) end
        return math.floor(n)
    end,
    label = function(n) return string.format("fcParam_%03d", n) end,
}

local M_LPOS

-- Returns { n1, joint1, n2, joint2, ... } and the number of joints found; missing joints are skipped.
function A.bind(face, keys)
    M_LPOS = M_LPOS or sdk.find_type_definition("via.Joint"):get_method("get_LocalPosition")
    local out = {}
    for _, n in ipairs(keys) do
        local j = jbn(face, string.format("fcParam_%03d", n))
        if j then out[#out + 1] = n; out[#out + 1] = j end
    end
    return out, #out // 2
end

function A.read(handle, P, inv_full)
    for k = 1, #handle, 2 do
        local p = M_LPOS:call(handle[k + 1])
        P[handle[k]] = p and p.z * inv_full or 0
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
        if not sdk.find_type_definition(t) then return false, "找不到类型 " .. t .. "（游戏更新后改名了？）" end
    end
    local T_DEMO = sdk.find_type_definition("app.DemoMediator")
    M_DEMO_BUSY = T_DEMO and T_DEMO:get_method("get_IsBusy")
    M_DEMO_LOAD = T_DEMO and T_DEMO:get_method("get_IsBusyLoad")

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
