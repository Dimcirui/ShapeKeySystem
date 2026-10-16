-- A separate runtime for the real Rise adapter: signals projected from face_base joints, channel names from get_Item
-- hashes only, the face anchors the rig without being a part, and a mod part's missing weight
-- buffer is allocated.
local NameHash = require("ShapeKeySystem_Core.NameHash")
local W = require("ShapeKeySystem_Core.Writer")
local U = require("ShapeKeySystem_Core.Util")
U.save_json(U.path("mods", "names", "rise-test.json"),
    { schema = "sks.names/1", names = { "eye_close", "Waist_thin" } })
-- the engine's getBlendShapeChannelName answers "" here; the adapter must not depend on it
W.M_CNAME = { call = function() return "" end }
HASH = NameHash.hash
-- eye_nagomi_1 is known only through builtin/names (shared by every game)
CHANNELS = { "eye_close", "jawOpen", "Waist_thin", "Mystery_key", "eye_nagomi_1" }

local face = ROOT:get_Child()
face._name = "face_base"
face._joints.Head_00 = {}
ARMOR._name = "f_body279"
ARMOR._mesh.get_ChannelNameHash = function()
    -- boxed get_elements values are garbage in this engine; get_Item returns the numbers
    return { get_elements = function() return { 1, 1, 1, 1 } end,
             call = function(_, m, i) if m == "get_Item" then return HASH(CHANNELS[i + 1]) end end }
end
-- a mod mesh in an armor slot arrives without a weight buffer
local weights = { count = 0, list = 2 }
ARMOR._mesh.get_BlendShapeChannelWeightCount = function() return weights.count end
ARMOR._mesh.set_BlendShapeChannelWeightCount = function(_, n) weights.count = n end
ARMOR._mesh.get_ChannelWeightList = function()
    return { call = function(_, m) if m == "get_Length" then return weights.list end end }
end

local flags = { ready = true }
local original_singleton = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "snow.player.PlayerManager" then
        return { call = function(_, m)
            if m == "isReadyPlayerLoad" then return flags.ready end
            if m == "findMasterPlayer" then
                return { call = function(_, p) if p == "get_GameObject" then return ROOT:get_GameObject() end end }
            end
        end }
    end
    return original_singleton(name)
end

GAME_NAME = "mhrise"
dofile(ENTRY)
package.searchers[2] = function(name) return "autorun module after load: " .. name end
local SKS = require("ShapeKeySystem_Core.API")
local A = SKS.adapter
local st = SKS.state
local failures = 0
local function check(ok, text)
    print((ok and "ok   " or "FAIL ") .. "[rise] " .. text)
    if not ok then failures = failures + 1 end
end
local function ticks(n) for _ = 1, n do CB.tick(); CB.frame() end end

check(A.id == GAME_NAME and next(HOOKS) == nil, "selected, no hooks")
check(A.primary_root() == ROOT and A.primary_ready(), "master player resolved")
check(A.is_face(face) and A.face_rank(face) == 1 and not A.is_part("face_base"),
    "face_base anchors the rig and is not a part")
check(A.is_part("f_body279") and A.is_part("m_helm001") and not A.is_part("f_hair033")
    and not A.is_part("B_Bow014") and not A.is_part("PlHeadMessage"), "armor slots are parts, hair and weapons are not")
local model, slot = A.model_of("f_arm279")
check(model == "f_279" and slot == "arm" and A.representative_of("f_wst279") == "f_body279"
    and A.model_of("m_arm279") ~= model, "one binding per sex and equipment number, the body represents it")
check(st.expression.no_signals == false and A.raw.parse("jawOpen") and not A.raw.parse("typo"),
    "face_base bone projection supplies expression signals")

-- face_base joints at the calibrated neutral pose; poses[bone] = {px, py, pz, qx, qy, qz, qw}
local cal = json.load_file("ShapeKeySystem/builtin/mhrise/face.json")
local poses = {}
local function strip(self, name, ...) return self[name:match("^([%w_]+)")](self, ...) end
for _, spec in pairs(cal.joints) do
    local n, bone = spec.neutral, spec.bone
    poses[bone] = { table.unpack(n) }
    face._joints[bone] = { call = strip,
        get_LocalPosition = function() local p = poses[bone]; return { x = p[1], y = p[2], z = p[3] } end,
        get_LocalRotation = function() local p = poses[bone]; return { x = p[4], y = p[5], z = p[6], w = p[7] } end }
end
local face_call = face.call
face.call = function(self, m, ...)
    if m:find("^getJointByName") then return self._joints[...] end
    return face_call(self, m, ...)
end
local function rotate(bone, axis, deg)   -- neutral * (deg about axis)
    local n, h = cal.joints[bone .. ".open"].neutral, math.rad(deg) / 2
    local bx, by, bz, bw = axis[1] * math.sin(h), axis[2] * math.sin(h), axis[3] * math.sin(h), math.cos(h)
    local ax, ay, az, aw = n[4], n[5], n[6], n[7]
    poses[bone] = { n[1], n[2], n[3],
        aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz }
end
local jaw, blink_l, blink_r = A.raw.parse("jawOpen"), A.raw.parse("eyeBlinkLeft"), A.raw.parse("eyeBlinkRight")
local h = A.bind(face, { jaw, blink_l, blink_r })
local P = {}
A.read(h, P, 1)
check(P[jaw] == 0 and P[blink_l] == 0 and P[blink_r] == 0, "neutral face: no expression")
local jaw_rule
for _, r in ipairs(cal.rules) do if r.key == "jawOpen" then jaw_rule = r end end
rotate("Jaw_00", cal.joints["Jaw_00.open"].axis, (jaw_rule.lo + jaw_rule.hi) / 2)
A.read(h, P, 1)
check(math.abs(P[jaw] - 0.5) < 1e-6, "jaw rotated half way: jawOpen 0.5 (" .. tostring(P[jaw]) .. ")")
local lid = cal.joints["L_Up_Eyelib.down"]
for _, r in ipairs(cal.rules) do
    if r.joint == "L_Up_Eyelib.down" then
        local n = lid.neutral
        poses.L_Up_Eyelib = { n[1] + lid.axis[1] * r.hi / 1000, n[2] + lid.axis[2] * r.hi / 1000,
            n[3] + lid.axis[3] * r.hi / 1000, n[4], n[5], n[6], n[7] }
    end
end
A.read(h, P, 1)
check(math.abs(P[blink_l] - 1) < 1e-6 and P[blink_r] == 0, "left upper lid fully down: left blink only")
local snap = A.native_snapshot()
check(snap and snap.joints.Jaw_00 and snap.joints.L_Brow_00 and snap.outputs.jawOpen
    and snap.measurements["Jaw_00.open"] and snap.status["joint:Throat"] and snap.source,
    "native snapshot records face joints, measurements and outputs; missing joints are listed")
for bone, spec in pairs(cal.joints) do poses[spec.bone] = { table.unpack(spec.neutral) } end

ticks(60)
check(weights.count == 0, "a weight list shorter than the channels: the weight count stays 0")
weights.list = #CHANNELS
SKS.call("sculpt_scan"); ticks(5)
check(weights.count == #CHANNELS, "the next scan allocates the weight buffer once the weight list is long enough")
SKS.call("sculpt_scan"); ticks(5)
local by = {}
for _, k in ipairs(st.sculpt.keys) do by[k.name] = k end
check(by.eye_close and by.Waist_thin and by[NameHash.label(HASH("Mystery_key"))],
    "names come from get_Item hashes")
check(by.eye_nagomi_1 ~= nil, "the builtin names table resolves a mod key no profile or label knows")
local t0 = os.clock()
local table_size = 0
for _ in pairs(NameHash.table(NameHash.table_names())) do table_size = table_size + 1 end
print(string.format("     [rise] name table: %d hashes in %.0f ms", table_size, (os.clock() - t0) * 1000))
-- the newly allocated buffer must stay ready for Guard.STABLE_FRAMES before the first write
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.6 }); ticks(40)
check(math.abs((WEIGHTS[2] or 0) - 0.6) < 1e-6, "a sculpt value is written (" .. tostring(WEIGHTS[2]) .. ")")

flags.ready = false; ticks(5)
check(not A.gate(), "player not ready: the gate closes")
weights.count = 0
flags.ready = true; ticks(60); SKS.call("sculpt_scan"); ticks(5)
check(weights.count == #CHANNELS, "a rebuilt part gets its weight buffer again")

-- no idle blink from the bones: the procedural layer blinks in its default fallback mode, and its
-- clock stops while the gate is closed
local Pr = require("ShapeKeySystem_Core.Procedural")
-- a mod head with ARKit blink keys (a target needs three expression keys)
CHANNELS[#CHANNELS + 1] = "eyeBlinkLeft"
CHANNELS[#CHANNELS + 1] = "eyeBlinkRight"
weights.list = #CHANNELS
SKS.call("rescan"); ticks(60)
local function blink_weight() return WEIGHTS[#CHANNELS - 2] or 0 end
local function run_for(sec)
    local m, stop = 0, os.clock() + sec
    while os.clock() < stop do
        local w = os.clock() + 0.01
        while os.clock() < w do end
        ticks(1)
        local v = blink_weight()
        if v > m then m = v end
    end
    return m
end
check(st.procedural.mode == "fallback" and st.procedural.lacking["blink.L"] and st.procedural.lacking["blink.R"],
    "Rise: blink.L / blink.R lacking (adapter procedural.blink), fallback by default")
SKS.call("set_procedural", { patch = { frequency = 4, blink = { interval_min = 0.5, interval_max = 0.5, double_chance = 0 } } })
local m = run_for(0.6)
check(#st.scene.rigs == 1 and m > 0.5,
    string.format("Rise, fallback: the mod head blinks with neutral face_base bones (max %.2f)", m))
flags.ready = false; ticks(2)
local t_closed = Pr.time
run_for(0.2)
check(Pr.time == t_closed, "gate closed: the generator's clock stands still")
flags.ready = true; ticks(2)
check(Pr.time > t_closed and Pr.time - t_closed <= 0.1 + 1e-9, "gate open again: the clock resumes without a jump")
SKS.call("set_procedural", { patch = { mode = "game" } })
ticks(60)
check(run_for(0.6) == 0, "Rise, game only: no blink")

print("RISE FAILS:", failures)
