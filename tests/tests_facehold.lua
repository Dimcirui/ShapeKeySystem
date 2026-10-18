-- face bone hold (FaceHold.lua) and the expression on/off switch
local SKS = require("ShapeKeySystem_Core.API")
local H = require("ShapeKeySystem_Core.FaceHold")
local hf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[hold] " .. what)
    if not cond then hf = hf + 1 end
end
local near = function(a, b) return math.abs(a - b) < 1e-6 end

-- a face whose joints follow `anim` unless every layer is muted, like the engine's motion pass
local function fake_face(addr, rates)
    local f = { addr = addr, layers = {}, joints = {}, anim = 0.01 }
    for i, r in ipairs(rates) do
        local l = { rate = r }
        l.call = function(self, m, v)
            if m == "get_BlendRate" then return self.rate end
            if m == "set_BlendRate(System.Single)" then self.rate = v end
        end
        f.layers[i] = l
    end
    for _, name in ipairs({ "C_Jaw_LOD02", "C_Nose_LOD01" }) do
        local j = { name = name, pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } }
        j.get_LocalPosition = function(self) return { x = self.pos.x, y = self.pos.y, z = self.pos.z } end
        j.get_LocalRotation = function(self) return { x = self.rot.x, y = self.rot.y, z = self.rot.z, w = self.rot.w } end
        j.set_LocalPosition = function(self, v) self.pos = v; f.writes = (f.writes or 0) + 1 end
        j.set_LocalRotation = function(self, q) self.rot = q end
        f.joints[#f.joints + 1] = { joint = j, name = name }
    end
    f.get_address = function() return addr end
    -- motion pass: neutral 0.02 when muted, 0.02 + anim otherwise
    f.animate = function()
        local muted = true
        for _, l in ipairs(f.layers) do if l.rate ~= 0 then muted = false end end
        for _, j in ipairs(f.joints) do
            j.joint.pos = { x = 0, y = 0.02 + (muted and 0 or f.anim), z = 0 }
            j.joint.rot = muted and { x = 0, y = 0, z = 0, w = 1 } or { x = 0.1, y = 0, z = 0, w = 0.995 }
        end
    end
    return f
end
local adapter = {
    expression_joints = function(face) return face.joints end,
    face_layers = function(face) return face.layers end,
}
local function frame(faces, list)
    for _, f in ipairs(faces) do f.animate() end
    H.update(adapter, list or faces)
end

H.release()
H.watch({ "C_Jaw_LOD02" })
local a = fake_face(0xA, { 1.0, 0.5 })
frame({ a })
check(H.capturing() and a.layers[1].rate == 0 and a.layers[2].rate == 0, "capture mutes every layer of the face")
for _ = 1, 4 do frame({ a }) end
check(not H.capturing() and a.layers[1].rate == 1.0 and a.layers[2].rate == 0.5, "capture ends once the pose settles and restores each layer's rate")
frame({ a })
local jaw = a.joints[1].joint
check(near(jaw.pos.y, 0.02) and jaw.rot.w == 1, "held joints are written back to the captured neutral pose")
local hp, hr = H.pose(0xA, "C_Jaw_LOD02")
check(hp and near(hp.y, 0.03) and hr.x == 0.1, "a watched joint keeps its animated pose for readers")
check(H.pose(0xA, "C_Nose_LOD01") == nil, "unwatched joints keep no animated pose")

-- a face left out of the list is let go; one dropped mid-capture gets its layers back
local b = fake_face(0xB, { 1.0 })
frame({ a, b })
check(H.capturing() and b.layers[1].rate == 0, "a second face starts its own capture")
frame({ a, b }, { a })
check(b.layers[1].rate == 1.0 and not H.capturing(), "a face dropped mid-capture gets its layer rates back")
local c = fake_face(0xC, { 0.8 })
frame({ c })
H.release()
check(c.layers[1].rate == 0.8 and not H.active() and H.pose(0xA, "C_Jaw_LOD02") == nil, "release restores muted layers and forgets every face")

-- an adapter that finds no bones fails once and writes nothing
local d = fake_face(0xD, { 1.0 })
local none = { expression_joints = function() return {} end, face_layers = function() return {} end }
H.update(none, { d }); H.update(none, { d })
check(not H.capturing() and d.layers[1].rate == 1.0 and not d.writes, "a face without expression bones is left alone")
H.release()

-- API: the expression switch, and the hold setting on a face the adapter cannot read
local st = SKS.state
local function ticks(n) for _ = 1, n or 1 do if CB.motion then CB.motion() end; CB.tick(); CB.frame() end end
-- the mesh's channel list depends on the groups before this one: compare every driven channel
local function snap() local t = {}; for i = 1, #CHANNELS do t[i] = WEIGHTS[i - 1] or 0 end; return t end
local function same(a, b) for i = 1, #a do if not near(a[i], b[i]) then return false end end; return true end
-- base: fcParam all 0 (sculpt values and other layers only); earlier groups leave values in FC
local saved_fc = {}
for k, v in pairs(FC) do saved_fc[k] = v; FC[k] = nil end
SKS.call("rescan"); ticks(80)
local base = snap()
FC[1], FC[2], FC[52], FC[33] = 0.008, 0.008, 0.005, 0.004; ticks(3)
local on = snap()
check(not same(on, base), "fcParam drives some keys with the expression on")
check(st.settings.expression_enabled == true and st.settings.hold_face_bones == false and st.settings.hold_available == true,
    "settings state reports both switches (hold off by default)")
SKS.call("set_setting", { key = "expression_enabled", value = false }); ticks(3)
local off = snap()
check(same(off, base), "expression off leaves only what the other layers write")
SKS.call("set_setting", { key = "expression_enabled", value = true }); ticks(3)
check(same(snap(), on), "expression on restores the weights")
SKS.call("set_setting", { key = "hold_face_bones", value = true }); ticks(5)
check(not H.capturing() and same(snap(), on) and st.settings.hold_status ~= "",
    "hold on a face without readable bones keeps driving and reports why")
SKS.call("set_setting", { key = "hold_face_bones", value = false }); ticks(2)
check(not H.active() and st.settings.hold_status == "", "hold off releases and clears the status")
for k in pairs(FC) do FC[k] = nil end
for k, v in pairs(saved_fc) do FC[k] = v end

print("HOLD FAILS:", hf)
