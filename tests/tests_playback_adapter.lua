-- 独立的引擎替身验证荒野写入边界；结束后恢复 SDK，避免影响后续适配器检查。
local U = require("ShapeKeySystem_Core.Util")
local keep_sdk, keep_thread, keep_entry = sdk, thread, re.on_pre_application_entry
local failures = 0
local function check(ok, label)
    print((ok and "ok   " or "FAIL ") .. "[playback adapter] " .. label)
    if not ok then failures = failures + 1 end
end
local A = assert(loadfile((ENTRY:gsub("ShapeKeySystem.lua$", "ShapeKeySystem_Games/Wilds/Playback.lua"))))()
local catalog = A.catalog()
local values, writes, layer_addr, swapped = { [0] = 0.002, [1] = 0.003 }, {}, 300, false
local indexes = { [catalog[1]] = 0, [catalog[7]] = 1 }
local layer = { get_address = function() return layer_addr end }
function layer:call(m, index, value)
    if m == "get_ValueCount" then return 2 end
    if m == "getValueIndexByNameHash(System.UInt32)" then
        return swapped and -1 or indexes[index]
    end
    if m == "getExtraValue(System.Int32)" then return values[index] end
    if m == "setExtraValue(System.Int32, System.Single)" then
        assert(math.type(value) == "float", "engine write must be a float")
        values[index] = value; writes[#writes + 1] = { index, value }; return
    end
    error(m)
end
local controller = { get_address = function() return 200 end }
local motion = { call = function(_, m) if m == "getLayerCount" then return 1 else return layer end end }
local face = { get_address = function() return 100 end }
local go = { call = function(_, m, ty)
    if m == "get_Name" then return "Player_Face" end
    if ty == "app.FacialController" then return controller end
    if ty == "via.motion.Motion" then return motion end
end }
function face:call(m)
    if m == "get_GameObject" then return go end
    if m == "getJointByName(System.String)" then return {} end
    error(m)
end
local root = { call = function() return face end }
local player = {
    get_field = function() return { call = function() return true end } end,
    call = function() return { call = function() return root end } end,
}
local pre, post, storage, update = nil, nil, {}, nil
sdk = {
    get_managed_singleton = function(n)
        if n == "app.PlayerManager" then return { call = function() return player end } end
        return { call = function() return false end }
    end,
    find_type_definition = function() return { get_method = function() return {} end } end,
    typeof = function(n) return n end,
    get_native_singleton = function() return {} end,
    call_native_func = function() return 1 end,
    to_managed_object = function(v) return v end,
    hook = function(_, p, q) pre, post = p, q end,
}
thread = { get_hook_storage = function() return storage end }
re.on_pre_application_entry = function(name, fn) if name == "UpdateMotion" then update = fn end end
local injects, ticks = 0, 0
A.attach({ inject = function() injects = injects + 1 end,
    tick = function(v) if v then ticks = ticks + 1 end end,
    fail = function(e) error(e) end })
check(A.hook_ready and update and pre and post, "selected adapter installs motion and face callbacks")
local clip = { track = "raw", map = { [1] = 1, [7] = 2 }, hashes = { catalog[1], catalog[7] } }
A.connect(clip); A.inject({ 0.01, 0.0 })
check(values[0] == 0.01 and values[1] == 0 and #writes == 2, "raw values are written once in engine units")
pre({ [2] = { get_address = function() return 999 end }, [4] = layer }); post(0)
check(injects == 0, "another character does not receive replay injection")
pre({ [2] = controller, [4] = layer }); post(0); update()
check(injects == 2 and ticks == 1, "matching callbacks inject before and after facial evaluation")
A.stop(true)
check(values[0] == 0.002 and values[1] == 0.003, "stopping restores the original extra values")
A.connect(clip); A.inject({ 0.01, 0.0 }); swapped = true
local count = #writes
check(not pcall(A.inject, { 0.0, 0.0 }) and #writes == count,
    "changed parameter indexes prevent the entire batch from writing")
A.stop(true)
check(#writes == count, "stale parameter indexes are not used for restoration")
swapped = false; A.connect(clip); A.inject({ 0.01, 0.0 }); layer_addr = 301
count = #writes
check(not A.valid() and not pcall(A.inject, { 0, 0 }), "replaced layer invalidates the session")
A.stop(true)
check(#writes == count, "a replaced layer receives no restoration through old references")
sdk, thread, re.on_pre_application_entry = keep_sdk, keep_thread, keep_entry
print("PLAYBACK ADAPTER FAILS:", failures)
assert(failures == 0, "playback adapter regression")
