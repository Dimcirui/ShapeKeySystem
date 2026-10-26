package.path=assert(arg[1]).."/reframework/autorun/?.lua;"..package.path
local now,mutations,extra_calls=0,0,0
os.clock=function() return now end
package.loaded["ShapeKeySystem_Games.RE4R.NativePose"]={bind=function()error("unexpected pose")end}
sdk={typeof=function(n)return n end,get_managed_singleton=function()end}
re={on_script_reset=function()end}
local Hash=require("ShapeKeySystem_Core.NameHash")
local F=require("ShapeKeySystem_Games.RE4R.NativeFace")
local function obj(methods)
 methods.call=function(self,name,...)
  if name:find("setupDeformer") then mutations=mutations+1;error("registration forbidden")end
  local f=self[name:match("^([^%(]+)")];if f then return f(self,...)end
 end
 methods.get_address=function(self)return self.address or 100 end
 return methods
end
local names={"brow_raiseInner_L","mouth_cornerDepress_L","jaw_openExtreme"}
local hashes,index={},{}
for i,n in ipairs(names)do local hash=Hash.hash("Face__geo__p000_cbs.crct_"..n);hashes[i]=hash;index[hash]=i-1 end
local registered={table.unpack(hashes)}
local values,extra={0,.4,.8},{0,.4,.8}
local ha=obj({get_Length=function()return #registered end,get_Item=function(_,i)return registered[i+1]end})
local va=obj({get_Length=function()return #values end,get_Item=function(_,i)return values[i+1]end})
local motion=obj({get_JointCount=function()return 3 end,get_SkeletonConstructCount=function()return 1 end,
 getJointIndexByNameHash=function(_,hash)return index[hash]end,getJointNameHashByIndex=function(_,i)return hashes[i+1]end,
 isExtraJoint=function()return true end,getCalculatedLocalPosition=function(_,i)extra_calls=extra_calls+1;return {x=extra[i+1],y=0,z=0}end,
 get_DeformNameHashes=function()return ha end,get_DeformValues=function()return va end})
local go=obj({getComponent=function()return motion end})
local face=obj({get_GameObject=function()return go end})
local rules={};for i,n in ipairs(names)do rules[i]={key=n,taps={n}}end
local h=F.bind(face,{joints={},rules=rules},{},false)
local function check(expected_reads)
 local before=extra_calls
 local out=F.read(h,false)
 for i,n in ipairs(names)do assert(out[n]==extra[i],n.." output changed")end
 assert(extra_calls-before==expected_reads, "fallback query count changed: "..(extra_calls-before))
 assert(mutations==0)
end
check(0) -- finite zero is supplied by Deform, not a missing source
registered={hashes[1],hashes[3]};values={0,.8};ha.address=101;check(1)
registered={table.unpack(hashes)};values={0/0,.4,.8};ha.address=102;check(1)
values={0,.4};check(1) -- short buffer restores the missing item through extra-joint
registered={hashes[3],hashes[1],hashes[2]};values={.8,0,.4};ha.address=103;check(3);check(0)
registered={hashes[1],hashes[2],hashes[3]};values={0,.4,.8};now=2.1;check(0) -- periodic verification catches in-place reorder
registered={};values={};check(3)
registered={table.unpack(hashes)};values={0,.4,.8};check(3);now=now+2.1;check(0)
print("DEFORM_PREFERRED_ROUTE_PASS", "existing zero, partial, invalid, short, reordered, absent, restored; no registration")
