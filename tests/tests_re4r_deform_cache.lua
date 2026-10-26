package.path=assert(arg[1]).."/reframework/autorun/?.lua;"..package.path
local now, item_reads=0,0
os.clock=function()return now end
re={on_script_reset=function()end}
local D=require("ShapeKeySystem_Games.RE4R.NativeDeform")
local function obj(methods)
 methods.call=function(self,n,...)local f=self[n:match("^([^%(]+)")];if f then return f(self,...)end end
 return methods
end
local registered,values={},{}
local address=100
local hashes=obj({get_Length=function()return #registered end,get_Item=function(_,i)item_reads=item_reads+1;return registered[i+1]end,
 get_address=function()address=address+1;return address end})
local weights=obj({get_Length=function()return #values end,get_Item=function(_,i)return values[i+1]end})
local motion=obj({get_DeformNameHashes=function()return hashes end,get_DeformValues=function()return weights end})
local requested={{name="a",hash=1001},{name="b",hash=1002},{name="c",hash=1003}}
for _,kind in ipairs({"unreadable","absent","ready"})do
 now,item_reads=0,0
 for i=1,748 do registered[i]=i+0.0;values[i]=i*.1 end
 if kind=="unreadable"then registered[748]=.5 end
 if kind=="ready"then for i=1,3 do registered[i]=1000+i+0.0 end end
 local h={motion=motion}
 for frame=0,3599 do
  now=frame/120
  local out=D.existing(h,requested)
  if kind=="ready"then for i,item in ipairs(requested)do assert(out[item.name]==values[i])end
  else assert(next(out)==nil)end
 end
 assert(item_reads <= 16*748 + (kind=="ready" and 3*3600 or 0), "full index work grew with frame count")
 if kind=="unreadable"then assert(h.existing.status=="index_unreadable" and h.existing.error.index==747)
 elseif kind=="absent"then assert(h.existing.status=="no_matching_inputs")
 else assert(h.existing.status=="ready")end
 print("CACHE_STRESS_PASS",kind,"frames",3600,"hash_item_reads",item_reads)
end
local array=obj({get_Item=function(_,i)return ({0,4294967295.0,-1,0/0,math.huge})[i+1]end})
assert(D.hash_list(array,2)[2]==4294967295)
local list,err=D.hash_list(array,3);assert(not list and err.index==2)
print("UINT32_VALIDATION_PASS")
