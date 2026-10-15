-- ShapeKeySystem: Leon bone measurements and read-only correction channels.
--
-- Positions are projected in millimetres from the calibrated neutral pose; rotations use the
-- quaternion log in degrees. Rules clamp before gain and sum, matching the Leon calibration.
-- Handles belong to a rig and are discarded with it; this module retains no engine objects.
local Hash = require("ShapeKeySystem_Core.NameHash")
local Names = require("ShapeKeySystem_Core.Names")
local S = {}
local data = { joints = {}, rules = {} }
local by_name, by_key, protected = {}, {}, {}
for i, name in ipairs(Names.ARKIT52) do by_name[name], by_key[i] = i, name end
local PREFIX = "Face__geo__p000_cbs.crct_"

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function call(obj, method, ...)
    if not obj then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    return ok and value or nil
end
local function number(v)
    if finite(v) then return math.tointeger(v) end
    local s = call(v, "ToString()")
    return s and math.tointeger(tonumber(s)) or nil
end

function S.configure(calibration)
    if type(calibration) ~= "table" or type(calibration.joints) ~= "table" or type(calibration.rules) ~= "table" then
        return false, "Leon 标定数据缺失"
    end
    for _, rule in ipairs(calibration.rules) do
        if not by_name[rule.key] or not finite(rule.lo) or not finite(rule.hi) or rule.lo == rule.hi
            or not finite(rule.gain or 1) then return false, "Leon 标定规则无效" end
        if rule.joint then
            local j = calibration.joints[rule.joint]
            if not j or (j.kind ~= "pos" and j.kind ~= "rot") or type(j.axis) ~= "table"
                or type(j.neutral) ~= "table" or #j.axis ~= 3 or #j.neutral ~= 7 then
                return false, "Leon 骨骼标定无效"
            end
            for _, v in ipairs(j.axis) do if not finite(v) then return false, "标定轴无效" end end
            for _, v in ipairs(j.neutral) do if not finite(v) then return false, "中立位无效" end end
        elseif type(rule.taps) ~= "table" or #rule.taps == 0 then return false, "标定缺少来源" end
    end
    data, protected = calibration, {}
    for _, name in ipairs(calibration.native_names or {}) do protected[Hash.hash(name)] = true end
    for _, r in ipairs(data.rules) do
        for _, tap in ipairs(r.taps or {}) do protected[Hash.hash(PREFIX .. tap)] = true end
    end
    return true
end

function S.hashes(mesh)
    local arr = call(mesh, "get_ChannelNameHash")
    local n = call(mesh, "get_BlendShapeChannelNum")
    if not arr or not finite(n) or n < 0 then return {} end
    local elems = nil
    pcall(function() elems = arr:get_elements() end)
    local out = {}
    for i = 0, n - 1 do
        local h = number(call(arr, "get_Item", i))
        if not h and elems then pcall(function() h = number(elems[i + 1]) end) end
        if h then out[h & 0xFFFFFFFF] = i end
    end
    return out
end

function S.writable(name, mesh, idx)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "#"
        or name:find("^Face__geo__") or name:find("^crct_") or protected[Hash.hash(name)] then return false end
    if mesh and idx ~= nil then
        local arr = call(mesh, "get_ChannelNameHash")
        local h = number(call(arr, "get_Item", idx))
        if not h and arr then pcall(function() h = number(arr:get_elements()[idx + 1]) end) end
        return h ~= nil and not protected[h & 0xFFFFFFFF]
    end
    return true
end

S.raw = {
    term = "Leon 标定信号",
    parse = function(value)
        local key = type(value) == "string" and by_name[value]
        if key then return key end
        return nil, "未知 Leon 标定信号"
    end,
    label = function(key) return by_key[key] or "?" end,
}

function S.bind(face, keys)
    local mesh = call(call(face, "get_GameObject"), "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    local h = { mesh = mesh, keys = keys, joints = {}, taps = {}, status = {}, count = call(mesh, "get_BlendShapeChannelNum") }
    local hashes = S.hashes(mesh)
    for name, spec in pairs(data.joints) do
        h.joints[name] = call(face, "getJointByName(System.String)", spec.bone or name)
    end
    for _, rule in ipairs(data.rules) do
        for _, name in ipairs(rule.taps or {}) do h.taps[name] = hashes[Hash.hash(PREFIX .. name)] end
    end
    return h, #keys
end

function S.measure(spec, position, rotation)
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

function S.read(h, P, inv_full)
    local values, measured, taps = {}, {}, {}
    local mesh = h.mesh
    local cn, wc = call(mesh, "get_BlendShapeChannelNum"), call(mesh, "get_BlendShapeChannelWeightCount")
    local length = call(call(mesh, "get_ChannelWeightList"), "get_Length")
    local bound = finite(cn) and finite(wc) and finite(length) and cn == h.count
    local limit = bound and math.min(cn, wc, length) or 0
    for _, rule in ipairs(data.rules) do
        local value
        if rule.joint then
            local name, spec = rule.joint, data.joints[rule.joint]
            if measured[name] == nil then
                local joint = h.joints[name]
                local ok, v = pcall(S.measure, spec, call(joint, "get_LocalPosition()"), call(joint, "get_LocalRotation()"))
                measured[name] = ok and finite(v) and v or false
            end
            value = measured[name]
        else
            for _, name in ipairs(rule.taps) do
                if taps[name] == nil then
                    local idx, state = h.taps[name], "unbound"
                    local v
                    if idx ~= nil then
                        if not bound then state = "bounds_unavailable"
                        elseif idx >= limit then state = "out_of_bounds"
                        else v = call(mesh, "getBlendShapeChannelWeightParam", idx); state = finite(v) and "ok" or "read_failed" end
                    end
                    h.status[name], taps[name] = state, finite(v) and v or false
                end
                local v = taps[name]
                if finite(v) and (not value or v > value) then value = v end
            end
        end
        if finite(value) then
            local v = math.max(0, math.min(1, (value - rule.lo) / (rule.hi - rule.lo))) * (rule.gain or 1)
            values[rule.key] = math.max(0, math.min(1, (values[rule.key] or 0) + v))
        end
    end
    for _, key in ipairs(h.keys) do P[key] = (values[by_key[key]] or 0) * inv_full end
end

return S
