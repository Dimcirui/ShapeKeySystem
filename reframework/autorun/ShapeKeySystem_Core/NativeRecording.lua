-- ShapeKeySystem: decode named diagnostic signals and recorded eye rotations for playback.
--
-- Every selected signal must be readable throughout the take. Missing or interrupted sources
-- are not interpolated as zero. Output frames contain numbers only and retain no engine objects.
local Recording = require("ShapeKeySystem_Core.Recording")
local Names = require("ShapeKeySystem_Core.Names")
local X = require("ShapeKeySystem_Core.Expression")
local L = require("ShapeKeySystem_Core.I18n")
local N = {}
local key_of = {}
for i, name in ipairs(Names.ARKIT52) do key_of[name] = i end

local function array(values, limit, label)
    assert(type(values) == "table", L.f("%s 必须是数组", label))
    local n, count = #values, 0
    assert(n <= limit, L.f("%s 超过数量上限", label))
    for key in pairs(values) do
        assert(Recording.finite(key, n, true) and key >= 1, L.f("%s 下标无效", label))
        count = count + 1
    end
    assert(count == n, L.f("%s 包含缺号", label))
    return n
end

function N.describe(data, game)
    if type(data) ~= "table" or data.schema ~= "sks.native-signals/1" or data.game ~= game then return end
    return { final = true, name = type(data.label) == "string" and data.label ~= "" and data.label or nil }
end

local function angle(pose, reference)
    if type(pose) ~= "table" then return end
    local q, length = {}, 0
    for i, axis in ipairs({"x", "y", "z", "w"}) do
        local v = pose[i + 3]
        if not Recording.finite(v, 2) then return end
        q[axis], length = v, length + v*v
    end
    if length < 0.25 or length > 2.25 then return end
    length = math.sqrt(length)
    for axis, value in pairs(q) do q[axis] = value / length end
    if reference then
        assert(array(reference, 4, "eye_reference") == 4, "eye_reference 需要四元数")
        local norm = 0
        for _, value in ipairs(reference) do
            assert(Recording.finite(value, 1), "eye_reference 数值无效")
            norm = norm + value*value
        end
        assert(math.abs(norm - 1) < 0.001, "eye_reference 需要单位四元数")
        local n = reference
        q = {x = n[4]*q.x - n[1]*q.w - n[2]*q.z + n[3]*q.y,
             y = n[4]*q.y + n[1]*q.z - n[2]*q.w - n[3]*q.x,
             z = n[4]*q.z - n[1]*q.y + n[2]*q.x - n[3]*q.w,
             w = n[4]*q.w + n[1]*q.x + n[2]*q.y + n[3]*q.z}
    end
    local yaw, pitch = X.quat_to_yaw_pitch(q)
    return {yaw, pitch}
end

function N.decode(data, track, catalog, game, checkpoint)
    assert(N.describe(data, game), "不是当前游戏的原生信号录制")
    assert(track == "final", "原生诊断录制使用信号回放模式")
    assert(Recording.finite(data.duration, 300) and data.duration > 0, "录制时长无效")
    local count = array(data.samples, 9001, "samples")
    assert(count >= 2, "录制至少需要两帧")
    local present, source, previous = {}, nil, -1
    for i, sample in ipairs(data.samples) do
        assert(type(sample) == "table" and Recording.finite(sample.t, data.duration) and sample.t >= 0 and sample.t > previous,
            "录制时间必须严格递增且不超过时长")
        previous = sample.t
        local values = sample.values
        assert(type(values) == "table" and type(values.outputs) == "table", "采样缺少标定输出")
        if values.source ~= nil then
            assert(type(values.source) == "string", "录制来源身份无效")
            source = source or values.source
            assert(source == values.source, "同一录制包含不同角色或部件")
        end
        for name, value in pairs(values.outputs) do
            local key = key_of[name]
            assert(key and catalog[key], L.f("录制包含未知信号：%s", tostring(name)))
            assert(Recording.finite(value, 1) and value >= 0, L.f("录制信号超出 0..1：%s", name))
            present[key] = true
        end
        if checkpoint then checkpoint(64, i, count * 2) end
    end
    assert(previous == data.duration, "最后一帧时间与 duration 不一致")
    local map, hashes, keys = {}, {}, {}
    for key, name in ipairs(Names.ARKIT52) do
        if present[key] then
            keys[#keys + 1] = {key = key, name = name}
            map[key], hashes[#keys] = #keys, catalog[key]
        end
    end
    assert(#keys > 0, "录制没有可回放的表情信号")
    local frames, has_eyes = {}, { L = true, R = true }
    local eyes = {}
    for i, sample in ipairs(data.samples) do
        local row = {t = sample.t, values = {}}
        for column, item in ipairs(keys) do
            local value = sample.values.outputs[item.name]
            assert(value ~= nil, L.f("录制信号中途缺失：%s，请重新录制", item.name))
            row.values[column] = value
        end
        local joints = sample.values.joints
        assert(joints == nil or type(joints) == "table", "录制骨骼数据无效")
        eyes[i] = {}
        for _, side in ipairs({"L", "R"}) do
            local references = type(data.calibration) == "table" and data.calibration.eye_reference
            eyes[i][side] = angle(joints and joints[side .. "_Eye"], type(references) == "table" and references[side])
            if not eyes[i][side] then has_eyes[side] = false end
        end
        frames[i] = row
        if checkpoint then checkpoint(64, count + i, count * 2) end
    end
    local n, eye_columns = #keys, {}
    for _, side in ipairs({"L", "R"}) do
        if has_eyes[side] then
            eye_columns[side] = {n + 1, n + 2}
            for i, row in ipairs(frames) do row.values[n + 1], row.values[n + 2] = eyes[i][side][1], eyes[i][side][2] end
            n = n + 2
        end
    end
    return {frames = frames, duration = data.duration, map = map, hashes = hashes, n = n,
        signal_count = #keys, eye_columns = eye_columns, track = "final", has_final = true}
end

return N
