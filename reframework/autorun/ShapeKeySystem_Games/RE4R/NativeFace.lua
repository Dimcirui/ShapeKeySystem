-- RE4R animation inputs for replacement heads without facial joints.
-- Motion keeps native correction tracks as extra joints; their position X is the scalar track.
-- Procedural blink comes from the matching character's FacialController, before mesh deformation.
local Hash = require("ShapeKeySystem_Core.NameHash")
local Deform = require("ShapeKeySystem_Games.RE4R.NativeDeform")
local Pose = require("ShapeKeySystem_Games.RE4R.NativePose")
local F = {}
local eye_cache = {} -- Numeric snapshots only, shared with the adapter's virtual eye descriptors.
local PREFIX = "Face__geo__p000_cbs.crct_"
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function call(o, method, ...)
    if not o then return nil end
    local ok, value = pcall(function(...) return o:call(method, ...) end, ...)
    if ok then return value end
end
local function address(o)
    if not o then return nil end
    local ok, value = pcall(o.get_address, o)
    return ok and value or nil
end
local function scalar_value(value)
    local x, y, z = value.x, value.y, value.z
    if finite(x) and finite(y) and finite(z) then return x end
end
local function scalar(value)
    if not value then return nil end
    local ok, v = pcall(scalar_value, value)
    return ok and v or nil
end
local function quaternion(value)
    if not value then return nil end
    local ok, v = pcall(function()
        if finite(value.x) and finite(value.y) and finite(value.z) and finite(value.w) then
            local norm = value.x^2 + value.y^2 + value.z^2 + value.w^2
            if norm > 0.5 and norm < 1.5 then return {value.x, value.y, value.z, value.w} end
        end
    end)
    return ok and v or nil
end
local function joint_index(motion, name)
    local hash, count = Hash.hash(name), call(motion, "get_JointCount")
    local i = call(motion, "getJointIndexByNameHash(System.UInt32)", hash)
    if finite(count) and finite(i) and i >= 0 and i < count and i % 1 == 0
        and call(motion, "getJointNameHashByIndex(System.Int32)", i) == hash then return i end
end
local function controller(h)
    if h.controller then return h.controller end
    local ctx = call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef()")
    local updater = call(ctx, "get_BodyUpdater")
    if address(call(updater, "get_HeadMotion")) == address(h.motion) then
        h.controller = call(updater, "get_FacialController")
    end
    return h.controller
end
function F.bind(face, calibration, joints, diagnostic)
    local go = call(face, "get_GameObject")
    local motion = call(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if not motion then return nil end
    local wanted, seen = {}, {}
    local function want(name)
        if not seen[name] then
            seen[name] = true
            wanted[#wanted + 1] = {name = name, hash = Hash.hash(PREFIX .. name)}
        end
    end
    if diagnostic then
        for _, full in ipairs(calibration.native_names or {}) do
            if full:sub(1, #PREFIX) == PREFIX then want(full:sub(#PREFIX + 1)) end
        end
    else
        for _, rule in ipairs(calibration.rules or {}) do
            for _, name in ipairs(rule.taps or {}) do want(name) end
        end
    end
    for _, name in ipairs(Deform.inputs()) do want(name) end
    local bones, available, real_blink = {}, {}, {}
    for name, spec in pairs(calibration.joints or {}) do
        local bone = spec.bone or name
        available[name] = joints[name] ~= nil
        if not available[name] then bones[name] = {name = bone, neutral = spec.neutral, kind = spec.kind} end
    end
    for _, rule in ipairs(calibration.rules or {}) do
        if (rule.key == "eyeBlinkLeft" or rule.key == "eyeBlinkRight") and rule.joint and available[rule.joint] then
            real_blink[rule.key] = true
        end
    end
    return {motion = motion, wanted = wanted, bones = bones, poses = {}, real_blink = real_blink,
        pose_reader = next(bones) and Pose.bind(motion, bones) or nil, deformer = Deform.bind(face),
        indices = {}, next_check = 0, status = "pending"}
end
local function read(h, register, select_bones)
    if not h then return {} end
    local m, now = h.motion, os.clock()
    local count = call(m, "get_JointCount")
    local generation = call(m, "get_SkeletonConstructCount")
    if not finite(count) or count <= 0 or count > 8192 then
        h.status, h.poses, h.values, h.blink = "waiting_for_motion", {}, {}, nil
        return {}
    end
    if h.count ~= count or h.generation ~= generation or now >= h.next_check then
        local indices = {}
        for _, item in ipairs(h.wanted) do
            local i = call(m, "getJointIndexByNameHash(System.UInt32)", item.hash)
            if finite(i) and i >= 0 and i < count and i % 1 == 0
                and call(m, "getJointNameHashByIndex(System.Int32)", i) == item.hash
                and call(m, "isExtraJoint(System.Int32)", i) == true then
                indices[item.name] = i
            end
        end
        h.indices, h.count, h.generation, h.next_check = indices, count, generation, now + 2
    end
    local out, n = Deform.existing(h.deformer, h.wanted), 0
    for _ in pairs(out) do n = n + 1 end

    for name, i in pairs(h.indices) do
        if out[name] == nil then

            local v = call(m, "getCalculatedLocalPosition(System.Int32)", i)
            local value = scalar(v)
            if value ~= nil then out[name], n = value, n + 1 end
        end
    end
    local inputs, present = Deform.inputs(), 0
    for _, name in ipairs(inputs) do if finite(out[name]) then present = present + 1 end end
    if present < #inputs then
        -- Register only native correction inputs when the current Motion table lacks them.
        for name, value in pairs(Deform.read(h.deformer, register)) do
            if out[name] == nil then out[name], n = value, n + 1 end
        end
    elseif h.deformer then h.deformer.status = "not_needed" end
    local c = (h.pose_reader or not h.real_blink.eyeBlinkLeft or not h.real_blink.eyeBlinkRight) and controller(h)
    local needed = select_bones and select_bones(out)
    local sampled = h.pose_reader and Pose.read(h.pose_reader, c, needed) or {}
    local poses, bone_count = {}, 0
    for name, bone in pairs(h.bones) do
        local pose = sampled[bone.name]
        if pose then
            poses[name] = pose
            if bone.kind == "pos" and pose.position or bone.kind == "rot" and pose.rotation then bone_count = bone_count + 1 end
        end
    end
    h.poses = poses
    local blink = (not h.real_blink.eyeBlinkLeft or not h.real_blink.eyeBlinkRight) and call(c, "get_BlinkRate")
    h.blink = finite(blink) and math.max(0, math.min(1, blink)) or nil
    h.status = n > 0 and "motion_curves" or "no_native_curves"
    h.values, h.curve_count, h.bone_count = out, n, bone_count
    local key = address(m)
    if key and (sampled.L_Eye or sampled.R_Eye) then
        eye_cache[key] = {at = os.clock(),
            L = sampled.L_Eye and sampled.L_Eye.rotation,
            R = sampled.R_Eye and sampled.R_Eye.rotation}
        local count = 0
        for id, entry in pairs(eye_cache) do
            if os.clock() - entry.at > 1 then eye_cache[id] = nil else count = count + 1 end
        end
        if count > 64 then eye_cache = {[key] = eye_cache[key]} end
    end
    return out
end
function F.read(h, register, select_bones)
    local values = read(h, register, select_bones)
    return values
end
function F.snapshot(h)
    if not h then return {status = "unavailable"} end
    local native_nine, n = {}, 0
    for _, name in ipairs(Deform.inputs()) do
        local value = h.values and h.values[name]
        if finite(value) then native_nine[name], n = value, n + 1 end
    end
    return {status = h.status, curve_count = h.curve_count, joint_count = h.count,
        curves = h.values, bones = h.poses, bone_count = h.bone_count, blink = h.blink,
        native_nine = native_nine, native_nine_count = n, registration = Deform.snapshot(h.deformer),
        resource_errors = h.pose_reader and h.pose_reader.errors or {}}
end
function F.apply(h, values)
    if not h or not finite(h.blink) then return end
    for _, key in ipairs({"eyeBlinkLeft", "eyeBlinkRight"}) do
        if not h.real_blink[key] then values[key] = math.max(values[key] or 0, h.blink) end
    end
end
function F.sample(h, name)
    local pose, bone = h and h.poses[name], h and h.bones[name]
    if not pose or not bone then return end
    local p, q = pose.position, pose.rotation
    local n = bone.neutral
    if bone.kind == "pos" and not p or bone.kind == "rot" and not q then return end
    return {x = p and p[1] or n[1], y = p and p[2] or n[2], z = p and p[3] or n[3]},
        {x = q and q[1] or n[4], y = q and q[2] or n[5], z = q and q[3] or n[6], w = q and q[4] or n[7]}
end
function F.eye(face, name)
    local motion = call(call(face, "get_GameObject"), "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    return motion and {motion = motion, name = name, animation_eye = true} or nil
end
function F.eye_rotation(eye)
    local cached = eye_cache[address(eye.motion)]
    local q = cached and cached[eye.name == "L_Eye" and "L" or "R"]
    if q and os.clock() - cached.at <= .25 then return {x = q[1], y = q[2], z = q[3], w = q[4]} end
    local i = joint_index(eye.motion, eye.name)
    if i and call(eye.motion, "isRotationAnimated(System.Int32)", i) == true then
        local q = call(eye.motion, "getCalculatedLocalRotation(System.Int32)", i)
        if quaternion(q) then return q end
    end
end
return F
