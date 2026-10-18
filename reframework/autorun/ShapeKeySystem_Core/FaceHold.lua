-- ShapeKeySystem: holds a face's expression bones at its neutral pose, so the game's facial
-- animation no longer moves them while shape keys carry the expression.
--
-- The neutral pose is captured, not taken from the skeleton: character creation offsets the face
-- joints from their base pose. Capture mutes every motion layer of the face for a few frames,
-- reads the unanimated pose and restores the layers; fcParam reads 0 meanwhile, so the caller
-- skips its expression writes while `H.capturing()` is true.
--
-- Constraints:
-- - `H.update` runs after UpdateMotion (the slot where joint writes reach the rendered pose).
-- - Adapter interface: `expression_joints(face)` -> { { joint, name }, ... } (eyeballs excluded:
--   gaze is read from them) and `face_layers(face)` -> { TreeLayer, ... }.
-- - Joint and layer references live only as long as the caller's rigs: `H.release` drops them
--   and restores any layer still muted by an unfinished capture.
local H = {}

local SETTLE = 2       -- frames muted before the first sample
local MAX_WAIT = 12    -- a pose still moving after this many frames is accepted as it is
local EPS = 1e-5

local M_GPOS, M_GROT, M_SPOS, M_SROT
local function methods()
    if M_GPOS then return end
    local t = sdk.find_type_definition("via.Joint")
    M_GPOS, M_GROT = t:get_method("get_LocalPosition"), t:get_method("get_LocalRotation")
    M_SPOS, M_SROT = t:get_method("set_LocalPosition"), t:get_method("set_LocalRotation")
end

-- faces[address] = { phase = "capture" | "hold" | "failed", joints, pos, rot, layers, rates, wait }
local faces = {}
-- joint names whose animated pose readers still need (`H.watch`); pre[address][name] = { pos, rot }
local watched, pre = {}, {}
H.status = ""

function H.watch(names)
    for _, n in ipairs(names) do watched[n] = true end
end

-- The animated pose of a watched joint as it was before this frame's hold; nil when not held.
function H.pose(face_addr, name)
    local p = pre[face_addr]
    p = p and p[name]
    if p then return p[1], p[2] end
    return nil
end

local function set_rates(e, muted)
    for i, layer in ipairs(e.layers) do
        pcall(layer.call, layer, "set_BlendRate(System.Single)", muted and 0.0 or (e.rates[i] + 0.0))
    end
end

local function snapshot(e)
    local pos, rot = {}, {}
    for i, j in ipairs(e.joints) do
        pos[i], rot[i] = M_GPOS:call(j.joint), M_GROT:call(j.joint)
    end
    return pos, rot
end

local function same(a, b)
    for i = 1, #a do
        local p, q = a[i], b[i]
        if math.abs(p.x - q.x) > EPS or math.abs(p.y - q.y) > EPS or math.abs(p.z - q.z) > EPS then return false end
    end
    return true
end

local function start(adapter, face)
    local e = { phase = "failed", wait = 0 }
    local ok, joints = pcall(adapter.expression_joints, face)
    local ok2, layers = pcall(adapter.face_layers, face)
    if not ok or not ok2 or type(joints) ~= "table" or #joints == 0 or type(layers) ~= "table" then
        H.status = "找不到面部表情骨骼"
        return e
    end
    e.joints, e.layers, e.rates = joints, layers, {}
    for i, layer in ipairs(layers) do
        local okr, r = pcall(layer.call, layer, "get_BlendRate")
        e.rates[i] = okr and tonumber(r) or 1.0
    end
    set_rates(e, true)
    e.phase = "capture"
    H.status = "正在读取中性脸"
    return e
end

local function capture(e)
    e.wait = e.wait + 1
    if e.wait < SETTLE then return end
    local pos, rot = snapshot(e)
    local settled = e.pos and same(e.pos, pos) and same(e.rot, rot)
    e.pos, e.rot = pos, rot
    if settled or e.wait >= MAX_WAIT then
        set_rates(e, false)
        e.layers, e.rates = nil, nil
        e.phase = "hold"
        H.status = string.format("已禁用 %d 根表情骨骼", #e.joints)
    end
end

local function hold(e, addr)
    local p = pre[addr]
    if not p then p = {}; pre[addr] = p end
    local pos, rot = e.pos, e.rot
    for i, j in ipairs(e.joints) do
        local jt = j.joint
        if watched[j.name] then p[j.name] = { M_GPOS:call(jt), M_GROT:call(jt) } end
        M_SPOS:call(jt, pos[i])
        M_SROT:call(jt, rot[i])
    end
end

-- Holds every face in `list` (transforms); faces not in the list are let go.
function H.update(adapter, list)
    if not adapter.expression_joints or not adapter.face_layers then
        H.status = "本游戏暂不支持禁用骨骼表情"
        return
    end
    methods()
    local seen = {}
    for _, face in ipairs(list) do
        local addr = face:get_address()
        seen[addr] = true
        local e = faces[addr]
        if not e then e = start(adapter, face); faces[addr] = e end
        if e.phase == "capture" then capture(e)
        elseif e.phase == "hold" then hold(e, addr) end
    end
    for addr, e in pairs(faces) do
        if not seen[addr] then
            if e.phase == "capture" then set_rates(e, false) end
            faces[addr], pre[addr] = nil, nil
        end
    end
end

function H.capturing()
    for _, e in pairs(faces) do if e.phase == "capture" then return true end end
    return false
end

function H.active()
    return next(faces) ~= nil
end

function H.release()
    for _, e in pairs(faces) do
        if e.phase == "capture" then set_rates(e, false) end
    end
    faces, pre = {}, {}
end

return H
