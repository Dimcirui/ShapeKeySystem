-- A separate runtime: the face is also the mod mesh, channel names are boxed hashes, an unready
-- player or a loading cutscene stops all writes, and a playing cutscene is left to Core's
-- cutscene drive.
local NameHash = require("ShapeKeySystem_Core.NameHash")
local W = require("ShapeKeySystem_Core.Writer")
local U = require("ShapeKeySystem_Core.Util")
U.save_json(U.path("mods", "names", "onimusha-test.json"),
    { schema = "sks.names/1", names = { "eye_close", "Waist_thin" } })
W.M_CNAME = nil
HASH = NameHash.hash
CHANNELS = { "eye_close", "mouth_a1", "Waist_thin", "Mystery_key", "eyeBlinkLeft", "jawOpen", "mouthSmileLeft" }
ARMOR._name = "Head"
ARMOR._joints.bsControl_000 = {}
local positions = {}
local eye_rotation = { w = math.cos(math.rad(10) / 2), x = 0, y = -math.sin(math.rad(10) / 2), z = 0 }
ARMOR._joints.eye_Lt = { get_LocalRotation = function() return eye_rotation end }
ARMOR._joints.eye_Rt = { get_LocalRotation = function() return eye_rotation end }
for i = 0, 27 do
    local n = i
    positions[n] = { x = 0.0, y = 0.0, z = 0.0 }
    ARMOR._joints[string.format("bsControl_%03d", n)] = { get_LocalPosition = function() return positions[n] end }
end
ARMOR.get_Parent = function() return ROOT end
ARMOR._mesh.getMesh = function()
    return { call = function() return "Art/Model/Character/ch0/ch001_00/10/ch001_00_10.mesh" end }
end
local flags = { ready = true, valid = true, character = true, busy = false, load = false }
local original_singleton = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "app.PlayerManager" then
        return { call = function(_, m)
            if m:find("isPlayerReady", 1, true) then return flags.ready end
            if m == "getControllingPlayer" then
                return { call = function(_, p)
                    if p == "get_Valid" then return flags.valid end
                    if p == "get_CharacterValid" then return flags.character end
                    if p == "get_Object" then return ROOT:get_GameObject() end
                end }
            end
        end }
    end
    if name == "app.DemoMediator" then
        return {
            get_IsBusy = function() return flags.busy end,
            get_IsBusyLoad = function() return flags.load end,
        }
    end
    return original_singleton(name)
end

-- A userdata-backed indexed collection reproduces REF's get_elements() container.
local vector = io.tmpfile()
local original_meta = getmetatable(vector)
local elements = {}
for i, name in ipairs(CHANNELS) do
    local hash = HASH(name)
    elements[i] = { call = function() return tostring(hash) end }
end
debug.setmetatable(vector, { __index = elements, __len = function() return #elements end })
ARMOR._mesh.get_ChannelNameHash = function()
    return { get_elements = function() return vector end }
end

GAME_NAME = "onimusha_wots"
dofile(ENTRY)
package.searchers[2] = function(name) return "autorun module after load: " .. name end
local SKS = require("ShapeKeySystem_Core.API")
local A = SKS.adapter
local failures = 0
local function check(ok, text)
    print((ok and "ok   " or "FAIL ") .. "[onimusha] " .. text)
    if not ok then failures = failures + 1 end
end
local function ticks(n) for _ = 1, n do CB.tick() end end
check(A.id == GAME_NAME and next(HOOKS) ~= nil, "selected, cutscene hooks installed")
check(A.primary_root() == ROOT and A.primary_ready(), "controlling player resolved")
check(SKS.state.expression.no_signals == false, "bsControl channels: the expression page reads game signals")
local eyes = A.eye_joints(ARMOR)
check(eyes.L == ARMOR._joints.eye_Lt and eyes.R == ARMOR._joints.eye_Rt, "animated eye_Lt / eye_Rt selected")
local X = require("ShapeKeySystem_Core.Expression")
local eye_rig = { params = {}, eyes = eyes, angles = { L = { 0, 0 }, R = { 0, 0 } } }
X.read(eye_rig, {}, 100, false, SKS.state.eyes, true)
check(math.abs(eye_rig.angles.L[1] - 10) < 1e-6 and math.abs(eye_rig.angles.R[1] - 10) < 1e-6,
    "eye rotations use Core's face-right positive yaw convention")
check(next(A.eye_joints(ROOT)) == nil, "faces without eye joints degrade to no gaze")
check(A.raw.parse("bsControl_003.z") == 11 and A.raw.parse("003.z") == 11 and A.raw.label(11) == "bsControl_003.z",
    "raw channel parse and label preserve the axis")
check(A.raw.parse("136.x") == nil and A.raw.parse("-1.x") == nil and A.raw.parse("012.w") == nil and A.raw.parse(12) == nil,
    "invalid raw channels rejected")
positions[0] = { x = 0.002, y = 0.004, z = 0.006 }
local handle, count = A.bind(ARMOR, { 0, 1, 2, 405 })
local values = {}
A.read(handle, values, 100)
check(count == 3 and values[0] == 0.2 and values[1] == 0.4 and values[2] == 0.6 and values[405] == nil,
    "all three axes normalised, missing joints skipped")
check(A.is_face(ARMOR) and A.face_rank(ARMOR) == 2 and A.face_rank(ROOT) == 0, "Head supplies the driver joints")
local npc_path = ARMOR._mesh.getMesh
ARMOR._mesh.getMesh = function() return { call = function() return "Art/Model/Character/ch0/ch034_00/10/ch034_00_10.mesh" end } end
check(not A.is_face(ARMOR), "an NPC head with bsControl is not a face")
ARMOR._mesh.getMesh = npc_path
check(A.is_part("ch001_00_10_event") and not A.is_part("ch034_00_10"), "the cutscene copy's parts are named after the player's meshes")
check(not A.is_part("Hair") and A.model_of("Head") == "musashi" and A.model_of("ch001_00_10_event") == "musashi"
    and A.representative_of("Body") == "musashi" and A.model_of("Gm800_000_00") == nil, "every player part belongs to musashi")
local Presets = require("ShapeKeySystem_Core.Presets")
local chain = {}
for _, e in ipairs(Presets.resolve_binding("Head").chain) do chain[#chain + 1] = e.path end
chain = table.concat(chain, " ")
check(chain == "user/musashi/musashi.json mods/musashi/musashi.json user/default.json mods/default.json",
    "bindings: one musashi/musashi.json for the whole character (" .. chain .. ")")
-- a Head.json written by an earlier version no longer splits the character between two presets
local Util = require("ShapeKeySystem_Core.Util")
Util.save_json(Util.path("user", "musashi", "musashi.json"), { schema = "sks.binding/1", sculpt = "Whole" })
Util.save_json(Util.path("user", "musashi", "Head.json"), { schema = "sks.binding/1", sculpt = "HeadOnly" })
local worn = { { id = "Head", n = 40 }, { id = "OniHead", n = 40 }, { id = "Body", n = 10 } }
check(Presets.resolve_binding("Head", nil, nil, worn).data.sculpt == "Whole"
    and Presets.resolve_binding("Body", nil, nil, worn).data.sculpt == "Whole", "Head and Body share the character's sculpt preset")
local legacy = Presets.legacy_bindings(worn)
check(#legacy == 1 and legacy[1].path == "user/musashi/Head.json", "Head.json is listed as an old part binding")
Util.save_json(Util.path("user", "musashi", "musashi.json"), { deleted = true })
Util.save_json(Util.path("user", "musashi", "Head.json"), { deleted = true })
local Scene = require("ShapeKeySystem_Core.Scene")
local sig = Scene.children_signature(ROOT)
local keep_addr = ARMOR._mesh.get_address
ARMOR._mesh.get_address = function() return 0x2000 end
check(Scene.children_signature(ROOT) ~= sig, "a rebuilt Head mesh changes the children signature")
ARMOR._mesh.get_address = keep_addr
check(A.is_part("Head") and A.is_part("Body") and A.is_part("OniHead") and A.is_part("OniBody")
    and not A.is_part("Gm800_00") and A.model_of("OniHead") == "musashi", "normal and demon form parts are selected")
-- the demon form: OniHead / OniBody hang hidden on the player until it turns
do
    local go = ARMOR.get_GameObject
    ARMOR.get_GameObject = function(self)
        local g = go(self)
        local call = g.call
        g.call = function(o, m, ...)
            if m == "get_DrawSelf" then return not self._hidden end
            return call(o, m, ...)
        end
        return g
    end
    local shown = Scene.children_signature(ROOT)
    ARMOR._hidden = true
    check(A.face_rank(ARMOR) == 1 and Scene.children_signature(ROOT) ~= shown,
        "a hidden head ranks below a drawn one and hiding it changes the children signature")
    ARMOR._name = "OniHead"; ARMOR._hidden = false
    check(A.is_face(ARMOR) and A.face_rank(ARMOR) == 2, "a drawn OniHead is the face")
    ARMOR._name = "Head"
end
-- a head mod that reuses the body skeleton: no bsControl, face_joint* bones read as bone signals
do
    local keep = ARMOR._joints.bsControl_000
    ARMOR._joints.bsControl_000 = nil
    ARMOR._joints.face_joint340 = {}
    check(A.is_face(ARMOR), "a head with face_joint340 and no bsControl is a face")
    ARMOR._name = "Body"
    check(not A.is_face(ARMOR), "the body sharing that skeleton is not a face")
    ARMOR._name = "Head"
    local ID = { w = 1, x = 0, y = 0, z = 0 }
    local d = 0
    local head = { get_Name = function() return "Head" end, get_Position = function() return { x = 0, y = 0, z = 0 } end,
                   get_Rotation = function() return ID end }
    local base = { x = 0.03, y = 0.05, z = 0.07 }
    ARMOR._joints.Head = head
    ARMOR.get_address = function() return 0xA11 end
    ARMOR._joints.face_joint343 = { get_Name = function() return "face_joint343" end, get_Parent = function() return head end,
        get_BaseLocalPosition = function() return base end, get_BaseLocalRotation = function() return ID end,
        get_BaseLocalScale = function() return { x = 1, y = 1, z = 1 } end,
        get_Position = function() return { x = base.x, y = base.y + d / 1000, z = base.z } end }
    local key = A.raw.parse("bone.eyeClose.L")
    check(key and key > 407 and A.raw.label(key) == "bone.eyeClose.L", "bone signals parse above the bsControl keys")
    local h, n = A.bind(ARMOR, { key, 0 })
    local P = {}
    d = -0.8 - 8 * (0.05 + 0.95 * 0.5)   -- rest -0.8 mm, lid down, half past the deadzone
    A.read(h, P, 100)
    check(n == 1 and math.abs((P[key] or -1) - 0.5) < 1e-6, "face_joint upper lid reads eyeClose.L in the head's frame")
    local sig = require("ShapeKeySystem_Core.Profile").signals.by_name["eyeClose.L"]
    check(sig and sig.key == key and not sig.no_signal, "the dictionary wires eyeClose.L to the face_joint bone")
    ARMOR._joints.bsControl_000, ARMOR._joints.face_joint340 = keep, nil
    ARMOR._joints.Head, ARMOR._joints.face_joint343 = nil, nil
end
local names = NameHash.names_of(ARMOR._mesh, #CHANNELS, NameHash.table({ "eye_close", "mouth_a1", "Waist_thin" }))
check(names and names[1] == "eye_close" and names[2] == "mouth_a1" and names[4] == NameHash.label(HASH("Mystery_key")),
    "userdata container and boxed UInt32 hashes resolve names and preserve unknown hashes")
ticks(65)
positions[3].z, positions[9].x, positions[12].x = 0.01, 0.005, 0.004
ticks(5)
check(math.abs((WEIGHTS[4] or 0) - 1) < 1e-6 and math.abs((WEIGHTS[5] or 0) - 0.5) < 1e-6
    and math.abs((WEIGHTS[6] or 0) - 0.4) < 1e-6, "bsControl blink, jaw and smile drive ARKit mesh channels")
SKS.call("sculpt_scan"); ticks(5)
local by = {}
for _, key in ipairs(SKS.state.sculpt.keys) do by[key.name] = key end
check(by.eye_close and by.mouth_a1 and by.Waist_thin, "sculpt lists the face mesh's resolved keys")
check(SKS.call("set_sculpt_key", { name = "eye_close", value = 0.8 }), "sculpt key accepted")
ticks(10)
check(math.abs((WEIGHTS[0] or 0) - 0.8) < 1e-6 and not INT_WRITES, "sculpt writes a float to the head mesh")
for _, flag in ipairs({ "ready", "valid", "character", "busy", "load" }) do
    local default = flags[flag]
    flags[flag] = not default
    local ok, _, kind = A.gate()
    local want = ({ busy = "playing", load = "load" })[flag]
    check(not ok and kind == want, flag .. ": gate kind " .. tostring(kind))
    ticks(1)
    local count = #writes
    ticks(40)
    if flag == "busy" then
        check(not SKS.state.debug.status:find("tick error", 1, true), flag .. ": cutscene drive runs without errors")
    else
        check(#writes == count and not SKS.state.debug.status:find("tick error", 1, true), flag .. ": no writes while blocked")
    end
    flags[flag] = default
    ticks(65)
end
check(A.gate() and not SKS.state.debug.status:find("tick error", 1, true), "gameplay resumes after gating")
-- combat effects come and go under the player root: they must not drop the rigs or rescan
do
    local effect = { get_Next = function() return ARMOR.get_Next(ARMOR) end }
    effect.get_GameObject = function() return { call = function() return "effect_Player_00" end } end
    effect.call = function(self, m, ...) return self[m](self, ...) end
    local next_of_armor, shown = ARMOR.get_Next, false
    ARMOR.get_Next = function(self) if shown then return effect end return next_of_armor(self) end
    effect.get_Next = function() return next_of_armor(ARMOR) end
    local sig = Scene.children_signature(ROOT)
    shown = true
    check(Scene.children_signature(ROOT) == sig, "an effect object under the player leaves the children signature alone")
    local scans, last_scan, count = 0, SKS.state.scene.last_scan, #writes
    for i = 1, 300 do
        shown = (i // 15) % 2 == 1
        CB.tick()
        if SKS.state.scene.last_scan ~= last_scan then scans, last_scan = scans + 1, SKS.state.scene.last_scan end
    end
    positions[3].z = 0.0
    ticks(3)
    check(scans == 0 and #writes > count, "effects spawning every 15 frames: no rescan, writing goes on (" .. scans .. " scans)")
    ARMOR.get_Next, shown = next_of_armor, false
end
debug.setmetatable(vector, original_meta)
vector:close()
do
    local saved_sdk, saved_thread, saved_re = sdk, thread, re
    local hooks, reset, enabled, releases, errors = {}, nil, false, 0, {}
    local storage = {}
    local gui = { priority = 0 }
    function gui:get_field() return self.priority end
    function gui:set_field(_, value) self.priority = value end
    sdk = {
        find_type_definition = function(name)
            return { get_method = function(_, signature) return name .. "." .. signature end }
        end,
        get_managed_singleton = function() return gui end,
        hook = function(method, pre, post) hooks[method] = { pre = pre, post = post } end,
        to_ptr = function(value) return value end,
    }
    thread = { get_hook_storage = function() return storage end }
    re = { on_script_reset = function(fn) reset = fn end }
    A.input.install(function() return enabled end, function(text) errors[#errors + 1] = text end,
        function() releases = releases + 1 end)
    local cursor = hooks["app.GUI090000.guiLateUpdate()"]
    local camera = hooks["app.mcCam_GameCameraInputRotate.checkInputRotationFixed()"]
    local function run(on, priority, inside, close_during_call)
        enabled, gui.priority, storage = on, priority, {}
        cursor.pre()
        local correct = gui.priority == inside
        if close_during_call then enabled = false end
        correct = cursor.post(99) == 99 and gui.priority == priority and correct
        return correct
    end
    check(run(false, 0, 0) and run(true, 0, 15) and run(true, 11, 15),
        "native cursor branch borrowed only while SKS is open, original priority restored")
    check(run(true, 15, 15) and run(true, 20, 20), "native menus retain their own priority")
    check(run(true, 0, 15, true), "closing during the cursor call still restores priority")
    enabled, gui.priority, storage = true, 0, {}
    cursor.pre()
    local outer = storage
    storage = {}; cursor.pre(); cursor.post(99)
    storage = outer; cursor.post(99)
    check(gui.priority == 0, "recursive cursor updates preserve the outer restoration")
    enabled = true
    check(camera.post(false) == true, "camera held while the panel is open")
    enabled = false
    check(camera.post(false) == false and camera.post(true) == true, "camera returns unchanged after closing")
    enabled = true; reset()
    check(run(true, 0, 0) and camera.post(false) == false and releases == 4 and #errors == 0,
        "reset disables hooks without leaving borrowed menu priority")
    sdk, thread, re = saved_sdk, saved_thread, saved_re
end
print("ONIMUSHA FAILS:", failures)
