-- ShapeKeySystem for MH Wilds
-- Drives armour mesh shape keys from the hunter's facial animation (expression system) and,
-- from M2 on, holds static sculpt values. Backend: ShapeKeySystem_Core/API.lua.
-- Data: reframework/data/ShapeKeySystem/{settings.json, builtin/, mods/, user/}

local SKS = require("ShapeKeySystem_Core.API")
local DebugUI = require("ShapeKeySystem_Core.DebugUI")
-- fixed to MH Wilds: there is no adapter registry yet
local Game = require("ShapeKeySystem_Games.Wilds.Adapter")

-- also installs the adapter's hooks (write safety: release on cutscene skip / stop, rescan after
-- equipment rebuilds and menus)
SKS.init(Game)
DebugUI.attach(SKS)

re.on_application_entry("LateUpdateBehavior", function()
    local ok, err = pcall(SKS.tick)
    if not ok then SKS.state.debug.status = "tick error: " .. tostring(err) end
end)

-- standalone panel (M3), drawn with reframework-d2d when it is installed, else with REFramework's
-- own ImGui draw list (settings.ui_backend: auto / d2d / imgui, see ShapeKeySystem_UI/Draw.lua).
-- With neither only the imgui debug panel exists.
local D = require("ShapeKeySystem_UI.Draw")
local Panel = require("ShapeKeySystem_UI.Panel")
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
if D.has_d2d() then d2d.register(function() end, function() draw_panel("d2d") end) end

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
