-- ShapeKeySystem: write safety. Ported from the SKS_Mocap crash investigation (2026-10-09):
--   * writing weights while a hunter part is rebuilt (entering the game, end of a cutscene)
--     crashed a game worker thread on a null blendshape buffer;
--   * holding Lua references to objects the game tears down (cutscene skip / end) crashed it
--     even with every weight at 0.
-- So: nothing is touched while a cutscene loads or plays or while the player is not set up,
-- every mesh must stay ready for STABLE_FRAMES before it is written, and references are dropped
-- (and collected) the moment any of that changes.

local W = require("ShapeKeySystem_Core.Writer")
local Game = require("ShapeKeySystem_Core.Game")

local G = {}

-- (halved 2026-10-09: the crashes these guarded against were traced to BoneSystem.dll)
G.STABLE_FRAMES = 30   -- a mesh must stay ready this long before it is written to
G.SETTLE_FRAMES = 15   -- wait after a rebuild / cutscene before rescanning

local T_RMESH = sdk.find_type_definition("via.render.Mesh")
local M_READY  = T_RMESH:get_method("get_MeshReady")
local M_BS_ON  = T_RMESH:get_method("get_BlendShapeEnable")
local M_BS_REL = T_RMESH:get_method("get_BlendShapeReleasedBuffers")
local M_CN, M_WC = W.M_CN, W.M_WC

local T_DEMO = sdk.find_type_definition("app.DemoMediator")
local M_DEMO_BUSY = T_DEMO and T_DEMO:get_method("get_IsBusy")
local M_DEMO_LOAD = T_DEMO and T_DEMO:get_method("get_IsBusyLoad")

local function call(m, obj)
    if not m then return nil end
    local ok, v = pcall(m.call, m, obj)
    if ok then return v end
    return nil
end

-- Full check, used while a target warms up. (BlendShapeReleasedFixBuffers is deliberately not
-- checked: it is true on the drawn, working hunter face too.)
function G.mesh_ready(mesh)
    if not call(M_READY, mesh) then return false, "MeshReady=false" end
    if not call(M_BS_ON, mesh) then return false, "BlendShapeEnable=false" end
    if call(M_BS_REL, mesh) then return false, "BlendShapeReleasedBuffers" end
    local cn, wc = call(M_CN, mesh), call(M_WC, mesh)
    if not cn or not wc then return false, "channel count unreadable" end
    if wc < cn then return false, "weight buffer not allocated" end
    return true
end

-- Cheap per-frame check once a target is stable (2 calls).
function G.mesh_still_ready(mesh)
    return call(M_READY, mesh) == true and call(M_BS_REL, mesh) ~= true
end

-- Game-level gate. Returns ok, reason. The player object is only looked at every 10 frames
-- while it is not set up (it may be mid-rebuild).
local setup = false
-- Onimusha: no cutscene or player-setup types are known there yet, so the gate is only "is there a
-- controlling player". Without one (title, loading) the meshes we held may already be gone:
-- kind "gone" lets go of them without a last write.
local function onimusha_stable()
    if Game.master_root() then return true end
    return false, "no player", "gone"
end

function G.game_stable(frame)
    if Game.id == "onimusha" then return onimusha_stable() end
    local dm = sdk.get_managed_singleton("app.DemoMediator")   -- persistent manager, safe to poll
    local busy = dm and call(M_DEMO_BUSY, dm) or false
    local load = dm and call(M_DEMO_LOAD, dm) or false
    dm = nil
    if busy or load then
        setup = false
        if load then return false, "cutscene loading", "load" end
        return false, "cutscene playing", "playing"
    end
    if setup or frame % 10 == 0 then
        local ok = false
        pcall(function()
            ok = sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer")
                :get_field("<Character>k__BackingField"):call("get_IsSetUp") == true
        end)
        setup = ok
    end
    if not setup then return false, "player not set up", "setup" end
    return true
end

function G.release_refs() collectgarbage("collect") end

-- Cutscene hooks (all pre-hooks, so references are gone before the game acts):
--   on_release(reason): skip / stop requested, or the cutscene unloads (unload runs twice)
--   on_segment(index):  onPlayStartTimeline(i), the start of each cutscene segment
function G.hook_cutscene(on_release, on_segment)
    if not Game.hooks then return end
    if not T_DEMO then return end
    for _, name in ipairs({ "requestSkip", "execSkip", "requestStop(ace.DemoMediatorBase.cParamBase)",
                            "requestForceStop", "unload(ace.DemoMediatorBase.cParamBase)" }) do
        pcall(function()
            local m = T_DEMO:get_method(name)
            if m then sdk.hook(m, function() pcall(on_release, name:match("^[%w_]+")) end, nil) end
        end)
    end
    pcall(function()
        local m = T_DEMO:get_method("onPlayStartTimeline(System.Int32)")
        if m then
            sdk.hook(m, function(args)
                local idx
                pcall(function() idx = sdk.to_int64(args[3]) & 0xFFFFFFFF end)
                pcall(on_segment, idx)
            end, nil)
        end
    end)
end

-- Calls on_rebuild() after any hunter finishes building its equipment (the meshes we hold may
-- have been replaced even when the part names did not change).
function G.hook_equip_build(on_rebuild)
    if not Game.hooks then return end
    pcall(function()
        local m = sdk.find_type_definition("app.HunterCharacter"):get_method("onEquipBuildEnd")
        if m then sdk.hook(m, nil, function(r) pcall(on_rebuild); return r end) end
    end)
end

-- Title / save-select screens (post-hooks): on_menu(name, open). The preview hunters are built
-- around these, so every open / close drops our references and schedules rescans.
function G.hook_menus(on_menu)
    if not Game.hooks then return end
    -- GUI010100 onClose runs many times per frame on the title screen (froze the game
    -- 2026-10-09): title GUIs hook onOpen only, as lua bone system does
    local list = { { "app.GUI010100", { "onOpen" } }, { "app.GUI010101", { "onOpen" } },
                   { "app.GUI010102", { "onOpen", "onClose" } } }
    for _, e in ipairs(list) do
        local tn = e[1]
        pcall(function()
            local t = sdk.find_type_definition(tn)
            if not t then return end
            for _, mn in ipairs(e[2]) do
                local m = t:get_method(mn)
                if m then
                    sdk.hook(m, nil, function(r) pcall(on_menu, tn:sub(5), mn == "onOpen"); return r end)
                end
            end
        end)
    end
end

return G
