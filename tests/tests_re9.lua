-- The real RE9 adapter: signals from the facial Motion on part "10", custom keys on any part mesh.
local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Signals = require("ShapeKeySystem_Games.RE9.Signals")
local failures, assertions = 0, 0
local function check(ok, label)
    assertions = assertions + 1
    print((ok and "ok   " or "FAIL ") .. "[re9] " .. label)
    if not ok then failures = failures + 1 end
end
local function call(self, signature, ...)
    local fn = self[signature:match("^([%w_]+)")]
    if fn then return fn(self, ...) end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end
local P_ = "HeadSkinned_blendShape."
local left, right = P_ .. "UprLdDn_00_L", P_ .. "UprLdDn_00_R"
local jaw_l, jaw_r = P_ .. "JwOpn_00_L", P_ .. "JwOpn_00_R"

-- Head mesh (part 10): native channels plus custom keys. Part 40 carries further custom keys.
CHANNELS = {left, right, jaw_l, jaw_r, "eyeBlinkLeft", "eyeBlinkRight", "jawOpen", "SKS_RE9_Test_NoseForward"}
local m = ARMOR._mesh
local wc, length, mesh_id, scene_id, generation, joint_count = #CHANNELS, #CHANNELS, 1000, 800, 1, 400
local active, visible = true, true
m.call = call
m.get_address = function() return mesh_id end
m.get_BlendShapeChannelWeightCount = function() return wc end
m.get_ChannelWeightList = function() return {call = call, get_Length = function() return length end} end
m.getMesh = function() return {call = call, get_ResourcePath = function() return "character/ch/ch01/0100/10/00/ch0100_10_00.mesh" end} end
m.get_ChannelNameHash = function()
    return {call = call, get_Item = function(_, i) return Hash.hash(CHANNELS[i + 1]) end,
        get_elements = function() error("RE9 only reads get_Item") end}
end
local m40 = {}
for k, v in pairs(m) do m40[k] = v end
CH40, WEIGHTS40 = {"eyeBlinkLeft", "eyeBlinkRight", "jawOpen", "BodyKey"}, {}
m40.get_address = function() return 4000 end
m40.get_BlendShapeChannelNum = function() return #CH40 end
m40.get_BlendShapeChannelWeightCount = function() return #CH40 end
m40.get_ChannelWeightList = function() return {call = call, get_Length = function() return #CH40 end} end
m40.getMesh = function() return {call = call, get_ResourcePath = function() return "character/ch/ch01/0100/40/01/ch0100_40_01.mesh" end} end
m40.get_ChannelNameHash = function()
    return {call = call, get_Item = function(_, i) return Hash.hash(CH40[i + 1]) end}
end
m40.setBlendShapeChannelWeightParam = function(_, i, w)
    if math.type(w) ~= "float" then INT_WRITES = (INT_WRITES or 0) + 1 end
    writes[#writes + 1] = {i, w, "40"}; WEIGHTS40[i] = w
end
m40.getBlendShapeChannelWeightParam = function(_, i) return WEIGHTS40[i] or 0 end

-- Facial Motion: parameter joints carry native values in X; clips play the same tracks.
NATIVE = {}           -- native name -> parameter joint value
local params = {left, right, jaw_l, jaw_r}
local param_index = {}
local removed = {}    -- native names whose parameter joint the head lacks
for i, name in ipairs(params) do param_index[Hash.hash(name)] = 100 + i end
CLIP = {}             -- native name -> clip track value
local mirrored, clip_passes, param_reads = false, 0, 0
local info = {call = call, clear = function(self) self.motion = nil end}
info.getAnimationTransform = function(self, hash, frame, data)
    for name, v in pairs(CLIP) do
        if Hash.hash(name) == hash then data.value = v; return true end
    end
    return false
end
local data_obj = {call = call, clear = function(self) self.value = nil end,
    get_ValidPosition = function(self) return self.value ~= nil end,
    get_Position = function(self) return {x = self.value, y = 0, z = 0} end}
sdk.create_instance = function(name)
    local o = name == "via.motion.MotionInfo" and info or data_obj
    o.add_ref = function(self) return self end
    return o
end
local node = {call = call, get_Weight = function() return 1.0 end, get_Frame = function() return 3.0 end,
    getMotionInfo = function(_, i) clip_passes = clip_passes + 1; return true end,
    get_OutputMirrored = function() return mirrored end}
local layer = {call = call, getMotionNodeCount = function() return 1 end, get_BlendRate = function() return 1.0 end,
    get_BlendMode = function() return 1 end, getMotionNode = function() return node end}
local face_go, root_go
local motion = {call = call, get_address = function() return 1900 end,
    get_SkeletonConstructCount = function() return generation end,
    get_JointCount = function() return joint_count end,
    get_GameObject = function() return face_go end,
    getJointIndexByNameHash = function(_, hash)
        local i = param_index[hash]
        if i then
            for name in pairs(removed) do if Hash.hash(name) == hash then return -1 end end
            return i
        end
        return BONE_INDEX and BONE_INDEX[hash] or -1
    end,
    getCalculatedLocalPosition = function(_, i)
        for k, name in ipairs(params) do
            if 100 + k == i then param_reads = param_reads + 1; return {x = NATIVE[name] or 0, y = 0, z = 0} end
        end
        return MOTION_POSITION and MOTION_POSITION(i)
    end,
    getCalculatedLocalRotation = function(_, i) return MOTION_ROTATION and MOTION_ROTATION(i) end,
    getLayerCount = function() return 1 end, getLayer = function() return layer end}

local FACE, PART40 = ARMOR, {}
local face_name = "10"
local function make_go(tr, name, mesh, mot, address)
    return {call = call, get_address = function() return address end,
        get_Name = function() return type(name) == "function" and name() or name end,
        get_Valid = function() return active end, get_DrawSelf = function() return visible end,
        get_Transform = function() return tr end,
        getComponent = function(_, kind)
            if kind == "via.render.Mesh" then return mesh end
            if kind == "via.motion.Motion" then return mot end
        end}
end
root_go = make_go(ROOT, "cp_A000", nil, nil, 9)
face_go = make_go(FACE, function() return face_name end, m, motion, 19)
local shadow_go = make_go({}, "Shadow", m, nil, 29)
local part40_go = make_go(PART40, "40", m40, nil, 39)
local SHADOW = {call = call, get_address = function() return 30 end, get_GameObject = function() return shadow_go end,
    get_Child = function() return nil end, get_Next = function() return nil end}
ROOT.call = call; FACE.call = call; PART40.call = call
ROOT.get_address = function() return 10 end; FACE.get_address = function() return 20 end
PART40.get_address = function() return 40 end
ROOT.get_GameObject = function() return root_go end
FACE.get_GameObject = function() return face_go end
PART40.get_GameObject = function() return part40_go end
ROOT.get_Child = function() return FACE end
FACE.get_Child = function() return SHADOW end
FACE.get_Next = function() return PART40 end
PART40.get_Child = function() return nil end
PART40.get_Next = function() return FACE end -- cyclic sibling chain must terminate
FACE.get_Parent = function() return ROOT end
SCENE = {call = call, get_address = function() return scene_id end,
    findGameObject = function(_, name) return active and name == "cp_A000" and root_go end}
GAME_NAME = "re9"
json.dump_file("ShapeKeySystem/mods/names/re9_test.json", {schema = "sks.names/1", names = {
    "eyeBlinkLeft", "eyeBlinkRight", "jawOpen", "SKS_RE9_Test_NoseForward", "BodyKey"}})
dofile(ENTRY)
local SKS = require("ShapeKeySystem_Core.API")
local A = SKS.adapter

check(A.id == "re9" and A.primary_ready(), "RE9 is selected and the face part is ready")
local parts = A.parts(ROOT, FACE)
check(A.primary_root() == ROOT and #A.faces(ROOT) == 1 and A.faces(ROOT)[1] == FACE
    and #parts == 2 and parts[1] == FACE and parts[2] == PART40,
    "the face is part 10; every part mesh except Shadow copies is a write target")
check(A.part_id(FACE) == "ch0100_10_00" and A.part_id(PART40) == "ch0100_40_01", "part ids come from the mesh file")
local model, slot = A.model_of("ch0100_40_01")
check(model == "leon" and slot == "40" and A.model_of("ch0200_10_00") == nil, "parts belong to Leon by mesh number")
check(not A.scene_search and A.rewrite_active_weights and A.strict_bounds, "strict bounds and active-weight rewrites enabled")
check(not A.channel_writable(left) and not A.channel_writable("#FFFFFFFF"), "native and unresolved channels are protected")
check(not A.channel_writable("renamed native", m, 0), "a renamed native index is protected by its actual hash")
check(A.channel_writable(CHANNELS[5], m, 4), "matching custom name and index are writable")
check(not A.channel_writable(CHANNELS[5], m, 5), "custom name cannot authorize a different index")
check(A.active_sculpt and A.batch_weights and A.write_context, "sculpt visits active keys and writes share one batch")
do
    local fetches, plain_fetch = 0, m.get_ChannelNameHash
    m.get_ChannelNameHash = function(self) fetches = fetches + 1; return plain_fetch(self) end
    local context = A.write_context(m)
    local same = true
    for _, name in ipairs({left, "renamed native", CHANNELS[5], CHANNELS[8], CHANNELS[5]}) do
        for index = 0, #CHANNELS do
            if A.channel_writable(name, m, index, context) ~= A.channel_writable(name, m, index) then same = false end
        end
    end
    local before = fetches
    for index = 0, #CHANNELS do A.channel_writable(CHANNELS[8], m, index, context) end
    check(same and fetches == before, "a write batch reuses the hash array and decides like the per-write checks")
    length = #CHANNELS - 1
    check(not A.channel_writable(CHANNELS[5], m, 4, A.write_context(m)), "a batch over a short weight list writes nothing")
    length = #CHANNELS
    m.get_ChannelNameHash = plain_fetch
end
check(A.raw.parse("eyeBlinkLeft") == 1 and A.raw.parse("jawOpen") == 3 and not A.raw.parse("typo"), "raw channels are explicit semantic keys")
local native_key = A.raw.parse("re9.native.UprLdDn_00_L")
check(native_key and not A.raw.parse("re9.native.UprLdDn_00_L_LOD1") and not A.raw.parse("re9.native.Unknown"),
    "each LOD0 native name is one re9.native key")

-- reading
local h, count = A.bind(FACE, {1, 2, 3, native_key})
check(count == 4 and h.mesh == nil and h.face == nil and h.motion == nil, "signal handles retain no engine objects")
NATIVE[left], NATIVE[right], NATIVE[jaw_l], NATIVE[jaw_r] = .8, .6, .04, .09
local P = {}; A.read(h, P, 1)
check(near(P[1], .8) and near(P[2], .6) and near(P[3], .09) and near(P[native_key], .8),
    "blink sides are independent, jaw takes the larger native tap, re9.native exposes one value")
check(h.status[left] == "parameter" and h.status[jaw_r] == "parameter" and clip_passes == 1,
    "parameter joints serve every native the head has; one clip pass covers the rest (" .. tostring(h.status[left]) .. "," .. clip_passes .. ")")
NATIVE[left] = 1.4; A.read(h, P, 1)
check(near(P[1], 1) and near(P[native_key], 1), "native values clamp to 0..1")
NATIVE[left] = .8
-- a head without some parameter joints has its own skeleton, so the face binds afresh
removed[left] = true; CLIP[left] = .3; clip_passes = 0
h = A.bind(FACE, {1, 2, 3, native_key}); A.read(h, P, 1)
check(near(P[1], .3) and near(P[2], .6) and h.status[left] == "clip" and h.status[right] == "parameter",
    "a missing parameter joint is sampled from the playing clip; the others still read their joints ("
    .. tostring(P[1]) .. "," .. tostring(P[2]) .. "," .. tostring(h.status[left]) .. ")")
check(clip_passes == 1, "one clip pass serves every missing name of a read")
mirrored = true; CLIP[left], CLIP[right] = nil, .45; A.read(h, P, 1)
check(near(P[1], .45), "a mirrored clip node is sampled on the opposite side")
mirrored = false; CLIP[right] = nil; A.read(h, P, 1)
check(P[1] == 0 and near(P[2], .6) and h.sources.eyeBlinkLeft == "unavailable",
    "a native neither the joints nor the clips have contributes zero without disabling the others")
removed[left] = nil; CLIP = {}
local original_signature = A.signature(ROOT)
generation = 2; A.read(h, P, 1)
check(P[1] == 0 and P[3] == 0 and A.signature(ROOT) ~= original_signature,
    "a skeleton rebuild invalidates handles and the target signature")
generation = 1
local sig = A.signature(ROOT); CH40[5] = "Extra"
local changed_after
for i = 1, A.FULL_SIGNATURE_CHECK do
    if A.signature(ROOT) ~= sig then changed_after = i; break end
end
check(changed_after and changed_after > 1, "a key added to another part changes the signature at the next full check ("
    .. tostring(changed_after) .. ")")
CH40[5] = nil
for _ = 1, A.FULL_SIGNATURE_CHECK do A.signature(ROOT) end
do
    local sig0 = A.signature(ROOT)
    local plain = PART40.get_GameObject
    local moved_go = {}
    for k, v in pairs(part40_go) do moved_go[k] = v end
    moved_go.getComponent = function(_, kind) if kind == "via.render.Mesh" then return m end end
    PART40.get_GameObject = function() return moved_go end
    check(A.signature(ROOT) ~= sig0, "a part whose mesh component changed fails the route check at once")
    PART40.get_GameObject = plain
    A.signature(ROOT)
    local walked
    sks_native = {layout_walk = function(root_address, head, flat)
        walked = {root_address, head, #flat}
        return true
    end}
    local before_native = A.signature(ROOT)
    check(walked and walked[1] == 10 and walked[2] == 0 and walked[3] == 2 * 5 and before_native == A.signature(ROOT),
        "with the native plugin one call checks every part route")
    sks_native = nil
    local lookups, plain_find = 0, SCENE.findGameObject
    SCENE.findGameObject = function(...) lookups = lookups + 1; return plain_find(...) end
    A.cache_begin()
    local same = A.primary_root() == ROOT and A.primary_ready() and A.signature(ROOT) == A.signature(ROOT)
        and R.find() == R.find()
    A.cache_end()
    local outside = lookups
    R.find(); R.find()
    check(same and outside == 1 and lookups == 3, "one callback resolves Leon once; outside a callback every call resolves ("
        .. outside .. "," .. lookups .. ")")
    local plain_singleton, player_go = sdk.get_managed_singleton, root_go
    sdk.get_managed_singleton = function(name)
        if name ~= "app.CharacterManager" then return plain_singleton(name) end
        local context = {call = call, get_GameObject = function() return player_go end}
        return {call = call, getPlayerContextRefFast = function() return context end}
    end
    lookups = 0
    check(R.find() and R.find().root == ROOT and lookups == 0, "Leon as the player comes from the player context without a scene search")
    local grace = make_go(ROOT, "cp_A100", nil, nil, 98)
    player_go = grace
    check(R.find() and R.find().root == ROOT and lookups == 0, "Grace as the player also comes from the player context")
    player_go = make_go({}, "cp_A200", nil, nil, 99)
    check(R.find() and R.find().root == ROOT and lookups == 2, "another player character falls back to the scene search")
    local plain_scene_find = SCENE.findGameObject
    SCENE.findGameObject = function(self, name) lookups = lookups + 1; return name == "cp_A100" and grace or nil end
    lookups = 0
    local found_grace = R.find(); local after_one = lookups
    check(found_grace and after_one == 2, "the scene search tries Leon, then Grace")
    SCENE.findGameObject = plain_scene_find
    player_go = root_go
    -- photo mode: the photo copy's parts sit directly under PlayerPhotoObject
    local PHOTO, booted, photo_valid = {call = call, get_address = function() return 110 end,
        get_Child = function() return FACE end}, true, false
    local photo_go = {call = call, get_address = function() return 111 end, get_Name = function() return "PlayerPhotoObject" end,
        get_Valid = function() return photo_valid end, get_DrawSelf = function() return true end,
        get_Transform = function() return PHOTO end}
    PHOTO.get_GameObject = function() return photo_go end
    local player_sig, with_player = A.signature(ROOT), sdk.get_managed_singleton
    sdk.get_managed_singleton = function(name)
        if name ~= "app.PhotoModeManager" then return with_player(name) end
        return {call = call, get_IsBoot = function() return booted end,
            getPlayerGameObjectPhotoMode = function() return photo_go end}
    end
    check(R.find() == nil and A.primary_root() == nil and A.gate() == false,
        "photo mode before the photo copy is built finds no character and does not fall back to the hidden player")
    photo_valid = true
    check(R.find() and R.find().root == PHOTO and A.primary_root() == PHOTO and A.gate() == true,
        "photo mode drives the photo copy once it is built (a later lookup retries)")
    check(A.signature(ROOT) == "RE9 face unavailable" and A.signature(PHOTO) ~= player_sig
        and #A.parts(PHOTO, FACE) > 0, "entering photo mode changes the signature, so the photo copy is scanned")
    booted = false
    check(R.find() and R.find().root == ROOT and A.signature(ROOT) == player_sig,
        "leaving photo mode goes back to the player and rescans")
    sdk.get_managed_singleton = plain_singleton
    SCENE.findGameObject = plain_find
    check(A.inspect_before_scan, "periodic scans only compare the signature")
    local names, plain_name = 0, part40_go.get_Name
    part40_go.get_Name = function(...) names = names + 1; return plain_name(...) end
    R.find(); R.find()
    check(names == 0 and R.find().face == FACE, "a later lookup goes straight to the face's position without reading other parts")
    part40_go.get_Name = plain_name
    local face_to_hint = FACE.get_Next
    ROOT.get_Child = function() return PART40 end
    PART40.get_Next = function() return FACE end
    FACE.get_Next = function() return nil end
    check(R.find() and R.find().face == FACE, "a face that moved in the sibling chain is found again")
    ROOT.get_Child = function() return FACE end
    PART40.get_Next = function() return FACE end
    FACE.get_Next = face_to_hint
    R.find()
end
do
    local calls, seen = 0, nil
    sks_native = {motion_curves = function(address, indices)
        calls, seen = calls + 1, {address = address, n = #indices}
        local out = {}
        for i, index in ipairs(indices) do out[i] = NATIVE[params[index - 100]] or 0 end
        return out
    end}
    local nh = A.bind(FACE, {1, 2, 3, native_key})
    local before = param_reads
    local NP = {}; A.read(nh, NP, 1)
    check(calls == 1 and seen.address == 1900 and seen.n == 4 and param_reads == before
        and near(NP[1], .8) and near(NP[3], .09) and nh.status[left] == "parameter",
        "with the native plugin one call reads every parameter joint of a read")
    sks_native.motion_curves = function() error("plugin failed") end
    A.read(nh, NP, 1)
    check(near(NP[1], .8) and param_reads > before, "a failing plugin call falls back to Lua reads")
    sks_native = nil
end
face_name = "11"
check(not A.primary_ready() and #A.faces(ROOT) == 0, "without part 10 there is no face")
face_name = "10"; joint_count = 0
check(not A.primary_ready(), "part 10 without a skeleton is not a face")
joint_count = 400; visible = false
check(A.primary_root() == nil and not A.primary_ready(), "hidden Leon root is excluded")
visible = true

-- Core
local ok, _, msg = SKS.call("set_profile", {id = "re9_minimal"})
check(ok, "minimal automatic profile is available: " .. tostring(msg))
SKS.call("set_smoothing", {value = 0})
local function ticks(n) for _ = 1, n do CB.tick() end end
NATIVE[left] = .8
ticks(100)
check(#SKS.state.scene.rigs == 1 and #SKS.state.scene.parts == 2, "Core scans one rig with the head and part 40")
check(near(WEIGHTS[4], .8) and near(WEIGHTS[5], .6) and near(WEIGHTS[6], .09),
    "native values drive the custom keys on the head mesh")
check(near(WEIGHTS40[0], .8) and near(WEIGHTS40[2], .09), "the same signals drive matching keys on part 40")
local native_writes = 0
for _, w in ipairs(writes) do if w[3] == nil and w[1] < 4 then native_writes = native_writes + 1 end end
check(native_writes == 0 and #writes > 0, "automatic output never writes native channels")
WEIGHTS[4], WEIGHTS[5], WEIGHTS[6], WEIGHTS40[0] = 0, 0, 0, 0
ticks(1)
check(near(WEIGHTS[4], .8) and near(WEIGHTS[5], .6) and near(WEIGHTS40[0], .8),
    "unchanged active outputs are restored after the game clears them")
ok, _, msg = SKS.call("set_sculpt_key", {name = "BodyKey", value = .5}); ticks(1)
check(ok and near(WEIGHTS40[3], .5), "a sculpt key on part 40 is written: " .. tostring(msg))
WEIGHTS40[3] = 0; ticks(1)
check(near(WEIGHTS40[3], .5), "the sculpt value survives per-frame engine clearing")
check(not ShapeKeySystemAPI.set("test", left, 1), "public API cannot target a native name")
local before = #writes
active = false; ticks(1)
check(#writes == before, "root disappearance drops old targets before another write")
active = true; ticks(100)
before = #writes; mesh_id = 1001; ticks(1)
check(#writes == before, "a replaced head mesh stops writes before it warms up")
ticks(100)
check(#writes > before, "the replacement is rescanned and driven after warm-up")
before = #writes; scene_id = 801; ticks(1)
check(#writes == before, "a scene change invalidates the old targets even at the same addresses")
ticks(100)
check((INT_WRITES or 0) == 0, "all engine weights are System.Single-compatible Lua floats")
check(not SKS.state.debug.status:find("error", 1, true), "tick finishes without a runtime error")

-- face-bone rules (labels without taps) and diagnostics
local Bones = require("ShapeKeySystem_Games.RE9.Bones")
local function q(degrees)
    local a = math.rad(degrees) / 2
    return {x=math.sin(a),y=0,z=0,w=math.cos(a)}
end
local poses = {LU={base=q(11),value=q(36)},LL={base=q(-4),value=q(-14)}}
FACE.getJointByName = function(_, name)
    local pose = poses[name]
    if not pose then return end
    return {call=call,get_Name=function()return name end,
        get_BaseLocalRotation=function()return pose.base end,get_LocalRotation=function()return pose.value end,
        get_LocalPosition=function()return pose.position or{x=.01,y=.02,z=.03}end,
        get_BaseLocalPosition=function()return pose.base_position or{x=.011,y=.021,z=.031}end}
end
local function rule(a,b)
    local terms={{bone=a,axis={1,0,0},weight=1}}
    if b then terms[2]={bone=b,axis={1,0,0},weight=-1}end
    return {lo=5,hi=35,terms=terms}
end
check(Bones.configure({eyeWideLeft=rule('LU','LL')}), "bone rules validate")
local bv, angle = Bones.read(R.find(), 'eyeWideLeft')
check(near(bv, 1) and near(angle, 35), "a bone measurement subtracts each joint's own nonidentity base pose")
local jq=poses.LU.value;poses.LU.value={x=-jq.x,y=-jq.y,z=-jq.z,w=-jq.w}
check(near(Bones.read(R.find(),'eyeWideLeft'), 1), "quaternion sign changes leave the measurement unchanged")
poses.LU.value={x=0,y=0,z=0,w=0}
local _, _, state = Bones.read(R.find(),'eyeWideLeft')
check(state and state:find('pose_unavailable',1,true), "invalid bone quaternions fail closed")
poses.LU.value=jq
check(not Bones.validate({jawOpen={lo=0,hi=0,terms={{bone='Jaw',axis={1,0,0}}}}}), "zero calibration ranges are rejected")
check(not Bones.validate({jawOpen={lo=0,hi=1,terms={{bone='Jaw',axis={2,0,0}}}}}), "nonunit projection axes are rejected")
local data = json.load_file('ShapeKeySystem/builtin/re9/leon.json')
data.bone_fallbacks = {eyeWideLeft = rule('LU','LL')}; data.expression_fallbacks = {}
check(Signals.configure(data), "a label measured from bones configures alongside native taps")
local wide = Signals.raw.parse('eyeWideLeft')
local bh = Signals.bind(FACE, {1, wide}); Signals.read(bh, P, 1)
check(near(P[1], .8) and near(P[wide], 1) and bh.sources.eyeWideLeft == 'bones' and bh.sources.eyeBlinkLeft == 'native',
    "native taps and bone rules feed one read")
data.expression_fallbacks = {eyeWideLeft = rule('LU')}
check(not Signals.configure(data), "a label cannot be measured by two bone rules")
data.taps.eyeBlinkLeft = {"HeadSkinned_blendShape.Unknown"}
check(not Signals.configure(data), "a tap outside the native names is rejected")
check(Signals.configure(json.load_file('ShapeKeySystem/builtin/re9/leon.json')), "the builtin data configures")
local diagnostic = A.native_snapshot({include_native_outputs = true})
check(diagnostic and near(diagnostic.taps[left], .8) and diagnostic.native_sources[left] == 'parameter'
    and diagnostic.outputs['re9.native.UprLdDn_00_L'] ~= nil and diagnostic.status[left] == nil
    and diagnostic.status[P_ .. 'NekTns_L'] == 'unavailable',
    'snapshots report native values and their source; status lists only unreadable natives')
local N=require('ShapeKeySystem_Core.NativeSignals')
check(N.command(A,{action='snapshot'}),'formal snapshot command is accepted')
local snapshot_ok,snapshot_error=pcall(N.tick,A,true,{})
check(snapshot_ok and N.state.file and json.load_file(N.state.file), 'the shared recorder saves RE9 snapshots: '..tostring(snapshot_error))
N.command(A,{action='start',label='RE9 integration'});N.tick(A,true,{})
check(N.state.recording and N.state.samples==1,'recording starts with a valid RE9 sample')
generation = 3
N.command(A,{action='snapshot'});N.tick(A,true,{})
check(not N.state.recording,'an identity change ends recording instead of joining two rigs')
generation = 1

dofile('tests_re9_bulk.lua')({check=check,Signals=Signals,R=R,Hash=Hash,poses=poses,FACE=FACE,
    SKS=SKS,ticks=ticks,near=near,refresh_channels=function()
        wc,length,mesh_id=#CHANNELS,#CHANNELS,mesh_id+1
    end})
print(string.format("RE9 %d assertions; FAILS: %d", assertions, failures))
if failures > 0 then error("RE9 adapter tests failed") end
