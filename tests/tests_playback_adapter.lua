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
local joints = {}
function face:call(m, name)
    if m == "get_GameObject" then return go end
    if m == "getJointByName(System.String)" then
        joints[name] = joints[name] or { pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } }
        return joints[name]
    end
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
    find_type_definition = function() return { get_method = function(_, name) return { call = function(_, j)
        if name == "get_LocalPosition" then return j.pos end
        if name == "get_LocalRotation" then return j.rot end
    end } end } end,
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

-- 游戏内录制：钩子读 raw，骨骼给 final，导出后能按两条轨道解码
local Recording = require("ShapeKeySystem_Core.Recording")
local keep_playback = package.loaded["ShapeKeySystem_Games.Wilds.Playback"]
package.loaded["ShapeKeySystem_Games.Wilds.Playback"] = A
local Rec = assert(loadfile((ENTRY:gsub("ShapeKeySystem.lua$", "ShapeKeySystem_Games/Wilds/Recorder.lua"))))()
values[0], values[1] = 0.002, 0.003
joints["fcParam_001"] = { pos = { x = 0, y = 0, z = 0.004 } }
local first = Rec.snapshot()
check(first and first.taps == nil and first.status.raw and #first.params == 2 and first.params[2] == 7,
    "recorder binds only parameters with an index and a joint, raw waits for the face callback")
check(math.abs(first.outputs[1] - 0.4) < 1e-9 and first.joints.fcParam_001[3] == 0.004 and first.joints.L_EyeJ_LOD02,
    "final is the fcParam joint z in recording units")
pre({ [2] = controller, [4] = layer }); post(0)
local second = Rec.snapshot()
check(second.taps and second.taps[1] == 0.002 and second.taps[2] == 0.003, "the face callback reads raw before evaluation")
check(injects == 2, "recording alone does not inject replay values")
local samples = { { t = 1.0, values = Rec.sample(first) }, { t = 1.05, values = Rec.sample(second) } }
values[1] = 0.006; joints["fcParam_001"].pos.z = 0.002
pre({ [2] = controller, [4] = layer }); post(0)
samples[3] = { t = 1.1, values = Rec.sample(Rec.snapshot()) }
samples[4] = { t = 1.15, values = Rec.sample(Rec.snapshot()) }
samples[5] = { t = 1.2 }                         -- a gap: nothing readable
local data, dir = Rec.export({ samples = samples, rate_hz = 20, label = "说话", reason = "手动停止", game = "mhwilds" })
check(dir == "user\\recordings" and data.label == "说话" and #data.frames == 5 and data.frames[1].t == 0
    and data.duration == 0.2 and data.frames[4].d == nil, "export keeps every sample and leaves unchanged frames empty")
local raw = Recording.decode(data, "raw", catalog, "mhwilds")
local final = Recording.decode(data, "final", catalog, "mhwilds")
check(raw.frames[3].values[2] == 0.006 and math.abs(final.frames[3].values[1] - 0.2) < 1e-9
    and raw.map[7] == 2, "exported recording decodes to the recorded raw and final values")
check(raw.frames[1].values[1] == 0 and math.abs(final.frames[1].values[1] - 0.4) < 1e-9,
    "a sample before the first raw read has raw 0 and its final values")
check(raw.frames[5].values[2] == 0 and final.frames[5].values[1] == 0, "a gap is recorded as zero signals")
check(A.describe(data).name == "说话" and A.describe({}).name == nil, "recording label is the playback list name")
local stale = { controller_addr = 200, layer_addr = layer_addr, indices = { 0 }, touched = os.clock() - 2 }
A.watch(stale)
pre({ [2] = controller, [4] = layer }); post(0)
check(stale.raw == nil, "a registration not renewed for a second is dropped without reading")
-- 过场里按正在驱动的面部录制；读不到的时段记为 0 信号，只有手动停止或到上限才保存
local NS = require("ShapeKeySystem_Core.NativeSignals")
local keep_on_export, exported = NS.on_export, false
NS.on_export = function() exported = true end
local wilds = { id = "mhwilds", native_snapshot = Rec.snapshot, native_sample = Rec.sample, native_export = Rec.export }
local function wait(s) local t = os.clock() + s; repeat until os.clock() >= t end
local function frame(stable) wait(0.06); pre({ [2] = controller, [4] = layer }); post(0); NS.tick(wilds, stable, { face = face }) end
NS.command(wilds, { action = "start", label = "猫饭" })
NS.tick(wilds, "hold", {})
check(NS.state.recording and NS.state.samples == 1 and NS.state.status:find("记为 0", 1, true),
    "a start while the cutscene segment settles begins with a zero gap")
frame(true); frame(true)
wait(0.06); NS.tick(wilds, "hold", {})
check(NS.state.recording and NS.state.status:find("等待过场", 1, true), "a settling segment records a gap without ending the take")
wait(0.06); NS.tick(wilds, false, {})
check(NS.state.recording, "an unavailable character does not end the take")
wait(0.6); values[0] = 0.008
frame(true); frame(true); frame(true)
local taken = NS.state.samples
NS.command(wilds, { action = "stop" }); NS.tick(wilds, true, { face = face })
local saved = NS.state.file and U.load_json(NS.state.file)
check(exported and saved and NS.state.file:find("user\\recordings\\mhwilds_", 1, true) and saved.label == "猫饭",
    "stopping saves a playable Wilds recording and refreshes the list")
local replay = saved and Recording.decode(saved, "raw", catalog, "mhwilds")
check(replay and replay.frames[#replay.frames].values[1] == 0.008, "samples after a pause carry the new raw input")
check(replay and #replay.frames == taken and saved.stop_reason == "手动停止", "only the manual stop ends the take, every sample kept")
NS.on_export = keep_on_export
package.loaded["ShapeKeySystem_Games.Wilds.Playback"] = keep_playback
sdk, thread, re.on_pre_application_entry = keep_sdk, keep_thread, keep_entry
print("PLAYBACK ADAPTER FAILS:", failures)
assert(failures == 0, "playback adapter regression")
