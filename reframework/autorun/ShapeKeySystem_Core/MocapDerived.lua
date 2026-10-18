-- ShapeKeySystem: profile channels built from ARKit channels, re-evaluated from the mocap values.
--
-- Mocap holds the 52 ARKit keys as External leases, which replace the written weight but not the
-- expression value V that `ref` nodes read. A channel such as eyeWideLeft_BlinkFix =
-- mul(ref eyeWideLeft, ref eyeBlinkLeft) would otherwise keep following the game's own facial
-- signals while the eyelids follow the phone. Each such channel is evaluated again here with the
-- mocap values as its ref inputs and held under the mocap owner too, so the profile stays the
-- only place a corrective is defined.
--
-- Rules:
-- - Only channels whose node uses nothing but ref / const / sum / mul / max / min / sub, and whose
--   refs lead (directly or through other such channels) to at least one mocap-held slot. A channel
--   that also reads a game signal, raw channel or eye angle keeps its game-driven value.
-- - ref reads the mocap value before gains (neutral removed, smoothed, 0..1), as ref in a profile
--   reads a channel before its gains; the result is then scaled by the mocap master gain.

local U = require("ShapeKeySystem_Core.Util")
local Ext = require("ShapeKeySystem_Core.External")

local D = {}

local PURE_OPS = { "sum", "mul", "max", "min", "sub" }

-- node built only from refs, constants and their combinations; returns the ref names or nil
local function pure_refs(node, out)
    if type(node) ~= "table" then return nil end
    if node.ref ~= nil then out[#out + 1] = node.ref; return out end
    if node.const ~= nil then return out end
    for _, op in ipairs(PURE_OPS) do
        local list = node[op]
        if list ~= nil then
            if type(list) ~= "table" then return nil end
            for _, sub in ipairs(list) do
                if not pure_refs(sub, out) then return nil end
            end
            return out
        end
    end
    return nil
end
D.pure_refs = pure_refs

-- slots evaluable from the mocap values, in the profile's evaluation order.
-- held[slot] = true for slots mocap holds directly.
function D.plan(prog, held)
    local ok = {}   -- slot -> true (evaluable), false (not)
    local list = {}
    for _, s in ipairs(prog.order or {}) do
        local c = prog.channels[s]
        if not held[s] and c and c.node then
            local refs = pure_refs(c.node, {})
            local good, reach = refs ~= nil and #refs > 0, false
            for _, name in ipairs(refs or {}) do
                local d = prog.slot_of[name]
                if d and held[d] then reach = true
                elseif d and ok[d] then reach = true   -- refs come first in prog.order
                elseif d and prog.channels[d] and prog.channels[d].fn then good = false
                end
                -- a ref to a channel without a node reads 0 in Core as well
            end
            ok[s] = good and reach
            if ok[s] then list[#list + 1] = s end
        end
    end
    return list
end

local st = { key = nil, list = {}, names = {} }
local V = {}
local ctx = { V = V, P = {}, A = { L = { 0, 0 }, R = { 0, 0 } }, fy = 25, fp = 20 }

-- Hold every derived channel of prog under owner. slots[i] = expression slot of mocap channel i
-- (false when the profile lacks it), pre[i] = its value before gains, f = fade (0..1),
-- expr = pure expression weights by slot (mixed in while fading). Returns the number held.
function D.hold(owner, prog, key, slots, pre, gain, f, expr)
    if not prog then D.release(owner); return 0 end
    if st.key ~= key then
        local held = {}
        for i = 1, #pre do if slots[i] then held[slots[i]] = true end end
        local list = D.plan(prog, held)
        local names = {}
        for _, s in ipairs(list) do names[prog.names[s]] = true end
        for name in pairs(st.names) do
            if not names[name] then Ext.release(owner, name) end
        end
        st.key, st.list, st.names = key, list, names
    end
    for k in pairs(V) do V[k] = nil end
    for i = 1, #pre do
        local s = slots[i]
        if s then V[s] = pre[i] end
    end
    local chans = prog.channels
    for _, s in ipairs(st.list) do
        local v = chans[s].fn(ctx)
        V[s] = v
        local w = U.clamp(v * gain, 0, 1)
        local e = expr[s] or 0
        Ext.set(owner, prog.names[s], (w * f + e * (1 - f)) + 0.0, Ext.DEFAULT_TTL)
    end
    return #st.list
end

-- forget the plan (the caller released the owner's leases)
function D.reset()
    st.key, st.list, st.names = nil, {}, {}
end

function D.release(owner)
    local any = false
    for name in pairs(st.names) do
        if Ext.release(owner, name) then any = true end
    end
    D.reset()
    return any
end

return D
