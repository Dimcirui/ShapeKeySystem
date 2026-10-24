-- ShapeKeySystem: block RE4R mouse data and gameplay commands while the panel reads native input.
-- Command dictionaries are cleared after mapping; native keyboard input remains available to
-- REFramework and text fields. Closing waits for keyboard release before restoring commands.
local L = require("ShapeKeySystem_Core.I18n")
local I = {}
local mouse_type, point_type, left_button
local live, enabled, forced, last_error
local saved, wheel = nil, 0
local waiting_release, installed = false, false
local waiting_keys, key_release_frame, frame_number = false, nil, 0
local key_poll_frame, keys_up = -1, false
local command_fields, command_type
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
    frame_number = frame_number + 1
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

local function keyboard_released()
    if key_poll_frame == frame_number then return keys_up end
    key_poll_frame, keys_up = frame_number, true
    -- Virtual keys 1..6 are mouse buttons; all keyboard keys include the panel hotkey.
    for key = 8, 255 do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if not ok or down == true then keys_up = false; break end
    end
    return keys_up
end

local function block_commands()
    if not live or other_panel() then return false end
    if enabled() then waiting_keys, key_release_frame = true, nil; return true end
    if waiting_keys then
        if not keyboard_released() then key_release_frame = nil
        elseif not key_release_frame then key_release_frame = frame_number
        elseif frame_number > key_release_frame + 1 then waiting_keys = false end
    end
    return waiting_keys
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
    local command_ok, command_error = pcall(function()
        command_type = sdk.find_type_definition("share.hid.Command")
        if not command_type then error("share.hid.Command unavailable") end
        command_fields = {}
        for _, name in ipairs({ "_Triggers", "_Downs", "_Releases", "_Floats", "_Points", "_Vec2s", "_Vec3s", "_Quaternions" }) do
            local field = command_type:get_field(name)
            local td = field and field:get_type()
            if not field or field:is_static() or not td
                or not td:get_full_name():find("System.Collections.Concurrent.ConcurrentDictionary`2<System.UInt32,", 1, true) then
                error("command dictionary layout mismatch: " .. name)
            end
            local clear
            for _, method in ipairs(td:get_methods()) do
                if method:get_name() == "Clear" and #(method:get_param_types() or {}) == 0 then clear = method; break end
            end
            if not clear then error("command dictionary Clear unavailable: " .. name) end
            command_fields[#command_fields + 1] = { field = field, clear = clear }
        end
        for index, method in ipairs(command_type:get_methods()) do
            local name = method:get_name()
            if name == "update" or name == "updateKeyAssign" or name == "updateExtraCommand" then
                local storage_key = "sks_re4r_command_" .. index
                sdk.hook(method, function(args)
                    local storage = thread.get_hook_storage()
                    local stack = storage[storage_key] or {}
                    storage[storage_key] = stack
                    local ok, object = pcall(function()
                        return block_commands() and sdk.to_managed_object(args[2]) or false
                    end)
                    stack[#stack + 1] = ok and object or false
                    if not ok then report(object) end
                end, function(retval)
                    local stack = thread.get_hook_storage()[storage_key]
                    local object = stack and table.remove(stack)
                    if object then
                        local ok, err = pcall(function()
                            if not block_commands() or not object:get_type_definition():is_a(command_type) then return end
                            for _, entry in ipairs(command_fields) do
                                local dictionary = entry.field:get_data(object)
                                if dictionary then entry.clear:call(dictionary) end
                            end
                            counters.command_updates = (counters.command_updates or 0) + 1
                        end)
                        if not ok then report(err) end
                    end
                    return retval
                end)
                counters.command_hooks = (counters.command_hooks or 0) + 1
            end
        end
        if not counters.command_hooks then error("RE4R command update hooks unavailable") end
    end)
    if not command_ok then report(command_error) end
    re.on_frame(frame)
    re.on_script_reset(function()
        live, waiting_release, wheel = false, false, 0
        waiting_keys, key_release_frame = false, nil
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
    return { candidate = "RE4R mouse and command clearing", live = live == true, hooks = counters.hooks,
        command_hooks = counters.command_hooks or 0, command_updates = counters.command_updates or 0,
        waiting_keys = waiting_keys,
        calls = counters.calls, blocked = counters.blocked, ui_bypass = counters.bypass,
        errors = counters.errors, device_updates = counters.device_updates or 0,
        keyassign_updates = counters.keyassign_updates or 0, layouts = layouts,
        rejected = counters.rejected or 0, last_error = last_error,
        waiting_release = waiting_release, other_panel = other_panel() }
end
function I.status()
    return L.f("鼠标拦截 %d 次 · 命令拦截 %d 次 · 错误 %d", counters.blocked, counters.command_updates or 0, counters.errors)
end
return I
