-- ShapeKeySystem: RE9 native face values sampled straight from the playing facial clips.
-- The clips carry one position track per native name (value in X); a head without the matching
-- parameter joints still plays them. Layers combine as the engine does: node weights average a
-- layer, the layer rate scales it, BlendMode 1 adds and other modes override.
-- Matched the engine's own parameter joints exactly on 96 channels (2026-11-24).
local Hash = require("ShapeKeySystem_Core.NameHash")
local C = {}
local info, data
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function call(o, method, ...)
    if not o then return nil end
    local ok, v = pcall(o.call, o, method, ...)
    if ok then return v end
end
local function buffers()
    if info and data then return true end
    local ok = pcall(function()
        info = sdk.create_instance("via.motion.MotionInfo"):add_ref()
        data = sdk.create_instance("via.motion.AnimationTransformData"):add_ref()
    end)
    if not ok then info, data = nil, nil end
    return ok
end
-- mirrored clips play the other side's tracks
local function mirror(name)
    local stem, side = name:match("^(.*)_([LR])$")
    if stem then return stem .. (side == "L" and "_R" or "_L") end
    return name
end

-- names: list of native names. Returns name -> value for every name some clip animates.
function C.sample(motion, names)
    local out = {}
    if #names == 0 or not buffers() then return out end
    local layers = call(motion, "getLayerCount")
    if not finite(layers) or layers < 0 or layers > 64 then return out end
    local hashes, mirrored = {}, {}
    for i, name in ipairs(names) do hashes[i], mirrored[i] = Hash.hash(name), Hash.hash(mirror(name)) end
    for li = 0, layers - 1 do
        local layer = call(motion, "getLayer(System.UInt32)", li)
        local count, rate = call(layer, "getMotionNodeCount"), call(layer, "get_BlendRate")
        local mode = call(layer, "get_BlendMode")
        if finite(count) and count > 0 and count <= 128 and finite(rate) and rate > 0 then
            local sum, weight = {}, {}
            for ni = 0, math.min(count, 32) - 1 do
                local node = call(layer, "getMotionNode(System.UInt32)", ni)
                local w, frame = call(node, "get_Weight"), call(node, "get_Frame")
                if finite(w) and w > 1e-6 and finite(frame) then
                    call(info, "clear")
                    if call(node, "getMotionInfo(via.motion.MotionInfo)", info) == true then
                        local flip = call(node, "get_OutputMirrored") == true
                        for i, name in ipairs(names) do
                            call(data, "clear")
                            if call(info, "getAnimationTransform(System.UInt32, System.Single, via.motion.AnimationTransformData)",
                                    flip and mirrored[i] or hashes[i], frame + 0.0, data) == true
                                and call(data, "get_ValidPosition") == true then
                                local p = call(data, "get_Position")
                                local x = p and p.x
                                if finite(x) then
                                    sum[name] = (sum[name] or 0) + x * w
                                    weight[name] = (weight[name] or 0) + w
                                end
                            end
                        end
                    end
                end
            end
            local a = math.max(0, math.min(1, rate))
            for name, total in pairs(sum) do
                local v = total / weight[name]
                local base = out[name] or 0
                out[name] = mode == 1 and base + v * a or base * (1 - a) + v * a
            end
        end
    end
    return out
end
return C
