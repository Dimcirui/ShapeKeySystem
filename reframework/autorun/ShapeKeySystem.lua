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

-- standalone panel (M3), drawn with reframework-d2d; without d2d only the imgui debug panel exists
local Panel
if type(d2d) == "table" and d2d.register then
    Panel = require("ShapeKeySystem_UI.Panel")
    Panel.attach(SKS)
    local last_err
    d2d.register(function() end, function()
        local ok, err = pcall(Panel.draw)
        if not ok and tostring(err) ~= last_err then
            last_err = tostring(err)
            SKS.log("panel draw error: %s", last_err)
        end
    end)
end

re.on_draw_ui(DebugUI.draw)
re.on_frame(function()
    local open, signals = false, false
    if Panel then
        local ok, err = pcall(Panel.frame)
        if not ok then SKS.log("panel frame error: %s", tostring(err)) end
        open, signals = Panel.ui_open()
    end
    DebugUI.end_frame(open, signals)
end)
re.on_script_reset(function()
    if Panel then pcall(Panel.set_open, false) end
    pcall(SKS.shutdown)
end)
