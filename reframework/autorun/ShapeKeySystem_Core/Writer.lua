-- ShapeKeySystem: cached engine methods and blendshape weight writes.
-- Changed values are written; adapters may also request active values every frame.
-- A mesh is not written until its weight buffer exists
-- (writing earlier can freeze the game — same guard as Female Body Sliders).

local W = {}
W.adapter = {}

local T_MESH = sdk.find_type_definition("via.render.Mesh")
W.M_SET   = T_MESH:get_method("setBlendShapeChannelWeightParam(System.UInt64, System.Single)")
    or T_MESH:get_method("setBlendShapeChannelWeightParam(System.UInt32, System.Single)")
    or T_MESH:get_method("setBlendShapeChannelWeightParam(System.Int32, System.Single)")
W.M_GETW  = T_MESH:get_method("getBlendShapeChannelWeightParam(System.UInt64)")
    or T_MESH:get_method("getBlendShapeChannelWeightParam(System.UInt32)")
    or T_MESH:get_method("getBlendShapeChannelWeightParam(System.Int32)")
W.M_WC    = T_MESH:get_method("get_BlendShapeChannelWeightCount")
W.M_CN    = T_MESH:get_method("get_BlendShapeChannelNum")
W.M_CNAME = T_MESH:get_method("getBlendShapeChannelName(System.UInt32)")
local T_JOINT = sdk.find_type_definition("via.Joint")
W.M_LPOS  = T_JOINT:get_method("get_LocalPosition")
W.M_LROT  = T_JOINT:get_method("get_LocalRotation")
local T_TR = sdk.find_type_definition("via.Transform")
W.M_JBN   = T_TR:get_method("getJointByName(System.String)")
W.MESH_TYPE   = sdk.typeof("via.render.Mesh")
W.MOTION_TYPE = sdk.typeof("via.motion.Motion")

local abs = math.abs
local M_SET, M_WC, M_CN = W.M_SET, W.M_WC, W.M_CN

-- Strict adapters require the live managed list as well as WeightCount; failures deny access.
function W.limit(mesh)
    local ok, n = pcall(function()
        local cn, wc = M_CN:call(mesh), M_WC:call(mesh)
        if type(cn) ~= "number" or type(wc) ~= "number" or cn ~= cn or wc ~= wc
            or cn < 0 or wc < 0 or cn == math.huge or wc == math.huge then return 0 end
        local limit = math.min(cn, wc)
        if W.adapter.strict_bounds then
            local list = mesh:call("get_ChannelWeightList")
            local length = list and list:call("get_Length")
            if type(length) ~= "number" or length ~= length or length < 0 or length == math.huge then return 0 end
            limit = math.min(limit, length)
        end
        return limit == limit and math.max(0, math.floor(limit)) or 0
    end)
    return ok and n or 0
end

function W.set_weight(mesh, idx, value, name)
    if W.adapter.strict_bounds then
        if idx < 0 or idx >= W.limit(mesh) then return false end
        if W.adapter.channel_writable and not W.adapter.channel_writable(name, mesh, idx) then return false end
    end
    M_SET:call(mesh, idx, value + 0.0)
    return true
end

-- t = { mesh, slots = {slot...}, idxs = {channel index...}, last = {...}, count, ready }
-- vals[slot] -> weight. Returns writes, skipped.
-- base[k] (optional): sculpt rest value of channel k, mixed in by mix(base, w) unless the slot is
-- in skip (held by another plugin, written as is).
function W.write_target(t, vals, force, eps, base, mix, skip)
    if W.adapter.strict_bounds and
        (W.limit(t.mesh) < (t.channels or 0) or M_CN:call(t.mesh) ~= t.channels) then
        t.ready, t.stable = false, 0
        return 0, t.count
    end
    if not t.ready then
        local wc = (M_WC:call(t.mesh) or 0)
        local cn = (M_CN:call(t.mesh) or 0)
        if wc < cn then
            pcall(t.mesh.call, t.mesh, "set_BlendShapeEnable", true)
            pcall(t.mesh.call, t.mesh, "set_BlendShapeChannelWeightCount", cn)
            wc = (M_WC:call(t.mesh) or 0)
        end
        if wc < cn then return 0, 0 end
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
        -- Some games refresh animated weights each frame: keep active values asserted.
        local active = W.adapter.rewrite_active_weights and (w ~= 0 or last[k] ~= 0)
        if force or active or abs(w - last[k]) > eps then
            -- always a float: a Lua integer (e.g. a value clamped to the integer 1 from
            -- settings.json) reaches the System.Single parameter as raw bits (1 -> 1.4e-45)
            if W.set_weight(mesh, idxs[k], w, t.names and t.names[idxs[k] + 1]) then
                last[k] = w
                writes = writes + 1
            end
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
    if W.adapter.strict_bounds and (idx < 0 or idx >= W.limit(mesh)) then return nil end
    local ok, v = pcall(W.M_GETW.call, W.M_GETW, mesh, idx)
    return ok and v or nil
end

return W
