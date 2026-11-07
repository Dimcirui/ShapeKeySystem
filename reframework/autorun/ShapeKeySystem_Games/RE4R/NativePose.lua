-- Read facial poses from active animation resources, including joints absent from the mesh.
-- Each rig owns its query buffers and only requests joints absent from its mesh.
local Hash = require("ShapeKeySystem_Core.NameHash")
local Trail = require("ShapeKeySystem_Core.Trail")
local P = {}
local clock = os.clock
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function clamp(v) return math.max(0, math.min(1, v)) end
local function call(o, method, ...)
    if not o then return nil end
    local ok, v = pcall(function(...) return o:call(method, ...) end, ...)
    if ok then return v end
end
local function vec(v)
    if v and finite(v.x) and finite(v.y) and finite(v.z) then return {v.x, v.y, v.z} end
end
local function quat(v)
    if not v or not finite(v.x) or not finite(v.y) or not finite(v.z) or not finite(v.w) then return end
    local n = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
    if n > .5 and n < 1.5 then return {v.x/n, v.y/n, v.z/n, v.w/n} end
end
local function normal(q)
    local n = math.sqrt(q[1]^2 + q[2]^2 + q[3]^2 + q[4]^2)
    if n < 1e-9 then return {0, 0, 0, 1} end
    return {q[1]/n, q[2]/n, q[3]/n, q[4]/n}
end
local function qblend(a, b, t)
    local sign = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4] < 0 and -1 or 1
    local q = {}
    for i = 1, 4 do q[i] = a[i]*(1-t) + b[i]*t*sign end
    return normal(q)
end
local function qmul(a, b)
    return normal({a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]})
end
local function mirror_name(name)
    if name:sub(1, 2) == "L_" then return "R_" .. name:sub(3) end
    if name:sub(1, 2) == "R_" then return "L_" .. name:sub(3) end
    return name
end
local function eyelid(name) return name:find("Eyelid", 1, true) ~= nil end
local function mouth(name)
    return name == "C_Chin" or name == "C_Jaw" or name:find("Lip", 1, true) ~= nil
        or name:find("Mouth", 1, true) ~= nil
end
-- ShapeKeySystem_Native.dll (sks_native) runs the same read with far fewer Lua-engine calls.
-- Rigs are rebound on every scan, so one native binding serves every rig with the same joints.
local native_ids = {}
local function native()
    local n = rawget(_G, "sks_native")
    return type(n) == "table" and type(n.pose_read) == "function" and n or nil
end
local function native_bind(sorted)
    local n = native()
    if not n then return nil end
    local flat = {}
    for i, spec in ipairs(sorted) do
        local neutral = spec.neutral
        if type(neutral) ~= "table" then return nil end
        for k = 1, 7 do if not finite(neutral[k]) then return nil end end
        spec.index = i
        flat[#flat + 1] = spec.hash
        flat[#flat + 1] = Hash.hash(mirror_name(spec.name))
        flat[#flat + 1] = (eyelid(spec.name) and 1 or 0) + (mouth(spec.name) and 2 or 0)
        for k = 1, 7 do flat[#flat + 1] = neutral[k] end
    end
    if #flat == 0 then return nil end
    local key = table.concat(flat, ",")
    if native_ids[key] == nil then
        local ok, id = pcall(n.pose_bind, flat)
        native_ids[key] = ok and id or false
    end
    return native_ids[key] or nil
end

function P.bind(motion, bones)
    local specs = {}
    for _, bone in pairs(bones) do
        specs[bone.name] = {name = bone.name, hash = Hash.hash(bone.name), neutral = bone.neutral}
    end
    local sorted = {}
    for _, spec in pairs(specs) do sorted[#sorted + 1] = spec end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    return {motion = motion, specs = sorted, masks = {}, errors = {}, error_seen = {},
        native_id = native_bind(sorted)}
end
local function buffers(h)
    if h.info and h.data then return true end
    local ok, why = pcall(function()
        h.info = sdk.create_instance("via.motion.MotionInfo"):add_ref()
        h.data = sdk.create_instance("via.motion.AnimationTransformData"):add_ref()
    end)
    if not ok then error(why) end
    return ok
end
local function masks(h, layer, li, generation, now)
    local id = call(layer, "get_ActiveJointMaskID")
    local old = h.masks[li]
    if old and old.id == id and old.generation == generation and now < old.due then return old end
    local bits = finite(id) and call(h.motion, "getJointMaskGroupBits(System.UInt32)", id)
    local arr = finite(bits) and call(h.motion, "getJointMaskInfo(System.UInt32)", bits)
    local n = call(arr, "get_Length")
    local result = {id = id, bits = bits, generation = generation, due = now + 2, entries = {}, count = 0}
    if finite(n) and n >= 0 and n <= 8192 then
        for i = 0, n - 1 do
            local item = call(arr, "GetValue(System.Int32)", i)
            local hash = call(item, "get_NameHash")
            if finite(hash) then
                result.entries[hash] = {position = call(item, "get_Trans"), rotation = call(item, "get_Rot")}
                result.count = result.count + 1
            end
        end
    end
    h.masks[li] = result
    return result
end
local function sample(h, frame, spec, mirrored)
    local name = mirrored and mirror_name(spec.name) or spec.name
    call(h.data, "clear")
    if call(h.info, "getAnimationTransform(System.UInt32, System.Single, via.motion.AnimationTransformData)",
        Hash.hash(name), frame, h.data) ~= true then return end
    local p = call(h.data, "get_ValidPosition") == true and vec(call(h.data, "get_Position")) or nil
    local q = call(h.data, "get_ValidRotation") == true and quat(call(h.data, "get_Rotation")) or nil
    if mirrored then
        if p then p[1] = -p[1] end
        if q then q[2], q[3] = -q[2], -q[3] end
    end
    if p or q then return {position = p, rotation = q} end
end
local function read(h, controller, specs)
    local m, now = h.motion, os.clock()
    local nlayer = call(m, "getLayerCount")
    if not finite(nlayer) or nlayer < 0 or nlayer > 64 or not buffers(h) then return {} end
    local blink = call(controller, "get_Layer_Blink")
    local lipsync = call(controller, "get_Layer_Lipsync")
    local generation = call(m, "get_SkeletonConstructCount")
    local result = {}
    for li = 0, nlayer - 1 do
        local layer = call(m, "getLayer(System.UInt32)", li)
        local count, rate = call(layer, "getRawMotionNodeCount"), call(layer, "get_BlendRate")
        local mode = call(layer, "get_BlendMode")
        if finite(count) and count >= 0 and count <= 128 and finite(rate) and rate > 0 and (mode == 0 or mode == 1) then
            local mask = masks(h, layer, li, generation, now)
            local sums = {}
            for ni = 0, math.min(count, 32) - 1 do
                local node = call(layer, "getRawMotionNode(System.UInt32)", ni)
                local weight, frame = call(node, "get_Weight"), call(node, "get_Frame")
                if finite(weight) and weight > 1e-6 and finite(frame) then
                    call(h.info, "clear")
                    if call(node, "getMotionInfo(via.motion.MotionInfo)", h.info) == true then
                        local name = call(node, "get_MotionName") or ""
                        local mirrored = call(node, "get_OutputMirrored") == true
                        local role = name:find("_blink_", 1, true) and "blink"
                            or name:find("_LipSync_", 1, true) and "lipsync" or "other"
                        -- Controller layer IDs take precedence over clip-name hints.
                        if li == blink then role = "blink" elseif li == lipsync then role = "lipsync" end
                        for _, spec in ipairs(specs) do
                            local allowed = (role ~= "blink" or eyelid(spec.name)) and (role ~= "lipsync" or mouth(spec.name))
                            if allowed then
                                local pose = sample(h, frame, spec, mirrored)
                                if pose then
                                    local flags = mask.entries[spec.hash]
                                    if flags then
                                        if flags.position == false then pose.position = nil end
                                        if flags.rotation == false then pose.rotation = nil end
                                    end
                                    local sum = sums[spec.name] or {pw = 0, qw = 0, p = {0, 0, 0}, q = {0, 0, 0, 0}}
                                    sums[spec.name] = sum
                                    if pose.position then
                                        sum.pw = sum.pw + weight
                                        for k = 1, 3 do sum.p[k] = sum.p[k] + pose.position[k]*weight end
                                    end
                                    if pose.rotation then
                                        local q = pose.rotation
                                        local sign = sum.qw > 0 and sum.q[1]*q[1]+sum.q[2]*q[2]+sum.q[3]*q[3]+sum.q[4]*q[4] < 0 and -1 or 1
                                        sum.qw = sum.qw + weight
                                        for k = 1, 4 do sum.q[k] = sum.q[k] + q[k]*weight*sign end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            for _, spec in ipairs(specs) do
                local sum = sums[spec.name]
                if sum then
                    local n = spec.neutral
                    local rest_p, rest_q = {n[1], n[2], n[3]}, {n[4], n[5], n[6], n[7]}
                    local old = result[spec.name] or {source = "animation_resource"}
                    if sum.pw > 0 then
                        -- Node weights select the layer pose; layer rate controls its contribution once.
                        local target, alpha = {}, clamp(rate)
                        local base = old.position or rest_p
                        for k = 1, 3 do
                            local v = sum.p[k]/sum.pw
                            target[k] = mode == 1 and base[k] + (v-rest_p[k])*alpha or base[k]*(1-alpha)+v*alpha
                        end
                        old.position = target
                    end
                    if sum.qw > 0 then
                        local q, alpha = normal(sum.q), clamp(rate)
                        local base = old.rotation or rest_q
                        if mode == 1 then
                            local delta = qmul({-rest_q[1], -rest_q[2], -rest_q[3], rest_q[4]}, q)
                            old.rotation = qmul(base, qblend({0, 0, 0, 1}, delta, alpha))
                        else old.rotation = qblend(base, q, alpha) end
                    end
                    result[spec.name] = old
                end
            end
        end
    end
    return result
end
local function read_native(h, controller, specs)
    if not buffers(h) then return {} end
    local blink = call(controller, "get_Layer_Blink")
    local lipsync = call(controller, "get_Layer_Lipsync")
    local selected = h.native_selected or {}
    h.native_selected = selected
    for i = #selected, 1, -1 do selected[i] = nil end
    for i, spec in ipairs(specs) do selected[i] = spec.index end
    local out, why = native().pose_read(h.native_id, h.motion:get_address(), h.info:get_address(),
        h.data:get_address(), finite(blink) and blink or -1, finite(lipsync) and lipsync or -1, selected)
    if not out then error(why or "native pose read failed") end
    local result = {}
    for i, spec in ipairs(specs) do
        local b = (i - 1) * 10
        if out[b + 1] == 1 then
            local pose = {source = "animation_resource"}
            if out[b + 2] == 1 then pose.position = {out[b + 3], out[b + 4], out[b + 5]} end
            if out[b + 6] == 1 then pose.rotation = {out[b + 7], out[b + 8], out[b + 9], out[b + 10]} end
            result[spec.name] = pose
        end
    end
    return result
end

-- largest difference between the native and the Lua read (positions, rotations up to sign)
local function difference(a, b)
    local worst, joints = 0, 0
    local names = {}
    for name in pairs(a) do names[name] = true end
    for name in pairs(b) do names[name] = true end
    for name in pairs(names) do
        joints = joints + 1
        local x, y = a[name], b[name]
        if not x or not y or (x.position == nil) ~= (y.position == nil) or (x.rotation == nil) ~= (y.rotation == nil) then
            return math.huge, joints
        end
        if x.position then
            for k = 1, 3 do worst = math.max(worst, math.abs(x.position[k] - y.position[k])) end
        end
        if x.rotation then
            local same, flip = 0, 0
            for k = 1, 4 do
                same = math.max(same, math.abs(x.rotation[k] - y.rotation[k]))
                flip = math.max(flip, math.abs(x.rotation[k] + y.rotation[k]))
            end
            worst = math.max(worst, math.min(same, flip))
        end
    end
    return worst, joints
end

-- at most every 10 s over all rigs: both paths 8 times each; the difference, the timings and the
-- reads since the last check go to trail.log
local reads, checked_reads, next_check = 0, 0, 0
local function compare(h, controller, specs, poses)
    local t0 = clock()
    for _ = 1, 8 do pcall(read_native, h, controller, specs) end
    local t1 = clock()
    local ok, lua_poses
    for _ = 1, 8 do ok, lua_poses = pcall(read, h, controller, specs) end
    local t2 = clock()
    if not ok then
        Trail.event("native pose check: Lua read failed (%s)", tostring(lua_poses))
        return
    end
    local diff, joints = difference(poses, lua_poses)
    Trail.event("native pose check: %d joints, max diff %.3g, native %.3f ms, Lua %.3f ms, %d reads since last check",
        joints, diff, (t1 - t0) * 1000 / 8, (t2 - t1) * 1000 / 8, reads - checked_reads)
    checked_reads = reads
end

function P.read(h, controller, needed)
    local specs = h.specs
    if needed then
        local selected = h.selected or {}
        h.selected = selected
        for i = #selected, 1, -1 do selected[i] = nil end
        for _, spec in ipairs(specs) do if needed[spec.name] then selected[#selected + 1] = spec end end
        specs = selected
    end
    if #specs == 0 then return {} end
    if h.native_id and native() then
        local ok, poses = pcall(read_native, h, controller, specs)
        if ok then
            reads = reads + 1
            local now = clock()
            if now >= next_check then
                next_check = now + 10
                compare(h, controller, specs, poses)
            end
            return poses
        end
        -- this rig falls back to the Lua read
        h.native_id = nil
        Trail.event("native pose read failed, using Lua: %s", tostring(poses))
    end
    local ok, poses = pcall(read, h, controller, specs)
    if not ok then
        local why = tostring(poses)
        if not h.error_seen[why] and #h.errors < 16 then h.error_seen[why] = true; h.errors[#h.errors + 1] = why end
        poses = {}
    end
    return poses
end
return P
