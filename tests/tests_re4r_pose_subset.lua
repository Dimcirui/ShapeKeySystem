-- Selected animation bones must preserve their full-sampling result and resume when needed.
local repo = assert(arg[1])
package.path = repo .. "/reframework/autorun/?.lua;" .. package.path
local now, trace, saved = 0, {}, nil
sks_perf_clock = {now=function() return now end, resolution_ms=0.0001}
json = {dump_file=function(_,r) saved=r; return true end}
re = {on_script_reset=function() end}
local Hash = require("ShapeKeySystem_Core.NameHash")
local function object(methods)
    local o = methods or {}
    o.add_ref = function(self) return self end
    o.get_address = function(self) return self.address or 123 end
    o.call = function(self,name,...)
        trace[#trace+1] = name
        now = now + 0.00001
        local method = name:match("^([^%(]+)")
        local fn = self[method]
        if fn then return fn(self,...) end
    end
    return o
end
local fail_position = false
sdk = {typeof=function(n) return n end}
sdk.create_instance = function(name)
    if name == "via.motion.AnimationTransformData" then
        return object({clear=function() end, get_ValidPosition=function() return true end,
            get_ValidRotation=function() return true end,
            get_Position=function(self)
                if fail_position then return setmetatable({}, {__index=function() error("pose read test") end}) end
                return self.p
            end, get_Rotation=function(self) return self.q end})
    end
    assert(name == "via.motion.MotionInfo")
    return object({clear=function() end,
        getAnimationTransform=function(_,hash,frame,data)
            data.p={x=frame*0.01,y=0.02,z=0}
            data.q={x=0,y=0,z=math.sin(frame*.01),w=math.cos(frame*.01)}
            return true
        end})
end
local function motion()
    local function node(frame, weight)
        return object({get_Weight=function() return weight end,get_Frame=function() return frame end,
            getMotionInfo=function() return true end,get_MotionName=function() return "idle" end,
            get_OutputMirrored=function() return false end})
    end
    local layers={}
    for li=1,2 do
        local nodes={node(li,.25),node(li+1,.75)}
        layers[li]=object({getRawMotionNodeCount=function() return 2 end,get_BlendRate=function() return .7 end,
            get_BlendMode=function() return li-1 end,get_ActiveJointMaskID=function() return li end,
            getRawMotionNode=function(_,i) return nodes[i+1] end})
    end
    local mask=object({get_Length=function() return 1 end,GetValue=function()
        return object({get_NameHash=function() return Hash.hash("L_Eye") end,
            get_Trans=function() return false end,get_Rot=function() return true end})
    end})
    return object({getLayerCount=function() return 2 end,getLayer=function(_,i) return layers[i+1] end,
        get_SkeletonConstructCount=function() return 1 end,getJointMaskGroupBits=function(_,i) return i end,
        getJointMaskInfo=function() return mask end})
end
local bones={a={name="C_Chin",neutral={0,0,0,0,0,0,1}},b={name="L_Eye",neutral={0,0,0,0,0,0,1}}}
local function encode(poses)
    local parts={}
    for _,name in ipairs({"C_Chin","L_Eye"}) do
        local p=poses[name]
        for _,kind in ipairs({"position","rotation"}) do
            for _,v in ipairs(p and p[kind] or {}) do parts[#parts+1]=string.format("%.12f",v) end
        end
    end
    return table.concat(parts,",")
end
local Pose = require("ShapeKeySystem_Games.RE4R.NativePose")
local ph = Pose.bind(motion(), bones)
fail_position=false
local full=Pose.read(ph,nil)
trace={};local selected=Pose.read(ph,nil,{C_Chin=true})
assert(selected.L_Eye==nil and selected.C_Chin)
for kind,values in pairs(full.C_Chin) do
 if type(values)=="table" then for i,v in ipairs(values) do assert(math.abs(v-selected.C_Chin[kind][i])<1e-12) end end
end
local samples=0;for _,v in ipairs(trace) do if v=="getAnimationTransform(System.UInt32, System.Single, via.motion.AnimationTransformData, System.Boolean)" then samples=samples+1 end end
assert(#ph.selected==1)
trace={};assert(next(Pose.read(ph,nil,{}))==nil and #trace==0)
local restored=Pose.read(ph,nil,{C_Chin=true,L_Eye=true});assert(encode(restored)==encode(full))
print("DEMAND_POSE_SUBSET_AND_RESTORE_PASS")

