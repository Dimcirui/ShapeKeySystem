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
    if name == "chainsaw.BonusContentsGuiManager" then
        return {call=call,get_FigureManager=function()
            return {call=call,get_ModelController=function() return FIGURE_GO and {call=call,get_GameObject=function() return FIGURE_GO end} end}
        end}
    end
    return original_singleton(name)
end
local pres, pre_counts = {}, {}
-- REFramework 同一阶段允许多个回调，不能让后注册的通用准备覆盖适配器的 LOD 准备。
re.on_pre_application_entry = function(stage, fn)
    pre_counts[stage] = (pre_counts[stage] or 0) + 1
    local previous = pres[stage]
    pres[stage] = function(...)
        if previous then previous(...) end
        fn(...)
    end
end
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
-- characters by person: the player Leon and the cutscene Ada; editing switches the primary scan
local Actors=require("ShapeKeySystem_Core.Actors")
local Scene=require("ShapeKeySystem_Core.Scene")
local Dr=require("ShapeKeySystem_Core.Drivers")
local function tick_n(n) for _=1,n do CB.tick() end end
tick_n(2)
local al=SKS.state.actors
check(al.enabled and #al.list==2 and al.list[1].id=="leon" and al.list[1].player and al.list[2].id=="ada"
    and al.selected=="leon", "characters: the player's Leon first, then Ada")
check(al.list[1].name=="里昂" and al.list[2].name=="艾达", "character names from character_names.json")
check(Scene.primary_root()==ROOT, "editing the player's character keeps the player's root")
local ok_sel=SKS.call("select_actor",{id="ada"})
check(ok_sel and al.selected=="ada" and Scene.primary_root()==ada_root, "editing Ada makes her root the primary scan")
local inst=Actors.instance_faces()
check(#inst==1 and inst[1]==ARMOR, "the player's head goes to the additional actors while Ada is edited")
local _,err_sel=SKS.call("select_actor",{id="ashley"})
check(err_sel=="E_NOT_FOUND", "a character not in the scene cannot be edited")
Dr.load({items={{key="SK__arkit.eyeBlinkLeft",wave="expr",expr="0.4",actor="leon"},
                {key="Other",wave="expr",expr="0.6"}}})
tick_n(1)
local lv=Dr.actor_values.leon
check(lv and lv[require("ShapeKeySystem_Core.External").norm("SK__arkit.eyeBlinkLeft")]
    and require("ShapeKeySystem_Core.External").get("SK__arkit.eyeBlinkLeft")==nil,
    "a driver of a character not being edited goes to its rigs, not to a lease")
check(Dr.actor_values.leon and Dr.actor_values.leon["other"]~=nil,
    "a driver without a character belongs to the player's character")
SKS.call("select_actor",{id="leon"})
tick_n(1)
check(Scene.primary_root()==ROOT and al.selected=="leon" and require("ShapeKeySystem_Core.External").get("Other")~=nil,
    "back to Leon: the player's root again, his drivers take leases")
Dr.load({})
tick_n(1)
-- public API v1.1: characters by id, by part ID or by scene object; picks for a character not being edited
local api=ShapeKeySystemAPI
local Presets=require("ShapeKeySystem_Core.Presets")
local AI=require("ShapeKeySystem_Core.ActorInstances")
local acts=api.actors()
local absent_ashley
for _,e in ipairs(acts) do if e.id=="ashley" then absent_ashley=e end end
check(#acts==7 and acts[1].id=="leon" and acts[1].edited and acts[1].present and acts[2].id=="ada" and not acts[2].edited
    and absent_ashley and not absent_ashley.present and absent_ashley.name=="阿什莉" and absent_ashley.folder=="ashley",
    "actors(): Leon (edited) and Ada present, the other people listed as absent with their folder")
check(api.actor_of("ada")=="ada" and api.actor_of("cha800_10")=="ada" and api.actor_of("/Character/cha000/10/cha000_10.mesh")=="leon"
    and api.actor_of("cha100_10")=="ashley" and api.actor_of("chi300_10")=="hunk" and api.actor_of("cha999_10")==nil,
    "actor_of: character ids, part IDs and mesh paths")
check(api.actor_of(ada_root:get_GameObject())=="ada" and api.actor_of(ada_body)=="ada" and api.actor_of(ada_face)=="ada",
    "actor_of: the character's root GameObject, a part under it, its head")
json.dump_file("ShapeKeySystem/user/ada/sculpt/ada_pick.json",{schema="sks.sculpt/1",name="ada_pick",values={Size=.4},
    key_groups={{name="G",value=0,options={{name="on",values={Size=.9}}}}}})
Presets.load_sculpt()
local okp,_,_,rp=api.select_sculpt("AVM","ada_pick",{actor="ada"})
local okg=api.select_group_option("AVM","G","on",{actor="ada"})
check(okp and not rp.applied and okg and AI.selection("ada").sculpt=="ada_pick" and AI.selection("ada").groups.G=="on"
    and AI.selection("leon")==nil, "a pick for Ada while Leon is edited goes to her own rigs, not the sculpt layer")
local _,ce=api.select_sculpt("AVM","ada_pick",{actor="ramon"})
check(ce=="E_NOT_FOUND" and api.select_group_option("AVM","G","on",{actor="ashley"}), "an unknown character is refused; an absent known one is queued")
api.clear_selection("AVM",{actor="ashley"})
check(api.selection({actor="ada"}).sculpt=="ada_pick" and api.selection()==nil, "selection() per character")
api.clear_selection("AVM",{actor="ada"})
check(AI.selection("ada")==nil, "clear_selection ends the pick for that character")
local ah=A.bind(ada_face,{A.raw.parse("jawOpen")})
check(ah.calibration.joints.L_U_Eyelid03~=nil, "secondary Ada handle selects Ada calibration rather than player's Leon calibration")
check(type(HOOKS.changeEventPhase)=="function" and type(HOOKS.unload)=="function", "RE4R phase and unload hooks register reference release")
local ashley_head=node("Ashley head","/Character/cha100/10/cha100_10.mesh.221108797")
check(A.is_face(node("Leon costume","/Character/cha005/10/cha005_10.mesh.221108797"))
    and A.is_face(node("Leon variant","/Character/cha006/10/cha006_10_TU1.mesh.221108797"))
    and A.is_face(ashley_head) and A.is_face(node("Hunk head","/Character/chi300/10/chi300_10.mesh.221108797"))
    and A.is_face(node("Krauser head","/Character/chb700/10/chb700_10.mesh.221108797"))
    and not A.is_face(node("Ashley body","/Character/cha100/00/cha100_00.mesh.221108797")),
    "head groups of every person are faces, including chi/chb/chj groups; bodies are not")
check(A.actor_of(ashley_head)=="ashley" and A.model_of("cha100_10")=="ashley" and A.model_of("chi300_10")=="hunk"
    and A.model_of("ashley")=="ashley", "people without a calibration have their own id and model folder")
local ah2=A.bind(ashley_head,{A.raw.parse("jawOpen")})
local P2={}
A.read(ah2,P2,1)
check(ah2.uncalibrated and next(P2)==nil and next(A.eye_joints(ashley_head))==nil,
    "a person without a calibration reads no expression and no gaze, never with Leon's calibration")
-- the player is a person without a calibration (Ashley's chapters, Mercenaries): she is the primary character
local leon_resource=m.getMesh
m.getMesh=function() return {call=call,get_ResourcePath=function() return "/Character/cha100/10/cha100_10.mesh.221108797" end} end
A.cache_end(); SKS.call("rescan"); tick_n(120)
local SculptA=require("ShapeKeySystem_Core.Sculpt")
check(A.primary_ready() and al.selected=="ashley" and al.list[1].id=="ashley" and al.list[1].player and #SculptA.K.keys>0,
    "an uncalibrated player becomes the edited character with her shape keys")
local sk
for _,k in ipairs(SculptA.K.keys) do if k.owner=="self" and not sk then sk=k.name end end
local before_w={}
for i,v in pairs(WEIGHTS) do before_w[i]=v end
assert(SKS.call("set_sculpt_key",{name=sk,value=.42})); tick_n(40)
local hit=false
for _,v in pairs(WEIGHTS) do if math.abs(v-.42)<1e-6 then hit=true end end
check(hit, "her sculpt values reach the mesh")
assert(SKS.call("sculpt_undo",{}))
m.getMesh=leon_resource; A.cache_end(); SKS.call("rescan"); tick_n(120)
check(al.selected=="leon" and al.list[1].id=="leon", "back to the Leon player")
-- model viewer figure: controller -> mesh-less ..._Body (Motion) -> Body / Head / Hair / prop
local fig_root=node("FigureModel_Figure00_010")
local fig_body=node("Figure00_010_Body")
local fig_skin=node("Body","/Character/cha002/00/cha002_00.mesh.221108797")
local fig_head=node("Head","/Character/cha000/10/cha000_10.mesh.221108797")
local fig_hair=node("Hair","/Character/cha000/20/cha000_20.mesh.221108797")
local fig_prop=node("Figure02_010_Body","/Weapon/wp4000/wp4000_00.mesh.221108797")
fig_root.child=fig_body; fig_body.parent=fig_root
fig_body.child=fig_skin; fig_skin.next=fig_head; fig_head.next=fig_hair; fig_hair.next=fig_prop
for _,c in ipairs({fig_skin,fig_head,fig_hair,fig_prop}) do c.parent=fig_body end
local function array(list)
    return {call=function(_, method,i) if method=="get_Length" then return #list else return list[i+1] end end}
end
SCENE={call=function() return array({{call=function()return fig_body:get_GameObject() end}}) end}
current=false
check(not A.primary_ready(), "no player and no figure: no primary character")
FIGURE_GO=fig_root:get_GameObject()
check(A.primary_ready() and A.primary_root()==fig_body and A.faces()[1]==fig_head,
    "without a player the model viewer figure is the primary character, rooted at its ..._Body")
check(A.instances_ready(true), "instances run while the figure is primary")
local fig_parts=A.parts(A.primary_root())
check(#fig_parts==4, "figure parts: body, head, hair and the prop mesh")
check(#A.additional_faces()==0, "the primary figure is not driven again as an additional actor")
local fh=A.bind(fig_head,{A.raw.parse("jawOpen")})
check(fh.calibration.joints.L_U_Eyelid03==nil, "a Leon figure binds the Leon calibration")
check(type(HOOKS.requestInstantiateModel)=="function" and type(HOOKS.requestDestroyInstantiatedModel)=="function",
    "figure swaps register reference release")
current=true
check(A.primary_root()==ROOT, "a player context takes precedence over the figure")
FIGURE_GO=nil
SCENE=old_scene;ARMOR.get_address=saved_address or function() return "player head" end


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
-- ShapeKeySystem_Native.dll: batched tap and joint reads give the Lua read's values and states
do
    local W = require("ShapeKeySystem_Core.Writer")
    -- engine joints have addresses; the bind collects them for the plugin
    local joints, next_address = {}, 0x7000
    for _, joint in pairs(ARMOR._joints) do
        if not joint.get_address then
            next_address = next_address + 0x10
            local address = next_address
            joint.get_address = function() return address end
        end
        joints[joint:get_address()] = joint
    end
    local h = A.bind(ARMOR, {key})
    local function compare_reads(label)
        sks_native = nil
        local plain = {}; A.read(h, plain, 1)
        local plain_status = {}; for k, v in pairs(h.status) do plain_status[k] = v end
        sks_native = {
            tap_weights = function(address, indices)
                local out = { W.M_CN:call(m), W.limit(m) }
                for i, idx in ipairs(indices) do
                    out[i + 2] = idx < out[2] and W.M_GETW:call(m, idx) or false
                end
                return out
            end,
            joint_poses = function(addresses)
                local out = {}
                for i, address in ipairs(addresses) do
                    local joint = joints[address]
                    local p, q = joint:call("get_LocalPosition()"), joint:call("get_LocalRotation()")
                    local row = p and q and { p.x, p.y, p.z, q.x, q.y, q.z, q.w } or { false, false, false, false, false, false, false }
                    for k = 1, 7 do out[(i - 1) * 7 + k] = row[k] end
                end
                return out
            end,
        }
        local batched = {}; A.read(h, batched, 1)
        local same = true
        for k, v in pairs(plain) do if math.abs((batched[k] or 0) - v) > 1e-9 then same = false end end
        for k, v in pairs(plain_status) do if h.status[k] ~= v then same = false end end
        sks_native = nil
        check(same, "native batched reads match the Lua read: " .. label)
    end
    WEIGHTS[0] = 0.5; compare_reads("in bounds")
    count = 0; compare_reads("zero weight count"); count = #CHANNELS
    length = 0; compare_reads("empty managed list"); length = #CHANNELS
end
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
local original_prepare_motion, motion_prepared = SKS.prepare_motion, false
SKS.prepare_motion = function(...)
    motion_prepared = true
    return original_prepare_motion(...)
end
pres.UpdateMotion()
SKS.prepare_motion = original_prepare_motion
check(lod==0,"LOD0 applied to valid current target")
check(pre_counts.UpdateMotion >= 2 and motion_prepared,
    "shared pre-Motion callbacks preserve both LOD and FaceHold preparation")
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
local batch_check=W.begin_batch(m)
check(not W.set_weight(m,4,1,"Size",batch_check),"native hash remains protected inside a batch after reordering")
CHANNELS[1],CHANNELS[5]=CHANNELS[5],CHANNELS[1]
-- ShapeKeySystem_Native.dll: a batch queues its writes and hands them over in one call
local plugin_calls={}
sks_native={write_weights=function(addr,idx,val,n) plugin_calls[#plugin_calls+1]={addr=addr,idx=idx[1],val=val[1],n=n}; return n end}
local queued=W.begin_batch(m)
before=#writes
check(W.set_weight(m,1,0.25,CHANNELS[2],queued) and #writes==before,"a native batch queues its writes")
W.flush(queued)
check(#plugin_calls==1 and plugin_calls[1].n==1 and plugin_calls[1].idx==1 and plugin_calls[1].val==0.25
    and plugin_calls[1].addr==m:get_address(),"flush hands the queued writes to the plugin in one call")
check(not W.set_weight(m,0,1,native,W.begin_batch(m)),"a native batch still rejects native channels")
sks_native={write_weights=function() error("plugin failed") end}
queued=W.begin_batch(m)
W.set_weight(m,1,0.5,CHANNELS[2],queued); W.flush(queued)
check(#writes==before+1,"a failed plugin call writes the queued values one by one")
sks_native=nil
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
