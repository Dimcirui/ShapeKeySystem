-- ShapeKeySystem: RE9 base-relative face measurements for missing native correction inputs.
-- Each read resolves joints on the current head. The base pose comes from the same skeleton;
-- no joint references or sampled extrema survive a read.
local R = require('ShapeKeySystem_Games.RE9.Runtime')
local B = require('ShapeKeySystem_Core.BoneSignals')
local M = {}
local finite = B.finite
local rules = {}
local labels = {eyeBlinkLeft=true,eyeBlinkRight=true,jawOpen=true}
function M.validate(data)
    if data == nil then return true end
    if type(data) ~= 'table' then return false, 'RE9 面骨回退配置无效' end
    for label, rule in pairs(data) do
        if not labels[label] or type(rule) ~= 'table' or not finite(rule.lo) or not finite(rule.hi)
            or rule.hi <= rule.lo or type(rule.terms) ~= 'table' or #rule.terms == 0 or #rule.terms > 8 then
            return false, 'RE9 面骨回退范围无效'
        end
        for _, term in ipairs(rule.terms) do
            if type(term) ~= 'table' or type(term.bone) ~= 'string' or term.bone == ''
                or type(term.axis) ~= 'table' or #term.axis ~= 3 or not finite(term.weight or 1) then
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
        end
    end
    return true
end
function M.configure(data)
    local ok, why = M.validate(data)
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
function M.read(head, label, diagnostic, fallback, omitted)
    local rule = rules[label]
    if not rule then return nil, nil, 'not_configured' end
    local value, joints, used_motion = 0, {}, false
    for _, term in ipairs(rule.terms) do
        local pose = joints[term.bone]
        if not pose then
            local joint = not(omitted and omitted[term.bone])and R.call(head.face,'getJointByName(System.String)',term.bone)or nil
            local base = quaternion(R.call(joint,'get_BaseLocalRotation()'))
            local current = quaternion(R.call(joint,'get_LocalRotation()'))
            local state
            if not joint or R.call(joint,'get_Name()')~=term.bone then state='joint_unavailable:'..term.bone
            elseif not base or not current then state='pose_unavailable:'..term.bone
            else
                pose = {base_rotation=base,rotation=current,source='bones'}
                if diagnostic then
                    pose.position=position(R.call(joint,'get_LocalPosition()'))
                    pose.base_position=position(R.call(joint,'get_BaseLocalPosition()'))
                end
            end
            if not pose and fallback then pose,state=fallback(term,diagnostic)end
            if not pose then return nil,nil,state or'pose_unavailable:'..term.bone end
            used_motion=used_motion or pose.source=='motion'
            joints[term.bone] = pose
        end
        local q = pose.rotation
        local v = B.measure({kind='rot',axis=term.axis,neutral={0,0,0,table.unpack(pose.base_rotation)}},
            nil,{x=q[1],y=q[2],z=q[3],w=q[4]})
        if not finite(v) then return nil, nil, 'measurement_failed:'..term.bone end
        value = value + v * (term.weight or 1)
    end
    return math.max(0,math.min(1,(value-rule.lo)/(rule.hi-rule.lo))), value, 'ok', joints, used_motion and'motion'or'bones'
end
return M
