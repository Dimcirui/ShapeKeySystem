-- ShapeKeySystem: cached engine methods and blendshape weight writes.
-- Only changed values are written; a mesh is not written until its weight buffer exists
-- (writing earlier can freeze the game — same guard as Female Body Sliders).

local W = {}

local T_MESH = sdk.find_type_definition("via.render.Mesh")
W.M_SET   = T_MESH:get_method("setBlendShapeChannelWeightParam(System.UInt64, System.Single)")
W.M_GETW  = T_MESH:get_method("getBlendShapeChannelWeightParam(System.UInt64)")
W.M_WC    = T_MESH:get_method("get_BlendShapeChannelWeightCount")
W.M_CN    = T_MESH:get_method("get_BlendShapeChannelNum")
W.M_CNAME = T_MESH:get_method("getBlendShapeChannelName(System.UInt32)")   -- nil in Onimusha
W.M_HASHES = T_MESH:get_method("get_ChannelNameHash")   -- murmur3 of each channel's name (Onimusha)
local T_JOINT = sdk.find_type_definition("via.Joint")
W.M_LPOS  = T_JOINT:get_method("get_LocalPosition")
W.M_LROT  = T_JOINT:get_method("get_LocalRotation")
-- bone signals (Scene.bone_reads, Expression.read): world pose, parent and rest (base) pose
W.M_POS   = T_JOINT:get_method("get_Position")
W.M_ROT   = T_JOINT:get_method("get_Rotation")
W.M_JNAME = T_JOINT:get_method("get_Name")
W.M_PARENT = T_JOINT:get_method("get_Parent")
W.M_BLPOS = T_JOINT:get_method("get_BaseLocalPosition")
W.M_BLROT = T_JOINT:get_method("get_BaseLocalRotation")
W.M_BLSCL = T_JOINT:get_method("get_BaseLocalScale")
local T_TR = sdk.find_type_definition("via.Transform")
W.M_JBN   = T_TR:get_method("getJointByName(System.String)")
W.MESH_TYPE   = sdk.typeof("via.render.Mesh")
W.MOTION_TYPE = sdk.typeof("via.motion.Motion")

local abs = math.abs
local M_SET, M_WC, M_CN = W.M_SET, W.M_WC, W.M_CN

-- t = { mesh, slots = {slot...}, idxs = {channel index...}, last = {...}, count, ready }
-- vals[slot] -> weight. Returns writes, skipped.
-- base[k] (optional): sculpt rest value of channel k, mixed in by mix(base, w) unless the slot is
-- in skip (held by another plugin, written as is).
function W.write_target(t, vals, force, eps, base, mix, skip)
    if not t.ready then
        if (M_WC:call(t.mesh) or 0) < (M_CN:call(t.mesh) or 0) then return 0, 0 end
        t.ready = true
    end
    local slots, idxs, last, mesh = t.slots, t.idxs, t.last, t.mesh
    local writes, skipped = 0, 0
    for k = 1, t.count do
        local s = slots[k]
        local w = vals[s] or 0
        if base then
            local b = base[k]
            if b and b > 0 and not (skip and skip[s]) then w = mix(b, w) end
        end
        if force or abs(w - last[k]) > eps then
            -- always a float: a Lua integer (e.g. a value clamped to the integer 1 from
            -- settings.json) reaches the System.Single parameter as raw bits (1 -> 1.4e-45)
            M_SET:call(mesh, idxs[k], w + 0.0)
            last[k] = w
            writes = writes + 1
        else
            skipped = skipped + 1
        end
    end
    return writes, skipped
end

local ZERO = setmetatable({}, { __index = function() return 0.0 end })

function W.zero_target(t)
    pcall(W.write_target, t, ZERO, true, 0)
end

function W.read_weight(mesh, idx)
    local ok, v = pcall(W.M_GETW.call, W.M_GETW, mesh, idx)
    return ok and v or nil
end

return W
