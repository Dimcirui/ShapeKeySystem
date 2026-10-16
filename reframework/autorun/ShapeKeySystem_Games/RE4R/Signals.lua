-- ShapeKeySystem: calibrated face measurements and read-only correction channels.
--
-- Joint projection and rule evaluation live in Core (BoneSignals); this module adds the native
-- crct_* taps, their write protection and the per-actor calibration. Each handle keeps its actor calibration.
-- Handles belong to a rig and are discarded with it; this module retains no engine objects.
local Hash = require("ShapeKeySystem_Core.NameHash")
local B = require("ShapeKeySystem_Core.BoneSignals")
local S = {}
local data = { joints = {}, rules = {} }
local by_key, protected = B.by_key, {}
local PREFIX = "Face__geo__p000_cbs.crct_"

local finite = B.finite
local function call(obj, method, ...)
    if not obj then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    return ok and value or nil
end

function S.validate(calibration) return B.validate(calibration, { label = "Leon", taps = true }) end

function S.configure(calibration)
    local ok, why = S.validate(calibration)
    if not ok then return false, why end
    data, protected = calibration, {}
    for _, name in ipairs(calibration.native_names or {}) do protected[Hash.hash(name)] = true end
    for _, r in ipairs(data.rules) do
        for _, tap in ipairs(r.taps or {}) do protected[Hash.hash(PREFIX .. tap)] = true end
    end
    return true
end

-- hash -> channel index of a mesh
function S.hashes(mesh)
    local n = call(mesh, "get_BlendShapeChannelNum")
    if not finite(n) or n < 0 then return {} end
    local hashes, out = Hash.hashes(mesh, n, true) or {}, {}
    for i = 1, n do
        if hashes[i] then out[hashes[i]] = i - 1 end
    end
    return out
end

function S.writable(name, mesh, idx)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "#"
        or name:find("^Face__geo__") or name:find("^crct_") or protected[Hash.hash(name)] then return false end
    if mesh and idx ~= nil then
        local arr = call(mesh, "get_ChannelNameHash")
        local h = arr and Hash.hash_at(arr, idx, true)
        return h ~= nil and not protected[h]
    end
    return true
end

S.raw = B.raw

function S.bind(face, keys, calibration)
    local data = calibration or data
    local mesh = call(call(face, "get_GameObject"), "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    local h = { mesh = mesh, keys = keys, joints = {}, taps = {}, status = {}, calibration = data,
        count = call(mesh, "get_BlendShapeChannelNum") }
    local hashes = S.hashes(mesh)
    h.joints = B.bind_joints(face, data)
    for _, rule in ipairs(data.rules) do
        for _, name in ipairs(rule.taps or {}) do h.taps[name] = hashes[Hash.hash(PREFIX .. name)] end
    end
    return h, #keys
end

S.measure = B.measure

function S.read(h, P, inv_full)
    local data = h.calibration or data
    local taps = {}
    local mesh = h.mesh
    local cn, wc = call(mesh, "get_BlendShapeChannelNum"), call(mesh, "get_BlendShapeChannelWeightCount")
    local length = call(call(mesh, "get_ChannelWeightList"), "get_Length")
    local bound = finite(cn) and finite(wc) and finite(length) and cn == h.count
    local limit = bound and math.min(cn, wc, length) or 0
    local function source(rule)
        local value
        for _, name in ipairs(rule.taps) do
            if taps[name] == nil then
                local idx, state = h.taps[name], "unbound"
                local v
                if idx ~= nil then
                    if not bound then state = "bounds_unavailable"
                    elseif idx >= limit then state = "out_of_bounds"
                    else v = call(mesh, "getBlendShapeChannelWeightParam", idx); state = finite(v) and "ok" or "read_failed" end
                end
                h.status[name], taps[name] = state, finite(v) and v or false
            end
            local v = taps[name]
            if finite(v) and (not value or v > value) then value = v end
        end
        return value
    end
    local values, measured = B.evaluate(data, B.sampler(h.joints), source)
    for _, key in ipairs(h.keys) do P[key] = (values[by_key[key]] or 0) * inv_full end
    return values, measured, taps
end

local DIAGNOSTIC_JOINTS = {
    "C_Jaw", "C_Mouth", "C_Chin", "C_UpperLip", "C_LowerLip", "L_MouthCorner", "R_MouthCorner",
    "L_UpperLip02", "R_UpperLip02", "L_LowerLip02", "R_LowerLip02",
    "L_U_Eyelid1", "L_U_Eyelid2", "L_U_Eyelid3", "L_U_Eyelid4",
    "R_U_Eyelid1", "R_U_Eyelid2", "R_U_Eyelid3", "R_U_Eyelid4",
    "L_D_Eyelid3", "R_D_Eyelid3", "L_Eye", "R_Eye", "L_I_Eyebrow", "R_I_Eyebrow",
    "L_O_Eyebrow", "R_O_Eyebrow", "L_UI_Eyebrow_01", "R_UI_Eyebrow_01",
    "L_Cheek", "R_Cheek", "L_NoseCorner", "R_NoseCorner", "Tongue01", "Tongue03",
}

-- Snapshots contain numbers and names only; every sample resolves fresh engine references.
function S.snapshot(face, calibration)
    local data = calibration or data
    local h = S.bind(face, {}, data)
    local outputs, measured = S.read(h, {}, 1)
    local result = { joints = {}, measurements = {}, taps = {}, outputs = outputs,
        status = {}, calibration = data }
    result.joints, result.status = B.snapshot_joints(face, data, DIAGNOSTIC_JOINTS)
    for name, value in pairs(measured) do
        if finite(value) then result.measurements[name] = value end
    end
    local hashes = S.hashes(h.mesh)
    local cn, wc = call(h.mesh, "get_BlendShapeChannelNum"), call(h.mesh, "get_BlendShapeChannelWeightCount")
    local length = call(call(h.mesh, "get_ChannelWeightList"), "get_Length")
    result.buffers = {channels = cn, count = wc, length = length}
    local limit = finite(cn) and finite(wc) and finite(length) and cn == h.count and math.min(cn, wc, length) or 0
    for _, name in ipairs(data.native_names or {}) do
        local idx = hashes[Hash.hash(name)]
        local value = idx ~= nil and idx < limit and call(h.mesh, "getBlendShapeChannelWeightParam", idx) or nil
        if finite(value) then result.taps[name] = value
        else result.status["tap:" .. name] = idx == nil and "unbound" or "unreadable" end
    end
    return result
end

return S
