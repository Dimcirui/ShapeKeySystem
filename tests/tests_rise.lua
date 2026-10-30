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
-- a face is recognised by its joints, not its name
for _, bone in ipairs({ "Head_00", "L_Up_Eyelib", "L_Lo_Eyelib", "Jaw_00", "L_Cheek_00", "L_Eye" }) do
    face._joints[bone] = {}
end
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
check(not A.is_face(ARMOR) and A.face_rank(ARMOR) == 0, "a mod head with only Head_00 is not a face")
-- a face named face_base / DummyFace needs no joint lookups; other names still need the joints
local named = { _joints = {}, call = function(self, m, ...) return self[m](self, ...) end,
    get_GameObject = function() return { call = function(_, m) if m == "get_Name" then return "DummyFace" end end } end }
local jbn_calls = 0
named.getJointByName = function() jbn_calls = jbn_calls + 1 end
check(A.is_face(named) and jbn_calls == 0, "a DummyFace transform is a face by its name alone")
-- one engine callback resolves the master player once; outside it every call resolves again
local lookups, singleton_now = 0, sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "snow.player.PlayerManager" then lookups = lookups + 1 end
    return singleton_now(name)
end
A.cache_begin()
for _ = 1, 5 do A.primary_root(); A.primary_ready() end
local inside = lookups
A.cache_end()
lookups = 0
for _ = 1, 3 do A.primary_root() end
sdk.get_managed_singleton = singleton_now
check(inside > 0 and inside <= 2 and lookups >= 3, "the player is looked up once per callback, fresh outside it ("
    .. inside .. " inside, " .. lookups .. " outside)")
check(A.primary_root() == ROOT, "the cache leaves nothing behind")
check(A.primary_source == "master", "no cutscene: the master player drives")
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
check(st.procedural.lacking.jawOpen and st.procedural.lacking.gaze,
    "Rise: jawOpen lacking (adapter procedural.breath), gaze lacking (no eye joints)")
SKS.call("set_procedural", { patch = { breath = { amplitude = 0.1, interval_min = 0.5, interval_max = 0.5,
                                                  open = 0.1, hold = 0.05, close = 0.1 } } })
local jaw_max, stop = 0, os.clock() + 1.2
while os.clock() < stop do
    local w = os.clock() + 0.01
    while os.clock() < w do end
    ticks(1)
    jaw_max = math.max(jaw_max, WEIGHTS[1] or 0)
end
check(math.abs(jaw_max - 0.1) < 0.02, string.format("Rise, fallback: the mouth opens slightly at idle (jawOpen max %.3f)", jaw_max))
flags.ready = false; ticks(2)
local t_closed = Pr.time
run_for(0.2)
check(Pr.time > t_closed, "player not ready: the generator keeps running")
flags.ready = true; ticks(1)
do local w = os.clock() + 0.02; while os.clock() < w do end end   -- the second frame needs real time to pass
ticks(1)
check(Pr.time > t_closed, "player ready again: the generator still runs")
SKS.call("set_procedural", { patch = { mode = "game" } })
ticks(60)
check(run_for(0.6) == 0, "Rise, game only: no blink")

-- periodic scans stop at the signature check while the hunter is unchanged
local Scene = require("ShapeKeySystem_Core.Scene")
local function wait_real(sec)
    local stop = os.clock() + sec
    while os.clock() < stop do
        local w = os.clock() + 0.01
        while os.clock() < w do end
        ticks(1)
    end
end
ROOT.get_address = function() return 0x7000 end   -- the root is matched by address
SKS.call("set_setting", { key = "periodic_scan_sec", value = 1 }); ticks(5)
local scanned = st.scene.last_scan
wait_real(1.2)
check(A.inspect_before_scan and st.scene.last_scan == scanned, "unchanged hunter: the periodic scan does not run")
local sig = Scene.children_signature(ROOT)
check(sig:find("f_body279@", 1, true) and sig:find("#" .. #CHANNELS, 1, true), "armor parts carry mesh and channel count")
local channel_num = ARMOR._mesh.get_BlendShapeChannelNum
ARMOR._mesh.get_BlendShapeChannelNum = function() return 0 end
check(Scene.children_signature(ROOT) ~= sig, "a mesh without channels yet changes the signature")
ARMOR._mesh.get_BlendShapeChannelNum = channel_num
local mesh_addr = ARMOR._mesh.get_address
ARMOR._mesh.get_address = function() return 0x9000 end
check(Scene.children_signature(ROOT) ~= sig, "a part rebuilt under the same name changes the signature")
ticks(10)
check(st.scene.last_scan ~= scanned, "a changed part: the next scan runs in full")
ARMOR._mesh.get_address = mesh_addr
SKS.call("set_setting", { key = "periodic_scan_sec", value = 5 }); ticks(10)

-- Cutscenes play a copy of the hunter (snow.eventcut.EventPlayer) whose face is DummyFace.
local function obj(t)
    t.call = function(self, m, ...) return self[m](self, ...) end
    return t
end
local dummy = obj({ _joints = face._joints })
dummy.getJointByName = function(self, n) return self._joints[n] end
dummy.get_GameObject = function() return obj({ get_Name = function() return "DummyFace" end }) end
local event_root = obj({ get_Child = function() return nil end })
local ep = obj({ get_Valid = function() return true end, getTransform = function() return event_root end,
    findGameObjectChild = function(_, name)
        if name == "DummyFace" then return obj({ get_Transform = function() return dummy end }) end
    end })
local players = obj({ get_Count = function() return 1 end, get_Item = function() return ep end })
local handler = obj({ get_Manager = function() return obj({ get_EventPlayerList = function() return players end }) end })
local event = { playing = true }
local em = obj({ get_Playing = function() return event.playing end,
    get_PlayingOrCheckScene = function() return false end, get_HoldingHandler = function() return false end,
    get_LoadHandlerStack = function() return obj({ get_Length = function() return 1 end,
        get_Item = function() return handler end }) end })
local singleton = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "snow.eventcut.EventManager" then return em end
    return singleton(name)
end
check(A.primary_root() == event_root and A.primary_ready() and A.primary_source == "event",
    "cutscene: the event player drives")
local esnap = A.native_snapshot()
check(esnap and esnap.driver == "event" and esnap.source:find("^DummyFace@"), "cutscene snapshot reads DummyFace")
event.playing = false
check(A.primary_root() == ROOT and A.primary_source == "master", "cutscene over: back to the master player")
sdk.get_managed_singleton = singleton

-- conditions: weapon state fields read straight off the master player's weapon class
local Cnd = require("ShapeKeySystem_Core.Conditions")
check(A.conditions and Cnd.defs.weapon_form and Cnd.defs.scroll, "conditions installed")
local hunter = { fields = {}, calls = {} }
function hunter:get_field(n) return self.fields[n] end
function hunter:call(m) return self.calls[m] end
local hud_state = "DEFAULT_BLUE"
local hud = { get_field = function(_, n) if n == "pnl_scrollicon" then
    return { call = function(_, m) if m == "get_PlayState" then return hud_state end end } end end }
sdk.get_managed_singleton = function(name)
    if name == "snow.player.PlayerManager" then
        return { call = function(_, m) if m == "findMasterPlayer" then return hunter end end }
    end
    if name == "snow.gui.GuiManager" then
        return { call = function(_, m) if m == "get_refGuiHud_WeaponTechniqueMySet" then return hud end end }
    end
    return singleton(name)
end
local frame_no = 1000
local function sample() frame_no = frame_no + 1; Cnd.reset(); Cnd.sample(frame_no); return Cnd.V end
hunter.fields._playerWeaponType = 11
hunter.calls.isWeaponOn = true
hunter.calls.get_Mode = 0
hunter.fields._ShieldBuffTimer, hunter.fields._SwordBuffTimer = 30.0, 0.0
local V = sample()
check(V.weapon_on == true and V.weapon_type == 11 and V.weapon_form == "cb_shield", "charge blade: sword + red shield")
check(V.charge_level == nil and V.spirit_level == nil, "charge blade has no charge or spirit level")
check(V.scroll == "blue", "scroll from the HUD play state")
hunter.calls.get_Mode = 1; hunter.fields._IsChainsawBuff = true
check(sample().weapon_form == "cb_axe_buff", "charge blade: axe + red axe")
hunter.fields = { _playerWeaponType = 0, _TameLv = 2 }
check(sample().charge_level == 2 and Cnd.V.weapon_form == "normal", "great sword charge level")
hunter.fields = { _playerWeaponType = 13 }
hunter.calls.get_ChargeLv = { get_field = function(_, n) if n == "value__" then return 3 end end }
check(sample().charge_level == 3, "bow charge level from a boxed enum")
hunter.fields = { _playerWeaponType = 2 }
check(sample().spirit_level == 0, "long sword spirit level unreadable -> 0")
hunter.fields = { _playerWeaponType = 9, IsKijinKyouka = false, ["<DBState>k__BackingField"] = 1 }
check(sample().weapon_form == "db_kijin", "dual blades demon mode")
hunter.fields = { _playerWeaponType = 1, _BottleAwakeDurationTimer = 5.0 }
check(sample().weapon_form == "sa_awakened", "switch axe amped")
hud_state = "SOMETHING_ELSE"; hunter.calls = {}
V = sample()
check(V.scroll == nil and V.weapon_on == nil, "unreadable scroll and weapon_on stay nil")
check(V.hp_pct == nil, "no HP source yet")
sdk.get_managed_singleton = function(name)
    if name == "snow.player.PlayerManager" then return { call = function() return nil end } end
    return singleton(name)
end
Cnd.reset()
check(Cnd.sample(frame_no + 1) == false, "no hunter: sample fails")
sdk.get_managed_singleton = singleton

print("RISE FAILS:", failures)
