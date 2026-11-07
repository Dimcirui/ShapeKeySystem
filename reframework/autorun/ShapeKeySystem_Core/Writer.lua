-- ShapeKeySystem: cached engine methods and blendshape weight writes.
-- Changed values are written; adapters may also request active values every frame.
-- A mesh is not written until its weight buffer exists
-- (writing earlier can freeze the game — same guard as Female Body Sliders).

local W = {}
W.adapter = {}

local T_MESH = sdk.find_type_definition("via.render.Mesh")
W.M_SET   = T_MESH:get_method("setBlendShapeChannelWeightParam(System.UInt64, System.Single)")
W.M_GETW  = T_MESH:get_method("getBlendShapeChannelWeightParam(System.UInt64)")
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

-- With ShapeKeySystem_Native.dll (adapters with `native_write`) a batch queues its writes and
-- W.flush hands them to the plugin in one call; without it every write goes out at once.
local function native_writer()
    if not W.adapter.native_write then return nil end
    local n = rawget(_G, "sks_native")
    return type(n) == "table" and type(n.write_weights) == "function" and n or nil
end

-- The context is local to one write invocation and never survives an engine callback.
-- Adapters without strict bounds get a batch only to queue writes for the plugin.
function W.begin_batch(mesh)
    local native = native_writer()
    if not (W.adapter.batch_weights and W.adapter.strict_bounds) and not native then return nil end
    local context = W.adapter.write_context and W.adapter.write_context(mesh)
    local hashes = type(context) == "table" and context.hashes
    local ok, stamp = pcall(function() return hashes and hashes:get_address() end)
    return {mesh = mesh, limit = W.limit(mesh), context = context, stamp = ok and stamp or nil,
        native = native, idx = native and {}, val = native and {}, n = 0}
end

-- Whether a channel may be written does not change while the mesh keeps its channel name list
-- (the batch's stamp); the adapter's check reads the channel's name hash from the engine, so it is
-- asked once per channel. Writes outside a batch ask every time.
local writable_cache = setmetatable({}, { __mode = "k" })
local function writable(mesh, idx, name, batch)
    if not (batch and batch.stamp) then return W.adapter.channel_writable(name, mesh, idx, batch and batch.context) end
    local known = writable_cache[mesh]
    if not known or known.stamp ~= batch.stamp then known = {stamp = batch.stamp}; writable_cache[mesh] = known end
    local v = known[idx]
    if v == nil then
        v = W.adapter.channel_writable(name, mesh, idx, batch and batch.context) and true or false
        known[idx] = v
    end
    return v
end

function W.set_weight(mesh, idx, value, name, batch)
    if W.adapter.strict_bounds then
        local limit = batch and batch.mesh == mesh and batch.limit or W.limit(mesh)
        if idx < 0 or idx >= limit then return false end
        if W.adapter.channel_writable and not writable(mesh, idx, name, batch) then return false end
    end
    if batch and batch.native and batch.mesh == mesh then
        local n = batch.n + 1
        batch.n, batch.idx[n], batch.val[n] = n, idx, value + 0.0
        return true
    end
    M_SET:call(mesh, idx, value + 0.0)
    return true
end

-- Sends the writes a batch queued; when the plugin call fails they are written one by one.
function W.flush(batch)
    if not batch or not batch.native or batch.n == 0 then return end
    local n = batch.n
    batch.n = 0
    local ok, written = pcall(batch.native.write_weights, batch.mesh:get_address(), batch.idx, batch.val, n)
    if ok and written then return end
    for i = 1, n do pcall(M_SET.call, M_SET, batch.mesh, batch.idx[i], batch.val[i]) end
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
        if (M_WC:call(t.mesh) or 0) < (M_CN:call(t.mesh) or 0) then return 0, 0 end
        t.ready = true
    end
    local slots, idxs, last, mesh = t.slots, t.idxs, t.last, t.mesh
    local writes, skipped = 0, 0
    local batch
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
            if W.adapter.batch_weights or W.adapter.native_write then batch = batch or W.begin_batch(mesh) end
            if W.set_weight(mesh, idxs[k], w, t.names and t.names[idxs[k] + 1], batch) then
                last[k] = w
                writes = writes + 1
            end
        else
            skipped = skipped + 1
        end
    end
    W.flush(batch)
    return writes, skipped
end

local ZERO = setmetatable({}, { __index = function() return 0.0 end })

function W.zero_target(t)
    pcall(W.write_target, t, ZERO, true, 0)
end

function W.read_weight(mesh, idx, batch)
    local limit = batch and batch.mesh == mesh and batch.limit
    if W.adapter.strict_bounds and (idx < 0 or idx >= (limit or W.limit(mesh))) then return nil end
    local ok, v = pcall(W.M_GETW.call, W.M_GETW, mesh, idx)
    return ok and v or nil
end

return W
