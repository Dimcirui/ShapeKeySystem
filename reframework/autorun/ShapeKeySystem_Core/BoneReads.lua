-- ShapeKeySystem: bone signals, face joint motion read as named dictionary signals.
--
-- An adapter's calibration table lists one signal per name, read as raw channel `bone.<name>`:
--   pos: the joint's position in the Head joint's frame against its rest pose (the base local pose
--        composed up to Head), along `axis` (+x = the face's left, +y = up, +z = forward), over
--        full_mm;
--   rot: the joint's local turn about its own `rot_axis` against its base rotation, over full_deg.
-- rest_mm / rest_deg is where the idle face holds the joint, so idle reads 0. Value =
-- sign * (offset - rest) / full, past the deadzone, within 0..1.
--
-- Constraints:
-- - Raw keys are BASE + index in the table, above every adapter's own raw keys, so P and the
--   profile's raw key list hold both kinds.
-- - While FaceHold holds the face the joints read neutral; positions are then composed from the
--   held animated local poses (`FaceHold.pose`) instead of the world pose.
-- - Handles hold joint references and belong to a rig; they are dropped with it.

local FaceHold = require("ShapeKeySystem_Core.FaceHold")
local L = require("ShapeKeySystem_Core.I18n")

local R = { BASE = 1000 }

local AXES = { x = 1, y = 2, z = 3 }
local atan2, deg = math.atan, math.deg

local M

local function methods()
    if M then return M end
    local t = sdk.find_type_definition("via.Joint")
    M = {}
    for k, name in pairs({ pos = "get_Position", rot = "get_Rotation", lpos = "get_LocalPosition",
                           lrot = "get_LocalRotation", lscl = "get_LocalScale", name = "get_Name",
                           parent = "get_Parent", bpos = "get_BaseLocalPosition",
                           brot = "get_BaseLocalRotation", bscl = "get_BaseLocalScale" }) do
        M[k] = t:get_method(name)
    end
    return M
end

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end

-- Returns { list, by_name } from a calibration table (name -> entry), or nil and a reason; an absent
-- table is an empty list. label prefixes the messages.
function R.load(data, label)
    label = label and L.tr(label) or ""
    local out = { list = {}, by_name = {} }
    if data == nil then return out end
    if type(data) ~= "table" then return nil, L.f("%s骨骼信号表无效", label) end
    local names = {}
    for name in pairs(data) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local e = data[name]
        local pos = type(e) == "table" and AXES[e.axis] and finite(e.full_mm) and e.full_mm ~= 0
        local rot = type(e) == "table" and AXES[e.rot_axis] and finite(e.full_deg) and e.full_deg ~= 0
        if type(e.bone) ~= "string" or not (pos or rot) then return nil, L.f("%s骨骼信号无效：%s", label, tostring(name)) end
        local sig = { name = name, bone = e.bone, kind = pos and "pos" or "rot",
                      axis = pos and AXES[e.axis] or AXES[e.rot_axis],
                      full = pos and e.full_mm / 1000 or e.full_deg,
                      rest = pos and (tonumber(e.rest_mm) or 0) / 1000 or (tonumber(e.rest_deg) or 0),
                      sign = (tonumber(e.sign) or 1) < 0 and -1 or 1,
                      deadzone = math.max(0, math.min(0.95, tonumber(e.deadzone) or 0)) }
        out.list[#out.list + 1] = sig
        sig.key = R.BASE + #out.list
        out.by_name[name] = sig
    end
    return out
end

-- `bone.<name>` -> raw key; nil and a reason for an unknown name. Not a `bone.` string: nil, nil.
function R.parse(sigs, v)
    if type(v) ~= "string" or v:find("bone.", 1, true) ~= 1 then return nil, nil end
    local sig = sigs and sigs.by_name[v:sub(6)]
    if not sig then return nil, L.f("未知骨骼信号：%s", v) end
    return sig.key
end

-- Raw key -> "bone.<name>"; nil below BASE.
function R.label(sigs, key)
    if key <= R.BASE then return nil end
    local sig = sigs and sigs.list[key - R.BASE]
    return "bone." .. (sig and sig.name or "?")
end

local function qrot(q, x, y, z, inverse)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    if inverse then qx, qy, qz = -qx, -qy, -qz end
    local tx, ty, tz = 2 * (qy * z - qz * y), 2 * (qz * x - qx * z), 2 * (qx * y - qy * x)
    return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
end

-- Joints from `j` up to (not including) Head; nil when Head is not above it.
local function chain_of(j)
    local m, chain, node = methods(), {}, j
    for _ = 1, 32 do
        if not node then return nil end
        local name = m.name:call(node)
        if name == "Head" then return chain end
        chain[#chain + 1] = { joint = node, name = name }
        node = m.parent:call(node)
    end
    return nil
end

-- Position in the Head's frame composed from per-joint local poses; get(node) -> pos, rot, scale.
local function compose(chain, get)
    local x, y, z = 0, 0, 0
    for _, n in ipairs(chain) do
        local p, q, s = get(n)
        if not p or not q then return nil end
        if s then x, y, z = x * s.x, y * s.y, z * s.z end
        x, y, z = qrot(q, x, y, z)
        x, y, z = x + p.x, y + p.y, z + p.z
    end
    return { x, y, z }
end

-- The turn about `axis` of rotation q on top of base rotation r ({x, y, z, w}), in degrees.
local function twist_deg(q, r, axis)
    local rx, ry, rz, rw = -r[1], -r[2], -r[3], r[4]
    local dw = rw * q.w - rx * q.x - ry * q.y - rz * q.z
    local d = { rw * q.x + rx * q.w + ry * q.z - rz * q.y,
                rw * q.y - rx * q.z + ry * q.w + rz * q.x,
                rw * q.z + rx * q.y - ry * q.x + rz * q.w }
    if dw < 0 then dw = -dw; d[axis] = -d[axis] end
    return deg(2 * atan2(d[axis], dw))
end

-- Returns a handle for the signals in `keys` that this face has, or nil when none.
function R.bind(face, keys, sigs, jbn)
    if not sigs or #sigs.list == 0 then return nil end
    local m = methods()
    local head, list, watch = nil, {}, {}
    for _, key in ipairs(keys) do
        local sig = sigs.list[key - R.BASE]
        if sig then
            head = head or jbn(face, "Head")
            local j = head and jbn(face, sig.bone)
            if j then
                local b = { key = key, sig = sig, j = j }
                if sig.kind == "rot" then
                    local ok, q = pcall(m.brot.call, m.brot, j)
                    b.rest = ok and q and { q.x, q.y, q.z, q.w } or nil
                    watch[#watch + 1] = sig.bone
                else
                    local ok, chain = pcall(chain_of, j)
                    b.chain = ok and chain or nil
                    if b.chain then
                        b.rest = compose(b.chain, function(n)
                            return m.bpos:call(n.joint), m.brot:call(n.joint), m.bscl and m.bscl:call(n.joint)
                        end)
                        for _, n in ipairs(b.chain) do watch[#watch + 1] = n.name end
                    end
                end
                if b.rest or sig.kind == "pos" then list[#list + 1] = b end
            end
        end
    end
    if #list == 0 then return nil end
    FaceHold.watch(watch)
    return { head = head, list = list, addr = face:get_address() }
end

local function value(b, v)
    if not v then return nil end
    if b.sig.deadzone > 0 then v = (v - b.sig.deadzone) / (1 - b.sig.deadzone) end
    return v <= 0 and 0 or (v < 1 and v or 1)
end

-- Writes each bound signal's 0..1 value into P[key]; a joint that cannot be read leaves its key.
function R.read(h, P)
    local m = methods()
    local held = FaceHold.active()
    local hp, hq
    if not held then hp, hq = m.pos:call(h.head), m.rot:call(h.head) end
    local function local_pose(n)
        local p, q = FaceHold.pose(h.addr, n.name)
        if not p then p, q = m.lpos:call(n.joint), m.lrot:call(n.joint) end
        return p, q, m.lscl and m.lscl:call(n.joint)
    end
    for _, b in ipairs(h.list) do
        local s, v = b.sig, nil
        if s.kind == "rot" then
            local q = held and select(2, FaceHold.pose(h.addr, s.bone)) or nil
            q = q or m.lrot:call(b.j)
            if q then v = s.sign * (twist_deg(q, b.rest, s.axis) - s.rest) / s.full end
        else
            local at
            if held then
                at = b.chain and compose(b.chain, local_pose)
            elseif hp and hq then
                local p = m.pos:call(b.j)
                if p then at = { qrot(hq, p.x - hp.x, p.y - hp.y, p.z - hp.z, true) } end
            end
            if at then
                -- without a rest pose the first reading, the idle face, is the rest
                if not b.rest then b.rest, b.off = at, 0 end
                local off = b.off or s.rest
                v = s.sign * (at[s.axis] - b.rest[s.axis] - off) / s.full
            end
        end
        v = value(b, v)
        if v then P[b.key] = v end
    end
end

return R
