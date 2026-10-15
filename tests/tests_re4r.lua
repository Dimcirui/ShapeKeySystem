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
dofile(ENTRY)
local SKS = require("ShapeKeySystem_Core.API")
local W = require("ShapeKeySystem_Core.Writer")
local A = SKS.adapter
check(A.id=="re4" and A.primary_ready(), "RE4R adapter resolves nested cha000 head")
check(pres.UpdateMotion and pres.PrepareRendering, "LOD preparation registered at both pre stages")
check(A.primary_root()==ROOT and #A.parts(ROOT)==1, "head may be separate from player-root children")
check(not A.channel_writable(native) and not A.channel_writable(Hash.label(Hash.hash(native))), "native and unresolved labels are read-only")
check(not ShapeKeySystemAPI.set("test",native,1), "public API rejects native channels")
check(A.raw.parse("jawOpen") and not A.raw.parse("typo"), "raw labels compile to stable keys")
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
check(init_ok and init_value==false,"malformed calibration fails adapter init without starting the plugin")
json.load_file=saved_loader
local saved_find=sdk.find_type_definition
sdk.find_type_definition=function(name) if name=="chainsaw.CharacterManager" then return nil end; return saved_find(name) end
check(A.init()==false,"missing game-specific type rejects adapter initialization")
sdk.find_type_definition=saved_find
print("RE4R ASSERTIONS:",assertions)
print("RE4R FAILS:",failures)
assert(failures==0,"RE4R integration failures")
