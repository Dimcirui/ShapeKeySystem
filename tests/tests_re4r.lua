-- A separate runtime models nested player parts, a shared signal/output head and delayed buffers.
local Hash = require("ShapeKeySystem_Core.NameHash")
local Signals = require("ShapeKeySystem_Games.RE4R.Signals")
local failures, assertions = 0, 0
local function check(ok, label)
    assertions = assertions + 1
    print((ok and "ok   " or "FAIL ") .. "[re4r] " .. label)
    if not ok then failures = failures + 1 end
end
local function call(self, name, ...) return self[name:match("^([%w_]+)")](self, ...) end
local function joint(pos, rot)
    return { call = call, get_LocalPosition = function() return pos end,
        get_LocalRotation = function() return rot end }
end
local native = "Face__geo__p000_cbs.crct_jaw_openExtreme"
CHANNELS = {native, "SK__arkit.eyeBlinkLeft", "SK__arkit.eyeBlinkRight", "SK__arkit.jawOpen", "Size"}
HASH = Hash.hash
local m = ARMOR._mesh
local count, length = #CHANNELS, #CHANNELS
local lod = 1
m.get_ChannelWeightList = function() return {call = call, get_Length = function() return length end} end
m.get_BlendShapeChannelWeightCount = function() return count end
m.set_LodLevel = function(_, v) lod = v end
m.get_ChannelNameHash = function()
    return {call = call, get_Item = function(_, i) return Hash.hash(CHANNELS[i+1]) end,
        get_elements = function() local t = {}; for i,n in ipairs(CHANNELS) do t[i] = Hash.hash(n) end; return t end}
end
m.getMesh = function() return {call = call, get_ResourcePath = function() return "/Character/cha000/10/cha000_10.mesh.221108797" end} end
local cal = json.load_file("ShapeKeySystem/builtin/re4/leon.json")
local q = {x=0,y=0,z=0,w=1}
local pos = {x=0,y=0,z=0}
for name,spec in pairs(cal.joints) do
    ARMOR._joints[spec.bone or name] = joint({x=spec.neutral[1],y=spec.neutral[2],z=spec.neutral[3]},
        {x=spec.neutral[4],y=spec.neutral[5],z=spec.neutral[6],w=spec.neutral[7]})
end
ARMOR.call = call
ARMOR.get_Next = function() return nil end
ARMOR.get_Child = function() return nil end
ARMOR.get_Parent = function() error("RE4R scanning must not depend on a direct parent") end
ROOT.get_Child = function() return nil end
local function go(tr) return {call=call,get_Transform=function() return tr end} end
local current = true
local ctx = {call=call,get_BodyGameObject=function() return go(ROOT) end,
    get_BodyUpdater=function() return {call=call,get_HeadMotion=function() return {call=call,get_GameObject=function() return go(ARMOR) end} end} end}
local original_singleton = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "chainsaw.CharacterManager" then
        return {call=call,getPlayerContextRef=function() return current and ctx or nil end}
    end
    return original_singleton(name)
end
local pres = {}
re.on_pre_application_entry = function(stage, fn) pres[stage] = fn end
GAME_NAME = "re4"
json.dump_file("ShapeKeySystem/mods/names/synthetic.json", {schema="sks.names/1",names=CHANNELS})
json.dump_file("ShapeKeySystem/mods/profiles/synthetic.json", {schema="sks.profile/1",name="Synthetic",channels={
    {name=CHANNELS[2],group="eye",s="blink.L"}, {name=CHANNELS[3],group="eye",s="blink.R"},
    {name=CHANNELS[4],group="jaw",s="jawOpen"}, {name=native,group="extra",const=1}}})
local original_type_lookup = sdk.find_type_definition
-- timeline playback state for the cutscene drive setting: no timeline is playing
local STATUS = { Play = 1, Pausing = 2, Pause = 3, Resume = 4, Skip = 5 }
local timeline_types = {
    ["chainsaw.TimelineEventManager"] = { get_field = function()
        return { get_data = function() return { call = function(_, m) if m == "get_Count" then return 0 end end } end }
    end },
    ["chainsaw.TimelineEventPlayerInfo"] = { get_method = function() return { call = function() return 0 end } end },
    ["chainsaw.TimelineEventPlayer.Status"] = { get_field = function(_, n)
        return { get_data = function() return STATUS[n] end }
    end },
}
sdk.find_type_definition = function(name)
    if timeline_types[name] then return timeline_types[name] end
    local td = original_type_lookup(name)
    if name ~= "via.render.Mesh" then return td end
    return {get_method=function(_, signature)
        if signature == "get_BlendShapeEnable" or signature == "get_BlendShapeReleasedBuffers" then return nil end
        return td:get_method(signature)
    end}
end
dofile(ENTRY)
sdk.find_type_definition = function(name) return timeline_types[name] or original_type_lookup(name) end
local SKS = require("ShapeKeySystem_Core.API")
local W = require("ShapeKeySystem_Core.Writer")
local A = SKS.adapter
local Guard = require("ShapeKeySystem_Core.Guard")
check(Guard.mesh_ready(m), "absent RE4R enable/release getters do not block an otherwise ready mesh")
MESH_STATE.ready = false
check(not Guard.mesh_ready(m), "MeshReady remains mandatory without blendshape flag getters")
MESH_STATE.ready = true
count = 0
check(not Guard.mesh_ready(m), "allocated weight count remains mandatory without blendshape flag getters")
count = #CHANNELS; length = 0
check(not Guard.mesh_ready(m), "weight-list bounds remain mandatory without blendshape flag getters")
length = #CHANNELS
check(A.id=="re4" and A.primary_ready(), "RE4R adapter resolves nested cha000 head")
check(pres.UpdateMotion and pres.PrepareRendering, "LOD preparation registered at both pre stages")
check(A.primary_root()==ROOT and #A.parts(ROOT)==1, "head may be separate from player-root children")
check(not A.channel_writable(native) and not A.channel_writable(Hash.label(Hash.hash(native))), "native and unresolved labels are read-only")
check(not ShapeKeySystemAPI.set("test",native,1), "public API rejects native channels")
check(A.raw.parse("jawOpen") and not A.raw.parse("typo"), "raw labels compile to stable keys")
local old_channels = CHANNELS
local set_count = 0
m.set_BlendShapeChannelWeightCount = function(_, value) count = value; set_count = set_count+1 end
CHANNELS = {}; for i=1,536 do CHANNELS[i] = "Custom_"..i end
local part = {id="cha000_10",mesh=m,n=536,names=CHANNELS}
count,length = 0,536
A.prepare_parts({part})
check(count==536 and part.weights.count==536, "Leon 536-channel custom head enables an already allocated list")
A.prepare_parts({part})
check(set_count==1, "allocation preparation is idempotent with a compatibility wrapper")
count,length = 0,535; A.prepare_parts({part})
check(count==0, "short allocated list is never enabled")
length=536; MESH_STATE.ready=false; A.prepare_parts({part})
check(count==0, "unready mesh is never enabled")
MESH_STATE.ready=true
m.get_BlendShapeReleasedBuffers=function() return true end; A.prepare_parts({part})
check(count==0, "released mesh is never enabled")
m.get_BlendShapeReleasedBuffers=function() return false end
local save_n=part.n; part.n=535; A.prepare_parts({part}); part.n=save_n
check(count==0, "channel count mismatch is never enabled")
CHANNELS={native}; part.n=1; part.names=CHANNELS; length=1; A.prepare_parts({part})
check(count==0, "native-only mesh retains engine-owned weight count")
CHANNELS=old_channels; count,length=#CHANNELS,#CHANNELS
m.get_BlendShapeReleasedBuffers=nil
local function node(name, resource)
    local tr = { _name=name }
    local mm = resource and {call=call,getMesh=function() return {call=call,get_ResourcePath=function() return resource end} end}
    local object = {call=call,get_Name=function()return name end,get_Transform=function()return tr end,
        getComponent=function()return mm end}
    tr.call=call; tr.get_GameObject=function()return object end
    tr.get_Parent=function()return tr.parent end; tr.get_Child=function()return tr.child end
    tr.get_Next=function()return tr.next end; tr.get_address=function()return name end
    tr.getJointByName=function()return {} end
    return tr
end
local ada_root=node("Ada actor")
local ada_face=node("Ada head","/Character/cha800/10/cha800_10.mesh.221108797")
local ada_body=node("Ada body","/Character/cha800/00/cha800_00.mesh.221108797")
ada_face.parent=ada_root; ada_body.parent=ada_root; ada_root.child=ada_face; ada_face.next=ada_body
local saved_address=ARMOR.get_address; ARMOR.get_address=function()return "player head" end
local old_scene=SCENE
SCENE={call=function()
    local comps={ {call=function()return go(ARMOR) end}, {call=function()return ada_face:get_GameObject() end},
        {call=function()return ada_body:get_GameObject() end} }
    return {call=function(_, method,i) if method=="get_Length" then return #comps else return comps[i+1] end end}
end}
local extra=A.additional_faces()
check(#extra==1 and extra[1]==ada_face, "scene discovery excludes player-owned meshes and body meshes carrying face bones")
check(A.face_root(ada_face, ROOT)==ada_root, "secondary face is grouped under its own actor root")
local ada_parts=A.parts(ada_root,ada_face)
local includes_player=false;for _,tr in ipairs(ada_parts) do includes_player=includes_player or tr==ARMOR end
check(#ada_parts==2 and not includes_player, "secondary actor parts never include the player's head")
local ah=A.bind(ada_face,{A.raw.parse("jawOpen")})
check(ah.calibration.joints.L_U_Eyelid03~=nil, "secondary Ada handle selects Ada calibration rather than player's Leon calibration")
check(type(HOOKS.changeEventPhase)=="function" and type(HOOKS.unload)=="function", "RE4R phase and unload hooks register reference release")
SCENE=old_scene;ARMOR.get_address=saved_address


local spec={kind="pos",neutral={0,0,0,0,0,0,1},axis={0,1,0}}
check(math.abs(Signals.measure(spec,{x=9,y=0.008,z=-3})-8)<1e-9, "position projection is in calibrated millimetres")
spec={kind="rot",neutral={0,0,0,0,0,0,1},axis={1,0,0}}
local r=math.rad(28)/2
check(math.abs(Signals.measure(spec,nil,{x=math.sin(r),y=0,z=0,w=math.cos(r)})-28)<1e-9, "rotation uses quaternion log in degrees")
check(math.abs(Signals.measure(spec,nil,{x=-math.sin(r),y=0,z=0,w=-math.cos(r)})-28)<1e-9,
    "equivalent quaternion signs produce the same rotation")
local key=A.raw.parse("jawOpen")
local h=A.bind(ARMOR,{key})
local P={}
WEIGHTS[0]=0.5
A.read(h,P,1)
check(P[key]>=0.5 and h.status.jaw_openExtreme=="ok", "native hash at index zero contributes")
count=0; A.read(h,P,1)
check(h.status.jaw_openExtreme=="out_of_bounds", "zero WeightCount blocks native reads")
count=#CHANNELS; length=0; A.read(h,P,1)
check(h.status.jaw_openExtreme=="out_of_bounds", "live managed list bounds checked")
length=#CHANNELS
local ok,code,msg=SKS.call("set_profile",{id="synthetic"})
check(ok,"synthetic exact-name profile selected: "..tostring(msg))
local function ticks(n) for _=1,n do CB.tick() end end
ticks(100)
check(not SKS.state.debug.status:find("error",1,true), "tick completes without an error status")
check(#SKS.state.scene.rigs==1 and SKS.state.scene.rigs[1].primary, "custom face root produces primary rig")
check(#SKS.state.scene.parts==1, "head part collected through optional parts")
local native_writes=0
for _,w in ipairs(writes) do if w[1]==0 then native_writes=native_writes+1 end end
check(#writes>0 and native_writes==0,"visible outputs are written and native input is never written")
local original_get=m.getBlendShapeChannelWeightParam
m.getBlendShapeChannelWeightParam=function() return nil end
A.read(h,P,1); check(h.status.jaw_openExtreme=="read_failed","failed read is distinct from a confirmed zero")
m.getBlendShapeChannelWeightParam=original_get
WEIGHTS[0]=0; A.read(h,P,1)
check(h.status.jaw_openExtreme=="ok","confirmed zero remains a successful native sample")
local short=A.bind(ARMOR,{key})
short.taps.jaw_openExtreme=nil; A.read(short,P,1)
check(short.status.jaw_openExtreme=="unbound","missing native tap degrades independently of bone inputs")
local old_count=m.get_BlendShapeChannelWeightCount
m.get_BlendShapeChannelWeightCount=function() return nil end
A.read(h,P,1); check(h.status.jaw_openExtreme=="bounds_unavailable","unreadable bounds remain distinct")
m.get_BlendShapeChannelWeightCount=old_count
local before=#writes
count=0; ticks(2); check(#writes==before,"allocated buffer shrinking blocks expression and sculpt writes")
count=#CHANNELS; ticks(50)
pres.UpdateMotion(); check(lod==0,"LOD0 applied to valid current target")
local old=lod; lod=2; current=false; pres.PrepareRendering()
check(lod==2,"lost player releases targets without dereferencing cached meshes")
ticks(2); check(not A.primary_ready(),"absent player does not become a preview actor")
current=true; SKS.call("rescan"); ticks(100)
local channels=ShapeKeySystemAPI.channels()
for _,c in ipairs(channels) do check(not c.name:find("crct_",1,true),"read-only channels excluded from editable list") end
local sig=A.signature(ROOT)
local old_address=m.get_address
m.get_address=function() return 0x9988 end
check(A.signature(ROOT)~=sig,"same-name mesh replacement changes topology signature")
before=#writes; pres.UpdateMotion(); check(#writes==before,"replacement is dropped without a last write")
m.get_address=old_address
check(not W.set_weight(m,0,1,native),"low-level writer also rejects native index")
before=#writes; length=0
check(not W.set_weight(m,1,1,CHANNELS[2]) and #writes==before,"low-level writer guards zero-length list")
length=#CHANNELS
local taps=Signals.hashes(m)
check(taps[Hash.hash(native)]==0,"native hashes are looked up by name, not an assumed channel count")
local original_hashes=m.get_ChannelNameHash
m.get_ChannelNameHash=function()
    return {call=call,get_Item=function(_,i)
        return {call=function() return tostring(Hash.hash(CHANNELS[i+1])) end}
    end}
end
check(Signals.hashes(m)[Hash.hash(native)]==0,"boxed UInt32 native hashes are accepted")
local core_names=Hash.names_of(m,#CHANNELS,Hash.table(CHANNELS))
check(core_names[2]==CHANNELS[2],"Core name resolution supports Item-only boxed collections")
m.get_ChannelNameHash=original_hashes
local element_reads = 0
m.get_ChannelNameHash=function()
    return {call=call,get_Item=function(_,i) return Hash.hash(CHANNELS[i+1]) end,
        get_elements=function()
            element_reads = element_reads + 1
            local t = {}
            for i = 1, #CHANNELS do t[i] = {call=function() return "2637986592" end} end
            return t
        end}
end
local known = Hash.table(CHANNELS)
local default_names = Hash.names_of(m,#CHANNELS,known)
check(default_names[2]=="#9D3C7B20", "default boxed-element path remains unchanged")
element_reads = 0
local item_names = Hash.names_of(m,#CHANNELS,known,A.hash_item_only)
check(A.hash_item_only and item_names[2]==CHANNELS[2] and item_names[3]==CHANNELS[3],
    "RE4R numeric Items override incorrect boxed ToString hashes")
check(element_reads==0,"numeric Item path never reads boxed elements")
SKS.call("rescan",{}); ticks(100)
check(#SKS.state.scene.rigs==1 and #SKS.state.scene.rigs[1].targets>0,
    "scene scanning creates targets despite incorrect boxed hashes")
check(not A.channel_writable(native,m,0),"native protection remains active with numeric Item discovery")
m.get_ChannelNameHash=function()
    return {call=call,get_Item=function() error("Item unavailable") end,
        get_elements=function() error("boxed fallback must not be called") end}
end
local unavailable = Hash.names_of(m,#CHANNELS,known,true)
check(unavailable[2]=="","failed numeric Items remain unavailable without boxed fallback")
for _, value in ipairs({ -1, 0x100000000, 0.5, math.huge }) do
    m.get_ChannelNameHash=function() return {call=call,get_Item=function() return value end} end
    check(Hash.names_of(m,1,known,true)[1]=="","invalid numeric Item hash is rejected: "..tostring(value))
end
m.get_ChannelNameHash=function() return {call=call,get_Item=function(_,i) return i==0 and 0 or 0xFFFFFFFF end} end
local edge_names = Hash.names_of(m,2,{},true)
check(edge_names[1]=="#00000000" and edge_names[2]=="#FFFFFFFF","numeric Item path accepts unsigned boundary hashes")
m.get_ChannelNameHash=original_hashes
local diagnostic=A.probe("ShapeKeySystem/hash_probe.txt")
check(#diagnostic>1,"existing probe action exposes native read diagnostics")
local saved_channels={table.unpack(CHANNELS)}
CHANNELS[1],CHANNELS[5]=CHANNELS[5],CHANNELS[1]
check(not W.set_weight(m,4,1,"Size"),"native hash remains protected after reordering")
CHANNELS=saved_channels
local before_reset=#writes
CB.reset()
for i=before_reset+1,#writes do check(writes[i][1]~=0,"reset never zeroes a native input") end
local saved_loader=json.load_file
json.load_file=function() error("synthetic malformed JSON") end
local init_ok, init_value=pcall(A.init)
check(init_ok and init_value==false,"malformed calibration fails adapter init without starting the plugin ("..tostring(init_ok).." "..tostring(init_value)..")")
json.load_file=saved_loader
local saved_find=sdk.find_type_definition
sdk.find_type_definition=function(name) if name=="chainsaw.CharacterManager" then return nil end; return saved_find(name) end
check(A.init()==false,"missing game-specific type rejects adapter initialization")
sdk.find_type_definition=saved_find
print("RE4R ASSERTIONS:",assertions)
print("RE4R FAILS:",failures)
assert(failures==0,"RE4R integration failures")
