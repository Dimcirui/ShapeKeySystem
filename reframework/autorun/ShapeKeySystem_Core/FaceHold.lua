-- 固定面部表情骨骼的运行时中性姿势，保留固定前的动画姿势供信号读取。
--
-- `prepare` 在 UpdateMotion 前撤销上次写入并静音；`update` 在之后推进采集。
-- `reapply` 仅重写姿势，不推进采集或覆盖信号快照。
-- 中性姿势包含捏脸偏移，必须在全部动画层成功静音后采集，不能使用骨架 Base 姿势。
-- 恢复动画层后须再等一次动画更新，期间调用方保留上一帧形态键权重。
-- 骨骼和动画层引用由本模块持有；普通取消重试未完成恢复，rig 释放或脚本卸载前必须 `release(true)`。
-- 穿戴部件若被其它插件逐帧复制源骨骼（BoneSystem），只固定 Native 源无法阻止复制到部件；
-- 采集时按原生公式核对被复制的目标骨骼，固定后在源写回同一帧再写回目标中性，取消时逐通道恢复目标动画姿势。
local L = require("ShapeKeySystem_Core.I18n")
local H = {}

local SETTLE = 2
local MAX_WAIT = 12
local RETRY = 30
local EPS = 1e-5
local COPY_EPS = 1e-3

local M_GPOS, M_GROT, M_SPOS, M_SROT, M_GSCALE, M_SSCALE
local M_GBP, M_GBR, M_GBS
local function methods()
    if M_GPOS then return end
    local t = sdk.find_type_definition("via.Joint")
    M_GPOS, M_GROT = t:get_method("get_LocalPosition"), t:get_method("get_LocalRotation")
    M_SPOS, M_SROT = t:get_method("set_LocalPosition"), t:get_method("set_LocalRotation")
    M_GSCALE, M_SSCALE = t:get_method("get_LocalScale"), t:get_method("set_LocalScale")
    M_GBP, M_GBR = t:get_method("get_BaseLocalPosition"), t:get_method("get_BaseLocalRotation")
    M_GBS = t:get_method("get_BaseLocalScale")
end

local faces = {}
local watched, pre = {}, {}
H.status = ""

function H.watch(names)
    for _, n in ipairs(names) do watched[n] = true end
end

-- 返回本次动画更新后、固定前的姿势；未接管的骨骼返回 nil。
function H.pose(face_addr, name)
    local p = pre[face_addr]
    p = p and p[name]
    if p then return p[1], p[2], p[3] end
    return nil
end

-- 每种层读回结果只记录一次，保留真实引擎差异，避免重试刷屏。
local reported = {}
local function report_rate(e, i, target, ok, err, read_ok, actual)
    if not (log and log.info) then return end
    local text = string.format("[SKS FaceHold] face=%s layer=%d target=%s setter_ok=%s result=%s read_ok=%s actual=%s",
        tostring(e.addr), i, tostring(target), tostring(ok), ok and "ok" or tostring(err), tostring(read_ok), tostring(actual))
    if reported[text] then return end
    reported[text] = true
    log.info(text)
end

-- 逐层保护恢复；清理时仅保留失败项，不能在后续重试中重写已经交还游戏的层。
local function set_rates(e, muted, consume)
    local success = true
    local pending_layers, pending_rates = {}, {}
    for i, layer in ipairs(e.layers or {}) do
        local rate = muted and 0.0 or e.rates[i]
        if rate ~= nil then
            local ok, err = pcall(layer.call, layer, "set_BlendRate(System.Single)", rate + 0.0)
            local read_ok, actual = pcall(layer.call, layer, "get_BlendRate")
            report_rate(e, i, rate, ok, err, read_ok, actual)
            if not ok or not read_ok or not tonumber(actual) or math.abs(actual - rate) > EPS then
                success = false
                pending_layers[#pending_layers + 1], pending_rates[#pending_rates + 1] = layer, e.rates[i]
            end
        end
    end
    if consume then
        e.layers = #pending_layers > 0 and pending_layers or nil
        e.rates = #pending_rates > 0 and pending_rates or nil
    end
    return success
end

local function muted(e)
    for i, layer in ipairs(e.layers) do
        local ok, rate = pcall(layer.call, layer, "get_BlendRate")
        if not ok or not tonumber(rate) or math.abs(rate) > EPS then
            if log and log.info then
                log.info(string.format("[SKS FaceHold] mute lost face=%s layer=%d wait=%d read_ok=%s actual=%s",
                    tostring(e.addr), i, e.wait, tostring(ok), tostring(rate)))
            end
            return false
        end
    end
    return true
end

-- 固定操作必须成对撤销：游戏动画可能只写旋转，不会替我们恢复位置或缩放。
-- 清理时逐通道保护，失效的骨骼不能阻止其余骨骼及动画层恢复。
local function restore_value(method, joint, values, i, consume)
    if values[i] == nil then return true end
    if not pcall(method.call, method, joint, values[i]) then return false end
    if consume then values[i] = nil end
    return true
end

local function restore_pose(e, consume)
    local pose = e.animated or e.resume
    if not pose then return true end
    local success = true
    for i, j in ipairs(e.joints) do
        if not restore_value(M_SPOS, j.joint, pose[1], i, consume) then success = false end
        if not restore_value(M_SROT, j.joint, pose[2], i, consume) then success = false end
        if not restore_value(M_SSCALE, j.joint, pose[3], i, consume) then success = false end
    end
    return success
end

-- 逐通道恢复被固定的部件目标骨骼；只有全部成功才消费快照，失效引用留给失败重试或重建。
local function restore_targets(e, consume)
    local pose, t = e.tanimated, e.tpose
    if not (pose and t) then
        if consume then e.tanimated = nil end
        return true
    end
    local success = true
    for k, joint in ipairs(t.joints) do
        if not restore_value(M_SPOS, joint.joint, pose[1], k, consume) then success = false end
        if not restore_value(M_SROT, joint.joint, pose[2], k, consume) then success = false end
        if not restore_value(M_SSCALE, joint.joint, pose[3], k, consume) then success = false end
    end
    if consume and success then e.tanimated = nil end
    return success
end

-- 清理失败保留原值；调用方销毁 rig 时才允许无条件释放引用。
local function cleanup(e)
    if restore_pose(e, true) then e.animated, e.resume = nil, nil end
    restore_targets(e, true)
    set_rates(e, false, true)
    return not (e.animated or e.resume or e.tanimated or e.layers)
end

local function fail(e, reason)
    cleanup(e)
    e.phase, e.retry = "failed", RETRY
    H.status = reason
end

local function snapshot(e)
    local pos, rot, scale = {}, {}, {}
    for i, j in ipairs(e.joints) do
        pos[i], rot[i] = M_GPOS:call(j.joint), M_GROT:call(j.joint)
        if M_GSCALE and M_SSCALE then scale[i] = M_GSCALE:call(j.joint) end
    end
    return pos, rot, scale
end

local function same(a, b, rotation)
    for i = 1, #a do
        local p, q = a[i], b[i]
        if math.abs(p.x - q.x) > EPS or math.abs(p.y - q.y) > EPS or math.abs(p.z - q.z) > EPS
            or (rotation and math.abs(p.w - q.w) > EPS) then return false end
    end
    return true
end

local function matches_neutral(e, pose)
    return same(e.pos, pose[1]) and same(e.rot, pose[2], true) and same(e.scale, pose[3])
end

-- 目标部件骨骼：与源骨骼同名、地址不同且地址去重；原生复制用名字在目标 Transform 上查找。
local function resolve_targets(targets, joints)
    if not targets or #targets == 0 or not (M_GBP and M_GBR and M_GBS) then return nil end
    local out, seen = {}, {}
    pcall(function()
        for _, target in ipairs(targets) do
            local tr = target.mesh:call("get_GameObject"):call("get_Transform")
            if tr then
                for i, src in ipairs(joints) do
                    local joint = tr:call("getJointByName(System.String)", src.name)
                    if joint then
                        local addr = joint:get_address()
                        if addr ~= src.joint:get_address() and not seen[addr] then
                            seen[addr] = true
                            out[#out + 1] = { joint = joint, name = src.name, index = i }
                        end
                    end
                end
            end
        end
    end)
    return #out > 0 and out or nil
end

-- 部件重建后目标骨骼引用会失效；用 mesh 地址签名识别，签名变化时重新采集。
local function targets_sig(targets)
    if not targets or #targets == 0 then return "" end
    local parts = {}
    for _, target in ipairs(targets) do
        local ok, addr = pcall(function() return target.mesh:get_address() end)
        parts[#parts + 1] = ok and tostring(addr) or tostring(target.name)
    end
    return table.concat(parts, ",")
end

local function close3(a, b)
    return math.abs(a.x - b.x) <= COPY_EPS and math.abs(a.y - b.y) <= COPY_EPS and math.abs(a.z - b.z) <= COPY_EPS
end

local function close4(a, b)
    return close3(a, b) and math.abs(a.w - b.w) <= COPY_EPS
end

-- 依据原生复制公式算出目标中性（源中性 - 源 Base + 目标 Base）；只有当前目标姿势确实等于该
-- 公式时才算被逐帧复制，避免把未被驱动的部件骨骼也写死。旋转按原生做法逐分量运算，不做归一化。
local function target_pose(e)
    local V3, Q4 = Vector3f, Quaternion
    if not (V3 and Q4) then return nil end
    local pos, rot, scale, joints = {}, {}, {}, {}
    local matches, total = 0, #e.targets
    for _, t in ipairs(e.targets) do
        local i = t.index
        local sbp, sbq, sbs = M_GBP:call(e.joints[i].joint), M_GBR:call(e.joints[i].joint), M_GBS:call(e.joints[i].joint)
        local tbp, tbq, tbs = M_GBP:call(t.joint), M_GBR:call(t.joint), M_GBS:call(t.joint)
        local p, q, s = e.pos[i], e.rot[i], e.scale[i]
        if p and q and s and sbp and sbq and sbs and tbp and tbq and tbs then
            local np = V3.new(p.x - sbp.x + tbp.x, p.y - sbp.y + tbp.y, p.z - sbp.z + tbp.z)
            local nq = Q4.new(q.w - sbq.w + tbq.w, q.x - sbq.x + tbq.x, q.y - sbq.y + tbq.y, q.z - sbq.z + tbq.z)
            local ns = V3.new(s.x - sbs.x + tbs.x, s.y - sbs.y + tbs.y, s.z - sbs.z + tbs.z)
            local ap, aq, as = M_GPOS:call(t.joint), M_GROT:call(t.joint), M_GSCALE:call(t.joint)
            if ap and aq and as and close3(ap, np) and close4(aq, nq) and close3(as, ns) then
                joints[#joints + 1] = t
                pos[#pos + 1], rot[#rot + 1], scale[#scale + 1] = np, nq, ns
                matches = matches + 1
            end
        end
    end
    if matches == 0 then return nil end
    return { joints = joints, pos = pos, rot = rot, scale = scale, matches = matches, total = total }
end

local function snapshot_targets(t)
    local pos, rot, scale = {}, {}, {}
    for k, joint in ipairs(t.joints) do
        pos[k], rot[k], scale[k] = M_GPOS:call(joint.joint), M_GROT:call(joint.joint), M_GSCALE:call(joint.joint)
    end
    return pos, rot, scale
end

local function write_targets(t)
    for k, joint in ipairs(t.joints) do
        M_SPOS:call(joint.joint, t.pos[k])
        M_SROT:call(joint.joint, t.rot[k])
        M_SSCALE:call(joint.joint, t.scale[k])
    end
end

local function start(adapter, face, targets)
    local e = { addr = face:get_address(), phase = "failed", wait = 0, retry = RETRY,
        target_sig = targets_sig(targets) }
    local ok, joints = pcall(adapter.expression_joints, face)
    local ok2, layers = pcall(adapter.face_layers, face)
    if not ok or not ok2 or type(joints) ~= "table" or #joints == 0 then
        H.status = "找不到面部表情骨骼"
        return e
    end
    if type(layers) ~= "table" or #layers == 0 then
        H.status = "找不到面部动画层，稍后重试"
        return e
    end
    e.joints, e.layers, e.rates = joints, layers, {}
    e.targets = resolve_targets(targets, e.joints)
    for i, layer in ipairs(layers) do
        local okr, r = pcall(layer.call, layer, "get_BlendRate")
        if not okr or not tonumber(r) then
            -- 尚未静音任何层，不得用猜测的混合率恢复动画。
            e.layers, e.rates = nil, nil
            H.status = "无法读取面部动画层，稍后重试"
            return e
        end
        e.rates[i] = tonumber(r)
    end
    e.resume = { snapshot(e) }
    if not set_rates(e, true) then
        fail(e, "无法静音面部动画层，稍后重试")
        return e
    end
    e.phase = "capture"
    H.status = "正在读取中性脸"
    return e
end

local function capture(e)
    if not muted(e) then
        fail(e, "无法静音面部动画层，稍后重试")
        return
    end
    e.wait = e.wait + 1
    if e.wait < SETTLE then return end
    local pos, rot, scale = snapshot(e)
    local settled = e.pos and same(e.pos, pos) and same(e.rot, rot, true) and same(e.scale, scale)
    e.pos, e.rot, e.scale = pos, rot, scale
    if settled then
        if e.targets then e.tpose = target_pose(e) end
        if not set_rates(e, false) then
            fail(e, "无法恢复面部动画层，稍后重试")
            return
        end
        e.layers, e.rates = nil, nil
        e.phase = "await"
        -- 首次读档时动画层可静音，骨架却可能尚未求值。静音前后相同的姿势在首次运动时重新采集。
        e.verify_on_motion = matches_neutral(e, e.resume)
        if log and log.info then
            log.info(string.format("[SKS FaceHold] captured face=%s joints=%d wait=%d pose_changed=%s targets=%d/%d", tostring(e.addr), #e.joints, e.wait,
                tostring(not e.verify_on_motion),
                e.tpose and e.tpose.matches or 0, e.tpose and e.tpose.total or #(e.targets or {})))
        end
    elseif e.wait >= MAX_WAIT then
        fail(e, "中性脸未稳定，稍后重试")
    end
end

local function write_pose(e)
    for i, j in ipairs(e.joints) do
        M_SPOS:call(j.joint, e.pos[i])
        M_SROT:call(j.joint, e.rot[i])
        if e.scale[i] then M_SSCALE:call(j.joint, e.scale[i]) end
    end
end

-- 返回 false 时，源和部件仍处于本帧的动画姿势，可直接开始新一轮静音。
local function hold(e, addr)
    -- 先读源与目标部件的动画姿势，再一起写回中性；两者必须来自同一帧，否则恢复会互相覆盖。
    e.animated = { snapshot(e) }
    if e.verify_on_motion and not matches_neutral(e, e.animated) then return false end
    if e.tpose then e.tanimated = { snapshot_targets(e.tpose) } end
    e.resume = nil
    local p = pre[addr]
    if not p then p = {}; pre[addr] = p end
    for i, j in ipairs(e.joints) do
        if watched[j.name] then
            p[j.name] = { e.animated[1][i], e.animated[2][i], e.animated[3][i] }
        end
    end
    write_pose(e)
    if e.tpose then write_targets(e.tpose) end
    e.phase = "hold"
    H.status = L.f("已禁用 %d 根表情骨骼", #e.joints)
    return true
end

-- Behaviour 可重设层混合率，故静音须在 Motion 求值前重新应用。
-- 同时撤销上一轮固定，保证稀疏动画和取消固定都不依赖游戏覆盖全部通道。
function H.prepare()
    for addr, e in pairs(faces) do
        if e.phase == "release" then
            if cleanup(e) then faces[addr] = nil end
        elseif e.phase == "capture" then
            if not set_rates(e, true) then fail(e, "无法静音面部动画层，稍后重试") end
        elseif e.phase == "await" or e.phase == "hold" then
            -- 待确认期间也在求值前撤销部件写入，重新采集时不能把旧的固定值留在部件上。
            if not restore_pose(e) or (e.verify_on_motion and not restore_targets(e)) then
                fail(e, "无法恢复面部骨骼，稍后重试")
            end
        end
    end
end

local function layer_key(layer)
    if layer.get_address then return layer:get_address() end
    return layer
end

-- Motion 换层后仅放掉已失效且不再属于当前 Motion 的旧层；仍可读的旧层必须恢复原混合率。
local function forget_expired_layers(e, adapter, face)
    if not e.layers then return end
    local ok, current = pcall(adapter.face_layers, face)
    if not ok or type(current) ~= "table" then return end
    local live, layers, rates = {}, {}, {}
    for _, layer in ipairs(current) do live[layer_key(layer)] = true end
    for i, layer in ipairs(e.layers) do
        local readable, rate = pcall(layer.call, layer, "get_BlendRate")
        if live[layer_key(layer)] or (readable and tonumber(rate)) then
            layers[#layers + 1], rates[#rates + 1] = layer, e.rates[i]
        end
    end
    e.layers, e.rates = #layers > 0 and layers or nil, #layers > 0 and rates or nil
end

-- 仅在动画更新后采样一次信号；失败项退避重试，不把失败姿势作为中性脸。
function H.update(adapter, list, targets)
    if not adapter.expression_joints or not adapter.face_layers then
        H.status = "本游戏暂不支持禁用骨骼表情"
        return
    end
    methods()
    local seen = {}
    for _, face in ipairs(list) do
        local addr = face:get_address()
        seen[addr] = true
        local passed = targets and targets[addr] or nil
        local sig = targets_sig(passed)
        local e = faces[addr]
        if e and e.target_sig ~= sig then
            -- 穿戴部件已重建：目标骨骼引用失效，先恢复源骨骼并重新采集。
            e.targets, e.tpose, e.tanimated = nil, nil, nil
            if cleanup(e) then e = nil else e.phase, e.retry = "failed", RETRY end
        end
        if e and e.phase == "release" and cleanup(e) then e = nil end
        if e and e.phase == "failed" then
            e.retry = e.retry - 1
            local restored = cleanup(e)
            if e.retry <= 0 then
                if not restored then
                    forget_expired_layers(e, adapter, face)
                    restored = cleanup(e)
                end
                if not restored then
                    -- 部件引用可能已随重建失效；放掉目标骨骼，至少恢复源骨骼和动画层。
                    e.targets, e.tpose, e.tanimated = nil, nil, nil
                    restored = cleanup(e)
                end
                if restored then e = nil else e.retry = RETRY end
            end
        end
        if e and (e.phase == "await" or e.phase == "hold") and not hold(e, addr) then e = nil end
        if not e then
            pre[addr] = nil
            e = start(adapter, face, passed)
            faces[addr] = e
        end
        if e.phase == "capture" then capture(e) end
    end
    for addr, e in pairs(faces) do
        if not seen[addr] then
            restore_pose(e)
            restore_targets(e)
            set_rates(e, false)
            faces[addr], pre[addr] = nil, nil
        end
    end
end

-- LateUpdateBehavior 的最终写回不重新读取信号，避免把中性姿势当作动画输入。
function H.reapply()
    for _, e in pairs(faces) do
        if e.phase == "hold" then
            write_pose(e)
            if e.tpose then write_targets(e.tpose) end
        end
    end
end

-- 限量读取最终源骨架与网格骨架；引用只在当前回调内使用，不参与姿势写入。
local function distance(a, b, rotation)
    if not a or not b then return 0 end
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y), math.abs(a.z - b.z),
        rotation and math.abs(a.w - b.w) or 0)
end

local function object_address(obj)
    local ok, addr = pcall(function() return obj:get_address() end)
    return ok and tostring(addr) or tostring(obj)
end

local function pose_text(p, q, s)
    return string.format("p=%.6g,%.6g,%.6g q=%.6g,%.6g,%.6g,%.6g s=%.6g,%.6g,%.6g",
        p.x, p.y, p.z, q.x, q.y, q.z, q.w, s and s.x or 1, s and s.y or 1, s and s.z or 1)
end

function H.audit(rigs, stage)
    if not (log and log.info) then return end
    for _, rig in ipairs(rigs) do
        local e = faces[rig.face:get_address()]
        if e and e.phase == "hold" and e.animated then
            e.audit = e.audit or {}
            local a = e.audit[stage] or { next = 0, count = 0 }
            e.audit[stage] = a
            if a.count < 30 and os.clock() >= a.next then
                a.next, a.count = os.clock() + 2, a.count + 1
                local ok, err = pcall(function()
                    local animated, current, index, jaw = 0, 0, 1, nil
                    for i, j in ipairs(e.joints) do
                        local d = math.max(distance(e.animated[1][i], e.pos[i]), distance(e.animated[2][i], e.rot[i], true),
                            distance(e.animated[3][i], e.scale[i]))
                        if d > animated then animated, index = d, i end
                        if j.name == "C_Jaw_LOD02" then jaw = i end
                        current = math.max(current, distance(M_GPOS:call(j.joint), e.pos[i]),
                            distance(M_GROT:call(j.joint), e.rot[i], true), M_GSCALE and distance(M_GSCALE:call(j.joint), e.scale[i]) or 0)
                    end
                    log.info(string.format("[SKS FaceHold audit] stage=%s face=%s animated_delta=%.6g current_delta=%.6g targets=%d",
                        stage, tostring(e.addr), animated, current, #rig.targets))
                    local indices = { index }
                    if jaw and jaw ~= index then indices[#indices + 1] = jaw end
                    for _, i in ipairs(indices) do
                        local j = e.joints[i]
                        log.info(string.format("[SKS FaceHold audit] stage=%s joint=%s address=%s neutral %s animated %s current %s", stage, j.name, object_address(j.joint),
                            pose_text(e.pos[i], e.rot[i], e.scale[i]),
                            pose_text(e.animated[1][i], e.animated[2][i], e.animated[3][i]),
                            pose_text(M_GPOS:call(j.joint), M_GROT:call(j.joint), M_GSCALE and M_GSCALE:call(j.joint))))
                        for _, target in ipairs(rig.targets) do
                            local tr = target.mesh:call("get_GameObject"):call("get_Transform")
                            local tj = tr:call("getJointByName(System.String)", j.name)
                            if tj then
                                local tp, tq, ts = M_GPOS:call(tj), M_GROT:call(tj), M_GSCALE and M_GSCALE:call(tj)
                                -- 与模块写回的目标中性比较：等于说明本帧渲染使用的是固定姿势；不等说明之后又被覆盖。
                                local nd = -1
                                if e.tpose and tp and tq then
                                    for k, tt in ipairs(e.tpose.joints) do
                                        if tt.name == j.name then
                                            nd = math.max(distance(tp, e.tpose.pos[k]), distance(tq, e.tpose.rot[k], true),
                                                e.tpose.scale[k] and distance(ts, e.tpose.scale[k]) or 0)
                                            break
                                        end
                                    end
                                end
                                log.info(string.format("[SKS FaceHold audit] stage=%s mesh=%s transform=%s joint=%s address=%s neutral_delta=%.6g %s", stage,
                                    tostring(target.name), tostring(tr:get_address()), j.name, object_address(tj), nd, pose_text(tp, tq, ts)))
                            end
                        end
                    end
                end)
                if not ok then log.info("[SKS FaceHold audit] " .. tostring(err)) end
            end
        end
    end
end

function H.capturing()
    for _, e in pairs(faces) do if e.phase == "capture" or e.phase == "await" then return true end end
    return false
end

function H.active()
    return next(faces) ~= nil
end

-- 普通取消保留未恢复的原值供下帧重试；rig 销毁或脚本卸载时必须传入 discard。
function H.release(discard)
    for addr, e in pairs(faces) do
        e.phase = "release"
        if cleanup(e) or discard then faces[addr] = nil end
    end
    pre = {}
end

return H
