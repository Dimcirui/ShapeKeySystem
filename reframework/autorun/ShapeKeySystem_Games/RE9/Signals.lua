-- ShapeKeySystem: RE9 expression inputs from the engine's own native face values.
--
-- The facial clips animate 96 native values (HeadSkinned_blendShape.*). The face Motion keeps them
-- as parameter joints (value in local X) on vanilla and mod heads alike; names a head lacks are
-- sampled from the playing clips instead. Labels with taps take the largest of their native
-- values; re9.native.* labels expose one value; vowels and labels without taps keep the face-bone
-- measurements. Handles contain numbers and names only; every read resolves the current face.
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")
local Clips = require("ShapeKeySystem_Games.RE9.Clips")
local Hash = require("ShapeKeySystem_Core.NameHash")
local Names = require("ShapeKeySystem_Core.Names")
local Vowels = require('ShapeKeySystem_Games.RE9.Vowels')
local Eyes = require('ShapeKeySystem_Games.RE9.Eyes')
local L = require("ShapeKeySystem_Core.I18n")
local S = {}
local PREFIX = "HeadSkinned_blendShape."
local labels = {"eyeBlinkLeft", "eyeBlinkRight", "jawOpen"}
local keys = {eyeBlinkLeft = 1, eyeBlinkRight = 2, jawOpen = 3}
for _,name in ipairs(Names.ARKIT52)do
    if not keys[name]then labels[#labels+1]=name;keys[name]=#labels end
end
local vowel_keys={re9VowelA=1,re9VowelI=2,re9VowelU=3,re9VowelE=4,re9VowelO=5}
for _,name in ipairs({'re9BrowInLeft','re9BrowInRight','re9VowelA','re9VowelI','re9VowelU','re9VowelE','re9VowelO'})do
    labels[#labels+1]=name;keys[name]=#labels
end
local fixed_key_count=#labels
local protected, taps, natives, bone_rules = {}, {}, {}, {}
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
local function clamp(v) return math.max(0, math.min(1, v)) end
S.raw = {term = "原生表情", parse = function(value)
    if keys[value]and(taps[value]and #taps[value]>0 or natives[value]or bone_rules[value]
        or vowel_keys[value]and Vowels.configured())then return keys[value] end
    return nil, "RE9 未配置该表情输入"
end, label = function(key) return labels[key] end}

function S.configure(data)
    if type(data) ~= "table" or data.schema ~= "sks.re9-native/1" or type(data.native_names) ~= "table"
        or type(data.taps) ~= "table" then return false, "RE9 原生通道表无效" end
    for _,name in ipairs({'bone_fallbacks','expression_fallbacks'})do
        if data[name]~=nil and type(data[name])~='table'then return false,'RE9 面部来源表无效'end
    end
    local names, native_labels, label_native = {}, {}, {}
    for _, name in ipairs(data.native_names) do
        if type(name) ~= "string" or name == "" then return false, "RE9 原生通道名称无效" end
        names[Hash.hash(name)] = true
        local suffix = name:sub(1, #PREFIX) == PREFIX and name:sub(#PREFIX + 1)
        if suffix and suffix:match("^[%w_]+$") and not suffix:find("_LOD%d+$") then
            local label = "re9.native." .. suffix
            if not label_native[label] then native_labels[#native_labels + 1] = label end
            label_native[label] = name
        end
    end
    local configured = {}
    for _, label in ipairs(labels) do
        local list = data.taps[label]
        if list==nil then list={}end
        if type(list) ~= "table" then return false, L.f("RE9 原生表情来源无效：%s", label) end
        configured[label] = {}
        for _, name in ipairs(list) do
            if type(name) ~= "string" or not names[Hash.hash(name)] then return false, "RE9 来源不属于原生通道" end
            configured[label][#configured[label] + 1] = name
        end
    end
    -- face-bone rules: every label the data measures from bones (taps win where both exist)
    local combined = {}
    for _, set in ipairs({data.bone_fallbacks or {}, data.expression_fallbacks or {}}) do
        for label, rule in pairs(set) do
            if combined[label] then return false, 'RE9 扩展表情不能覆盖基础输入' end
            combined[label] = rule
        end
    end
    local extra={re9BrowInLeft=true,re9BrowInRight=true}
    local ok, why = Bones.validate(combined,extra)
    if not ok then return false, why end
    ok,why=Vowels.validate(data.vowels)
    if not ok then return false,why end
    if data.eye_neutrals~=nil then
        if type(data.eye_neutrals)~='table'then return false,'RE9 眼球静止位无效'end
        for _,side in ipairs({'L','R'})do
            local eye=data.eye_neutrals[side]
            if eye~=nil and(type(eye)~='table'or not eye.rotation or not Bones.validate({jawOpen={lo=0,hi=1,
                terms={{bone=side..'_Eye',axis={1,0,0},motion_neutral=eye.rotation}}}}))then
                return false,'RE9 眼球静止位无效'
            end
        end
    end
    Bones.configure(combined,extra);Vowels.configure(data.vowels)
    while #labels>fixed_key_count do keys[labels[#labels]]=nil;table.remove(labels)end
    table.sort(native_labels)
    for _,label in ipairs(native_labels)do labels[#labels+1]=label;keys[label]=#labels;configured[label]={}end
    protected, taps, natives = names, configured, label_native
    bone_rules = {}
    for label in pairs(combined) do bone_rules[label] = true end
    Eyes.configure(data.eye_neutrals, true)
    return true
end

-- One write batch reads the bounds and the hash array once; it never outlives the callback.
function S.write_context(mesh)
    local cn = R.bounds(mesh)
    return {count = cn or false, hashes = cn and R.call(mesh, "get_ChannelNameHash")}
end

function S.writable(name, mesh, index, context)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "#"
        or name:find("_blendShape", 1, true) then return false end
    local name_hash = Hash.hash(name)
    if protected[name_hash] then return false end
    if mesh and index ~= nil then
        local cn
        if context then cn = context.count else cn = R.bounds(mesh) end
        if not cn or not R.integer(index, cn - 1) then return false end
        local hashes
        if context then hashes = context.hashes else hashes = R.call(mesh, "get_ChannelNameHash") end
        local hash = Hash.hash_at(hashes, index, true)
        return hash == name_hash and not protected[hash]
    end
    return true
end

function S.bind(face, requested)
    local head = R.find()
    local h = {keys = requested, identity = head and head.identity, status = {}, motion_cache = {}}
    if not head or R.address(face) ~= R.address(head.face) then h.identity = nil; return h, 0 end
    return h, #requested
end

-- Native values for one read: parameter joints first, one clip pass for the names they miss.
local function native_reader(h, open_motion)
    local values, sources, missing = {}, {}, nil
    local function sample_missing()
        local context = open_motion()
        local list = {}
        for name in pairs(missing) do list[#list + 1] = name end
        missing = false
        if not context or #list == 0 then return end
        h.clip_requests = (h.clip_requests or 0) + 1
        for name, v in pairs(Clips.sample(context.motion, list)) do
            if finite(v) then values[name], sources[name] = v, 'clip' end
        end
    end
    local function get(name)
        if sources[name] == nil then
            local context = open_motion()
            local v = context and Motion.scalar(context, name)
            if finite(v) then values[name], sources[name] = v, 'parameter'
            else sources[name] = false end
        end
        if sources[name] == false and missing ~= false then
            missing = missing or {}
            missing[name] = true
            return nil, 'pending'
        end
        return values[name], sources[name]
    end
    return get, sample_missing, values, sources, function() return missing end
end

function S.read(h, P, inv_full, diagnostic)
    local head = R.find()
    local valid = head and h.identity ~= nil and head.identity == h.identity
    local values, observed, frame = {}, {}, {}
    local motion_context,motion_error
    h.motion_requests, h.clip_requests = 0, 0
    local function open_motion()
        if motion_context==nil then
            motion_context,motion_error=Motion.open(head,h.motion_cache)
            motion_context=motion_context or false
        end
        return motion_context or nil
    end
    local function fallback(term,detail)
        if not open_motion()then return nil,motion_error end
        h.motion_requests=h.motion_requests+1
        if term.kind=='pos'and not term.motion_neutral_position then return nil,'motion_position_neutral_unavailable'end
        return Motion.read(motion_context,term.bone,term.motion_neutral,detail,
            term.kind=='pos'and term.motion_neutral_position or nil)
    end
    local get, sample_missing, native_values, native_sources, pending = native_reader(h, open_motion)
    h.sources, h.measurements, h.bone_status, h.bone_joints = {}, {}, {}, {}
    -- first pass registers every native name the requested labels need, so one clip pass covers them
    if valid then
        for _, key in ipairs(h.keys) do
            local label = labels[key]
            for _, name in ipairs(taps[label] or {}) do get(name) end
            if natives[label] then get(natives[label]) end
        end
        if pending() then sample_missing() end
    end
    for _, key in ipairs(h.keys) do
        local label, value = labels[key], 0
        local list = taps[label] or {}
        if valid and (#list > 0 or natives[label]) then
            local any = false
            if #list == 0 then list = {natives[label]} end
            for _, name in ipairs(list) do
                local v, source = get(name)
                if finite(v) then
                    any = true
                    observed[name] = v
                    value = math.max(value, clamp(v))
                    h.status[name] = source
                else h.status[name] = 'unavailable' end
            end
            h.sources[label] = any and 'native' or 'unavailable'
        elseif valid then
            local bone, measured, state, joints, source
            if vowel_keys[label] then
                local weights
                weights,state,joints,source=Vowels.read(head,diagnostic,fallback,h.omitted,frame)
                bone=weights and weights[vowel_keys[label]]
            else
                bone,measured,state,joints,source=Bones.read(head,label,diagnostic,fallback,h.omitted,frame)
            end
            h.bone_status[label], h.measurements[label] = state, measured
            if finite(bone) then
                value, h.sources[label] = bone, source
                for name, pose in pairs(joints or {}) do h.bone_joints[name] = pose end
            else h.sources[label] = 'unavailable' end
        else h.sources[label] = 'head_unavailable' end
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
    h.native_sources = native_sources
    return values, observed
end

function S.snapshot(context)
    local head = R.find()
    if not head then return nil, "里昂面部尚未就绪" end
    local requested={}
    for key,label in ipairs(labels)do
        if S.raw.parse(label)and(not label:match('^re9%.native%.')or type(context)=='table'and context.include_native_outputs)then
            requested[#requested+1]=key
        end
    end
    local h = S.bind(head.face, requested)
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
    -- status lists only the natives that could not be read; the diagnostics page counts it as missing
    local native_sources, missing = {}, {}
    for name, source in pairs(h.native_sources or {}) do
        native_sources[name] = source or 'unavailable'
        if not source then missing[name] = 'unavailable' end
    end
    return {source = head.identity..':'..tostring(h.motion_cache.identity),
        simulated_missing_bones=h.omitted~=nil,
        motion_requests=h.motion_requests, clip_requests=h.clip_requests,
        joints = joints, bone_poses=h.bone_joints, joint_status=joint_status,
        measurements = h.measurements, outputs = values, taps = observed, native_sources = native_sources,
        sources = h.sources, bone_status = h.bone_status, status = missing, eyes=Eyes.diagnostics()}
end
return S
