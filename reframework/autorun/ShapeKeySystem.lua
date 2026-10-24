-- ShapeKeySystem
-- Drives outfit mesh shape keys from the character's facial animation (expression system) and
-- holds static sculpt values. Backend: ShapeKeySystem_Core/API.lua; the game adapter is picked
-- from ShapeKeySystem_Games/Registry.lua.
-- Data: reframework/data/ShapeKeySystem/{settings.json, builtin/, mods/, user/}

local SKS = require("ShapeKeySystem_Core.API")
local DebugUI = require("ShapeKeySystem_Core.DebugUI")
local Games = require("ShapeKeySystem_Games.Registry")
local D = require("ShapeKeySystem_UI.Draw")
local Faces = require("ShapeKeySystem_UI.Faces")
local Panel = require("ShapeKeySystem_UI.Panel")
local L = require("ShapeKeySystem_Core.I18n")

-- an unsupported game (or an adapter whose types are gone after a game update) only gets a line
-- in the REFramework menu: no hooks, no callbacks, the data folder is not touched
local game = Games.game_name()
local Game = Games.pick(game)
local ok, why = false, nil
-- also installs the adapter's hooks (write safety: release on cutscene skip / stop, rescan after
-- equipment rebuilds and menus)
if Game then ok, why = SKS.init(Game) end
if not ok then
    -- translated while drawing: the interface language can change after load
    re.on_draw_ui(function()
        if imgui.tree_node("ShapeKeySystem") then
            local reason = Game and L.tr(tostring(why)) or L.f("暂不支持当前游戏（%s）", tostring(game))
            imgui.text(L.f("ShapeKeySystem 没有启动：%s", reason))
            imgui.tree_pop()
        end
    end)
    return
end
DebugUI.attach(SKS)

if Game.prepare_mesh and re.on_pre_application_entry then
    for _, stage in ipairs({ "UpdateMotion", "PrepareRendering" }) do
        re.on_pre_application_entry(stage, function()
            local ok, err = pcall(SKS.prepare_targets)
            if not ok then SKS.state.debug.status = "prepare error: " .. tostring(err) end
        end)
    end
end

-- after the animation has posed the joints (same slot as Lua Bone System): mocap head turn
re.on_application_entry("UpdateMotion", function()
    local ok, err = pcall(SKS.update_motion)
    if not ok then SKS.state.mocap.head_status = L.f("头部错误：%s", tostring(err)) end
end)

re.on_application_entry("LateUpdateBehavior", function()
    local ok, err = pcall(SKS.tick)
    if not ok then SKS.state.debug.status = "tick error: " .. tostring(err) end
end)

-- standalone panel (M3), drawn with reframework-d2d when it is installed, else with REFramework's
-- own ImGui draw list (settings.ui_backend: auto / d2d / imgui, see ShapeKeySystem_UI/Draw.lua).
-- With neither only the imgui debug panel exists.
Panel.attach(SKS)
local last_err
local function draw_panel(backend)
    if D.backend ~= backend then return end
    local ok, err = pcall(Panel.draw)
    if not ok and tostring(err) ~= last_err then
        last_err = tostring(err)
        SKS.log("panel draw error: %s", last_err)
    end
end
if D.has_d2d() then
    d2d.register(function() D.init_images(Faces.image_paths()) end, function() draw_panel("d2d") end)
end

re.on_draw_ui(DebugUI.draw)
re.on_frame(function()
    D.set_backend(D.pick(SKS.state.settings.ui_backend))
    local ok, err = pcall(Panel.frame)
    if not ok then SKS.log("panel frame error: %s", tostring(err)) end
    draw_panel("imgui")
    Panel.draw_inputs()
    DebugUI.end_frame(Panel.ui_open())
end)
re.on_script_reset(function()
    pcall(Panel.set_open, false)
    pcall(SKS.shutdown)
end)
