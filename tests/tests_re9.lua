-- The real RE9 adapter drives named custom channels on a native-animation head.
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
local left, right = "HeadSkinned_blendShape.UprLdDn_00_L", "HeadSkinned_blendShape.UprLdDn_00_R"
local jaw_l, jaw_r = "HeadSkinned_blendShape.JwOpn_00_L", "HeadSkinned_blendShape.JwOpn_00_R"
CHANNELS = {left, right, jaw_l, jaw_r, "eyeBlinkLeft", "eyeBlinkRight", "jawOpen", "SKS_RE9_Test_NoseForward"}
local m, wc, length, generation = ARMOR._mesh, #CHANNELS, #CHANNELS, 1
local active, visible, shadow, read_fail, bad_hash, missing_hash = true, true, false, false, false, false
local scene_id, mesh_id, hash_reads = 800, 1000, 0
m.call = call
m.get_address = function() return mesh_id end
m.get_BlendShapeChannelWeightCount = function() return wc end
m.get_ChannelWeightList = function() return {call = call, get_Length = function() return length end} end
m.getMesh = function() return {call = call, get_ResourcePath = function() return "character/ch/ch01/0100/10/00/ch0100_10_00.mesh" end} end
m.get_ChannelNameHash = function()
    return {call = call, get_Item = function(_, i)
        hash_reads = hash_reads + 1
        if missing_hash and i == 0 then return nil end
        return bad_hash and i == 0 and 999 or Hash.hash(CHANNELS[i + 1])
    end, get_elements = function() error("RE9 only reads get_Item") end}
end
local original_read = m.getBlendShapeChannelWeightParam
m.getBlendShapeChannelWeightParam = function(self, i)
    assert(i >= 0 and i < math.min(#CHANNELS, wc, length), "out of bounds")
    if read_fail and i == 0 then return nil end
    return original_read(self, i)
end
local motion = {call = call, get_SkeletonConstructCount = function() return generation end}
local function go(tr, name)
    return {call = call, get_Name = function() return shadow and tr == ARMOR and "Shadow" or name end,
        get_Valid = function() return active end, get_DrawSelf = function() return visible end,
        get_Transform = function() return tr end,
        getComponent = function(_, kind)
            if tr == ARMOR and kind == "via.render.Mesh" then return m end
            if tr == ARMOR and kind == "via.motion.Motion" then return motion end
        end}
end
ROOT.call = call; ARMOR.call = call
ROOT.get_address = function() return 10 end; ARMOR.get_address = function() return 20 end
ROOT.get_GameObject = function() return go(ROOT, "cp_A000") end
ARMOR.get_GameObject = function() return go(ARMOR, "10") end
ROOT.get_Child = function() return ARMOR end
ARMOR.get_Child = function() return nil end
ARMOR.get_Next = function() return ARMOR end -- cyclic sibling chain must terminate
ARMOR.get_Parent = function() return ROOT end
SCENE = {call = call, get_address = function() return scene_id end,
    findGameObject = function(_, name) return active and name == "cp_A000" and go(ROOT, name) end}
GAME_NAME = "re9"
json.dump_file("ShapeKeySystem/mods/names/re9_test.json", {schema = "sks.names/1", names = CHANNELS})
json.dump_file('ShapeKeySystem/user/re9_input.json',{schema='sks.re9-input/1',mode='legacy',extended=false})
dofile(ENTRY)
local SKS = require("ShapeKeySystem_Core.API")
local A = SKS.adapter
check(A.id == "re9" and A.primary_ready(), "RE9 is selected and the visible Leon head is ready")
check(A.primary_root() == ROOT and #A.faces(ROOT) == 1 and #A.parts(ROOT) == 1, "only the gameplay head is scanned")
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
local h, count = A.bind(ARMOR, {1, 2, 3})
check(count == 3 and h.mesh == nil and h.face == nil, "signal handles retain no engine objects")
WEIGHTS[0], WEIGHTS[1], WEIGHTS[2], WEIGHTS[3] = .8, .6, .04, .09
local P = {}; A.read(h, P, 1)
check(P[1] == .8 and P[2] == .6 and P[3] == .09, "left/right blink are independent and jaw uses the maximum native tap")
read_fail = true; A.read(h, P, 1)
check(P[1] == 0 and P[2] == .6 and h.status[left] == "read_failed", "one failed input does not disable the others")
read_fail = false; bad_hash = true; A.read(h, P, 1)
check(P[1] == 0 and h.status[left] == "hash_changed", "changed tap hash prevents an unrelated index read")
bad_hash = false; missing_hash = true
local sparse = A.bind(ARMOR, {1, 2}); A.read(sparse, P, 1)
check(P[1] == 0 and P[2] == .6, "an unreadable first hash does not hide later taps")
missing_hash = false
local original_signature = A.signature(ROOT)
generation = 2; A.read(h, P, 1)
check(P[1] == 0 and A.signature(ROOT) ~= original_signature, "skeleton rebuild invalidates handles and the target signature")
generation = 1
for _, value in ipairs({0, #CHANNELS - 1}) do
    wc = value
    check(not A.primary_ready() and not A.channel_writable(CHANNELS[5], m, 4), "incomplete WeightCount denies the head: " .. value)
end
wc = #CHANNELS; length = #CHANNELS - 1
check(not A.primary_ready(), "short allocated list denies the head")
length = #CHANNELS; MESH_STATE.released = true
check(not A.primary_ready(), "released buffer denies the head")
MESH_STATE.released = false; MESH_STATE.ready = false
check(not A.primary_ready(), "unready mesh denies the head")
MESH_STATE.ready = true; shadow = true
check(not A.primary_ready(), "Shadow head is excluded even with allocated weights")
shadow = false; visible = false
check(A.primary_root() == nil and not A.primary_ready(), "hidden Leon root is excluded")
visible = true
local ok, _, msg = SKS.call("set_profile", {id = "re9_minimal"})
check(ok, "minimal automatic profile is available: " .. tostring(msg))
SKS.call("set_smoothing", {value = 0})
local function ticks(n) for _ = 1, n do CB.tick() end end
ticks(100)
check(#SKS.state.scene.rigs == 1 and #SKS.state.scene.parts == 1, "Core scans a single primary rig and head part")
check(WEIGHTS[4] == .8 and WEIGHTS[5] == .6 and WEIGHTS[6] == .09, "native inputs drive the three custom outputs through Core")
local native_writes = 0
for _, w in ipairs(writes) do if w[1] < 4 then native_writes = native_writes + 1 end end
check(native_writes == 0 and #writes > 0, "automatic output never writes native input channels")
WEIGHTS[4], WEIGHTS[5], WEIGHTS[6] = 0, 0, 0
ticks(1)
check(WEIGHTS[4] == .8 and WEIGHTS[5] == .6, "unchanged active outputs are restored after the game clears them")
ok, _, msg = SKS.call("set_sculpt_key", {name = CHANNELS[8], value = .5})
ticks(1)
check(ok and WEIGHTS[7] == .5, "panel sculpt command writes a manual custom key: " .. tostring(msg))
WEIGHTS[7] = 0; ticks(1)
check(WEIGHTS[7] == .5, "manual sculpt value also survives per-frame engine clearing")
check(not ShapeKeySystemAPI.set("test", left, 1), "public API cannot target a native name")
local before = #writes
active = false; ticks(1)
check(#writes == before, "root disappearance drops old targets before another write")
active = true; ticks(100)
before = #writes; mesh_id = 1001; ticks(1)
check(#writes == before, "mesh replacement stops writes before the new mesh warms up")
ticks(100)
check(#writes > before, "replacement head is rescanned and driven after warm-up")
before = #writes; MESH_STATE.released = true; ticks(1)
check(#writes == before, "released buffers stop both sculpt and expression writes")
MESH_STATE.released = false; ticks(100)
before = #writes; scene_id = 801; ticks(1)
check(#writes == before, "scene identity change invalidates the old target even at the same mesh address")
check((INT_WRITES or 0) == 0, "all engine weights are System.Single-compatible Lua floats")
check(not SKS.state.debug.status:find("error", 1, true), "tick finishes without a runtime error")
CHANNELS[9], CHANNELS[10] = CHANNELS[8], CHANNELS[8]
CHANNELS[11], CHANNELS[12], CHANNELS[13], CHANNELS[14] = "まばたき", "まばたき", "あ", "あ"
wc, length, mesh_id = #CHANNELS, #CHANNELS, 1002
json.dump_file("ShapeKeySystem/mods/names/re9_test.json", {schema = "sks.names/1", names = CHANNELS})
SKS.call("rescan", {}); ticks(100)
check(WEIGHTS[7] == .5 and WEIGHTS[8] == .5 and WEIGHTS[9] == .5,
    "one manual key writes every repeated channel index")
local blink_ok = SKS.call("set_sculpt_key", {name = "まばたき", value = .5})
local mouth_ok = SKS.call("set_sculpt_key", {name = "あ", value = 1})
ticks(1)
check(blink_ok and mouth_ok and WEIGHTS[10] == .5 and WEIGHTS[11] == .5 and WEIGHTS[12] == 1 and WEIGHTS[13] == 1,
    "MMD blink and mouth names drive all matching indices independently")
WEIGHTS[10], WEIGHTS[11], WEIGHTS[12], WEIGHTS[13] = 0, 0, 0, 0; ticks(1)
check(WEIGHTS[10] == .5 and WEIGHTS[11] == .5 and WEIGHTS[12] == 1 and WEIGHTS[13] == 1,
    "repeated MMD channels are restored after the engine clears them")
SKS.call("set_sculpt_key", {name = "まばたき", value = 0})
SKS.call("set_sculpt_key", {name = "あ", value = 0}); ticks(1)
check(WEIGHTS[10] == 0 and WEIGHTS[11] == 0 and WEIGHTS[12] == 0 and WEIGHTS[13] == 0,
    "returning MMD sliders to zero releases every repeated channel")
CHANNELS[15]='う';wc,length=#CHANNELS,#CHANNELS
WEIGHTS[2],WEIGHTS[3]=0,0
SKS.call('rescan',{});ticks(100)
local mmd_ok, mmd_code, mmd_why = SKS.call("set_profile", {id = "mmd"}); ticks(100)
check(mmd_ok and SKS.state.expression.profile.id=='mmd' and not SKS.state.debug.status:find('driven=none',1,true),
    'MMD profile with three matching keys is selected and driven: '..tostring(mmd_code)..' '..tostring(mmd_why))
SKS.call("set_sculpt_key", {name = "あ", value = .5}); ticks(2)
check(WEIGHTS[12] == .5 and WEIGHTS[13] == .5,
    "MMD-profile mouth rest value reaches all repeated expression-owned indices")
SKS.call("set_sculpt_key", {name = "あ", value = 0}); ticks(2)
check(WEIGHTS[12] == 0 and WEIGHTS[13] == 0,
    "MMD-profile mouth rest value returns all expression-owned indices to zero")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")
local function q(degrees)
    local a = math.rad(degrees) / 2
    return {x=math.sin(a),y=0,z=0,w=math.cos(a)}
end
local position_reads=0
local poses = {LU={base=q(11),value=q(36)},LL={base=q(-4),value=q(-14)},
    RU={base=q(7),value=q(32)},RL={base=q(-2),value=q(-12)},Jaw={base=q(3),value=q(13)}}
ARMOR.getJointByName = function(_, name)
    local pose = poses[name]
    if not pose then return end
    return {call=call,get_Name=function()return name end,
        get_BaseLocalRotation=function()return pose.base end,get_LocalRotation=function()return pose.value end,
        get_LocalPosition=function()position_reads=position_reads+1;return pose.position or{x=.01,y=.02,z=.03}end,
        get_BaseLocalPosition=function()return pose.base_position or{x=.011,y=.021,z=.031}end}
end
local function rule(a,b)
    local terms={{bone=a,axis={1,0,0},weight=1}}
    if b then terms[2]={bone=b,axis={1,0,0},weight=-1}end
    return {lo=5,hi=35,terms=terms}
end
check(Bones.configure({eyeBlinkLeft=rule('LU','LL'),eyeBlinkRight=rule('RU','RL'),
    jawOpen={lo=0,hi=20,terms={{bone='Jaw',axis={1,0,0}}}}}), "bone fallback rules validate")
local bv, angle = Bones.read(R.find(), 'eyeBlinkLeft')
check(math.abs(bv-1)<1e-8 and math.abs(angle-35)<1e-8, "eyelid measurement subtracts each joint's own nonidentity base pose")
local jq=poses.LU.value;poses.LU.value={x=-jq.x,y=-jq.y,z=-jq.z,w=-jq.w}
bv=Bones.read(R.find(),'eyeBlinkLeft')
check(math.abs(bv-1)<1e-8,"quaternion sign changes leave the measurement unchanged")
poses.LU.value=jq
WEIGHTS[0],WEIGHTS[1],WEIGHTS[2],WEIGHTS[3]=0,.6,0,0
local bh=A.bind(ARMOR,{1,2,3});A.read(bh,P,1)
check(P[1]==0 and P[3]==0 and bh.sources.eyeBlinkLeft=='native',
    "readable native zero takes priority over a moving bone")
local native_hashes=m.get_ChannelNameHash
m.get_ChannelNameHash=function()
    return {call=call,get_Item=function(_,i)
        return i<4 and Hash.hash('missing native '..i) or Hash.hash(CHANNELS[i+1])
    end}
end
bh=A.bind(ARMOR,{1,2,3});A.read(bh,P,1)
check(math.abs(P[1]-1)<1e-8 and math.abs(P[2]-1)<1e-8 and math.abs(P[3]-.5)<1e-8
    and bh.sources.jawOpen=='bones', "missing correction channels use three independent bone measurements")
check(bh.mesh==nil and bh.joints==nil and bh.bone_joints.LU.rotation[1]~=nil,
    "handles and diagnostic snapshots retain only numbers and names")
local saved_lu=poses.LU;poses.LU=nil;A.read(bh,P,1)
check(P[1]==0 and math.abs(P[2]-1)<1e-8 and math.abs(P[3]-.5)<1e-8,
    "a missing eyelid only disables its own fallback")
poses.LU=saved_lu;poses.LU.value={x=0,y=0,z=0,w=0};A.read(bh,P,1)
check(P[1]==0 and bh.bone_status.eyeBlinkLeft:find('pose_unavailable',1,true), "invalid bone quaternions fail closed")
poses.LU.value=q(36);mesh_id=mesh_id+1;A.read(bh,P,1)
check(P[1]==0 and P[2]==0 and P[3]==0, "old identity cannot use current bones after a mesh rebuild")
m.get_ChannelNameHash=native_hashes
for i=1,4 do CHANNELS[i]='CustomBeforeMMD'..i end
json.dump_file("ShapeKeySystem/mods/names/re9_test.json", {schema="sks.names/1",names=CHANNELS})
SKS.call('rescan',{});ticks(100)
check(math.abs(WEIGHTS[10]-1)<1e-8 and math.abs(WEIGHTS[11]-1)<1e-8
    and math.abs(WEIGHTS[12]-.5)<1e-8 and math.abs(WEIGHTS[13]-.5)<1e-8,
    "real Core and MMD profile drive repeated shape channels from bones alone ("..
    tostring(WEIGHTS[10])..", "..tostring(WEIGHTS[11])..", "..tostring(WEIGHTS[12])..", "..tostring(WEIGHTS[13])..
    "; profile="..tostring(SKS.state.expression.profile.id).."; "..SKS.state.debug.status..")")
check(not Bones.validate({jawOpen={lo=0,hi=0,terms={{bone='Jaw',axis={1,0,0}}}}}),
    "zero calibration ranges are rejected")
check(not Bones.validate({jawOpen={lo=0,hi=1,terms={{bone='Jaw',axis={2,0,0}}}}}),
    "nonunit projection axes are rejected")
local diagnostic=A.native_snapshot()
check(#diagnostic.joints.LU==7 and diagnostic.joints.LU[1]==.01
    and diagnostic.bone_poses.LU.base_rotation[1]~=nil and diagnostic.calibration~=nil,
    'diagnostics provide actual position/quaternion arrays and retain detailed calibration')
local N=require('ShapeKeySystem_Core.NativeSignals')
check(N.command(A,{action='snapshot'}),'formal snapshot command is accepted')
local snapshot_ok,snapshot_error=pcall(N.tick,A,true,{})
local saved_snapshot=N.state.file and json.load_file(N.state.file)
check(snapshot_ok and saved_snapshot and #saved_snapshot.snapshot.joints.LU==7,
    'real shared recorder observes and saves RE9 bone snapshots: '..tostring(snapshot_error))
N.command(A,{action='start',label='RE9 integration'});N.tick(A,true,{})
check(N.state.recording and N.state.samples==1,'formal recording starts with a valid RE9 sample')
local dump=json.dump_file
json.dump_file=function(path,...)
    if path:find('native_signals_re9_',1,true)then return false end
    return dump(path,...)
end
N.command(A,{action='stop'});N.tick(A,true,{})
check(not N.state.recording and N.unsaved~=nil,'save failure retains the completed diagnostic take')
json.dump_file=dump
N.command(A,{action='retry'});N.tick(A,true,{})
local take=N.state.file and json.load_file(N.state.file)
check(N.unsaved==nil and take and take.calibration and #take.samples[1].values.joints.LU==7,
    'retry saves calibration and valid poses without losing the take')
N.command(A,{action='start'});N.tick(A,true,{})
mesh_id=mesh_id+1
N.command(A,{action='snapshot'});N.tick(A,true,{})
check(not N.state.recording,'an identity change ends recording instead of joining two rigs')
local function neutral(p)return {p.base.x,p.base.y,p.base.z,p.base.w}end
local function candidate_rule(a,b)
    local r=rule(a,b)
    for _,term in ipairs(r.terms)do term.motion_neutral=neutral(poses[term.bone])end
    return r
end
check(Bones.configure({eyeBlinkLeft=candidate_rule('LU','LL'),eyeBlinkRight=candidate_rule('RU','RL'),
    jawOpen={lo=0,hi=20,terms={{bone='Jaw',axis={1,0,0},motion_neutral=neutral(poses.Jaw)}}}}),
    'candidate uses the same angular rules and explicit neutral rotations for missing bones')
local ordered={'LU','LL','RU','RL','Jaw'}
local by_hash,animation={},{}
for i,name in ipairs(ordered)do by_hash[Hash.hash(name)]=i-1;animation[i]=poses[name]end
local motion_queries,motion_rotations,motion_id=0,0,1900
motion.get_address=function()return motion_id end
motion.get_GameObject=function()return go(ARMOR,'10')end
motion.get_JointCount=function()return 5 end
motion.getJointIndexByNameHash=function(_,hash)motion_queries=motion_queries+1;return by_hash[hash]or-1 end
motion.getCalculatedLocalRotation=function(_,i)motion_rotations=motion_rotations+1;return animation[i+1].value end
motion.getCalculatedLocalPosition=function()return {x=.01,y=.02,z=.03}end
local candidate=Signals.bind(ARMOR,{1,2,3},'bones_first')
Signals.read(candidate,P,1)
check(P[1]>0 and candidate.sources.eyeBlinkLeft=='bones'and motion_queries==0 and motion_rotations==0,
    'complete face bones use no Motion pose lookup or sampling')
local lu_value,ll_value=poses.LU.value,poses.LL.value
poses.LU.value,poses.LL.value=poses.LU.base,poses.LL.base
Signals.read(candidate,P,1)
check(P[1]==0 and candidate.sources.eyeBlinkLeft=='bones'and motion_rotations==0,
    'a valid bone zero does not fall back to Motion or native corrections')
poses.LU.value,poses.LL.value=lu_value,ll_value
local kept_lu=poses.LU;poses.LU=nil
Signals.read(candidate,P,1)
check(math.abs(P[1]-1)<1e-8 and candidate.sources.eyeBlinkLeft=='motion'and motion_rotations==1
    and motion_queries==1 and candidate.sources.eyeBlinkRight=='bones'and candidate.sources.jawOpen=='bones',
    'only the missing upper eyelid is sampled from the same-named Motion bone')
Signals.read(candidate,P,1)
check(motion_queries==1 and motion_rotations==2,'numeric Motion indices are reused for an unchanged identity')
motion_id=motion_id+1;Signals.read(candidate,P,1)
check(motion_queries==2,'a replaced Motion owner invalidates its cached indices')
local previous_rotation=animation[1].value;animation[1].value={x=0,y=0,z=0,w=0}
Signals.read(candidate,P,1)
check(P[1]==0 and candidate.sources.eyeBlinkLeft=='unavailable'and P[2]>0,
    'invalid Motion rotation fails independently without stale output')
animation[1].value=previous_rotation
local lookups_before=motion_queries
mesh_id=mesh_id+1;Signals.read(candidate,P,1)
check(P[1]==0 and P[2]==0 and P[3]==0 and motion_queries==lookups_before,
    'an old head handle cannot sample Motion after a rebuild')
poses.LU=kept_lu
local simulated=A.native_snapshot({input_mode='bones_first',omit_bones={LU=true}})
check(simulated.simulated_missing_bones and simulated.sources.eyeBlinkLeft=='motion'
    and #simulated.joints.LU==7,'read-only diagnostics can exercise fallback without changing the model')
check(A.native_snapshot().input_mode=='legacy','shadow diagnostics leave the active legacy mode unchanged')
local physical=poses;poses={}
local all_missing=Signals.bind(ARMOR,{1,2,3},'bones_first')
local before_rotations=motion_rotations;Signals.read(all_missing,P,1)
check(P[1]>0 and P[2]>0 and P[3]>0 and motion_rotations-before_rotations==5,
    'three missing inputs request five actual bone poses rather than 128 correction parameters')
poses=physical
local lookup=motion.getJointIndexByNameHash
motion.getJointIndexByNameHash=function()return -1 end
local absent=Signals.bind(ARMOR,{1,2,3},'bones_first');poses.LU=nil
Signals.read(absent,P,1)
check(P[1]==0 and absent.bone_status.eyeBlinkLeft:find('motion_joint_unavailable',1,true),
    'bones absent from both Transform and Motion are explicitly unavailable')
motion.getJointIndexByNameHash=lookup;poses.LU=kept_lu
check(not Bones.validate({jawOpen={lo=0,hi=1,terms={{bone='Jaw',axis={1,0,0},motion_neutral={0,0,0,0}}}}}),
    'invalid Motion neutral quaternions are rejected')
local expanded=json.load_file('ShapeKeySystem/builtin/re9/leon.json')
local brow={base=q(0),value=q(0),position={x=.01,y=.022,z=.03},base_position={x=.01,y=.02,z=.03}}
poses.Brow=brow
local function position_rule(axis)
    return {lo=0,hi=4,terms={{bone='Brow',kind='pos',axis=axis,
        motion_neutral={0,0,0,1},motion_neutral_position={.01,.02,.03}}}}
end
expanded.bone_fallbacks={browOuterUpLeft=position_rule({0,1,0}),mouthSmileLeft=position_rule({0,1,0}),
    mouthFrownLeft=position_rule({0,-1,0})}
check(Signals.configure(expanded,'bones_first'),'extended position measurements configure without changing the three original keys')
local brow_key,smile_key,frown_key=Signals.raw.parse('browOuterUpLeft'),Signals.raw.parse('mouthSmileLeft'),Signals.raw.parse('mouthFrownLeft')
check(brow_key and smile_key and frown_key and Signals.raw.parse('jawOpen')==3,
    'configured semantic names get stable keys alongside the legacy three')
check(not Signals.raw.parse('mouthRollUpper'),'unconfigured semantics remain explicitly unavailable')
local ext=Signals.bind(ARMOR,{brow_key,smile_key,frown_key},'bones_first')
local before_positions,before_motion=position_reads,motion_rotations
Signals.read(ext,P,1)
check(math.abs(P[brow_key]-.5)<1e-8 and math.abs(P[smile_key]-.5)<1e-8 and P[frown_key]==0,
    'position inputs use their own base pose in millimetres and independent signed axes')
check(position_reads-before_positions==1 and motion_rotations==before_motion,
    'several semantics sharing a physical position read it once with no Motion requests')
brow.position={x=.01,y=.02,z=.03};Signals.read(ext,P,1)
check(P[brow_key]==0 and ext.sources.browOuterUpLeft=='bones'and ext.motion_requests==0,
    'a valid position zero also wins over Motion')
brow.position={x=.01,y=.024,z=.03};Signals.read(ext,P,1)
check(math.abs(P[brow_key]-1)<1e-8,'position cache is local to the read and never preserves a previous frame')
brow.position={x=.01,y=.022,z=.03}
by_hash[Hash.hash('Brow')]=5;animation[6]=brow
motion.get_JointCount=function()return 6 end
motion.getCalculatedLocalPosition=function(_,i)return i==5 and brow.position or{x=.01,y=.02,z=.03}end
poses.Brow=nil
before_motion=motion_rotations
Signals.read(ext,P,1)
check(math.abs(P[brow_key]-.5)<1e-8 and ext.sources.browOuterUpLeft=='motion'and ext.motion_requests==1
    and motion_rotations-before_motion==1,'a missing position is sampled once from the same-named Motion joint for every dependent semantic')
motion.getCalculatedLocalPosition=function()return nil end;Signals.read(ext,P,1)
check(P[brow_key]==0 and ext.bone_status.browOuterUpLeft:find('motion_position_unavailable',1,true),
    'unreadable Motion position fails without falling back to stale or rotation-only values')
poses.Brow=brow
local expanded_snapshot=Signals.snapshot()
check(#expanded_snapshot.joints.Brow==7 and expanded_snapshot.outputs.browOuterUpLeft>.49,
    'extended signals use the same seven-number formal diagnostic contract')
check(not Bones.validate({mouthSmileLeft={lo=0,hi=1,terms={{bone='Brow',kind='scale',axis={0,1,0}}}}}),
    'unsupported measurement kinds are rejected')
check(not Bones.validate({mouthSmileLeft={lo=0,hi=1,terms={{bone='Brow',kind='pos',axis={0,1,0},motion_neutral_position={0,0}}}}}),
    'Motion position neutrals require three finite coordinates')
expanded.expression_fallbacks={browDownLeft=position_rule({0,1,0})}
check(Signals.configure(expanded,'bones_first',true)and Signals.expanded()and Signals.raw.parse('browDownLeft'),
    'extension rules are available only after explicit opt-in')
check(Signals.configure(expanded,'bones_first',false)and not Signals.expanded(),
    'disabling the extension restores the previous configured input set')
local disabled_key=Signals.raw.parse('browDownLeft')
local disabled=Signals.bind(ARMOR,{disabled_key},'bones_first');Signals.read(disabled,P,1)
check(P[disabled_key]==0 and disabled.bone_status.browDownLeft=='extension_disabled'and disabled.motion_requests==0,
    'disabled extension entries remain profile-compatible but read no poses and produce zero')
local previous_extension=expanded.expression_fallbacks
expanded.expression_fallbacks={mouthSmileLeft=position_rule({0,1,0})}
check(not Signals.configure(expanded,'bones_first',true),'an extension cannot override an existing calibrated input')
expanded.expression_fallbacks=previous_extension;Signals.configure(expanded,'bones_first',true)
CHANNELS[16],CHANNELS[17],CHANNELS[18],CHANNELS[19]='上左','上左','下左','口角上げ左'
wc,length,mesh_id=#CHANNELS,#CHANNELS,mesh_id+1
json.dump_file('ShapeKeySystem/mods/names/re9_test.json',{schema='sks.names/1',names=CHANNELS})
SKS.call('rescan',{});ticks(100)
local re9_profile,profile_code,profile_why=SKS.call('set_profile',{id='re9_mmd'});ticks(100)
check(re9_profile and SKS.state.expression.profile.id=='re9_mmd',
    'RE9 MMD inherits the common profile and selects through the real API: '..tostring(profile_code)..' '..tostring(profile_why))
check(math.abs((WEIGHTS[15]or-1)-.5)<1e-8 and math.abs((WEIGHTS[16]or-1)-.5)<1e-8
    and math.abs((WEIGHTS[17]or-1)-.5)<1e-8 and math.abs((WEIGHTS[18]or-1)-.5)<1e-8,
    'real Core drives duplicate independent brow channels and mouth corners from extension positions')
brow.position=brow.base_position;ticks(2)
check(WEIGHTS[15]==0 and WEIGHTS[16]==0 and WEIGHTS[17]==0 and WEIGHTS[18]==0,
    'returning the new physical inputs to rest releases every matching extension index')
local brow_r={base=q(0),value=q(0),position={x=.009,y=.024,z=.03},base_position={x=.01,y=.02,z=.03}}
poses.BrowR=brow_r;brow.position={x=.012,y=.022,z=.03}
expanded.expression_fallbacks.browInnerUp={lo=0,hi=4,terms={
    {bone='Brow',kind='pos',axis={0,1,0},weight=.5,motion_neutral={0,0,0,1},motion_neutral_position={.01,.02,.03}},
    {bone='BrowR',kind='pos',axis={0,1,0},weight=.5,motion_neutral={0,0,0,1},motion_neutral_position={.01,.02,.03}}}}
expanded.expression_fallbacks.mouthStretchLeft=position_rule({1,0,0})
expanded.expression_fallbacks.mouthStretchRight={lo=0,hi=4,terms={
    {bone='BrowR',kind='pos',axis={-1,0,0},motion_neutral={0,0,0,1},motion_neutral_position={.01,.02,.03}}}}
check(Signals.configure(expanded,'bones_first',true),'second-group inputs share the optional extension configuration')
local inner_key,left_stretch,right_stretch=Signals.raw.parse('browInnerUp'),
    Signals.raw.parse('mouthStretchLeft'),Signals.raw.parse('mouthStretchRight')
local second=Signals.bind(ARMOR,{inner_key,left_stretch,right_stretch},'bones_first')
before_positions=position_reads;Signals.read(second,P,1)
check(math.abs(P[inner_key]-.75)<1e-8 and math.abs(P[left_stretch]-.5)<1e-8
    and math.abs(P[right_stretch]-.25)<1e-8,'inner-brow averaging and mirrored lateral axes preserve independent values')
check(position_reads-before_positions==2 and second.motion_requests==0,
    'new axes reuse each physical position once without extra Motion poses')
motion.getCalculatedLocalPosition=function(_,i)return i==5 and brow.position or{x=.01,y=.02,z=.03}end
poses.Brow=nil;Signals.read(second,P,1)
check(math.abs(P[inner_key]-.75)<1e-8 and math.abs(P[left_stretch]-.5)<1e-8
    and second.motion_requests==1 and second.sources.browInnerUp=='motion'
    and second.sources.mouthStretchRight=='bones','one absent physical position serves both new dependent inputs from one Motion pose')
poses.Brow=brow
CHANNELS[20],CHANNELS[21],CHANNELS[22],CHANNELS[23],CHANNELS[24]=
    '口横広げ左','口横広げ左','口横広げ右','困る','口横広げ'
wc,length,mesh_id=#CHANNELS,#CHANNELS,mesh_id+1
json.dump_file('ShapeKeySystem/mods/names/re9_test.json',{schema='sks.names/1',names=CHANNELS})
SKS.call('rescan',{});ticks(100)
check(math.abs((WEIGHTS[19]or-1)-.5)<1e-8 and math.abs((WEIGHTS[20]or-1)-.5)<1e-8
    and math.abs((WEIGHTS[21]or-1)-.25)<1e-8 and math.abs((WEIGHTS[22]or-1)-.75)<1e-8,
    'real Core drives all duplicate lateral mouth indices and the inherited inner-brow channel')
check((WEIGHTS[23]or 0)==0,'independent lateral keys suppress the symmetric mouth stretch channel')
brow.position=brow.base_position;brow_r.position=brow_r.base_position;ticks(2)
check(WEIGHTS[19]==0 and WEIGHTS[20]==0 and WEIGHTS[21]==0 and WEIGHTS[22]==0,
    'new channels return every matched index to zero when the source returns to base')
dofile('tests_re9_bulk.lua')({check=check,Signals=Signals,R=R,Hash=Hash,poses=poses,motion=motion,
    SKS=SKS,ticks=ticks,refresh_channels=function()
        wc,length,mesh_id=#CHANNELS,#CHANNELS,mesh_id+1
        json.dump_file('ShapeKeySystem/mods/names/re9_test.json',{schema='sks.names/1',names=CHANNELS})
    end})
do
    local load=json.load_file
    local override
    json.load_file=function(path)
        if path=='ShapeKeySystem/user/re9_input.json'then return override end
        return load(path)
    end
    check(A.init()and Signals.mode()=='bones_first'and Signals.expanded(),
        'fresh RE9 installations default to bone priority and the head expansion')
    override={schema='sks.re9-input/1',mode='legacy'}
    check(A.init()and Signals.mode()=='legacy'and not Signals.expanded(),
        'existing legacy overrides without an expansion field preserve their previous behavior')
    override={schema='sks.re9-input/1',mode='bones_first'}
    check(A.init()and Signals.mode()=='bones_first'and not Signals.expanded(),
        'existing three-input bone overrides do not silently opt into the new expansion')
    override.extended=true
    check(A.init()and Signals.expanded(),'an explicit existing expansion opt-in is retained')
    override.extended=false
    check(A.init()and not Signals.expanded(),'an explicit expansion opt-out is retained')
    override.extended='yes'
    check(not A.init(),'invalid user overrides do not silently become fresh-install defaults')
    json.load_file=load
end
print(string.format("RE9 %d assertions; FAILS: %d", assertions, failures))
if failures > 0 then error("RE9 adapter tests failed") end
