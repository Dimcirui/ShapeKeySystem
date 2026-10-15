-- ShapeKeySystem: clear RE4R managed mouse input while the panel reads the native device.
-- Only typed mouse fields are cleared; cursor settings are restored after button release.
local I = {}
local mouse_type, point_type, left_button
local live, enabled, forced, last_error
local saved, wheel = nil, 0
local waiting_release, installed = false, false
local counters = { calls = 0, blocked = 0, bypass = 0, errors = 0, hooks = 0 }

local function other_panel()
    local states = rawget(_G, "__AVM_UI_INPUT_BLOCKER_STATES")
    if type(states) ~= "table" then return false end
    for id, on in pairs(states) do
        if id ~= "ShapeKeySystem" and on == true then return true end
    end
    return false
end
local function raw_read(fn)
    local result = table.pack(pcall(fn))
    if not result[1] then counters.errors = counters.errors + 1; return nil end
    return table.unpack(result, 2, result.n)
end
local function native(name, ...)
    local mouse = sdk.get_native_singleton("via.hid.Mouse")
    if not mouse then return nil end
    return sdk.call_native_func(mouse, mouse_type, name, ...)
end
local function xy(p)
    if not p then return nil, nil end
    local ok, x, y = pcall(function() return sdk.get_native_field(p, point_type, "x"), sdk.get_native_field(p, point_type, "y") end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    ok, x, y = pcall(function() return p.x, p.y end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
end
local function physical()
    return raw_read(function()
        local device = native("get_Device()")
        if not device then return nil end
        local dx, dy = xy(device:call("get_DeltaPosition()"))
        return { buttons = device:call("get_Button()"), released = device:call("get_ButtonUp()"), dx = dx, dy = dy,
            wheel = device:call("get_WheelDelta()") }
    end)
end
local function released(state)
    return state and state.buttons == 0 and state.released == 0
end
local function restore_cursor()
    if not saved or other_panel() then return end
    local state = saved
    local ok = pcall(function()
        if state.absolute ~= nil then native("set_AbsoluteMode(System.Boolean)", state.absolute) end
        if state.clip ~= nil then native("set_ClipCursorToScreen(System.Boolean)", state.clip) end
    end)
    if ok then saved = nil else counters.errors = counters.errors + 1 end
end
local function release_cursor()
    if other_panel() then return end
    local ok = pcall(function()
        if not saved then
            local absolute, clip = native("get_AbsoluteMode()"), native("get_ClipCursorToScreen()")
            saved = { absolute = type(absolute) == "boolean" and absolute or nil,
                clip = type(clip) == "boolean" and clip or nil }
        end
        local changed = false
        if saved.absolute ~= nil and native("get_AbsoluteMode()") ~= true then
            native("set_AbsoluteMode(System.Boolean)", true); changed = true
        end
        if saved.clip ~= nil and native("get_ClipCursorToScreen()") ~= false then
            native("set_ClipCursorToScreen(System.Boolean)", false); changed = true
        end
        if changed then forced() end
    end)
    if not ok then counters.errors = counters.errors + 1 end
end
local function frame()
    if not live then return end
    if enabled() then waiting_release = true; release_cursor(); return end
    wheel = 0
    if waiting_release then
        local state = physical()
        if not released(state) then return end
        waiting_release = false
    end
    restore_cursor()
end

local layouts, device_type
local function should_block()
    if not live or other_panel() then return false end
    if enabled() then waiting_release = true; return true end
    if waiting_release then
        if not released(physical()) then return true end
        waiting_release = false
        restore_cursor()
    end
    return false
end

local function clear_device(device)
    if not device or not device:get_type_definition():is_a(device_type) then
        counters.rejected = (counters.rejected or 0) + 1
        return false
    end
    for _, field in ipairs(layouts) do
        for byte = 0, field.size - 1 do device:write_byte(field.offset + byte, 0) end
    end
    counters.blocked = counters.blocked + 1
    return true
end

function I.install(is_enabled, failed, on_forced)
    if installed then return end
    installed, live, enabled, forced = true, true, is_enabled, on_forced
    mouse_type = sdk.find_type_definition("via.hid.Mouse")
    point_type = sdk.find_type_definition("via.Point")
    device_type = sdk.find_type_definition("share.hid.Device")
    if not mouse_type or not device_type or not thread or not thread.get_hook_storage then
        live = false; failed("RE4R managed mouse or hook API unavailable"); return
    end
    local seen_errors = {}
    local function report(err)
        counters.errors = counters.errors + 1
        local text = tostring(err)
        last_error = text
        if not seen_errors[text] then seen_errors[text] = true; failed(text) end
    end
    local valid, why = pcall(function()
        layouts = {}
        local object_size = device_type:get_size()
        for _, item in ipairs({
            { "MouseButtonTrigger", "via.hid.MouseButton", 4 },
            { "MouseButtonDown", "via.hid.MouseButton", 4 },
            { "MouseButtonRelease", "via.hid.MouseButton", 4 },
            { "MouseButtonRepeat", "via.hid.MouseButton", 4 },
            { "Wheel", "System.Single", 4 }, { "WheelDelta", "System.Single", 4 },
            { "MovePosition", "via.Point", 8 }, { "RawMovePosition", "via.Point", 8 },
        }) do
            local field = device_type:get_field("<" .. item[1] .. ">k__BackingField")
            if not field or field:is_static() then error("mouse field missing: " .. item[1]) end
            local td = field:get_type()
            local offset, size = field:get_offset_from_base(), td:get_valuetype_size()
            if td:get_full_name() ~= item[2] or size ~= item[3]
                or type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0
                or offset + size > object_size then error("mouse field layout mismatch: " .. item[1]) end
            for _, previous in ipairs(layouts) do
                if offset < previous.offset + previous.size and previous.offset < offset + size then
                    error("overlapping mouse fields")
                end
            end
            layouts[#layouts + 1] = { name = item[1], offset = offset, size = size }
        end
        left_button = sdk.find_type_definition("via.hid.MouseButton"):get_field("L"):get_data(nil)
    end)
    if not valid then live = false; report(why); return end
    local function hook(td, signature, pre, post)
        local ok, err = pcall(function()
            local method = td and td:get_method(signature)
            if not method then error("method unavailable: " .. signature) end
            sdk.hook(method, pre, post)
            counters.hooks = counters.hooks + 1
        end)
        if not ok then report(err) end
    end
    hook(device_type, "update()", function(args)
        local storage = thread.get_hook_storage()
        storage.sks_re4r_device = nil
        local ok, err = pcall(function()
            if should_block() then storage.sks_re4r_device = sdk.to_managed_object(args[2]) end
        end)
        if not ok then report(err) end
    end, function(retval)
        local storage = thread.get_hook_storage()
        local device = storage.sks_re4r_device
        storage.sks_re4r_device = nil
        if device then
            counters.calls = counters.calls + 1
            local ok, err = pcall(function()
                if should_block() and clear_device(device) then
                    counters.device_updates = (counters.device_updates or 0) + 1
                end
            end)
            if not ok then report(err) end
        end
        return retval
    end)
    if counters.hooks == 0 then live = false; failed("RE4R managed mouse hooks unavailable"); return end
    re.on_frame(frame)
    re.on_script_reset(function()
        live, waiting_release, wheel = false, false, 0
        restore_cursor()
    end)
end

function I.capture_mouse()
    if not live then return nil end
    local state = physical()
    if not state then return nil end
    if type(state.wheel) == "number" then wheel = wheel + state.wheel end
    return state.dx, state.dy, 0
end
function I.left_down()
    if not live then return false end
    local state = physical()
    return state ~= nil and type(state.buttons) == "number" and type(left_button) == "number"
        and (state.buttons & left_button) ~= 0
end
function I.take_wheel() local value = wheel; wheel = 0; return value end
function I.diagnostics()
    return { candidate = "RE4R managed mouse clearing r7", live = live == true, hooks = counters.hooks,
        calls = counters.calls, blocked = counters.blocked, ui_bypass = counters.bypass,
        errors = counters.errors, device_updates = counters.device_updates or 0,
        keyassign_updates = counters.keyassign_updates or 0, layouts = layouts,
        rejected = counters.rejected or 0, last_error = last_error,
        waiting_release = waiting_release, other_panel = other_panel() }
end
function I.status()
    return string.format("鼠标拦截 %d 次 / 读取 %d 次 · 错误 %d", counters.blocked, counters.calls, counters.errors)
end
return I
