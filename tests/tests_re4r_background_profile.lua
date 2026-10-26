-- An unbound custom player must keep its matching profile while the original secondary actor is edited.
local Profile=require("ShapeKeySystem_Core.Profile")
ROOT.get_address=function() return "player root" end
local native_name=CHANNELS[1]
CHANNELS={native_name,"player_only_mouth","player_only_blink_l","player_only_blink_r","Size"}
ada_mesh.get_BlendShapeChannelNum=function() return 1 end
ada_mesh.get_BlendShapeChannelWeightCount=function() return 1 end
ada_mesh.get_ChannelWeightList=function() return {call=function() return 1 end} end
ada_mesh.get_ChannelNameHash=function() return {call=function(_,_,i) if i==0 then return Hash.hash(native_name) end end} end
json.dump_file("ShapeKeySystem/mods/profiles/player_only.json",{schema="sks.profile/1",channels={
 {name=CHANNELS[2],group="mouth",const=.7}, {name=CHANNELS[3],group="eye",const=.4}, {name=CHANNELS[4],group="eye",const=.4}}})
Profile.load_all()
assert(SKS.call("set_profile",{id="arkit"}))
SKS.on_rebuilt();tick_n(180)
assert(al.selected=="ada" and #al.list==2,"Ada selection/list changed")
local found
for _,entry in ipairs(SKS.state.scene.additional.instances) do
 if entry.profile=="player_only" and entry.channels==3 then found=true end
end
if not found then
 print("BACKGROUND_DEBUG",SKS.state.debug.status)
 for _,e in ipairs(SKS.state.scene.additional.errors or {})do print("BACKGROUND_ERROR",e)end
 for _,e in ipairs(SKS.state.scene.additional.instances or {})do print("BACKGROUND_ROW",e.profile,e.channels,e.label)end
end
assert(found,"background Leon did not independently match player_only profile")
for _=1,60 do
 WEIGHTS[1]=0;tick_n(1)
 assert(math.abs((WEIGHTS[1] or 0)-.7)<1e-9,"background Leon stopped while Ada was edited")
end
assert(SKS.call("select_actor",{id="leon"}));tick_n(120)
assert(al.selected=="leon" and math.abs((WEIGHTS[1] or 0)-.7)<1e-9)
print("BACKGROUND_PROFILE_TAB_CONTINUITY_PASS", "60 consecutive background write frames while Ada selected")
