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
    local face_go=R.call(current.face,'get_GameObject')
    local root_go=R.call(current.root,'get_GameObject')

    local face_motion=face_go and R.component(face_go,sdk.typeof('via.motion.Motion'))
    local root_motion=root_go and R.component(root_go,sdk.typeof('via.motion.Motion'))

    local motion = face_motion or root_motion
    if not motion then return nil,'motion_unavailable' end

    local function has_deforms(comp)
        if not comp then return false end
        local dh = R.call(comp, "get_DeformNameHashes")
        local len = dh and (R.call(dh, "get_Length") or R.call(dh, "get_Count")) or 0
        return len > 0
    end

    local deform_motion = motion
    if has_deforms(face_motion) then
        deform_motion = face_motion
    elseif has_deforms(root_motion) then
        deform_motion = root_motion
    end

    local address=R.address(motion)
    local generation=R.call(motion,'get_SkeletonConstructCount') or 1
    local count=R.call(motion,'get_JointCount') or 0
    if count == 0 and root_motion then
        count = R.call(root_motion, 'get_JointCount') or 0
    end

    return {
        motion=motion,
        root_motion=root_motion,
        deform_motion=deform_motion,
        count=count,
        identity=head.identity..':'..address..':'..generation..':'..count
    }
end
function M.open(head,cache)
    local c,why=resolve(head)
    if not c then return nil,why end
    if cache.identity~=c.identity then 
        cache.identity,cache.indices=c.identity,{}
        cache.deform_indices=nil
    end
    c.cache,c.head=cache,head
    return c
end
local function index_of(c,name)
    local cache=c.cache
    local index=cache.indices[name]
    if index==nil then
        index=R.call(c.motion,'getJointIndexByNameHash(System.UInt32)',Hash.hash(name))
        if not R.integer(index,c.count-1) and c.root_motion then
            index=R.call(c.root_motion,'getJointIndexByNameHash(System.UInt32)',Hash.hash(name))
        end
        cache.indices[name]=R.integer(index,c.count-1)and index or false
    end
    if R.integer(index,c.count-1)then return index end
end

-- Read native RE9 FACS Deform track evaluated on via.motion.Motion
function M.deform_value(c, hash)
    if not c then return nil end
    local dm = c.deform_motion or c.motion
    if not dm then return nil end
    local cache = c.cache
    if not cache.deform_indices then
        cache.deform_indices = {}
        local dhashes = R.call(dm, "get_DeformNameHashes")
        local len = dhashes and (R.call(dhashes, "get_Length") or R.call(dhashes, "get_Count")) or 0
        for i = 0, len - 1 do
            local h = Hash.hash_at(dhashes, i, true)
            if h then cache.deform_indices[h] = i end
        end
    end
    local idx = cache.deform_indices[hash]
    if not idx then return nil end
    if not c.deform_values then
        c.deform_values = R.call(dm, "get_DeformValues")
    end
    if not c.deform_values then return nil end
    local val = R.call(c.deform_values, "get_Item", idx)
    if type(val) == "number" and val == val and math.abs(val) < math.huge then
        return val
    end
    return nil
end

function M.scalar(c,name)
    -- 1. Try deform track first (in RE9, native FACS blendshapes are evaluated as deforms!)
    local dv = M.deform_value(c, Hash.hash(name))
    if dv ~= nil then return dv, 'ok' end
    
    -- 2. Fall back to joint position if it was an actual bone
    local index=index_of(c,name)
    if index==nil then return nil,'motion_target_unavailable:'..name end
    local p=vector(R.call(c.motion,'getCalculatedLocalPosition(System.Int32)',index),3)
    return p and p[1]or nil,p and'ok'or('motion_position_unavailable:'..name)
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
function M.finish(c)
    local after=resolve(c.head)
    return after~=nil and after.identity==c.identity
end
return M
