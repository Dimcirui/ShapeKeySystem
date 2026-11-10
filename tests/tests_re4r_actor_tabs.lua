-- Appended while both actors are present in the RE4 fixture.
local ada_mesh=ada_face:call("get_GameObject"):call("getComponent(System.Type)","via.render.Mesh")
local ada_body_mesh=ada_body:call("get_GameObject"):call("getComponent(System.Type)","via.render.Mesh")
ada_body_mesh.get_BlendShapeChannelNum=function() return 0 end
local ada_resource=ada_mesh.getMesh
for k,v in pairs(m) do ada_mesh[k]=v end
ada_mesh.getMesh=ada_resource
ada_mesh.get_address=function() return "ada test mesh" end
local ada_weights={}
ada_mesh.setBlendShapeChannelWeightParam=function(_,i,v) ada_weights[i]=v end
ada_mesh.getBlendShapeChannelWeightParam=function(_,i) return ada_weights[i] or 0 end
assert(SKS.call("select_actor",{id="ada"}))
assert(SKS.call("set_profile",{id="synthetic"}))
tick_n(100)
assert(Scene.primary_root()==ada_root and al.selected=="ada" and #al.list==2)
assert(SKS.call("set_sculpt_key",{name="Size",value=.65}))
tick_n(40)
if not ada_weights[4] then
 print("TAB_DEBUG",SKS.state.debug.status)
 local Sculpt=require("ShapeKeySystem_Core.Sculpt")
 for _,t in ipairs(Sculpt.K.targets) do print("TARGET",t.id,t.stable,t.addr,t.mesh==ada_mesh) end
 for i,v in pairs(ada_weights) do print("WEIGHT",i,v) end
end
assert(math.abs((ada_weights[4] or 0)-.65)<1e-9,"selected Ada sculpt did not reach her mesh")
local switched,why=SKS.call("select_actor",{id="leon"})
assert(not switched and why=="E_UNSAVED","unsaved edit protection changed")
assert(SKS.call("sculpt_undo",{}));tick_n(2)
assert(SKS.call("select_actor",{id="leon"}));tick_n(100)
assert(Scene.primary_root()==ROOT and al.selected=="leon" and #al.list==2)
assert(SKS.call("select_actor",{id="ada"}));tick_n(100)
assert(Scene.primary_root()==ada_root and #SKS.state.scene.parts>0)
print("ACTOR_TAB_EDIT_SWITCH_PASS", "Ada profile, sculpt, unsaved guard, undo, Leon, Ada")
-- a pick made for Ada while Leon is edited reaches the sculpt layer once Ada is edited again
json.dump_file("ShapeKeySystem/user/ada/sculpt/ada_switch.json",{schema="sks.sculpt/1",name="ada_switch",values={Size=.3}})
require("ShapeKeySystem_Core.Presets").load_sculpt()
assert(SKS.call("select_actor",{id="leon"}));tick_n(100)
local picked,_,_,pick=ShapeKeySystemAPI.select_sculpt("AVM","ada_switch",{actor="ada"})
assert(picked and not pick.applied,"a pick for a character not being edited is not applied to the sculpt layer")
assert(SKS.call("select_actor",{id="ada"}));tick_n(100)
assert(math.abs((ada_weights[4] or 0)-.3)<1e-9,"the pick was not applied when Ada became the edited character")
assert(not SKS.state.sculpt.dirty and SKS.state.sculpt.preset.name=="ada_switch","an applied pick counts as saved")
assert(SKS.call("select_actor",{id="leon"}),"switching away after a pick is not blocked")
ShapeKeySystemAPI.clear_selection("AVM")
assert(SKS.call("select_actor",{id="ada"}));tick_n(100)   -- the next file starts with Ada edited
print("ACTOR_TAB_API_PICK_PASS")
