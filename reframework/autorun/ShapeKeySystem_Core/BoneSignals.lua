-- ShapeKeySystem: expression signals projected from face joint poses (#21).
--
-- A calibration lists joints (kind, neutral local pose, axis) and rules (ARKit key, joint, lo, hi, gain).
-- Positions are projected in millimetres from the neutral pose; rotations use the quaternion log in degrees.
-- Rules clamp to 0..1 before gain, same-key outputs add and clamp again; fallback rules only fill keys
-- that no primary rule produced. Adapters may feed extra sources (RE4R native taps) through `source`.
-- Handles belong to a rig and are discarded with it; this module retains no engine objects.
local Names = require("ShapeKeySystem_Core.Names")
local L = require("ShapeKeySystem_Core.I18n")
local B = {}
local by_name, by_key = {}, {}
for i, name in ipairs(Names.ARKIT52) do by_name[name], by_key[i] = i, name end
B.by_name, B.by_key = by_name, by_key

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
B.finite = finite
local function call(obj, method, ...)
    if not obj then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    return ok and value or nil
end

-- opts.label prefixes the messages ("Leon"); opts.taps allows rules without a joint (adapter sources).
function B.validate(calibration, opts)
    opts = opts or {}
    local label = opts.label and (L.tr(opts.label) .. " ") or ""
    if type(calibration) ~= "table" or type(calibration.joints) ~= "table" or type(calibration.rules) ~= "table" then
        return false, L.f("%s标定数据缺失", label)
    end
    for _, rule in ipairs(calibration.rules) do
        if not by_name[rule.key] or not finite(rule.lo) or not finite(rule.hi) or rule.lo == rule.hi
            or not finite(rule.gain or 1) then return false, L.f("%s标定规则无效", label) end
        if rule.fallback ~= nil and (type(rule.fallback) ~= "boolean" or not rule.joint) then
            return false, L.f("%s补充规则需要骨骼来源", label)
        end
        if rule.joint then
            local j = calibration.joints[rule.joint]
            if not j or (j.kind ~= "pos" and j.kind ~= "rot") or type(j.axis) ~= "table"
                or type(j.neutral) ~= "table" or #j.axis ~= 3 or #j.neutral ~= 7 then
                return false, L.f("%s骨骼标定无效", label)
            end
            for _, v in ipairs(j.axis) do if not finite(v) then return false, "标定轴无效" end end
            for _, v in ipairs(j.neutral) do if not finite(v) then return false, "中立位无效" end end
        elseif not opts.taps or type(rule.taps) ~= "table" or #rule.taps == 0 then return false, "标定缺少来源" end
    end
    return true
end

B.raw = {
    term = "角色标定信号",
    parse = function(value)
        local key = type(value) == "string" and by_name[value]
        if key then return key end
        return nil, "未知角色标定信号"
    end,
    label = function(key) return by_key[key] or "?" end,
}

function B.measure(spec, position, rotation)
    local n, a = spec.neutral, spec.axis
    if spec.kind == "pos" then
        if not position then return nil end
        return ((position.x - n[1]) * a[1] + (position.y - n[2]) * a[2] + (position.z - n[3]) * a[3]) * 1000
    end
    if not rotation then return nil end
    local ax, ay, az, aw = -n[4], -n[5], -n[6], n[7]
    local bx, by, bz, bw = rotation.x, rotation.y, rotation.z, rotation.w
    local x = aw * bx + ax * bw + ay * bz - az * by
    local y = aw * by - ax * bz + ay * bw + az * bx
    local z = aw * bz + ax * by - ay * bx + az * bw
    local w = aw * bw - ax * bx - ay * by - az * bz
    if w < 0 then x, y, z, w = -x, -y, -z, -w end
    local length = math.sqrt(x*x + y*y + z*z)
    if length < 1e-9 then return 0 end
    return (x*a[1] + y*a[2] + z*a[3]) / length * math.deg(2 * math.atan(length, w))
end

-- sample(name) -> local position, local rotation of the calibrated joint;
-- source(rule) -> value for a rule without a joint, or nil.
function B.evaluate(calibration, sample, source, lazy_fallback)
    local values, fallback, measured = {}, {}, {}
    local function evaluate(rule)
        local value
        if rule.joint then
            local name = rule.joint
            if measured[name] == nil then
                local ok, v = pcall(function() return B.measure(calibration.joints[name], sample(name)) end)
                measured[name] = ok and finite(v) and v or false
            end
            value = measured[name]
        elseif source then
            value = source(rule)
        end
        if finite(value) then
            local v = math.max(0, math.min(1, (value - rule.lo) / (rule.hi - rule.lo))) * (rule.gain or 1)
            local target = rule.fallback and fallback or values
            target[rule.key] = math.max(0, math.min(1, (target[rule.key] or 0) + v))
        end
    end
    for _, rule in ipairs(calibration.rules) do
        if not lazy_fallback or not rule.fallback then evaluate(rule) end
    end
    if lazy_fallback then
        for _, rule in ipairs(calibration.rules) do
            if rule.fallback and values[rule.key] == nil then evaluate(rule) end
        end
    end
    -- A readable zero is an available source; only absent outputs use bone fallbacks.
    for key, value in pairs(fallback) do if values[key] == nil then values[key] = value end end
    return values, measured
end

function B.bind_joints(face, calibration)
    local joints = {}
    for name, spec in pairs(calibration.joints) do
        joints[name] = call(face, "getJointByName(System.String)", spec.bone or name)
    end
    return joints
end

function B.sampler(joints)
    return function(name)
        local joint = joints[name]
        return call(joint, "get_LocalPosition()"), call(joint, "get_LocalRotation()")
    end
end

-- Joint-only rigs: adapters without extra sources use bind/read directly.
function B.bind(face, keys, calibration)
    return { keys = keys, joints = B.bind_joints(face, calibration), calibration = calibration }, #keys
end

function B.read(h, P, inv_full)
    local values, measured = B.evaluate(h.calibration, B.sampler(h.joints))
    for _, key in ipairs(h.keys) do P[key] = (values[by_key[key]] or 0) * inv_full end
    return values, measured
end

-- Numbers and names only: local poses of the calibrated joints plus `extra` joint names.
function B.snapshot_joints(face, calibration, extra)
    local joints, status = {}, {}
    local names = {}
    for _, name in ipairs(extra or {}) do names[name] = name end
    for name, spec in pairs(calibration.joints) do names[name] = spec.bone or name end
    for name, bone in pairs(names) do
        local joint = call(face, "getJointByName(System.String)", bone)
        local p, q = call(joint, "get_LocalPosition()"), call(joint, "get_LocalRotation()")
        if p and q and finite(p.x) and finite(p.y) and finite(p.z)
            and finite(q.x) and finite(q.y) and finite(q.z) and finite(q.w) then
            joints[name] = {p.x, p.y, p.z, q.x, q.y, q.z, q.w}
        else status["joint:" .. name] = "unavailable" end
    end
    return joints, status
end

return B
