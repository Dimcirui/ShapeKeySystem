local repo, variant, game = assert(arg[1]), assert(arg[2]), arg[3] or "re4"
package.path = repo .. "/reframework/autorun/?.lua;" .. package.path
sdk = { typeof = function(n) return n end,
    find_type_definition = function()
        return { get_method = function(_, name)
            return { call = function(_, object, ...) return object:call(name, ...) end }
        end }
    end }
local cond, touch = { values = {}, active = false }, { values = {}, active = false }
for _, state in ipairs({cond, touch}) do
    state.any = function() return state.active end
    state.for_key = function(name, value) return state.values[name] or value end
end
package.loaded["ShapeKeySystem_Core.CondExpr"] = cond
package.loaded["ShapeKeySystem_Core.Touch"] = touch
package.loaded["ShapeKeySystem_Core.BoneSignals"] = { by_key = {},
    finite = function(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end,
    validate = function() return true end }
package.loaded["ShapeKeySystem_Core.FaceHold"] = {}
package.loaded["ShapeKeySystem_Games.RE4R.NativeFace"] = {}
package.loaded["ShapeKeySystem_Games.RE4R.NativeDeform"] = {}
local ExtModule = require("ShapeKeySystem_Core.External")
for _, state in ipairs({cond, touch}) do
    state.targets = function(out) if state.active then for name in pairs(state.values) do out[ExtModule.norm(name)] = true end end end
    state.for_key = function(name, value)
        if not state.active then return value end
        for key, v in pairs(state.values) do if ExtModule.norm(name) == ExtModule.norm(key) then value = v end end
        return value
    end
end
local W = require("ShapeKeySystem_Core.Writer")
local S = require("ShapeKeySystem_Core.Sculpt")
local G = require("ShapeKeySystem_Core.Guard")
local Ext = require("ShapeKeySystem_Core.External")
local Hash = require("ShapeKeySystem_Core.NameHash")
local Signals
if game == "re9" then
    -- RE9 authorizes a write only when the key name hashes to the channel's own hash.
    Signals = require("ShapeKeySystem_Games.RE9.Signals")
    assert(Signals.configure({schema = "sks.re9-native/1", native_names = {"native_input"}, taps = {}}))
else
    Signals = require("ShapeKeySystem_Games.RE4R.Signals")
    assert(Signals.configure({native_names = {"native_input"}, joints = {}, rules = {}}))
end
local PREFIX = game == "re9" and "" or "SK."
W.adapter = { id = game, strict_bounds = true, rewrite_active_weights = true,
    channel_writable = Signals.writable, write_context = Signals.write_context, active_sculpt = variant == "B", batch_weights = variant == "B" }
local writes, sdk_calls = 0, 0
local function mesh(address)
    local m = { weights = {}, names = {}, hashes = {}, ready = true, count = 128, length = 128 }
    for i = 1, m.count do
        m.names[i] = string.format("%sshape_%03d", PREFIX, i)
        m.hashes[i] = Hash.hash(m.names[i])
    end
    m.names[128], m.hashes[128] = "native_input", Hash.hash("native_input")
    function m:get_address() return address end
    function m:call(name, index, value)
        sdk_calls = sdk_calls + 1
        if name == "get_MeshReady" or name == "get_BlendShapeEnable" then return self.ready end
        if name == "get_BlendShapeReleasedBuffers" then return false end
        if name == "get_BlendShapeChannelNum" or name == "get_BlendShapeChannelWeightCount" then return self.count end
        if name == "get_ChannelWeightList" then return { call = function() return self.length end } end
        if name == "get_ChannelNameHash" then
            if self.missing_hashes then return nil end
            return { call = function(_, method, i)
                assert(method == "get_Item")
                return self.hashes[i + 1]
            end }
        end
        if name:match("^getBlendShapeChannelWeightParam") then return self.weights[index] or 0 end
        if name == "setBlendShapeChannelWeightParam(System.UInt64, System.Single)" then
            assert(index >= 0 and index < self.length, "out of bounds write")
            assert(math.type(value) == "float", "integer engine value")
            assert(self.hashes[index + 1] ~= Hash.hash("native_input"), "native input overwritten")
            self.weights[index] = value
            writes = writes + 1
            return
        end
        error("unknown mock call " .. name)
    end
    return m
end
local a, b = mesh(100), mesh(200)
a.names[128], b.names[128] = "", ""
local parts = { { id = "head", mesh = a, names = a.names }, { id = "body", mesh = b, names = b.names } }
local own = { [a] = { [0] = true }, [b] = { [0] = true } }
local function presets(id)
    local p = { values = { shape_010 = 0.25 }, overrides = {} }
    if id == "body" then p.values.shape_010 = 0.4 end
    return p, p
end
local function rebuild()
    S.rebuild(parts, own, presets)
    for _, t in ipairs(S.K.targets) do t.stable = G.STABLE_FRAMES end
end
rebuild()
local states = 0
local function step(label, edit, preview, expected_error)
    local n, err = S.tick(edit or false, preview or false, 0.001)
    assert((err ~= nil) == (expected_error == true), tostring(err))
    local values = { "STATE", label }
    for _, m in ipairs({a, b}) do
        for i = 0, m.count - 1 do values[#values + 1] = string.format("%.6f", m.weights[i] or 0) end
    end
    print(table.concat(values, ":"))
    states = states + 1
    return n
end
step("initial")
for i = 1, 20 do step("idle" .. i) end
assert(S.set("shape_020", 0.7)); step("set")
assert(a.weights[19] == 0.7 and b.weights[19] == 0.7)
a.weights[19], b.weights[19] = 0, 0
step("engine_refresh")
assert(a.weights[19] == 0.7 and b.weights[19] == 0.7, "active values were not rewritten")
assert(S.set_override("shape_020", "body", 0.2)); step("override")
assert(S.set_override("shape_020", "body", nil)); step("override_removed")
assert(S.set("shape_020", 0)); step("zero")
assert(a.weights[19] == 0 and b.weights[19] == 0)
assert(S.undo()); step("undo")
assert(S.redo()); step("redo")
S.apply_preset({values = {shape_030 = 0.9}, overrides = {body = {shape_030 = 0.6}}}); step("preset")
step("preview", false, true); step("preview_end")
cond.active, cond.values.shape_040 = true, 0.8; step("condition")
cond.values.shape_040 = 0.3; step("condition_changed")
cond.active, cond.values = false, {}; step("condition_end")
touch.active, touch.values.shape_050 = true, 0.9; step("touch")
touch.active, touch.values = false, {}; step("touch_end")
Ext.set("test", "shape_060", 0.85, 0); step("external")
Ext.set("test", "shape_060", 0.15, 0); step("external_changed")
Ext.release_all("test"); step("external_end")
Ext.set("test", "SHAPE-030", 0, 0); step("external_zero")
assert(a.weights[29] == 0 and b.weights[29] == 0)
Ext.release_all("test"); step("external_zero_release")
assert(a.weights[29] == 0.9 and b.weights[29] == 0.6)
cond.active, cond.values["SHAPE-050"] = true, 0.4; step("normalized_condition")
assert(a.weights[49] == 0.4)
cond.active, cond.values = false, {}; step("normalized_condition_release")
assert(S.clear_all()); step("clear")
assert(S.undo()); step("clear_undo")
assert(S.reset_all()); step("reset")
assert(S.set("shape_070", 0.00001)); step("small_active")
assert(S.set("shape_070", 0)); step("small_zero")
S.set("shape_080", 0.5); a.ready = false
local prior = writes; step("not_ready", false, false, true)
assert(writes == prior)
a.ready = true; step("ready_again")
a.length = 4; prior = writes; step("short_buffer", false, false, true)
assert(writes == prior)
a.length = 128; step("buffer_restored")
S.set("shape_080", 0.6); a.missing_hashes = true; step("missing_hashes")
a.missing_hashes = false; step("hashes_restored")
S.set("shape_080", 0); a.missing_hashes = true; step("zero_rejected")
a.missing_hashes = false; step("zero_retry")
assert(a.weights[79] == 0)
rebuild(); step("rescan_same_mesh")
S.clear_targets(); rebuild(); step("rebind")
local batch = W.begin_batch and W.begin_batch(a)
assert(not W.set_weight(a, 127, 0.9, "a_safe_alias", batch), "protected live hash was ignored")
assert(not W.set_weight(a, 999, 0.9, "shape", batch), "invalid index was accepted")
local target = {mesh = a, slots = {1}, idxs = {0}, last = {0}, count = 1, channels = 128,
    names = a.names, ready = true}
assert(W.write_target(target, {0.7}, false, 0.001) == 1)
a.weights[0] = 0
assert(W.write_target(target, {0.7}, false, 0.001) == 1 and a.weights[0] == 0.7)
assert(W.write_target(target, {0}, false, 0.001) == 1 and a.weights[0] == 0)
assert(W.write_target(target, {0}, false, 0.001) == 0)
print(string.format("RESULT variant=%s states=%d writes=%d sdk_calls=%d",
    variant, states, writes, sdk_calls))

