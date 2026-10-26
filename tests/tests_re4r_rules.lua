local calibrations={leon=json.load_file("ShapeKeySystem/builtin/re4/leon.json"),ada=json.load_file("ShapeKeySystem/builtin/re4/ada.json")}

local old=require("ShapeKeySystem_Core.BoneSignals")
local new=require("ShapeKeySystem_Core.BoneSignals")
math.randomseed(7519)
local total=0
for actor,c in pairs(calibrations) do
 for iteration=1,240 do
    local positions,rotations,taps={},{},{}
    for name,s in pairs(c.joints) do
        local n=s.neutral
        positions[name]={x=n[1]+(math.random()-.5)*.02,y=n[2]+(math.random()-.5)*.02,z=n[3]+(math.random()-.5)*.02}
        rotations[name]={x=n[4],y=n[5],z=n[6],w=n[7]}
        if iteration%7==0 then positions[name],rotations[name]=nil,nil end
    end
    for _,r in ipairs(c.rules) do
        if r.taps then
            local v=iteration%3==0 and 0 or math.random()
            if iteration%4~=0 then taps[r]=v end
        end
    end
    local calls=0
    local function sample(name) calls=calls+1;return positions[name],rotations[name] end
    local function source(rule) return taps[rule] end
    local a=old.evaluate(c,sample,source);local before=calls;calls=0
    local b=new.evaluate(c,sample,source,true)
    for key,v in pairs(a) do assert(b[key]==v,actor.." "..key) end
    for key,v in pairs(b) do assert(a[key]==v,actor.." "..key) end
    assert(calls<=before)
    total=total+1
 end
end
-- Primary-plus-bone addition and readable zero keep their distinct meanings.
local spec={kind="pos",neutral={0,0,0,0,0,0,1},axis={1,0,0}}
local c={joints={jaw=spec,brow=spec},rules={
 {key="jawOpen",joint="jaw",lo=0,hi=1}, {key="jawOpen",taps={"jaw"},lo=0,hi=1},
 {key="browUp",joint="brow",fallback=true,lo=0,hi=1}, {key="browUp",taps={"brow"},lo=0,hi=1}}}
local calls={}
local function sample(name) calls[name]=true;return {x=.0003,y=0,z=0} end
local function source(r) return r.key=="jawOpen" and .4 or 0 end
local v=new.evaluate(c,sample,source,true)
assert(math.abs(v.jawOpen-.7)<1e-12 and v.browUp==0 and not calls.brow)
calls={};v=new.evaluate(c,sample,function(r) if r.key=="jawOpen" then return .4 end end,true)
assert(calls.brow and math.abs(v.browUp-.3)<1e-12)
print("DEMAND_RULES_PASS",total,"calibration cases plus zero, missing and additive checks")
