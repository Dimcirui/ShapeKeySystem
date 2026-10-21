local failures, assertions = 0, 0
local function check(ok, label)
    assertions = assertions + 1
    print((ok and 'ok   ' or 'FAIL ') .. '[re9-input] ' .. label)
    if not ok then failures = failures + 1 end
end
local callbacks, hooks, stores, active_thread = {}, {}, {{}, {}}, 1
local enabled, held_key, buttons, button_up, bad_layout = false, false, 0, 0, false
local types = {}
local function type_of(name)
    if types[name] then return types[name] end
    local t = {name = name}
    types[name] = t
    function t:get_full_name() return self.name end
    function t:is_a(other) return self == other end
    function t:get_method(signature)
        local ret = signature == 'update(System.Single)' and 'System.Int32' or 'System.Boolean'
        return {signature = signature, get_return_type = function() return type_of(ret) end}
    end
    function t:get_field(field)
        if field == 'L' then return {get_data = function() return 1 end} end
        return {is_static = function() return false end,
            get_type = function() return type_of(bad_layout and 'System.Object[]' or 'app.GameInputCondition[]') end,
            get_data = function(_, object) return object.list end}
    end
    return t
end
local condition_type, provider_type = type_of('app.GameInputCondition'), type_of('app.GameInputProvider')
local function condition()
    return {value = 0, get_type_definition = function() return condition_type end,
        call = function(self, method) assert(method == 'resetCondition()'); self.value = 0 end}
end
local c1, c2 = condition(), condition()
local list = {n = 2, call = function(self, method, i)
    if method == 'get_Length()' then return self.n end
    assert(method == 'get_Item(System.Int32)'); return ({c1, c2})[i + 1]
end}
local provider = {list = list, get_type_definition = function() return provider_type end, get_address = function() return 123 end}
local device = {call = function(_, method)
    if method == 'get_Button()' then return buttons end
    if method == 'get_ButtonUp()' then return button_up end
    if method == 'get_DeltaPosition()' then return {x = 9, y = -3} end
    if method == 'get_WheelDelta()' then return 1 end
end}
local native_reads = 0
sdk = {find_type_definition = type_of, to_managed_object = function(o) return o end, to_int64 = function(v) return v end,
    get_native_singleton = function() return {} end,
    call_native_func = function(_, _, method) native_reads = native_reads + 1; assert(method == 'get_Device()'); return device end,
    get_native_field = function(point, _, field) return point[field] end,
    hook = function(method, pre, post) hooks[method.signature] = {pre = pre, post = post} end}
thread = {get_hook_storage = function() return stores[active_thread] end}
reframework = {is_key_down = function(_, key) return held_key and key == 46 end}
re = {on_frame = function(fn) callbacks.frame = fn end, on_script_reset = function(fn) callbacks.reset = fn end}
local I = require('ShapeKeySystem_Games.RE9.Input')
local errors = {}
check(native_reads == 0 and next(hooks) == nil, 'loading does not read SDK state or install hooks')
I.install(function() return enabled end, function(why) errors[#errors + 1] = why end)
check(I.diagnostics().live and I.diagnostics().hooks == 2 and #errors == 0, 'validated provider and condition hooks install')
local update, change = hooks['update(System.Single)'], hooks['updateCondition(System.Int32)']
local function run(index, value)
    change.pre({nil, provider, index}); ({c1, c2})[index + 1].value = value
    return change.post(27)
end
run(0, 1)
check(c1.value == 1, 'closed panel leaves gameplay inputs untouched')
enabled = true; c1.value, c2.value = 1, 1; update.pre({nil, provider})
check(c1.value == 0 and c2.value == 0, 'opening resets previously held conditions')
check(run(0, .8) == 27 and c1.value == 0, 'fresh game condition is reset without changing the update return')
active_thread = 1; change.pre({nil, provider, 0})
active_thread = 2; change.pre({nil, provider, 1}); c2.value = .9; change.post(1)
active_thread = 1; c1.value = .7; change.post(1)
check(c1.value == 0 and c2.value == 0, 'thread hook stacks keep each provider/index pair')
change.pre({nil, provider, 0}); change.pre({nil, provider, 1}); c2.value = 1; change.post(1); c1.value = 1; change.post(1)
check(c1.value == 0 and c2.value == 0 and #stores[1].sks_re9_condition == 0, 'nested calls drain their engine references')
local dx, dy = I.capture_mouse(); I.capture_mouse(); buttons = 1
check(dx == 9 and dy == -3 and I.left_down(), 'physical mouse remains available to panel dragging')
check(I.take_wheel() == 1 and I.take_wheel() == 0, 'wheel is counted once per frame')
enabled, held_key = false, true; callbacks.frame(); run(0, 1)
check(c1.value == 0, 'closing with Delete held keeps game commands blocked')
held_key = false; callbacks.frame(); run(0, 1)
check(c1.value == 0, 'held mouse button also delays resume')
buttons, button_up = 0, 1; callbacks.frame(); run(0, 1)
check(c1.value == 0, 'mouse release edge is consumed')
button_up = 0; callbacks.frame(); callbacks.frame(); callbacks.frame(); run(0, 1)
check(c1.value == 1 and not I.diagnostics().waiting_release, 'commands resume after keys and release edges clear')
enabled = true; _G.__AVM_UI_INPUT_BLOCKER_STATES = {ArmorVariantManager = true}; run(0, 1)
check(c1.value == 1, 'another panel owns its input blocking')
_G.__AVM_UI_INPUT_BLOCKER_STATES = nil; callbacks.frame(); run(1, 1)
check(c2.value == 0, 'blocking resumes after the other panel closes')
list.n = 5000; c1.value = 1; change.pre({nil, provider, 0}); change.post(1)
check(c1.value == 1, 'unbounded condition arrays are rejected')
list.n = 2; callbacks.reset(); run(0, 1)
check(c1.value == 1 and not I.diagnostics().live and not I.diagnostics().waiting_release, 'script reset makes installed hooks inert')
package.loaded['ShapeKeySystem_Games.RE9.Input'] = nil
bad_layout = true
local rejected = require('ShapeKeySystem_Games.RE9.Input')
rejected.install(function() return true end, function(why) errors[#errors + 1] = why end)
check(not rejected.diagnostics().live and #errors == 1, 'unexpected condition layout fails closed before hooking')
print('RE9 INPUT ' .. assertions .. ' assertions; FAILS: ' .. failures)
assert(failures == 0, 'RE9 Input failures')
