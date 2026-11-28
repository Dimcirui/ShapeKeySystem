-- Missing face joints may still have calculated poses in the current Motion skeleton.
-- Cache numeric indices by full owner identity. Native scalar tracks are requested only
-- for a configured output whose physical pose and same-named Motion pose are missing.
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
    local motion=current.motion
    if R.address(R.call(motion,'get_GameObject'))~=R.address(go)then return nil,'motion_owner_unverified'end
    local address=R.address(motion)
    local generation,count=current.generation,current.count
    if not address or not R.integer(generation,0xFFFFFFFF)or not R.integer(count,8192)or count==0 then
        return nil,'motion_unavailable'
    end
    return {motion=motion,count=count,generation=generation,
        identity=head.identity..':'..address..':'..generation..':'..count}
end
function M.open(head,cache)
    local c,why=resolve(head)
    if not c then return nil,why end
    if cache.identity~=c.identity then cache.identity,cache.indices=c.identity,{}end
    c.cache,c.head=cache,head
    return c
end
local function index_of(c,name)
    local cache=c.cache
    local index=cache.indices[name]
    if index==nil then
        index=R.call(c.motion,'getJointIndexByNameHash(System.UInt32)',Hash.hash(name))
        cache.indices[name]=R.integer(index,c.count-1)and index or false
    end
    if R.integer(index,c.count-1)then return index end
end
function M.scalar(c,name)
    local index=index_of(c,name)
    if index==nil then return nil,'motion_joint_unavailable:'..name end
    local p=vector(R.call(c.motion,'getCalculatedLocalPosition(System.Int32)',index),3)
    return p and p[1]or nil,p and'ok'or('motion_position_unavailable:'..name)
end
-- names -> {name = x}; one ShapeKeySystem_Native.dll call reads every joint when it is loaded
function M.scalars(c,names)
    local out,indices,wanted={},{},{}
    for _,name in ipairs(names)do
        local index=index_of(c,name)
        if index then indices[#indices+1]=index;wanted[#wanted+1]=name end
    end
    local native=rawget(_G,'sks_native')
    if #indices>0 and type(native)=='table'and type(native.motion_curves)=='function'then
        local ok,motion_address=pcall(c.motion.get_address,c.motion)
        local read,values
        if ok then read,values=pcall(native.motion_curves,motion_address,indices)end
        if read and type(values)=='table'then
            for i,name in ipairs(wanted)do
                local v=values[i]
                if type(v)=='number'then out[name]=v end
            end
            return out
        end
    end
    for _,name in ipairs(wanted)do out[name]=M.scalar(c,name)end
    return out
end
function M.read(c,name,neutral,diagnostic,neutral_position)
    if type(neutral)~='table'or #neutral~=4 then return nil,'motion_neutral_unavailable'end
    local index=index_of(c,name)
    if index==nil then return nil,'motion_joint_unavailable:'..name end
    local q=vector(R.call(c.motion,'getCalculatedLocalRotation(System.Int32)',index),4)
    if not q then return nil,'motion_rotation_unavailable:'..name end
    local pose={base_rotation={table.unpack(neutral)},rotation=q,source='motion',motion_index=index}
    if diagnostic or neutral_position then
        pose.position=vector(R.call(c.motion,'getCalculatedLocalPosition(System.Int32)',index),3)
        if neutral_position then
            if not pose.position then return nil,'motion_position_unavailable:'..name end
            pose.base_position={table.unpack(neutral_position)}
        end
    end
    return pose,'ok'
end
-- The head must still be the one opened and its skeleton must not have been rebuilt meanwhile.
function M.finish(c)
    local current=R.find()
    return current~=nil and current.identity==c.head.identity
        and R.call(c.motion,'get_SkeletonConstructCount')==c.generation
        and R.call(c.motion,'get_JointCount')==c.count
end
return M
