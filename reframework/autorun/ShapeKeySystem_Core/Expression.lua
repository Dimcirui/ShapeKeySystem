-- ShapeKeySystem: per-frame signal reading and expression weight computation for one rig.

local W = require("ShapeKeySystem_Core.Writer")

local X = {}

X.REGIONS = {
    { key = "brow",       name = "眉" },
    { key = "eye",        name = "眼" },
    { key = "nose_cheek", name = "鼻·颊" },
    { key = "mouth",      name = "嘴" },
}
-- group key -> region key (nil = not in a region: gaze uses gaze_gain, extra only master gain)
X.GROUPS = {
    { key = "brow",       name = "眉",    region = "brow" },
    { key = "eye",        name = "眼",    region = "eye" },
    { key = "gaze",       name = "视线" },
    { key = "nose_cheek", name = "鼻·颊", region = "nose_cheek" },
    { key = "mouth",      name = "嘴",    region = "mouth" },
    { key = "jaw",        name = "下颌",  region = "mouth" },
    { key = "tongue",     name = "舌",    region = "mouth" },
    { key = "extra",      name = "扩展" },
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

-- Read fcParams into P (normalised by full) and eye angles into rig.angles.
-- eyes = state.eyes (neutral / invert); read_eyes = profile has eye nodes.
function X.read(rig, P, inv_full, use_dict, eyes, read_eyes)
    local params = use_dict and rig.dict_params or rig.params
    for k = 1, #params, 2 do
        local p = M_LPOS:call(params[k + 1])
        P[params[k]] = p and p.z * inv_full or 0
    end
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
