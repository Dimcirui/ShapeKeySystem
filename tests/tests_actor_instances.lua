-- Independent actor programs, binding precedence and lifecycle with real Core evaluation/writes.
local M = require("ShapeKeySystem_Core.ActorInstances")
local Scene = require("ShapeKeySystem_Core.Scene")
local W = require("ShapeKeySystem_Core.Writer")
local X = require("ShapeKeySystem_Core.Expression")
local P = require("ShapeKeySystem_Core.Profile")
local Presets = require("ShapeKeySystem_Core.Presets")
local U = require("ShapeKeySystem_Core.Util")
local assertions = 0
local function check(value, message)
    assertions = assertions + 1
    assert(value, message)
    print("ok   [instances] " .. message)
end
local function call(self, name, ...) return self[name:match("^([%w_]+)")](self, ...) end
local actors, serial = {}, 100
local function actor(name, prefix, amount, yaw)
    serial = serial + 100
    local address = serial
    local mesh = {count = 4, length = 4, ready = true, values = {}, writes = 0}
    local names = {prefix.."mouth", prefix.."blink", prefix.."look", prefix.."size"}
    mesh.get_address = function() return address + 1 end
    mesh.get_BlendShapeChannelNum = function() return #names end
    mesh.get_BlendShapeChannelWeightCount = function(self) return self.count end
    mesh.get_ChannelWeightList = function() return {call = function() return mesh.length end} end
    mesh.get_MeshReady = function(self) return self.ready end
    mesh.get_BlendShapeEnable = function() return true end
    mesh.get_BlendShapeReleasedBuffers = function(self) return self.released or false end
    mesh.getBlendShapeChannelName = function(_, i) return names[i+1] end
    mesh.setBlendShapeChannelWeightParam = function(self, i, value)
        assert(i >= 0 and i < self.count and i < self.length and self.ready and not self.released)
        self.values[i], self.writes = value, self.writes+1
    end
    mesh.getBlendShapeChannelWeightParam = function(self, i) return self.values[i] or 0 end
    mesh.call = call
    local root = {version = name .. "-1", get_address = function() return address + 2 end}
    local tr = {parent = root, mouth = amount, blink = 1-amount, yaw = yaw}
    tr.get_address = function() return address end
    tr.get_GameObject = function() return {call = function(_, method)
        if method == "get_Name" then return name .. "_head" end
        if method:find("getComponent") then return mesh end
    end} end
    tr.call = call
    root.face, root.mesh, root.names = tr, mesh, names
    local fp = {}; for i, value in ipairs(names) do fp[i] = value end; table.sort(fp)
    root.fingerprint = U.fnv(table.concat(fp, "\n"))
    return root
end
local a, b = actor("leon", "A_", .2, 15), actor("ada", "B_", .8, 30)
actors = {a.face, b.face}
local enabled = true
local adapter = {id = "synthetic_instances", scoped_bindings = true, strict_bounds = true,
    rewrite_active_weights = true, raw = {parse = tonumber, label = tostring},
    primary_root = function() return ROOT end, is_face = function() return true end,
    face_root = function(face) return face.parent end, face_rank = function() return 1 end,
    signature = function(root) return root.version end,
    parts = function(root) return {root.face} end,
    part_id = function(tr) return tr.parent == a and "leon_head" or "ada_head" end,
    model_of = function(part) return part:match("^([^_]+)") end,
    representative_of = function(part) return part:match("^([^_]+)") end,
    additional_faces = function() return actors end,
    instances_ready = function() return enabled end,
    eye_joints = function(face) return {L = face, R = face} end,
    eye_angles = function(face) return face.yaw, 0 end,
    bind = function(face, keys) return {face = face, keys = keys} end,
    read = function(handle, values) for _, key in ipairs(handle.keys) do
        values[key] = key == 1 and handle.face.mouth or handle.face.blink
    end end,
    prepare_mesh = function(mesh) mesh.lod = 0 end}
Scene.adapter, W.adapter, X.adapter, P.adapter, Presets.adapter = adapter, adapter, adapter, adapter, adapter
P.load_signals({full = 1, signals = {{name = "jawOpen", raw = 1}, {name = "blink.L", raw = 2}}})
local function profile(id, prefix)
    json.dump_file("ShapeKeySystem/mods/profiles/"..id..".json", {schema = "sks.profile/1", channels = {
        {name = prefix.."mouth", group = "mouth", s = "jawOpen"},
        {name = prefix.."blink", group = "eye", s = "blink.L"},
        {name = prefix.."look", group = "gaze", eye = "L", axis = "yaw", sign = 1}}})
end
profile("profile_a", "A_"); profile("profile_b", "B_"); P.load_all()
local function own(root, name, id, neutral, gain)
    json.dump_file("ShapeKeySystem/mods/"..name.."/"..name.."_head.json", {
        schema = "sks.binding/1", profile = id, fingerprints = {[name.."_head"] = root.fingerprint},
        gains = {master_gain = gain}, eyes = {neutral = {L = {yaw = neutral, pitch = 0}}}})
end
own(a, "leon", "profile_a", 15, .5); own(b, "ada", "profile_b", 20, 1)
json.dump_file("ShapeKeySystem/mods/leon/leon.json", {profile = "legacy_wrong", global = true})
local r = Presets.resolve_binding("leon_head", nil, a.fingerprint)
local warned = false
for _, entry in ipairs(r.chain) do warned = warned or entry.error ~= nil end
check(r.data.profile == "profile_a" and warned, "fingerprinted own binding wins over unscoped stale global")
local siblings = {{id = "leon_head", fingerprint = a.fingerprint}, {id = "leon_body", fingerprint = "body"}}
r = Presets.resolve_binding("leon_body", nil, "body", siblings)
check(not r.hit, "stale global does not re-enter through an actor's body")
json.dump_file("ShapeKeySystem/user/leon/leon_head.json", {profile = "user_choice"})
r = Presets.resolve_binding("leon_head", nil, a.fingerprint)
check(r.source == "user" and r.data.profile == "user_choice", "user own binding stays above mod global")
json.dump_file("ShapeKeySystem/user/leon/leon_head.json", {deleted = true})
json.dump_file("ShapeKeySystem/mods/leon/leon.json", {profile = "profile_a", global = true,
    fingerprints = {leon_head = a.fingerprint}})
check(Presets.resolve_binding("leon_head", nil, a.fingerprint).level == "global", "matching global fingerprint retains explicit global precedence")
json.dump_file("ShapeKeySystem/mods/leon/leon.json", {profile = "legacy_wrong", global = true})
check(not Presets.validate_binding({eyes = {neutral = {L = {yaw = math.huge}}}}), "non-finite neutral calibration is rejected")
local options = {enabled = true, cutscene_drive = true, profile = "profile_a", inv_full = 1,
    clamp = true, epsilon = .001, expression = {master_gain = 1, gaze_gain = 1, smoothing = 0,
    region_gains = {}, channel_gains = {}}, eyes = {full_deg = {yaw = 10, pitch = 10},
    neutral = {L = {yaw = 99, pitch = 0}, R = {yaw = 99, pitch = 0}}, invert = {}, sets = {}}}
M.init(adapter)
for frame = 1, 60 do M.tick(frame, options); M.prepare() end
check(#M.state.errors == 0 and #M.state.instances == 2, "two distinct instances are discovered")
check(M.state.instances[1].profile == "profile_a" and M.state.instances[2].profile == "profile_b", "each actor keeps its own compiled profile")
check(math.abs(a.mesh.values[0] - .1) < 1e-6 and math.abs(b.mesh.values[0] - .8) < 1e-6, "different source signals and gains reach only their own mesh")
check(math.abs(a.mesh.values[1] - .4) < 1e-6 and math.abs(b.mesh.values[1] - .2) < 1e-6, "actors do not copy the player's blink pulse")
check(a.mesh.values[2] == 0 and b.mesh.values[2] == 1, "bound neutral poses are isolated from player calibration and each other")
check(a.mesh.lod == 0 and b.mesh.lod == 0, "render preparation includes secondary instances")
local previous = a.mesh.writes
a.mesh.length = 0
M.tick(61, options)
check(a.mesh.writes == previous, "lost weight list blocks all writes")
a.mesh.length = 4
for frame = 62, 100 do M.tick(frame, options) end
check(a.mesh.writes > previous, "ready buffers warm up again after allocation returns")
previous = b.mesh.writes
b.version = "replaced"
M.tick(101, options)
check(b.mesh.writes == previous, "signature replacement releases actor before any weight write")
M.release("skip")
previous = a.mesh.writes
actors = {}
for frame = 102, 130 do M.tick(frame, options) end
check(a.mesh.writes == previous and #M.state.instances == 0, "skip/removal releases all old references")
actors = {a.face, b.face}
for frame = 131, 230 do M.tick(frame, options) end
check(#M.state.instances == 2, "new scene actors rebuild after lifecycle settling")
options.enabled = false
M.tick(231, options)
check(a.mesh.values[0] == 0 and b.mesh.values[0] == 0, "disable clears only valid owned weights in update")
check(#M.state.instances == 0, "disable releases independent instances")
M.init({id = "other_game"})
M.tick(232, options)
check(#M.state.instances == 0, "adapters without the capability do not scan or drive extra actors")
print("ACTOR INSTANCE ASSERTIONS:", assertions)
print("ACTOR INSTANCE FAILS:", 0)
