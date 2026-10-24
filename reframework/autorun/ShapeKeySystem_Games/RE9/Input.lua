-- ShapeKeySystem: reset RE9 command conditions while the shared panel reads physical input.
-- Hook references stay in per-thread call stacks. Native HID devices remain readable by the
-- panel's virtual cursor and hotkeys; commands resume only after held mouse/keyboard keys lift.
local L = require("ShapeKeySystem_Core.I18n")
local I = {}
local installed, live, enabled, failed = false, false
local provider_type, condition_type, conditions_field, mouse_type, point_type, left_button
local frame, epoch, waiting, release_frame, was_blocked = 0, 0, false, nil, false
local checked_frame, released_keys = -1, false
local primed, wheel, wheel_frame = {}, 0, -1
local counters = {hooks = 0, updates = 0, resets = 0, errors = 0}
local last_error

local function report(why)
    counters.errors = counters.errors + 1
    last_error = tostring(why)
    if counters.errors == 1 then failed(last_error) end
end
local function other_panel()
    local states = rawget(_G, '__AVM_UI_INPUT_BLOCKER_STATES')
    if type(states) ~= 'table' then return false end
    for id, on in pairs(states) do if id ~= 'ShapeKeySystem' and on == true then return true end end
    return false
end
local function native(name, ...)
    local mouse = sdk.get_native_singleton('via.hid.Mouse')
    if mouse then return sdk.call_native_func(mouse, mouse_type, name, ...) end
end
local function physical()
    local device = native('get_Device()')
    return device and {device = device, buttons = device:call('get_Button()'), up = device:call('get_ButtonUp()')}
end
local function all_released()
    if checked_frame == frame then return released_keys end
    checked_frame, released_keys = frame, false
    local ok, yes = pcall(function()
        local state = physical()
        if not state or state.buttons ~= 0 or state.up ~= 0 then return false end
        for key = 8, 255 do if reframework:is_key_down(key) then return false end end
        return true
    end)
    released_keys = ok and yes == true
    return released_keys
end
local function blocked()
    if not live or other_panel() then return false end
    if enabled() then
        if not was_blocked then epoch = epoch + 1; primed = {} end
        was_blocked, waiting, release_frame = true, true, nil
        return true
    end
    was_blocked = false
    if waiting then
        if not all_released() then release_frame = nil
        elseif not release_frame then release_frame = frame
        elseif frame > release_frame + 1 then waiting = false; primed = {} end
    end
    return waiting
end
local function conditions(provider)
    if not provider or not provider:get_type_definition():is_a(provider_type) then return end
    local list = conditions_field:get_data(provider)
    local n = list and list:call('get_Length()')
    if type(n) == 'number' and n >= 0 and n <= 4096 and n % 1 == 0 then return list, n end
end
local function reset(list, n, index)
    if type(index) ~= 'number' or index < 0 or index >= n or index % 1 ~= 0 then return end
    local condition = list:call('get_Item(System.Int32)', index)
    if condition and condition:get_type_definition():is_a(condition_type) then
        condition:call('resetCondition()')
        counters.resets = counters.resets + 1
    end
end
local function hook(method, pre, post)
    sdk.hook(method, pre, post)
    counters.hooks = counters.hooks + 1
end
function I.install(is_enabled, on_failed)
    if installed then return end
    installed, enabled, failed = true, is_enabled, on_failed
    local ok, why = pcall(function()
        if not thread or not thread.get_hook_storage then error('RE9 hook storage unavailable') end
        provider_type = sdk.find_type_definition('app.GameInputProvider')
        condition_type = sdk.find_type_definition('app.GameInputCondition')
        mouse_type = sdk.find_type_definition('via.hid.Mouse')
        point_type = sdk.find_type_definition('via.Point')
        if not provider_type or not condition_type or not mouse_type or not point_type then error('RE9 input types unavailable') end
        conditions_field = provider_type:get_field('_InputConditions')
        if not conditions_field or conditions_field:is_static()
            or conditions_field:get_type():get_full_name() ~= 'app.GameInputCondition[]' then error('RE9 condition array mismatch') end
        local update = provider_type:get_method('update(System.Single)')
        local update_condition = provider_type:get_method('updateCondition(System.Int32)')
        if not update or update:get_return_type():get_full_name() ~= 'System.Int32'
            or not update_condition or update_condition:get_return_type():get_full_name() ~= 'System.Boolean'
            or not condition_type:get_method('resetCondition()') then error('RE9 condition methods unavailable') end
        left_button = sdk.find_type_definition('via.hid.MouseButton'):get_field('L'):get_data(nil)
        hook(update, function(args)
            local good, err = pcall(function()
                if not blocked() then return end
                local provider = sdk.to_managed_object(args[2])
                local address = provider and provider:get_address()
                if not address or primed[address] == epoch then return end
                local list, n = conditions(provider)
                if not list then return end
                for i = 0, n - 1 do reset(list, n, i) end
                primed[address] = epoch
            end)
            if not good then report(err) end
        end, nil)
        hook(update_condition, function(args)
            local storage = thread.get_hook_storage()
            local stack = storage.sks_re9_condition or {}
            storage.sks_re9_condition = stack
            local good, context = pcall(function()
                if not blocked() then return false end
                return {provider = sdk.to_managed_object(args[2]), index = sdk.to_int64(args[3])}
            end)
            stack[#stack + 1] = good and context or false
            if not good then report(context) end
        end, function(retval)
            local stack = thread.get_hook_storage().sks_re9_condition
            local context = stack and table.remove(stack)
            if context then
                local good, err = pcall(function()
                    if not blocked() then return end
                    local list, n = conditions(context.provider)
                    if list then reset(list, n, context.index); counters.updates = counters.updates + 1 end
                end)
                if not good then report(err) end
            end
            return retval
        end)
        live = true
        re.on_frame(function() frame = frame + 1; blocked() end)
        re.on_script_reset(function()
            live, waiting, was_blocked, release_frame = false, false, false, nil
            primed, wheel = {}, 0
        end)
    end)
    if not ok then live = false; report(why) end
end
local function xy(point)
    local ok, x, y = pcall(function() return sdk.get_native_field(point, point_type, 'x'), sdk.get_native_field(point, point_type, 'y') end)
    if ok and type(x) == 'number' and type(y) == 'number' then return x, y end
end
function I.capture_mouse()
    if not live then return nil end
    local ok, dx, dy = pcall(function()
        local state = physical()
        if not state then return end
        local x, y = xy(state.device:call('get_DeltaPosition()'))
        if wheel_frame ~= frame then
            local value = state.device:call('get_WheelDelta()')
            if type(value) == 'number' then wheel = wheel + value end
            wheel_frame = frame
        end
        return x, y
    end)
    if not ok then report(dx); return nil end
    return dx, dy, 0
end
function I.left_down()
    if not live then return false end
    local ok, state = pcall(physical)
    return ok and state ~= nil and type(state.buttons) == 'number' and type(left_button) == 'number'
        and (state.buttons & left_button) ~= 0
end
function I.take_wheel() local value = wheel; wheel = 0; return value end
function I.diagnostics()
    return {live = live, hooks = counters.hooks, updates = counters.updates, resets = counters.resets,
        errors = counters.errors, last_error = last_error, waiting_release = waiting,
        enabled = live and enabled() == true, other_panel = other_panel(), cursor = 'shared_virtual'}
end
function I.status()
    return L.f('命令重置 %d 次 · 错误 %d', counters.resets, counters.errors)
end
return I
