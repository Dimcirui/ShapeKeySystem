-- ShapeKeySystem: RE9 base-relative face measurements for missing native correction inputs.
-- Each read resolves joints on the current head. The base pose comes from the same skeleton;
-- no joint references or sampled extrema survive a read.
local R = require('ShapeKeySystem_Games.RE9.Runtime')
local B = require('ShapeKeySystem_Core.BoneSignals')
local M = {}
local finite = B.finite
local rules = {}
local labels = B.by_name
function M.validate(data,extra_labels)
    if data == nil then return true end
    if type(data) ~= 'table' then return false, 'RE9 面骨回退配置无效' end
    for label, rule in pairs(data) do
        if not(labels[label]or extra_labels and extra_labels[label])or type(rule) ~= 'table' or not finite(rule.lo) or not finite(rule.hi)
            or rule.hi <= rule.lo or type(rule.terms) ~= 'table' or #rule.terms == 0 or #rule.terms > 16 then
            return false, 'RE9 面骨回退范围无效'
        end
        for _, term in ipairs(rule.terms) do
            if type(term) ~= 'table' or type(term.bone) ~= 'string' or term.bone == ''
                or type(term.axis) ~= 'table' or #term.axis ~= 3 or not finite(term.weight or 1)
                or term.kind~=nil and term.kind~='rot' and term.kind~='pos' then
                return false, 'RE9 面骨回退来源无效'
            end
            local norm = 0
            for _, value in ipairs(term.axis) do
                if not finite(value) then return false, 'RE9 面骨投影轴无效' end
                norm = norm + value * value
            end
            if math.abs(norm - 1) > .001 then return false, 'RE9 面骨投影轴必须为单位向量' end
            if term.motion_neutral~=nil then
                if type(term.motion_neutral)~='table'or #term.motion_neutral~=4 then return false,'RE9 Motion 静止旋转无效'end
                local qnorm=0
                for _,v in ipairs(term.motion_neutral)do
                    if not finite(v)then return false,'RE9 Motion 静止旋转无效'end
                    qnorm=qnorm+v*v
                end
                if math.abs(qnorm-1)>.001 then return false,'RE9 Motion 静止旋转必须归一化'end
            end
            if term.motion_neutral_position~=nil then
                if type(term.motion_neutral_position)~='table'or #term.motion_neutral_position~=3 then
                    return false,'RE9 Motion 静止位置无效'
                end
                for _,v in ipairs(term.motion_neutral_position)do
                    if not finite(v)then return false,'RE9 Motion 静止位置无效'end
                end
            end
        end
    end
    return true
end
function M.configure(data,extra_labels)
    local ok, why = M.validate(data,extra_labels)
    if not ok then return false, why end
    rules = data or {}
    return true
end
local function quaternion(value)
    if not value then return end
    local ok, q = pcall(function() return {value.x,value.y,value.z,value.w} end)
    if not ok or #q ~= 4 then return end
    local norm = 0
    for _, x in ipairs(q) do if not finite(x) then return end; norm = norm + x*x end
    if norm < .25 or norm > 4 then return end
    norm = math.sqrt(norm)
    for i = 1,4 do q[i] = q[i] / norm end
    return q
end
local function position(value)
    if not value then return end
    local ok,p=pcall(function()return {value.x,value.y,value.z}end)
    if ok and #p==3 and finite(p[1])and finite(p[2])and finite(p[3])then return p end
end

-- Joint handle and static base pose cache keyed by head face identity
local joint_cache = {}
local cached_face_identity = nil

local function get_bone_info(head, bone_name, omitted)
    if omitted and omitted[bone_name] then return nil, 'omitted' end
    local face = head and head.face
    local face_id = face and R.address(face) or "nil"
    if face_id ~= cached_face_identity then
        joint_cache = {}
        cached_face_identity = face_id
    end
    local cached = joint_cache[bone_name]
    if cached == nil then
        local joint = face and R.call(face, 'getJointByName(System.String)', bone_name)
        if not joint and head and head.root then
            joint = R.call(head.root, 'getJointByName(System.String)', bone_name)
        end
        if joint and R.call(joint, 'get_Name') == bone_name then
            local base_rot = quaternion(R.call(joint, 'get_BaseLocalRotation'))
            local base_pos = position(R.call(joint, 'get_BaseLocalPosition'))
            cached = {
                joint = joint,
                base_rotation = base_rot,
                base_position = base_pos,
                neutral_rotation = base_rot and {0, 0, 0, base_rot[1], base_rot[2], base_rot[3], base_rot[4]} or nil
            }
        else
            cached = false
        end
        joint_cache[bone_name] = cached
    end
    if not cached then
        return nil, 'joint_unavailable:' .. bone_name
    end
    return cached
end

function M.evaluate(head, rule, diagnostic, fallback, omitted, frame)
    local value, joints, used_motion = 0, {}, false
    frame=frame or {}
    for _, term in ipairs(rule.terms) do
        local kind=term.kind or'rot'
        local cache_key=term.bone..':'..kind
        local entry=frame[cache_key]
        local pose=entry and entry.pose
        if entry and not pose then return nil,nil,entry.state end
        if not pose then
            local binfo, err = get_bone_info(head, term.bone, omitted)
            local state
            if not binfo then
                state = err or ('joint_unavailable:' .. term.bone)
            else
                pose = {source='bones'}
                local joint = binfo.joint
                pose.base_rotation = binfo.base_rotation
                pose.base_position = binfo.base_position
                pose.neutral_rotation = binfo.neutral_rotation
                if kind=='rot'or diagnostic then
                    pose.rotation=quaternion(R.call(joint,'get_LocalRotation'))
                end
                if kind=='pos'or diagnostic then
                    pose.position=position(R.call(joint,'get_LocalPosition'))
                end
                if kind=='rot'and not(pose.base_rotation and pose.rotation)
                    or kind=='pos'and not(pose.base_position and pose.position)then
                    pose,state=nil,'pose_unavailable:'..term.bone
                end
            end
            if not pose and fallback then pose,state=fallback(term,diagnostic)end
            frame[cache_key]={pose=pose,state=state}
            if not pose then return nil,nil,state or('pose_unavailable:'..term.bone) end
        end
        used_motion=used_motion or pose.source=='motion'
        joints[term.bone] = pose
        local q,p = pose.rotation,pose.position
        local v
        if kind=='pos'then
            v=B.measure({kind='pos',axis=term.axis,neutral=pose.base_position},
                p and {x=p[1],y=p[2],z=p[3]})
        else
            local neutral = pose.neutral_rotation or (pose.base_rotation and {0,0,0,table.unpack(pose.base_rotation)})
            v=B.measure({kind='rot',axis=term.axis,neutral=neutral},
                nil,q and {x=q[1],y=q[2],z=q[3],w=q[4]})
        end
        if not finite(v) then return nil, nil, 'measurement_failed:'..term.bone end
        value = value + v * (term.weight or 1)
    end
    return math.max(0,math.min(1,(value-rule.lo)/(rule.hi-rule.lo))), value, 'ok', joints, used_motion and'motion'or'bones'
end
function M.read(head,label,diagnostic,fallback,omitted,frame)
    local rule=rules[label]
    if not rule then return nil,nil,'not_configured'end
    return M.evaluate(head,rule,diagnostic,fallback,omitted,frame)
end
return M
