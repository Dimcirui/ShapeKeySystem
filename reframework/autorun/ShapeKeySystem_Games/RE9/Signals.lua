-- ShapeKeySystem: native RE9 correction inputs, with base-relative bones for unavailable inputs.
--
-- Handles contain numbers and names only. Each sample resolves the current head and verifies
-- its identity and tap hashes before reading; missing inputs contribute zero independently.
local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")
local S = {}
local labels = {"eyeBlinkLeft", "eyeBlinkRight", "jawOpen"}
local keys = {eyeBlinkLeft = 1, eyeBlinkRight = 2, jawOpen = 3}
local protected, taps, calibration = {}, {}, {}
local input_mode='legacy'
local modes={legacy=true,bones_first=true}
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
S.raw = {term = "原生表情", parse = function(value)
    if keys[value] then return keys[value] end
    return nil, "RE9 当前仅接入 eyeBlinkLeft、eyeBlinkRight、jawOpen"
end, label = function(key) return labels[key] end}
function S.mode()return input_mode end

function S.configure(data,mode)
    if type(data) ~= "table" or data.schema ~= "sks.re9-native/1" or type(data.native_names) ~= "table"
        or type(data.taps) ~= "table" then return false, "RE9 原生通道表无效" end
    local names, configured = {}, {}
    for _, name in ipairs(data.native_names) do
        if type(name) ~= "string" or name == "" then return false, "RE9 原生通道名称无效" end
        names[Hash.hash(name)] = true
    end
    for _, label in ipairs(labels) do
        local list = data.taps[label]
        if type(list) ~= "table" or #list == 0 then return false, "RE9 原生表情来源缺失：" .. label end
        configured[label] = {}
        for _, name in ipairs(list) do
            if type(name) ~= "string" or not names[Hash.hash(name)] then return false, "RE9 来源不属于原生通道" end
            configured[label][#configured[label] + 1] = {name = name, hash = Hash.hash(name)}
        end
    end
    local ok, why = Bones.configure(data.bone_fallbacks)
    if not ok then return false, why end
    mode=mode or data.input_mode or'legacy'
    if not modes[mode]then return false,'RE9 输入模式无效'end
    protected, taps, calibration = names, configured, data
    input_mode=mode
    return true
end

function S.writable(name, mesh, index)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "#"
        or name:find("_blendShape", 1, true) or protected[Hash.hash(name)] then return false end
    if mesh and index ~= nil then
        local cn = R.bounds(mesh)
        if not cn or not R.integer(index, cn - 1) then return false end
        local hash = Hash.hash_at(R.call(mesh, "get_ChannelNameHash"), index, true)
        return hash == Hash.hash(name) and not protected[hash]
    end
    return true
end

function S.bind(face, requested, mode)
    local head = R.find()
    local h = {keys = requested, identity = head and head.identity, indices = {}, status = {},
        mode=mode or input_mode,motion_cache={}}
    if not head or R.address(face) ~= R.address(head.face) then h.identity = nil; return h, 0 end
    local hashes = Hash.hashes(head.mesh, head.count, true) or {}
    local positions = {}
    for i = 1, head.count do
        local hash = hashes[i]
        if hash ~= nil then
            if positions[hash] ~= nil then positions[hash] = false else positions[hash] = i - 1 end
        end
    end
    for _, list in pairs(taps) do
        for _, tap in ipairs(list) do h.indices[tap.name] = positions[tap.hash] end
    end
    return h, #requested
end

function S.read(h, P, inv_full, diagnostic)
    local head = R.find()
    local valid = head and h.identity ~= nil and head.identity == h.identity
    local hashes = valid and R.call(head.mesh, "get_ChannelNameHash")
    local values, observed = {}, {}
    local motion_context,motion_error
    h.motion_requests=0
    local function fallback(term,detail)
        if motion_context==nil then
            motion_context,motion_error=Motion.open(head,h.motion_cache)
            motion_context=motion_context or false
        end
        if not motion_context then return nil,motion_error end
        h.motion_requests=h.motion_requests+1
        return Motion.read(motion_context,term.bone,term.motion_neutral,detail)
    end
    h.sources, h.measurements, h.bone_status, h.bone_joints = {}, {}, {}, {}
    for _, key in ipairs(h.keys) do
        local label, value, available = labels[key], 0, false
        for _, tap in ipairs((h.mode=='legacy'or diagnostic)and taps[label]or{}) do
            local index = h.indices[tap.name]
            local state, v = "head_unavailable"
            if valid then
                if type(index) ~= "number" then state = "unbound"
                elseif index >= head.count then state = "out_of_bounds"
                elseif Hash.hash_at(hashes, index, true) ~= tap.hash then state = "hash_changed"
                else
                    v = R.call(head.mesh, "getBlendShapeChannelWeightParam(System.UInt64)", index)
                    state = finite(v) and "ok" or "read_failed"
                end
            end
            h.status[tap.name] = state
            if finite(v) then
                available = true
                observed[tap.name] = v; value = math.max(value, math.max(0, math.min(1, v)))
            end
        end
        h.sources[label] = available and "native" or "unavailable"
        if valid and (h.mode=='bones_first'or not available) then
            local bone, measured, state, joints,source = Bones.read(head, label, diagnostic,
                h.mode=='bones_first'and fallback or nil,h.omitted)
            h.bone_status[label], h.measurements[label] = state, measured
            if finite(bone) then
                value, h.sources[label] = bone, source
                for name, pose in pairs(joints or {}) do h.bone_joints[name] = pose end
            elseif h.mode=='bones_first'then
                value,h.sources[label]=0,'unavailable'
            end
        end
        values[label] = value
        P[key] = value * inv_full
    end
    if motion_context and not Motion.finish(motion_context)then
        h.bone_joints={}
        for _,key in ipairs(h.keys)do
            values[labels[key]],P[key]=0,0
            h.sources[labels[key]],h.bone_status[labels[key]]='unavailable','motion_changed_during_read'
        end
    end
    return values, observed
end

function S.snapshot(context)
    local head = R.find()
    if not head then return nil, "里昂主头部尚未就绪" end
    local mode=type(context)=='table'and context.input_mode or input_mode
    if not modes[mode]then return nil,'RE9 输入模式无效'end
    local h = S.bind(head.face, {1, 2, 3},mode)
    -- Omissions are confined to read-only diagnostics; normal adapter bindings never set them.
    h.omitted=type(context)=='table'and context.omit_bones or nil
    local values, observed = S.read(h, {}, 1, true)
    local joints,joint_status={},{}
    for name,pose in pairs(h.bone_joints)do
        if pose.position and pose.rotation then
            joints[name]={table.unpack(pose.position)}
            for _,v in ipairs(pose.rotation)do joints[name][#joints[name]+1]=v end
        else joint_status[name]='local_position_unavailable'end
    end
    return {source = head.identity..':'..mode..':'..tostring(h.motion_cache.identity),
        input_mode=mode,simulated_missing_bones=h.omitted~=nil,
        motion_requests=h.motion_requests,
        joints = joints, bone_poses=h.bone_joints, joint_status=joint_status,
        calibration={input_mode=mode,data=calibration}, measurements = h.measurements, outputs = values, taps = observed,
        sources = h.sources, bone_status = h.bone_status, status = h.status, buffers = {channels = head.count}}
end
return S
