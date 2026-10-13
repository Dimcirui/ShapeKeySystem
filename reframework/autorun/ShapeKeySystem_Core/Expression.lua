-- ShapeKeySystem: per-frame signal reading and expression weight computation for one rig.

local W = require("ShapeKeySystem_Core.Writer")

local X = {}

-- name: Chinese (default UI language), name_en: English (I18n.field picks by settings.language)
X.REGIONS = {
    { key = "brow",       name = "眉",    name_en = "Brows" },
    { key = "eye",        name = "眼",    name_en = "Eyes" },
    { key = "nose_cheek", name = "鼻·颊", name_en = "Nose & cheeks" },
    { key = "mouth",      name = "嘴",    name_en = "Mouth" },
}
-- group key -> region key (nil = not in a region: gaze uses gaze_gain, extra only master gain)
X.GROUPS = {
    { key = "brow",       name = "眉",    name_en = "Brows",         region = "brow" },
    { key = "eye",        name = "眼",    name_en = "Eyes",          region = "eye" },
    { key = "gaze",       name = "视线",  name_en = "Gaze" },
    { key = "nose_cheek", name = "鼻·颊", name_en = "Nose & cheeks", region = "nose_cheek" },
    { key = "mouth",      name = "嘴",    name_en = "Mouth",         region = "mouth" },
    { key = "jaw",        name = "下颌",  name_en = "Jaw",           region = "mouth" },
    { key = "tongue",     name = "舌",    name_en = "Tongue",        region = "mouth" },
    { key = "extra",      name = "扩展",  name_en = "Extra" },
}
X.REGION_OF = {}
for _, g in ipairs(X.GROUPS) do X.REGION_OF[g.key] = g.region end

local M_LPOS, M_LROT = W.M_LPOS, W.M_LROT
local deg, atan, asin = math.deg, math.atan, math.asin

-- Eye joint local rotation -> SKS gaze convention (+yaw = the face's own right, +pitch = up), the
-- same one gaze_hold and the profiles' `sign` use. RE Engine is right-handed, Y up, face toward +Z
-- (+X = the face's left), so a positive turn about +Y looks left and about +X looks down: both negated.
local function quat_to_yaw_pitch(q)
    local pitch = deg(atan(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y)))
    local s = 2 * (q.w * q.y - q.z * q.x)
    if s > 1 then s = 1 elseif s < -1 then s = -1 end
    return -deg(asin(s)), -pitch
end

-- Bone signals (Profile.BONE_BASE ids), past the idle offset `off`, times sign, over full, past the
-- deadzone, within 0..1:
--   pos: the bone's position in the head's frame against its rest pose, along the signal's axis
--        (a bone without a rest pose takes its first reading as rest);
--   rot: the bone's local turn (degrees) about its own axis against its base rotation.
-- bones = Scene.bone_reads result.
local M_POS, M_ROT = W.M_POS, W.M_ROT
local atan2 = math.atan
local function twist_deg(q, r, axis)
    -- d = conj(r) * q: the turn on top of the base rotation, in the joint's own frame
    local rx, ry, rz, rw = -r[1], -r[2], -r[3], r[4]
    local dw = rw * q.w - rx * q.x - ry * q.y - rz * q.z
    local d = { rw * q.x + rx * q.w + ry * q.z - rz * q.y,
                rw * q.y - rx * q.z + ry * q.w + rz * q.x,
                rw * q.z + rx * q.y - ry * q.x + rz * q.w }
    if dw < 0 then dw = -dw; d[axis] = -d[axis] end
    return deg(2 * atan2(d[axis], dw))
end
local function read_bones(bones, P)
    if #bones.list == 0 then return end
    local head = bones.head
    local hp, hq = head and M_POS:call(head), head and M_ROT:call(head)
    local qx, qy, qz, qw
    if hq then qx, qy, qz, qw = -hq.x, -hq.y, -hq.z, hq.w end
    for _, b in ipairs(bones.list) do
        local val
        if b.kind == "rot" then
            local q = M_LROT:call(b.j)
            if q then val = b.sign * (twist_deg(q, b.rest, b.axis) - b.off) / b.full end
        elseif hp and hq then
            local p = M_POS:call(b.j)
            if p then
                local x, y, z = p.x - hp.x, p.y - hp.y, p.z - hp.z
                local tx, ty, tz = 2 * (qy * z - qz * y), 2 * (qz * x - qx * z), 2 * (qx * y - qy * x)
                local v = { x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx) }
                if not b.rest then b.rest, b.off = v, 0 end   -- a first reading is already the idle face
                val = b.sign * (v[b.axis] - b.rest[b.axis] - b.off) / b.full
            end
        end
        if val then
            if b.deadzone > 0 then val = (val - b.deadzone) / (1 - b.deadzone) end
            P[b.id] = val <= 0 and 0 or (val < 1 and val or 1)   -- past calibration stays at full
        end
    end
end

-- Read fcParams into P (normalised by full), bone signals into P and eye angles into rig.angles.
-- eyes = state.eyes (neutral / invert); read_eyes = profile has eye nodes.
function X.read(rig, P, inv_full, use_dict, eyes, read_eyes)
    local params = use_dict and rig.dict_params or rig.params
    for k = 1, #params, 2 do
        local p = M_LPOS:call(params[k + 1])
        P[params[k]] = p and p.z * inv_full or 0
    end
    local bones = use_dict and rig.dict_bones or rig.bones
    if bones then read_bones(bones, P) end
    if not read_eyes then return end
    local ang = rig.angles
    local iy = eyes.invert.yaw and -1 or 1
    local ip = eyes.invert.pitch and -1 or 1
    for side, j in pairs(rig.eyes) do
        if j then
            local q = M_LROT:call(j)
            if q then
                local yaw, pitch = quat_to_yaw_pitch(q)
                local n = eyes.neutral[side]
                local a = ang[side]
                a[1] = (yaw - n.yaw) * iy
                a[2] = (pitch - n.pitch) * ip
            end
        end
    end
end

-- Evaluate the compiled profile into rig.W.
--   gains[slot] = effective multiplier (channel × region/gaze × master; 0 disables)
--   forced[slot] = true -> 1.0
--   alpha = smoothing blend factor (1 = no smoothing)
local ctx = { P = nil, A = nil, V = nil, fy = 25, fp = 20 }
function X.compute(prog, rig, P, gains, forced, clamp, alpha, fy, fp)
    local V, Wt = rig.V, rig.W
    ctx.P, ctx.A, ctx.V, ctx.fy, ctx.fp = P, rig.angles, V, fy, fp
    local chans = prog.channels
    local order = prog.order
    for i = 1, #order do
        local s = order[i]
        V[s] = chans[s].fn(ctx)
    end
    for s = 1, prog.n do
        local w
        if forced[s] then
            w = 1.0
        else
            w = (V[s] or 0) * gains[s]
            if clamp then w = (w < 0) and 0 or ((w > 1) and 1 or w) end
            if alpha < 1 then
                local prev = Wt[s]
                if prev then w = prev + (w - prev) * alpha end
            end
        end
        Wt[s] = w
    end
end

return X
