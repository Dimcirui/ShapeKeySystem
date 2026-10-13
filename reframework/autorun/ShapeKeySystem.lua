-- ShapeKeySystem for MH Wilds
-- Drives armour mesh shape keys from the hunter's facial animation (expression system) and,
-- from M2 on, holds static sculpt values. Backend: ShapeKeySystem_Core/API.lua.
-- Data: reframework/data/ShapeKeySystem/{settings.json, builtin/, mods/, user/}

local SKS = require("ShapeKeySystem_Core.API")
local DebugUI = require("ShapeKeySystem_Core.DebugUI")

SKS.init()
DebugUI.attach(SKS)

re.on_application_entry("LateUpdateBehavior", function()
    local ok, err = pcall(SKS.tick)
    if not ok then SKS.state.debug.status = "tick error: " .. tostring(err) end
end)

-- the guild card preview hunter spawns some time after onOpen
pcall(function()
    local gc = sdk.find_type_definition("app.GUI040200")
    local open_m, close_m = gc:get_method("onOpen"), gc:get_method("onClose")
    if open_m then sdk.hook(open_m, nil, function(r) SKS.on_guild_card(true); return r end) end
    if close_m then sdk.hook(close_m, nil, function(r) SKS.on_guild_card(false); return r end) end
end)

-- write safety: release everything the moment a cutscene skip / stop is requested, and rescan
-- after any hunter rebuilds its equipment (ShapeKeySystem_Core/Guard.lua)
local Guard = require("ShapeKeySystem_Core.Guard")
Guard.hook_cutscene(SKS.on_cutscene_stop, SKS.on_cutscene_segment)
Guard.hook_equip_build(SKS.on_equip_build)
Guard.hook_menus(SKS.on_menu)

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
    DebugUI.end_frame(Panel.ui_open())
end)
re.on_script_reset(function()
    pcall(Panel.set_open, false)
    pcall(SKS.shutdown)
end)
