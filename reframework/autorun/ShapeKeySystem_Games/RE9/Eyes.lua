-- Current-head eye descriptors retain only identity strings and numeric Motion indices.
local R=require('ShapeKeySystem_Games.RE9.Runtime')
local Bones=require('ShapeKeySystem_Games.RE9.Bones')
local Motion=require('ShapeKeySystem_Games.RE9.Motion')
local X=require('ShapeKeySystem_Core.Expression')
local E={}
local neutrals,enabled={},false
local diagnostics={}
function E.configure(data,active)
    neutrals,enabled=data or{},active==true
    diagnostics={}
end
function E.bind(face)
    if not enabled then return{}end
    local head=R.find()
    if not head or R.address(face)~=R.address(head.face)then return{}end
    local result={}
    for _,side in ipairs({'L','R'})do
        if neutrals[side]then result[side]={side=side,identity=head.identity,cache={}}end
    end
    return result
end
function E.angles(handle)
    if type(handle)~='table'then return end
    local head=R.find()
    local side=handle.side
    if not head or head.identity~=handle.identity or not enabled or not neutrals[side]then return end
    local neutral=neutrals[side]
    local term={bone=side..'_Eye',kind='rot',axis={1,0,0},motion_neutral=neutral.rotation}
    local context,requests
    requests=0
    local function fallback()
        local why
        context,why=Motion.open(head,handle.cache)
        if not context then return nil,why end
        requests=requests+1
        return Motion.read(context,term.bone,neutral.rotation,false)
    end
    local _,value,state,joints,source=Bones.evaluate(head,{lo=0,hi=1,terms={term}},false,fallback,nil,{})
    if context and not Motion.finish(context)then value=nil;state='motion_changed_during_read'end
    diagnostics[side]={source=source,status=state,motion_requests=requests}
    if value==nil then return end
    local pose=joints[term.bone]
    local a,b=pose.base_rotation,pose.rotation
    local q={x=a[4]*b[1]-a[1]*b[4]-a[2]*b[3]+a[3]*b[2],
        y=a[4]*b[2]+a[1]*b[3]-a[2]*b[4]-a[3]*b[1],
        z=a[4]*b[3]-a[1]*b[2]+a[2]*b[1]-a[3]*b[4],
        w=a[4]*b[4]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3]}
    return X.quat_to_yaw_pitch(q)
end
function E.diagnostics()return diagnostics end
return E
