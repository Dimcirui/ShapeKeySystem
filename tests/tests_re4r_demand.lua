package.path=assert(arg[1]).."/reframework/autorun/?.lua;"..package.path
package.loaded["ShapeKeySystem_Core.FaceHold"]={pose=function() end,watch=function() end}
local selected
package.loaded["ShapeKeySystem_Games.RE4R.NativePose"]={
 bind=function(_,bones) return {bones=bones} end,
 read=function(h,_,needed)
  local out={};selected={}
  for _,b in pairs(h.bones) do if not needed or needed[b.name] then
   local n=b.neutral;out[b.name]={position={n[1]+.002,n[2]+.002,n[3]+.002},rotation={n[4],n[5],n[6],n[7]}}
   selected[b.name]=true
  end end
  return out
 end}
sdk={typeof=function(n) return n end,get_managed_singleton=function() end}
re={on_script_reset=function() end}
local Hash=require("ShapeKeySystem_Core.NameHash")
local B=require("ShapeKeySystem_Core.BoneSignals")
local S=require("ShapeKeySystem_Games.RE4R.Signals")
local F=require("ShapeKeySystem_Games.RE4R.NativeFace")
local old=S
local function object(methods)
 methods.call=function(self,name,...) local f=self[name:match("^([^%(]+)")];if f then return f(self,...) end end
 methods.get_address=function() return 100 end
 return methods
end
local cases=0
for _,cal in pairs({json.load_file("ShapeKeySystem/builtin/re4/leon.json"),json.load_file("ShapeKeySystem/builtin/re4/ada.json")}) do
 local names,indices,hashes={},{},{}
 for _,r in ipairs(cal.rules) do for _,name in ipairs(r.taps or {}) do
  local hash=Hash.hash("Face__geo__p000_cbs.crct_"..name)
  if not indices[hash] then names[#names+1]=name;indices[hash]=#names-1;hashes[#names]=hash end
 end end
 local mode=0
 local motion=object({get_JointCount=function() return #names end,get_SkeletonConstructCount=function() return 1 end,
  getJointIndexByNameHash=function(_,hash) return indices[hash] end,getJointNameHashByIndex=function(_,i) return hashes[i+1] end,
  isExtraJoint=function() return true end,getCalculatedLocalPosition=function(_,i)
   if mode==2 and names[i+1]:find("brow") then return nil end
   if mode==3 then return nil end
   return {x=mode==0 and 0 or .4,y=0,z=0}
  end})
 local mesh=object({get_BlendShapeChannelNum=function() return 100 end,get_BlendShapeChannelWeightCount=function() return 100 end,
  get_ChannelWeightList=function() return object({get_Length=function() return 100 end}) end})
 local face=object({get_GameObject=function() return object({getComponent=function() return motion end}) end})
 for _,missing_only_five in ipairs({false,true}) do
  local joints={}
  if missing_only_five then
   for alias,spec in pairs(cal.joints) do
    local name=spec.bone or alias
    if name~="C_Chin" and not name:find("Eyebrow") then
     local n=spec.neutral
     joints[alias]=object({get_LocalPosition=function() return {x=n[1]+.002,y=n[2]+.002,z=n[3]+.002} end,
      get_LocalRotation=function() return {x=n[4],y=n[5],z=n[6],w=n[7]} end})
    end
   end
  end
  local function handle() return {mesh=mesh,keys={},joints=joints,taps={},status={},calibration=cal,count=100,face_address=100,
   animation=F.bind(face,cal,joints,false)} end
  local reference,current=handle(),handle()
  reference.read_only=true
  for _,value in ipairs({0,1,2,3,0,1}) do
   mode=value
   local a=old.read(reference,{},1)
   local b=S.read(current,{},1)
   for k,v in pairs(a) do assert(b[k]==v,cal.rig.." "..k.." "..tostring(v).." vs "..tostring(b[k])) end
   for k,v in pairs(b) do assert(a[k]==v,k) end
   assert(selected.C_Chin,"additive chin contribution was removed")
   if value==0 or value==1 then
    assert(not selected.L_I_Eyebrow and not selected.R_O_Eyebrow,"available native input must skip brow sampling")
    if missing_only_five then local n=0;for _ in pairs(selected) do n=n+1 end;assert(n==1) end
   end
   if value==3 then assert(selected.L_I_Eyebrow and selected.R_O_Eyebrow,"missing sources must restore brow sampling") end
   cases=cases+1
  end
 end
end
print("SIGNAL_DEMAND_EQUIVALENCE_PASS",cases,"actor/skeleton/source transitions")
