-- 采样荒野主猎人的 fcParam 输入，并把原生信号录制转换为面部动画测试的录制格式。
--
-- raw 由面部动画钩子在 updateAfterMotion 之前读取，与内置录制同一时机；final 为 fcParam 骨骼的局部 z。
-- 骨骼引用按面部、控制器和动画层地址缓存，地址或参数数量变化即重建；录制数据只保存数值。
local Playback = require("ShapeKeySystem_Games.Wilds.Playback")
local Recording = require("ShapeKeySystem_Core.Recording")
local R = {}
local RAW_SCALE, FINAL_SCALE = 10000000, 100000
local EYES = { "L_EyeJ_LOD02", "R_EyeJ_LOD02" }
local catalog, bound, M_LPOS, M_LROT

local function bind(face, controller, layer)
    catalog = catalog or Playback.catalog()
    local count = layer:call("get_ValueCount")
    local key = string.format("%X:%X:%X:%s", face:get_address(), controller:get_address(), layer:get_address(), tostring(count))
    if bound and bound.key == key then return bound end
    assert(Recording.finite(count, 4096, true) and count >= 1, "面部动画层数量异常")
    -- 只收参数索引和骨骼都在的通道，回放连接时同样要求这两项
    local params, labels, indices, joints, seen = {}, {}, {}, {}, {}
    for param = 1, 200 do
        local label = string.format("fcParam_%03d", param)
        local index = layer:call("getValueIndexByNameHash(System.UInt32)", catalog[param])
        if Recording.finite(index, count - 1, true) and index >= 0 and not seen[index] then
            local joint = face:call("getJointByName(System.String)", label)
            if joint then
                local n = #params + 1
                params[n], labels[n], indices[n], joints[n], seen[index] = param, label, index, joint, true
            end
        end
    end
    assert(#params > 0, "当前面部没有可录制的 fcParam")
    local eyes = {}
    for _, name in ipairs(EYES) do eyes[name] = face:call("getJointByName(System.String)", name) or false end
    bound = { key = key, params = params, labels = labels, joints = joints, eyes = eyes,
        watch = { controller_addr = controller:get_address(), layer_addr = layer:get_address(), indices = indices } }
    return bound
end

-- taps 与 outputs 按 params 的顺序排列；钩子还没读到 raw 时 taps 为空，status.raw 说明原因。
-- context.face 是 SKS 正在驱动的面部（过场里常是猎人替身）；没有时找主猎人自己的面部。
function R.snapshot(context)
    local face, controller, layer
    if context and context.face then
        face = context.face
        controller, layer = Playback.face_parts(face)
        if not controller then bound = nil; return nil, "当前面部没有表情控制器或动画层" end
    else
        face, controller, layer = Playback.locate()
        if not face then bound = nil; return nil, "主猎人面部尚未就绪" end
    end
    if Playback.hook_ready ~= true then return nil, "面部动画回调不可用，无法录制原版输入" end
    local b = bind(face, controller, layer)
    M_LPOS = M_LPOS or sdk.find_type_definition("via.Joint"):get_method("get_LocalPosition")
    M_LROT = M_LROT or sdk.find_type_definition("via.Joint"):get_method("get_LocalRotation")
    local w = b.watch
    local now = os.clock()
    -- 采样中断过（过场片段切换），之前读到的 raw 已过期，重新等钩子
    if w.touched and now - w.touched > 0.5 then w.raw, w.read_at = nil, nil end
    w.touched = now
    Playback.watch(w)
    if w.error then return nil, w.error end
    local joints, outputs, status = {}, {}, {}
    for i, joint in ipairs(b.joints) do
        local p = M_LPOS:call(joint)
        assert(p and Recording.finite(p.z, 10), b.labels[i] .. " 无法读取")
        outputs[i] = p.z / Playback.final_unit
        joints[b.labels[i]] = { p.x, p.y, p.z, 0, 0, 0, 1 }
    end
    for name, joint in pairs(b.eyes) do
        if joint then
            local p, q = M_LPOS:call(joint), M_LROT:call(joint)
            joints[name] = { p.x, p.y, p.z, q.x, q.y, q.z, q.w }
        else status[name] = "missing" end
    end
    local taps
    if w.read_at and os.clock() - w.read_at > 0.5 then return nil, "面部动画回调已停止" end
    if w.read_at then taps = w.raw else status.raw = "等待面部动画回调" end
    return { source = b.key, params = b.params, taps = taps, outputs = outputs, joints = joints, status = status }
end

-- 录制只留回放需要的数值；params 是同一张表，录制中不重复复制。
function R.sample(snapshot)
    return { source = snapshot.source, params = snapshot.params, taps = snapshot.taps, outputs = snapshot.outputs }
end

local function quantize(v, scale, limit, label)
    assert(Recording.finite(v, limit), label .. " 数值无效")
    return math.floor(v * scale + 0.5)
end

local function delta(previous, current)
    local d = {}
    for i, v in ipairs(current) do
        if v ~= previous[i] then d[#d + 1] = i; d[#d + 1] = v end
    end
    return #d > 0 and d or nil
end

-- 返回 fcparam.recording/2 和保存目录。列为整段出现过的全部 fcParam；空档样本、没读到 raw 的样本
-- 和当时面部没有的参数都记为 0，时间从第一份样本起算。
function R.export(r)
    catalog = catalog or Playback.catalog()
    local column, any = {}, false
    for _, s in ipairs(r.samples) do
        local v = s.values
        if v then
            for _, param in ipairs(v.params) do column[param] = true end
            any = any or v.taps ~= nil
        end
    end
    assert(any and #r.samples >= 2, "没有录到面部动画输入，请让主猎人保持可见后重新录制")
    local data = { schema = "fcparam.recording/2", game = Playback.id, encoding = "quantized-delta",
        raw_scale = RAW_SCALE, final_scale = FINAL_SCALE, sample_hz = r.rate_hz, clock = "os.clock",
        raw_source = "TreeLayer.getExtraValue before FacialController.updateAfterMotion",
        final_source = "fcParam joint local z / final_unit",
        label = r.label ~= "" and r.label or nil, stop_reason = r.reason,
        created_at = os.date("%Y-%m-%d %H:%M:%S"), params = {}, frames = {} }
    for param = 1, 200 do
        if column[param] then
            data.params[#data.params + 1] = { param = param, hash = catalog[param] }
            column[param] = #data.params
        end
    end
    local n, t0, previous = #data.params, r.samples[1].t, nil
    for i, s in ipairs(r.samples) do
        local raw, final = {}, {}
        for c = 1, n do raw[c], final[c] = 0, 0 end
        local v = s.values
        if v then
            for k, param in ipairs(v.params) do
                local c = column[param]
                if v.taps then raw[c] = quantize(v.taps[k], RAW_SCALE, 1000, "raw") end
                final[c] = quantize(v.outputs[k], FINAL_SCALE, 100000, "final")
            end
        end
        local frame = { t = math.floor((s.t - t0) * 1000 + 0.5) / 1000 }
        if previous then frame.d, frame.df = delta(previous.raw, raw), delta(previous.final, final)
        else frame.raw, frame.final = raw, final end
        data.frames[i], previous = frame, { raw = raw, final = final }
    end
    data.duration = data.frames[#data.frames].t
    return data, "user\\recordings"
end

return R
