-- ShapeKeySystem panel: keeps the game from reacting to mouse / keyboard while the panel is open.
--
-- Adapted from ArmorVariantManager (ArmorVariantManager_UI/Service/InputBlocker.lua,
-- https://github.com/Monkeysama/ArmorVariantManager):
--   MIT License, Copyright (c) 2026 MK
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
--   and associated documentation files (the "Software"), to deal in the Software without
--   restriction, including without limitation the rights to use, copy, modify, merge, publish,
--   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions: The above copyright
--   notice and this permission notice shall be included in all copies or substantial portions of
--   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
--   PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
--   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
--   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.
--
-- What it does while enabled:
--   * post-hooks app.GameInputManager updatePlayerInput / updateUIInput and clears those inputs
--   * before UpdateMotionFrame: reads the wheel, zeroes the mouse deltas (camera stays still)
--   * puts via.hid.Mouse into absolute mode with the game's cursor hidden (the panel draws its
--     own); the previous mode is restored when disabled
-- No UI DLL: AVM's bridge (custom cursor / IME) is not used.
--
-- Coexistence with ArmorVariantManager (same audience, both may be installed):
--   * we register in AVM's shared table _G.__AVM_UI_INPUT_BLOCKER_STATES under "ShapeKeySystem",
--     so either mod sees when the other blocks input (B.others_active())
--   * the original mouse mode is saved only when nobody else blocks (otherwise we would save the
--     other mod's modified state), and restored only when nobody else blocks any more; a restore
--     that had to wait is done by B.frame() once the other mod lets go (this also repairs a
--     restore of a wrong saved state by the other side)

local I18n = require("ShapeKeySystem_Core.I18n")
local Game = require("ShapeKeySystem_Core.Game")

local B = {
    enabled = false, installed = false, failed = {}, last_error = nil,
    wheel = 0, saved = nil, last_mode_at = 0,
    cursor = nil,     -- virtual cursor, screen px
    pinned = false,   -- the OS cursor sits at the screen centre (game owns the mouse)
    reapplied = 0,    -- unused since the GUIManager hook (kept for the status line)
    forced = 0,       -- isMouseCursorAvailable answers we forced to true (diagnostics)
    delta = { 0, 0 }, -- last non-zero mouse delta seen (diagnostics)
}

local ID = "ShapeKeySystem"
local function registry()
    local t = rawget(_G, "__AVM_UI_INPUT_BLOCKER_STATES")
    if type(t) ~= "table" then t = {}; rawset(_G, "__AVM_UI_INPUT_BLOCKER_STATES", t) end
    return t
end

-- another mod (AVM) blocks input right now
function B.others_active()
    for id, on in pairs(registry()) do
        if id ~= ID and on == true then return true, id end
    end
    return false
end

local function publish(on)
    registry()[ID] = on == true
    local any = on == true or B.others_active()
    rawset(_G, "__AVM_REFD2D_INPUT_BLOCKED", any)
end

local T_MOUSE = sdk.find_type_definition("via.hid.Mouse")
local T_POINT = sdk.find_type_definition("via.Point")

local function err(e) B.last_error = tostring(e) end

local function mouse_call(mouse, name, ...)
    local args = table.pack(...)
    local ok, v = pcall(sdk.call_native_func, mouse, T_MOUSE, name, table.unpack(args, 1, args.n))
    if ok then return true, v end
    ok, v = pcall(function() return mouse:call(name, table.unpack(args, 1, args.n)) end)
    if ok then return true, v end
    err(v)
    return false
end

local function bool_ptr(v)
    local ok, p = pcall(sdk.to_ptr, v == true)
    return ok and p or nil
end

local function enum_value(type_name, field_name)
    local ok, v = pcall(function()
        return sdk.find_type_definition(type_name):get_field(field_name):get_data(nil)
    end)
    return ok and v or 0
end

-- Measured in game 2026-10-10 (panel open, field gameplay): the game keeps via.hid.Mouse in
-- relative mode (set_AbsoluteMode(true) never sticks) and pins the OS cursor to the screen centre;
-- with MouseManipulator = Null the mouse device reads all zero, so neither the OS cursor nor the
-- virtual cursor could move. So the manipulator and the absolute mode are left alone: the panel
-- follows the virtual cursor driven by the game's own mouse deltas, which capture_and_clear_mouse
-- then zeroes so the camera stays still. Only the game's cursor image is hidden (we draw ours).
local function set_mouse_mode(blocked)
    -- nothing to set any more: the cursor is freed through app.GUIManager.isMouseCursorAvailable
    -- (see B.install); kept so the enable / restore flow stays the same
    if not blocked then B.applied = false else B.applied = true end
end

-- builds before 2026-10-10 set MouseManipulator = Null while open; a crash / reset in between
-- could leave the game without mouse input. Repair once at load when nobody blocks input.
local function repair_null_manipulator()
    pcall(function()
        if B.others_active() then return end
        local mouse = sdk.get_native_singleton("via.hid.Mouse")
        if not mouse or not T_MOUSE then return end
        local _, manip = mouse_call(mouse, "get_MouseManipulator()")
        if manip == enum_value("via.hid.mouse.ManipulatorClientType", "Null") then
            local def = enum_value("via.hid.mouse.ManipulatorClientType", "RuntimeDefault")
            mouse_call(mouse, "set_MouseManipulator(via.hid.mouse.ManipulatorClientType)", sdk.to_ptr(def))
            B.repaired = true
        end
    end)
end

local function point_xy(p)
    local x, y
    pcall(function()
        x = sdk.get_native_field(p, T_POINT, "x")
        y = sdk.get_native_field(p, T_POINT, "y")
    end)
    if type(x) ~= "number" then pcall(function() x, y = p.x, p.y end) end
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

local function zero_field(obj, name)
    pcall(function()
        local f = obj:get_type_definition():get_field(name)
        if not f then return end
        local off, size = f:get_offset_from_base(), f:get_type():get_valuetype_size()
        for i = 0, size - 1 do obj:write_byte(off + i, 0) end
    end)
end

-- the game pins the OS cursor to the screen centre while it owns the mouse (REFramework frees
-- it only while its own menu is open). Then the panel follows a virtual cursor moved by the
-- mouse deltas; whenever the OS cursor is free, the virtual cursor is synced to it (Input.lua).
local function move_cursor(dx, dy, sw, sh)
    if not dx or (dx == 0 and dy == 0) then return end
    B.delta[1], B.delta[2] = dx, dy
    local c = B.cursor
    if not c then c = { x = sw / 2, y = sh / 2 }; B.cursor = c end
    if not B.pinned then return end
    c.x = math.max(0, math.min(sw - 1, c.x + dx))
    c.y = math.max(0, math.min(sh - 1, c.y + dy))
end

B.surface = function() return 1920, 1080 end

-- left button on the engine mouse device (fallback when imgui sees no button while the game owns
-- the mouse)
local BTN_L
function B.device_left_down()
    local down = false
    pcall(function()
        BTN_L = BTN_L or enum_value("via.hid.MouseButton", "L")
        local mouse = sdk.get_native_singleton("via.hid.Mouse")
        local dev = mouse and sdk.call_native_func(mouse, T_MOUSE, "get_Device()")
        local b = dev and dev:call("get_Button()")
        if type(b) == "number" and BTN_L and BTN_L ~= 0 then down = (b & BTN_L) ~= 0 end
    end)
    return down
end

-- engine mouse device delta (via.hid.MouseDevice.get_DeltaPosition), px this frame
function B.device_delta()
    local dx, dy
    pcall(function()
        local mouse = sdk.get_native_singleton("via.hid.Mouse")
        local dev = mouse and sdk.call_native_func(mouse, T_MOUSE, "get_Device()")
        local p = dev and dev:call("get_DeltaPosition()")
        if p then dx, dy = point_xy(p) end
    end)
    return dx, dy
end   -- set by the panel (d2d surface size)

local function capture_and_clear_mouse()
    pcall(function()
        local mgr = sdk.get_managed_singleton("app.AppMouseKeyboardManager")
        local mk = mgr and mgr:call("get_MainMouseKeyboard")
        if not mk then return end
        local w = mk:call("get_MouseWheelDelta")
        if type(w) == "number" and w ~= 0 then B.wheel = B.wheel + w end
        local p = mk:call("get_MouseDeltaPos")
        local dx, dy
        if p then dx, dy = point_xy(p) end
        if not dx or (dx == 0 and dy == 0) then dx, dy = B.device_delta() end
        local sw, sh = B.surface()
        move_cursor(dx, dy, sw, sh)
        pcall(function() mk:call("clear") end)
        zero_field(mk, "_MouseDeltaPos")
        zero_field(mk, "_MouseMovePos")
        zero_field(mk, "_MouseRawDeltaPos")
        pcall(function() mk:set_field("_MouseWheel", 0) end)
        pcall(function() mk:set_field("_MouseWheelDelta", 0) end)
    end)
end

local function clear_game_inputs(player)
    pcall(function()
        local m = sdk.get_managed_singleton("app.GameInputManager")
        if not m then return end
        local a, b
        if player then a, b = m:call("get_PcPlayerInput"), m:call("get_PlayerInput")
        else a, b = m:call("get_PcUIInput"), m:call("get_UIInput") end
        if a then pcall(function() a:call("clear") end) end
        if b then pcall(function() b:call("clear") end) end
    end)
end

function B.install()
    if B.installed then return end
    B.installed = true
    -- the hooked types are MH Wilds'; another game's types of the same name do other things
    if not Game.hooks then B.failed[#B.failed + 1] = "game input hooks: MH Wilds only"; return end
    local td = sdk.find_type_definition("app.GameInputManager")
    if not td then B.failed[#B.failed + 1] = "app.GameInputManager"; return end
    for _, e in ipairs({ { "updatePlayerInput()", true }, { "updateUIInput()", false } }) do
        local m = td:get_method(e[1])
        if m then
            local player = e[2]
            local ok, e2 = pcall(sdk.hook, m, nil, function(r)
                if B.enabled then clear_game_inputs(player) end
                return r
            end)
            if not ok then B.failed[#B.failed + 1] = e[1] .. " " .. tostring(e2) end
        else
            B.failed[#B.failed + 1] = e[1]
        end
    end
    -- Measured 2026-10-10: in the field the game keeps the mouse relative and pulls the OS cursor
    -- back to the screen centre every frame; via.hid.Mouse setters do not stick. In its menus the
    -- cursor is free, decided by app.GUIManager.isMouseCursorAvailable(). While the panel is open
    -- that answers true, so the game itself lets the cursor go.
    local gm = sdk.find_type_definition("app.GUIManager")
    local m = gm and gm:get_method("isMouseCursorAvailable()")
    if m then
        local ok, e2 = pcall(sdk.hook, m, nil, function(r)
            if B.enabled then B.forced = B.forced + 1; return sdk.to_ptr(true) end
            return r
        end)
        if not ok then B.failed[#B.failed + 1] = "isMouseCursorAvailable " .. tostring(e2) end
    else
        B.failed[#B.failed + 1] = "app.GUIManager.isMouseCursorAvailable"
    end
    re.on_pre_application_entry("UpdateMotionFrame", function() if B.enabled then capture_and_clear_mouse() end end)
end

repair_null_manipulator()

function B.set_enabled(on)
    on = on == true
    if on == B.enabled then return end
    B.enabled = on
    B.wheel = 0
    publish(on)
    if on then B.install(); B.cursor = nil; B.reapplied = 0; B.forced = 0; B.delta[1], B.delta[2] = 0, 0 end
    set_mouse_mode(on)
end

-- every game frame, open or not: finish a restore that waited for the other mod
function B.frame()
    if not B.enabled and B.saved and not B.others_active() then set_mouse_mode(false) end
end

-- one line for the status bar: is the OS cursor pinned, how often the game fought the mode
function B.diag()
    if not B.enabled then return "" end
    local L = I18n
    local hook = (#B.failed == 0) and L.t("blocker.forced", B.forced) or L.t("blocker.hook_failed", B.failed[#B.failed])
    return L.t("blocker.line", B.pinned and L.t("blocker.pinned") or L.t("blocker.free"), hook, B.delta[1], B.delta[2])
end

-- engine mouse device wheel (via.hid.MouseDevice.get_WheelDelta). Read every game frame by
-- Input.capture: the game-side AppMouseKeyboardManager wheel read before UpdateMotionFrame stayed 0.
local T_DEV = sdk.find_type_definition("via.hid.MouseDevice")
function B.poll_wheel()
    pcall(function()
        local mouse = sdk.get_native_singleton("via.hid.Mouse")
        if not mouse then return end
        for _, getter in ipairs({ "get_Device()", "get_MergedDevice()" }) do
            local dev = sdk.call_native_func(mouse, T_MOUSE, getter)
            if dev then
                local w = dev:call("get_WheelDelta()")
                if type(w) == "number" and w ~= 0 then B.wheel = B.wheel + w; return end
            end
        end
    end)
end

-- wheel notches since the last call
function B.take_wheel()
    local w = B.wheel
    B.wheel = 0
    return w
end

return B
