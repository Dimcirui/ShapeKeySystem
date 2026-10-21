-- Missing face joints may still have calculated poses in the current Motion skeleton.
-- Cache numeric indices by full owner identity; never sample unrelated parameter tracks.
local R=require('ShapeKeySystem_Games.RE9.Runtime')
local Hash=require('ShapeKeySystem_Core.NameHash')
local M={}
local function vector(value,n)
    if not value then return end
    local ok,p=pcall(function()
        local a={value.x,value.y,value.z};if n==4 then a[4]=value.w end;return a
    end)
    if not ok or #p~=n then return end
    local norm=0
    for _,v in ipairs(p)do
        if type(v)~='number'or v~=v or math.abs(v)==math.huge then return end
        norm=norm+v*v
    end
    if n==4 then
        if norm<.25 or norm>4 then return end
        norm=math.sqrt(norm);for i=1,4 do p[i]=p[i]/norm end
    end
    return p
end
local function resolve(head)
    local current=R.find()
    if not current or current.identity~=head.identity then return nil,'head_changed' end
    local go=R.call(current.face,'get_GameObject')
    local motion=R.component(go,sdk.typeof('via.motion.Motion'))
    if R.address(R.call(motion,'get_GameObject'))~=R.address(go)then return nil,'motion_owner_unverified'end
    local address=R.address(motion)
    local generation=R.call(motion,'get_SkeletonConstructCount')
    local count=R.call(motion,'get_JointCount')
    if not address or not R.integer(generation,0xFFFFFFFF)or not R.integer(count,8192)or count==0 then
        return nil,'motion_unavailable'
    end
    return {motion=motion,count=count,identity=head.identity..':'..address..':'..generation..':'..count}
end
function M.open(head,cache)
    local c,why=resolve(head)
    if not c then return nil,why end
    if cache.identity~=c.identity then cache.identity,cache.indices=c.identity,{}end
    c.cache,c.head=cache,head
    return c
end
function M.read(c,name,neutral,diagnostic)
    if type(neutral)~='table'or #neutral~=4 then return nil,'motion_neutral_unavailable'end
    local cache=c.cache
    local index=cache.indices[name]
    if index==nil then
        index=R.call(c.motion,'getJointIndexByNameHash(System.UInt32)',Hash.hash(name))
        cache.indices[name]=R.integer(index,c.count-1)and index or false
    end
    if not R.integer(index,c.count-1)then return nil,'motion_joint_unavailable:'..name end
    local q=vector(R.call(c.motion,'getCalculatedLocalRotation(System.Int32)',index),4)
    if not q then return nil,'motion_rotation_unavailable:'..name end
    local pose={base_rotation={table.unpack(neutral)},rotation=q,source='motion',motion_index=index}
    if diagnostic then pose.position=vector(R.call(c.motion,'getCalculatedLocalPosition(System.Int32)',index),3)end
    return pose,'ok'
end
function M.finish(c)
    local after=resolve(c.head)
    return after~=nil and after.identity==c.identity
end
return M
