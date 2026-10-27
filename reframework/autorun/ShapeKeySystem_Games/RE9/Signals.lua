-- ShapeKeySystem: native RE9 correction inputs, with base-relative bones for unavailable inputs.
--
-- Handles contain numbers and names only. Each sample resolves the current head and verifies
-- its identity and tap hashes before reading; missing inputs contribute zero independently.
local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")
local Names = require("ShapeKeySystem_Core.Names")
local Vowels = require('ShapeKeySystem_Games.RE9.Vowels')
local Eyes = require('ShapeKeySystem_Games.RE9.Eyes')
local VirtualFACS = require("ShapeKeySystem_Games.RE9.VirtualFACS")
local S = {}
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
local protected, taps, calibration = {}, {}, {}
local input_mode='legacy'
local extension_enabled=false
local modes={legacy=true,bones_first=true,native_first=true}
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
S.raw = {term = "原生表情", parse = function(value)
    if keys[value]and(taps[value]and #taps[value]>0 or(calibration.bone_fallbacks or{})[value]
        or(calibration.expression_fallbacks or{})[value]or(calibration.native_output_rules or{})[value]
        or vowel_keys[value]and Vowels.configured())then return keys[value] end
    return nil, "RE9 未配置该表情输入"
end, label = function(key) return labels[key] end}
function S.mode()return input_mode end
function S.expanded()return extension_enabled end

function S.configure(data,mode,expanded)
    if type(data) ~= "table" or data.schema ~= "sks.re9-native/1" or type(data.native_names) ~= "table"
        or type(data.taps) ~= "table" then return false, "RE9 原生通道表无效" end
    mode=mode or data.input_mode or'legacy'
    if not modes[mode]then return false,'RE9 输入模式无效'end
    for _,name in ipairs({'bone_fallbacks','expression_fallbacks','native_output_rules'})do
        if data[name]~=nil and type(data[name])~='table'then return false,'RE9 面部来源表无效'end
    end
    if expanded then
        if type(data.expression_fallbacks)~='table'then return false,'RE9 扩展表情标定缺失'end
        local copy,combined={},{}
        for name,value in pairs(data)do copy[name]=value end
        for label,rule in pairs(data.bone_fallbacks or{})do combined[label]=rule end
        for _,set in ipairs({data.expression_fallbacks,data.native_output_rules or{}})do
            for label,rule in pairs(set)do
                if combined[label]then return false,'RE9 扩展表情不能覆盖基础输入'end
                combined[label]=rule
            end
        end
        copy.bone_fallbacks=combined;data=copy
    end
    local names, configured = {}, {}
    for _, name in ipairs(data.native_names) do
        if type(name) ~= "string" or name == "" then return false, "RE9 原生通道名称无效" end
        names[Hash.hash(name)] = true
    end
    for _, label in ipairs(labels) do
        local list = data.taps[label]
        if list==nil then list={}end
        if type(list) ~= "table" then return false, "RE9 原生表情来源无效：" .. label end
        configured[label] = {}
        for _, name in ipairs(list) do
            if type(name) ~= "string" or not names[Hash.hash(name)] then return false, "RE9 来源不属于原生通道" end
            configured[label][#configured[label] + 1] = {name = name, hash = Hash.hash(name)}
        end
    end
    local extra={re9BrowInLeft=true,re9BrowInRight=true}
    local native_labels={}
    for label,rule in pairs(data.native_output_rules or{})do
        local suffix=type(label)=='string'and label:match('^re9%.native%.([%w_]+)$')
        local expected=suffix and('HeadSkinned_blendShape.'..suffix)
        if not expected or not names[Hash.hash(expected)]or type(rule)~='table'
            or type(rule.native_parameters)~='table'or #rule.native_parameters~=1
            or rule.native_parameters[1]~=expected then return false,'RE9 原生输出来源无效'end
        extra[label]=true;native_labels[#native_labels+1]=label
    end
    for _,rule in pairs(data.bone_fallbacks or{})do
        if type(rule)~='table'then return false,'RE9 面部来源无效'end
        if rule.native_parameters~=nil then
            if type(rule.native_parameters)~='table'or #rule.native_parameters<1 or #rule.native_parameters>4 then
                return false,'RE9 原生输出回退无效'
            end
            for _,name in ipairs(rule.native_parameters)do
                if type(name)~='string'or not names[Hash.hash(name)]then return false,'RE9 原生输出回退不在名称表中'end
            end
        end
    end
    local ok, why = Bones.validate(data.bone_fallbacks,extra)
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
    Bones.configure(data.bone_fallbacks,extra);Vowels.configure(data.vowels)
    while #labels>fixed_key_count do keys[labels[#labels]]=nil;table.remove(labels)end
    table.sort(native_labels)
    for _,label in ipairs(native_labels)do labels[#labels+1]=label;keys[label]=#labels;configured[label]={}end
    protected, taps, calibration = names, configured, data
    input_mode=mode
    extension_enabled=expanded==true
    Eyes.configure(data.eye_neutrals,extension_enabled)
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
    if not h or type(h) ~= "table" or not h.keys then return {}, {} end
    P = P or {}
    inv_full = inv_full or 1
    local head = R.find()
    local valid = head and h.identity ~= nil and head.identity == h.identity
    local hashes = valid and R.call(head.mesh, "get_ChannelNameHash")
    local values, observed, frame = {}, {}, {}
    local motion_context,motion_error
    local scalars={}
    h.motion_requests=0
    if valid then
        VirtualFACS.evaluate(head, open_motion())
    end
    local function open_motion()
        if motion_context==nil then
            motion_context,motion_error=Motion.open(head,h.motion_cache)
            motion_context=motion_context or false
        end
        return motion_context
    end
    local function fallback(term,detail)
        if not open_motion()then return nil,motion_error end
        h.motion_requests=h.motion_requests+1
        if term.kind=='pos'and not term.motion_neutral_position then return nil,'motion_position_neutral_unavailable'end
        return Motion.read(motion_context,term.bone,term.motion_neutral,detail,
            term.kind=='pos'and term.motion_neutral_position or nil)
    end
    h.sources, h.measurements, h.bone_status, h.bone_joints = {}, {}, {}, {}
    for _, key in ipairs(h.keys) do
        local label, value, available = labels[key], 0, false
        for _, tap in ipairs(taps[label] or {}) do
            local index = h.indices[tap.name]
            local state, v = "head_unavailable"
            if valid then
                -- 1. Try reading directly from mesh channel (e.g. vanilla Leon head)
                if type(index) == "number" and index < head.count and Hash.hash_at(hashes, index, true) == tap.hash then
                    v = R.call(head.mesh, "getBlendShapeChannelWeightParam(System.UInt64)", index)
                end
                -- 2. If mesh didn't have it (mod mesh!), read from Virtual 96 FACS bus!
                if not finite(v) then
                    v = VirtualFACS.get(tap.name)
                end
                state = finite(v) and "ok" or "read_failed"
            end
            h.status[tap.name] = state
            if finite(v) then
                available = true
                observed[tap.name] = v
                value = math.max(value, math.max(0, math.min(1, v)))
            end
        end
        h.sources[label] = available and "native" or "unavailable"
        
        -- Fallback to driver vowels or bones only if native tap wasn't available
        if valid and not available then
            local bone, measured, state, joints, source
            local extension_rule=(calibration.expression_fallbacks or{})[label]or(calibration.native_output_rules or{})[label]
            if vowel_keys[label]then
                if extension_enabled then
                    local values
                    values,state,joints,source=Vowels.read(head,diagnostic,fallback,h.omitted,frame,open_motion())
                    bone=values and values[vowel_keys[label]]
                else state='extension_disabled'end
            else
                bone,measured,state,joints,source=Bones.read(head,label,diagnostic,
                    fallback,h.omitted,frame)
            end
            if not extension_enabled and extension_rule
                and not(calibration.bone_fallbacks or{})[label]then state='extension_disabled'end
            local rule=(calibration.bone_fallbacks or{})[label]
            if not finite(bone) and rule and rule.native_parameters and open_motion() then
                local total, complete = 0, true
                for _, name in ipairs(rule.native_parameters) do
                    local entry = scalars[name]
                    if entry == nil then
                        h.motion_requests = h.motion_requests + 1
                        local v, why = Motion.scalar(motion_context, name)
                        entry = {value = v, state = why}
                        scalars[name] = entry
                    end
                    if not finite(entry.value) then complete = false; state = entry.state; break end
                    total = total + entry.value
                end
                if complete then
                    bone = math.max(0, math.min(1, total / #rule.native_parameters))
                    state, source = 'native_parameter_fallback', 'motion_native'
                end
            end
            h.bone_status[label], h.measurements[label] = state, measured
            if finite(bone) then
                value, h.sources[label] = bone, source
                for name, pose in pairs(joints or {}) do h.bone_joints[name] = pose end
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
    local requested={}
    for key,label in ipairs(labels)do
        if S.raw.parse(label)and(not label:match('^re9%.native%.')or type(context)=='table'and context.include_native_outputs)then
            requested[#requested+1]=key
        end
    end
    local h = S.bind(head.face, requested,mode)
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
        input_mode=mode,extended_expressions=extension_enabled,simulated_missing_bones=h.omitted~=nil,
        motion_requests=h.motion_requests,
        joints = joints, bone_poses=h.bone_joints, joint_status=joint_status,
        calibration={input_mode=mode,data=calibration}, measurements = h.measurements, outputs = values, taps = observed,
        sources = h.sources, bone_status = h.bone_status, status = h.status, eyes=Eyes.diagnostics(), buffers = {channels = head.count}}
end
return S
