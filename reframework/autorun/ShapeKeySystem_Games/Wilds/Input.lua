-- ShapeKeySystem: MH Wilds side of the panel input blocker (ShapeKeySystem_UI/InputBlocker.lua).
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
-- While the panel blocks input: app.GameInputManager player / UI inputs are cleared after each
-- update, app.GUIManager.isMouseCursorAvailable answers true so the game frees the OS cursor, and
-- the game's mouse deltas are read and zeroed before UpdateMotionFrame (the camera stays still).

local I = {}

local T_POINT

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

-- Installs the game hooks once. is_enabled() is read on every call; failed(text) reports a hook
-- that could not be installed, forced() counts each cursor release.
function I.install(is_enabled, failed, forced)
    T_POINT = sdk.find_type_definition("via.Point")
    local td = sdk.find_type_definition("app.GameInputManager")
    if not td then failed("app.GameInputManager"); return end
    for _, e in ipairs({ { "updatePlayerInput()", true }, { "updateUIInput()", false } }) do
        local m = td:get_method(e[1])
        if m then
            local player = e[2]
            local ok, e2 = pcall(sdk.hook, m, nil, function(r)
                if is_enabled() then clear_game_inputs(player) end
                return r
            end)
            if not ok then failed(e[1] .. " " .. tostring(e2)) end
        else
            failed(e[1])
        end
    end
    -- in the field the game keeps the mouse relative and pulls the OS cursor back to the screen
    -- centre every frame (via.hid.Mouse setters do not stick); its menus free the cursor through
    -- isMouseCursorAvailable, so answering true lets the game itself release it
    local gm = sdk.find_type_definition("app.GUIManager")
    local m = gm and gm:get_method("isMouseCursorAvailable()")
    if m then
        local ok, e2 = pcall(sdk.hook, m, nil, function(r)
            if is_enabled() then forced(); return sdk.to_ptr(true) end
            return r
        end)
        if not ok then failed("isMouseCursorAvailable " .. tostring(e2)) end
    else
        failed("app.GUIManager.isMouseCursorAvailable")
    end
end

-- Reads this frame's mouse delta and wheel, then clears them on the game side.
-- Returns dx, dy (nil when unreadable), wheel; nothing when the manager is missing.
function I.capture_mouse()
    local dx, dy, wheel
    local ok = pcall(function()
        local mgr = sdk.get_managed_singleton("app.AppMouseKeyboardManager")
        local mk = mgr and mgr:call("get_MainMouseKeyboard")
        if not mk then error("no mouse") end
        local w = mk:call("get_MouseWheelDelta")
        wheel = (type(w) == "number") and w or 0
        local p = mk:call("get_MouseDeltaPos")
        if p then dx, dy = point_xy(p) end
        pcall(function() mk:call("clear") end)
        zero_field(mk, "_MouseDeltaPos")
        zero_field(mk, "_MouseMovePos")
        zero_field(mk, "_MouseRawDeltaPos")
        pcall(function() mk:set_field("_MouseWheel", 0) end)
        pcall(function() mk:set_field("_MouseWheelDelta", 0) end)
    end)
    if not ok then return nil end
    return dx, dy, wheel
end

return I
