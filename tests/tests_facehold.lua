-- 验证中性姿势采集、动画层恢复、最终骨骼写回与表情开关。
-- 假动画由测试显式求值，`reapply` 不得推进采集或覆盖动画信号快照。
local SKS = require("ShapeKeySystem_Core.API")
local H = require("ShapeKeySystem_Core.FaceHold")
local hf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[hold] " .. what)
    if not cond then hf = hf + 1 end
end
local near = function(a, b) return math.abs(a - b) < 1e-6 end

local function clone3(v) return { x = v.x, y = v.y, z = v.z } end
local function clone4(v) return { x = v.x, y = v.y, z = v.z, w = v.w } end
local function clone_base(base)
    return { pos = clone3(base.pos), rot = clone4(base.rot), scale = clone3(base.scale) }
end
-- 源骨骼与穿戴部件的 Base 不同，复制中性必须逐分量重定位，不能直接拿源中性或目标 Base。
local SOURCE_BASE = { pos = { x = 0, y = 0.005, z = 0 }, rot = { x = 0.02, y = 0, z = 0, w = 0.9998 },
    scale = { x = 1.05, y = 0.95, z = 1.1 } }
local TARGET_BASE = { pos = { x = 2, y = 3, z = 4 }, rot = { x = 0.05, y = 0.02, z = 0, w = 0.99855 },
    scale = { x = 0.8, y = 1.3, z = 0.9 } }

-- 模拟动画求值和分层故障；中性缩放保留捏脸比例，不等于单位缩放。
local function fake_face(addr, rates)
    local f = { addr = addr, layers = {}, joints = {}, anim = 0.01, motion_frames = 0 }
    for i, r in ipairs(rates) do
        local l = { rate = r, gets = 0, sets = 0 }
        l.call = function(self, m, v)
            if m == "get_BlendRate" then
                self.gets = self.gets + 1
                if self.get_error then error("模拟读取失败") end
                if self.get_nil then return nil end
                return self.rate
            end
            if m == "set_BlendRate(System.Single)" then
                self.sets = self.sets + 1
                assert(math.type(v) == "float", "混合率必须按 System.Single 传递")
                if self.set_error then error("模拟写入失败") end
                if not (self.ignore_mute and v == 0) then self.rate = v end
            end
        end
        f.layers[i] = l
    end
    for _, name in ipairs({ "C_Jaw_LOD02", "C_Nose_LOD01" }) do
        local j = { name = name, base = clone_base(SOURCE_BASE), pos = { x = 0, y = 0, z = 0 },
            rot = { x = 0, y = 0, z = 0, w = 1 }, scale = { x = 1.1, y = 0.9, z = 1.2 } }
        j.get_address = function(self) return self.addr end
        j.addr = addr * 10 + #f.joints
        j.get_LocalPosition = function(self) return { x = self.pos.x, y = self.pos.y, z = self.pos.z } end
        j.get_LocalRotation = function(self) return { x = self.rot.x, y = self.rot.y, z = self.rot.z, w = self.rot.w } end
        j.get_LocalScale = function(self) return { x = self.scale.x, y = self.scale.y, z = self.scale.z } end
        j.get_BaseLocalPosition = function(self) return clone3(self.base.pos) end
        j.get_BaseLocalRotation = function(self) return clone4(self.base.rot) end
        j.get_BaseLocalScale = function(self) return clone3(self.base.scale) end
        j.set_LocalPosition = function(self, v) self.pos = v; f.writes = (f.writes or 0) + 1 end
        j.set_LocalRotation = function(self, q) self.rot = q end
        j.set_LocalScale = function(self, v) self.scale = v end
        f.joints[#f.joints + 1] = { joint = j, name = name }
    end
    f.get_address = function() return addr end
    f.behave = function()
        if f.reset_rates then
            for _, l in ipairs(f.layers) do l.rate = 1.0 end
        end
    end
    f.animate = function()
        f.motion_frames = f.motion_frames + 1
        local muted = #f.layers > 0
        for _, l in ipairs(f.layers) do if l.rate ~= 0 then muted = false end end
        for _, j in ipairs(f.joints) do
            local drift = muted and f.unstable == "position" and f.motion_frames * 0.001 or 0
            j.joint.pos = { x = 0, y = 0.02 + (muted and 0 or f.anim) + drift, z = 0 }
            j.joint.rot = muted and { x = 0, y = 0, z = 0, w = 1 } or { x = 0.1, y = 0, z = 0, w = 0.995 }
            if muted and f.unstable == "rotation" then
                j.joint.rot = { x = 0.8, y = 0, z = 0, w = f.motion_frames % 2 == 0 and 0.6 or -0.6 }
            end
            local scale_drift = muted and f.unstable == "scale" and f.motion_frames * 0.001 or 0
            j.joint.scale = { x = 1.1 + (muted and 0 or 0.1) + scale_drift, y = 0.9, z = 1.2 }
        end
    end
    return f
end
local adapter = {
    expression_joints = function(face) return face.joints end,
    face_layers = function(face) return face.layers end,
}
-- 行为更新先重设权重；pre-Motion 再静音和撤销上次固定，最后才求值动画。
local function frame(faces, list, game)
    for _, f in ipairs(faces) do f.behave() end
    H.prepare()
    for _, f in ipairs(faces) do f.animate() end
    H.update(game or adapter, list or faces)
end

-- 最多等待一个正常采集周期，失败时由调用方断言，不无限循环。
local function wait_hold(f, game)
    for _ = 1, 12 do
        frame({ f }, nil, game)
        if not H.capturing() and (f.writes or 0) > 0 then return true end
    end
    return false
end

-- 模拟被其它插件逐帧复制的穿戴部件：目标骨骼有自己的 Base，复制按原生公式逐分量写 LocalPRS。
local NEXT_TARGET_ADDR = 0x9000
local function fake_bone(name, base)
    NEXT_TARGET_ADDR = NEXT_TARGET_ADDR + 1
    local j = { name = name, base = clone_base(base), writes = 0, addr = NEXT_TARGET_ADDR,
        pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 },
        scale = { x = 1, y = 1, z = 1 } }
    j.get_address = function(self) return self.addr end
    j.get_LocalPosition = function(self) return clone3(self.pos) end
    j.get_LocalRotation = function(self) return clone4(self.rot) end
    j.get_LocalScale = function(self) return clone3(self.scale) end
    j.get_BaseLocalPosition = function(self) return clone3(self.base.pos) end
    j.get_BaseLocalRotation = function(self) return clone4(self.base.rot) end
    j.get_BaseLocalScale = function(self) return clone3(self.base.scale) end
    j.set_LocalPosition = function(self, v)
        if self.set_error then error("模拟目标位置写入失败") end
        self.pos = clone3(v); self.writes = self.writes + 1
    end
    j.set_LocalRotation = function(self, q)
        if self.set_error then error("模拟目标旋转写入失败") end
        self.rot = clone4(q); self.writes = self.writes + 1
    end
    j.set_LocalScale = function(self, v)
        if self.set_error then error("模拟目标缩放写入失败") end
        self.scale = clone3(v); self.writes = self.writes + 1
    end
    return j
end

local function fake_part(addr, joints)
    local tr = { getJointByName = function(self, n) return self.joints[n] end, joints = joints }
    local go = { call = function(_, m) if m == "get_Transform" then return tr end end }
    tr.get_GameObject = function() return go end
    tr.call = function(self, m, ...)
        local fn = self[m:match("^([%w_]+)")]
        return fn and fn(self, ...) or nil
    end
    local mesh = { get_address = function() return addr end }
    mesh.call = function(_, m) if m == "get_GameObject" then return go end end
    return { name = "part:" .. tostring(addr), joints = joints, mesh = mesh }
end

-- 原生逐帧复制：target = source.Local - source.Base + target.Base（四元数逐分量，不归一化）。
local function target_copy(face, parts)
    local source = {}
    for _, entry in ipairs(face.joints) do source[entry.name] = entry.joint end
    for _, part in ipairs(parts) do
        for name, target in pairs(part.joints) do
            local src = source[name]
            if src then
                local sbp, sbq, sbs = src:get_BaseLocalPosition(), src:get_BaseLocalRotation(), src:get_BaseLocalScale()
                local tbp, tbq, tbs = target:get_BaseLocalPosition(), target:get_BaseLocalRotation(), target:get_BaseLocalScale()
                target.pos = { x = src.pos.x - sbp.x + tbp.x, y = src.pos.y - sbp.y + tbp.y, z = src.pos.z - sbp.z + tbp.z }
                target.rot = { x = src.rot.x - sbq.x + tbq.x, y = src.rot.y - sbq.y + tbq.y,
                    z = src.rot.z - sbq.z + tbq.z, w = src.rot.w - sbq.w + tbq.w }
                target.scale = { x = src.scale.x - sbs.x + tbs.x, y = src.scale.y - sbs.y + tbs.y,
                    z = src.scale.z - sbs.z + tbs.z }
            end
        end
    end
end

local function copied_frame(face, parts)
    face.behave()
    H.prepare()
    face.animate()
    target_copy(face, parts)
    H.update(adapter, { face }, { [face:get_address()] = parts })
end

local function wait_copied_hold(face, parts)
    for _ = 1, 12 do
        copied_frame(face, parts)
        if not H.capturing() and (face.writes or 0) > 0 then return true end
    end
    return false
end

H.release()
H.watch({ "C_Jaw_LOD02" })
local a = fake_face(0xA, { 1.0, 0.5 })
frame({ a })
check(H.capturing() and a.layers[1].rate == 0 and a.layers[2].rate == 0, "capture mutes every layer of the face")
for _ = 1, 10 do H.reapply() end
check(H.capturing() and a.layers[1].rate == 0 and not a.writes, "reapply neither writes nor advances a capture")
for _ = 1, 12 do
    frame({ a })
    if a.layers[1].rate == 1.0 then break end
end
check(H.capturing() and a.layers[1].rate == 1.0 and a.layers[2].rate == 0.5 and not a.writes,
    "restored layers still await the next animation update before hold")
check(H.pose(0xA, "C_Jaw_LOD02") == nil, "capture completion publishes no muted animation snapshot")
for _ = 1, 10 do H.reapply() end
check(H.capturing() and not a.writes, "reapply cannot end the restored-layer await phase")
check(wait_hold(a), "capture becomes a hold after animation resumes")
local jaw = a.joints[1].joint
check(near(jaw.pos.y, 0.02) and jaw.rot.w == 1 and near(jaw.scale.x, 1.1),
    "held joints restore captured position rotation and sculpt scale")
local hp, hr, hs = H.pose(0xA, "C_Jaw_LOD02")
check(hp and near(hp.y, 0.03) and hr.x == 0.1, "a watched joint keeps its animated pose for readers")
check(hs and near(hs.x, 1.2), "a watched joint keeps its pre-hold animated scale for bone-chain readers")
check(H.pose(0xA, "C_Nose_LOD01") == nil, "unwatched joints keep no animated pose")

-- 模拟后续系统再次覆盖骨骼，最终写回只恢复中性姿势，不能重新采样动画输入。
a.anim = 0.2
a.animate()
check(near(jaw.pos.y, 0.22) and near(jaw.scale.x, 1.2), "a later animation pass can overwrite held bones and scale")
H.reapply()
local rp, rr, rs = H.pose(0xA, "C_Jaw_LOD02")
check(near(jaw.pos.y, 0.02) and jaw.rot.w == 1 and near(jaw.scale.x, 1.1),
    "reapply repairs later position rotation and scale overwrites")
check(rp == hp and rr == hr and near(rp.y, 0.03), "reapply preserves the original animated signal snapshot")
check(rs == hs and rs and near(rs.x, 1.2), "reapply preserves the same pre-hold animated scale object")
frame({ a })
local next_pose = H.pose(0xA, "C_Jaw_LOD02")
check(next_pose and near(next_pose.y, 0.22), "only the next motion update refreshes the animated signal snapshot")

-- 移除和释放必须恢复正在采集的动画层，并放掉旧姿势。
local b = fake_face(0xB, { 1.0 })
frame({ a, b })
check(H.capturing() and b.layers[1].rate == 0, "a second face starts its own capture")
frame({ a, b }, { a })
check(b.layers[1].rate == 1.0 and not H.capturing(), "a face dropped mid-capture gets its layer rates back")
local c = fake_face(0xC, { 0.8 })
frame({ c })
H.release()
check(c.layers[1].rate == 0.8 and not H.active() and H.pose(0xA, "C_Jaw_LOD02") == nil,
    "release restores muted layers and forgets every face")

-- 直接调用荒野适配器，缺失或枚举不完整的 Motion 不得返回可采集层集合。
local wilds = require("ShapeKeySystem_Games.Wilds.Adapter")
local function motion_face(motion)
    local go = { call = function(_, method)
        assert(method == "getComponent(System.Type)")
        return motion
    end }
    return { call = function(_, method)
        assert(method == "get_GameObject")
        return go
    end }
end
local function motion_layers(count, layers)
    return { call = function(_, method, index)
        if method == "getLayerCount" then return count end
        assert(method == "getLayer(System.UInt32)")
        return layers[index + 1]
    end }
end
local layer_a, layer_b = {}, {}
check(wilds.face_layers(motion_face(nil)) == nil, "Wilds rejects a face without Motion")
check(wilds.face_layers(motion_face(motion_layers(nil, {}))) == nil, "Wilds rejects an unreadable motion layer count")
check(wilds.face_layers(motion_face(motion_layers(0, {}))) == nil, "Wilds rejects an empty motion layer collection")
check(wilds.face_layers(motion_face(motion_layers(2, { layer_a }))) == nil,
    "Wilds rejects a missing layer instead of returning a partially muted set")
local all_layers = wilds.face_layers(motion_face(motion_layers(2, { layer_a, layer_b })))
check(all_layers and #all_layers == 2 and all_layers[1] == layer_a and all_layers[2] == layer_b,
    "Wilds returns every motion layer in native order")

-- 静音不可靠时不得把正在播放的表情误认作中性脸。
local empty = fake_face(0xD, {})
for _ = 1, 5 do frame({ empty }) end
check(not H.capturing() and not empty.writes and not H.status:find("已禁用", 1, true),
    "valid bones with no motion layers cannot report a successful hold")
for i, failure in ipairs({ "get_error", "get_nil", "set_error", "ignore_mute" }) do
    H.release()
    local f = fake_face(0xD0 + i, { 0.8, 0.4 })
    f.layers[2][failure] = true
    for _ = 1, 5 do frame({ f }) end
    check(not H.capturing() and H.pose(f.addr, "C_Jaw_LOD02") == nil and not H.status:find("已禁用", 1, true),
        failure .. " prevents a false neutral hold")
    check(near(f.layers[1].rate, 0.8) and near(f.layers[2].rate, 0.4),
        failure .. " preserves or restores each original layer rate")
    if failure == "get_error" or failure == "get_nil" then
        check(f.layers[1].sets == 0 and f.layers[2].sets == 0,
            failure .. " never writes guessed rates after an initial read failure")
    end
    f.layers[2][failure] = nil
    for _ = 1, 30 do frame({ f }) end
    check(wait_hold(f), failure .. " recovers automatically after the layer becomes usable")
end
H.release()
local reset_rates = fake_face(0xD9, { 1.0, 1.0 })
reset_rates.reset_rates = true
frame({ reset_rates })
check(H.capturing() and reset_rates.layers[1].rate == 0, "capture starts after the first behaviour update")
reset_rates.behave()
check(reset_rates.layers[1].rate == 1.0 and reset_rates.layers[2].rate == 1.0,
    "behaviour can overwrite every muted layer before the next Motion update")
H.prepare()
check(reset_rates.layers[1].rate == 0 and reset_rates.layers[2].rate == 0,
    "pre-Motion reasserts capture muting after behaviour resets every layer")
reset_rates.animate()
H.update(adapter, { reset_rates })
check(wait_hold(reset_rates), "capture succeeds while behaviour resets all layer rates on every frame")
check(reset_rates.layers[1].rate == 1.0 and reset_rates.layers[2].rate == 1.0,
    "capture restores both native rates before a behaviour-reset face enters hold")
H.release()
local changed = fake_face(0xDA, { 0.75 })
frame({ changed })
H.prepare()
changed.layers[1].rate = 0.2
changed.animate()
H.update(adapter, { changed })
check(not H.capturing() and H.pose(changed.addr, "C_Jaw_LOD02") == nil
    and near(changed.layers[1].rate, 0.75) and near(changed.joints[1].joint.pos.y, 0.03),
    "a layer unmuted after pre-Motion aborts capture and restores the original rate and native pose")

-- 稀疏动画只增量更新一个通道；未被动画触及的通道不得积累上次固定值。
H.release()
local sparse = fake_face(0xDB, { 1.0 })
check(wait_hold(sparse), "sparse-animation fixture captures a neutral pose before limiting native writes")
sparse.animate = function()
    local j = sparse.joints[1].joint
    j.pos = { x = j.pos.x, y = j.pos.y + 0.01, z = j.pos.z }
end
for i = 1, 3 do
    frame({ sparse })
    local p, r, s = H.pose(0xDB, "C_Jaw_LOD02")
    check(p and near(p.y, 0.03 + i * 0.01) and r and near(r.x, 0.1) and s and near(s.x, 1.2),
        "pre-Motion restores native channels before sparse animation frame " .. i)
    check(near(sparse.joints[1].joint.pos.y, 0.02) and near(sparse.joints[2].joint.scale.x, 1.1),
        "sparse animation remains visually held on watched and unwatched joints frame " .. i)
end
H.prepare()
local sparse_jaw, sparse_nose = sparse.joints[1].joint, sparse.joints[2].joint
check(near(sparse_jaw.pos.y, 0.06) and near(sparse_jaw.rot.x, 0.1) and near(sparse_jaw.scale.x, 1.2),
    "pre-Motion restores every written channel on a watched joint")
check(near(sparse_nose.pos.y, 0.03) and near(sparse_nose.rot.x, 0.1) and near(sparse_nose.scale.x, 1.2),
    "pre-Motion also restores every written channel on an unwatched joint")
sparse.animate()
H.update(adapter, { sparse })
H.reapply()
H.release()
check(near(sparse_jaw.pos.y, 0.07) and near(sparse_jaw.rot.x, 0.1) and near(sparse_jaw.scale.x, 1.2),
    "release restores the last native position rotation and scale without another animation update")
check(near(sparse_nose.pos.y, 0.03) and near(sparse_nose.rot.x, 0.1) and near(sparse_nose.scale.x, 1.2)
    and not H.active(), "release restores unwatched channels and drops all hold references")

-- 位置、四元数 w 或缩放持续变化时，12 次更新只能判失败；30 次更新后自动重试。
for i, kind in ipairs({ "position", "rotation", "scale" }) do
    H.release()
    local f = fake_face(0xE0 + i, { 0.7 })
    f.unstable = kind
    local attempts = 0
    local game = {
        expression_joints = function(face) attempts = attempts + 1; return face.joints end,
        face_layers = adapter.face_layers,
    }
    for _ = 1, 12 do frame({ f }, nil, game) end
    check(not H.capturing() and H.pose(f.addr, "C_Jaw_LOD02") == nil and near(f.layers[1].rate, 0.7)
        and near(f.joints[1].joint.pos.y, 0.03) and not H.status:find("已禁用", 1, true),
        kind .. " instability times out and restores the native pose without accepting the last muted pose")
    f.unstable = nil
    for _ = 1, 29 do frame({ f }, nil, game) end
    check(attempts == 1 and H.pose(f.addr, "C_Jaw_LOD02") == nil,
        kind .. " failure backs off for 29 updates without publishing a held pose")
    frame({ f }, nil, game)
    check(attempts == 2 and H.capturing() and f.layers[1].rate == 0,
        kind .. " failure retries on update 30 without toggling the setting")
    check(wait_hold(f, game), kind .. " retry captures a newly stable neutral pose")
end

-- 骨骼尚未创建时先保留动画，就绪后无需重新启用设置。
H.release()
local d = fake_face(0xF, { 1.0 })
local ready, attempts = false, 0
local delayed = {
    expression_joints = function(face) attempts = attempts + 1; return ready and face.joints or {} end,
    face_layers = adapter.face_layers,
}
frame({ d }, nil, delayed)
check(not H.capturing() and d.layers[1].rate == 1.0 and not d.writes, "a face without expression bones is left alone")
ready = true
for _ = 1, 29 do frame({ d }, nil, delayed) end
check(attempts == 1 and not d.writes, "unready bones use the same bounded retry delay")
frame({ d }, nil, delayed)
check(attempts == 2 and H.capturing(), "newly available bones are automatically retried")
check(wait_hold(d, delayed), "newly available bones eventually enter a valid hold")
H.release()

-- 释放失败时保留原始混合率，关闭设置后的动画前回调仍须完成恢复。
do
    H.release()
    local f = fake_face(0xF1, { 0.25, 0.75 })
    frame({ f })
    f.layers[1].set_error = true
    H.release()
    check(H.active() and f.layers[1].rate == 0 and near(f.layers[2].rate, 0.75),
        "release retains failed layer restoration while restoring the other original rate")
    f.layers[1].set_error = false
    f.layers[2].rate = 0.6
    H.prepare()
    check(not H.active() and near(f.layers[1].rate, 0.25) and near(f.layers[2].rate, 0.6),
        "pre-Motion retries only pending layers without overwriting a restored layer's resumed rate")
    H.release()
    frame({ f })
    f.layers[1].set_error = true
    H.release(true)
    local sets = f.layers[1].sets
    H.prepare()
    check(not H.active() and f.layers[1].sets == sets,
        "forced release drops invalid references and never retries writes after rig teardown")
    f.layers[1].set_error = false
end

-- 旧层失效不能永久阻塞同一 rig 的新层，仍可写入的旧层须恢复原始混合率。
do
    H.release()
    local f = fake_face(0xF2, { 0.35, 0.65 })
    local attempts = 0
    local game = {
        expression_joints = adapter.expression_joints,
        face_layers = function(face) attempts = attempts + 1; return face.layers end,
    }
    frame({ f }, nil, game)
    local old = f.layers
    old[1].get_error, old[1].set_error, old[2].set_error = true, true, true
    f.layers = fake_face(0xF2, { 0.4, 0.9 }).layers
    frame({ f }, nil, game)
    old[2].set_error = false
    for _ = 1, 65 do frame({ f }, nil, game) end
    check(near(old[2].rate, 0.65), "replacement restores a usable old layer even when its sibling is invalid")
    check(attempts > 1 and H.pose(f.addr, "C_Jaw_LOD02") ~= nil
        and near(f.layers[1].rate, 0.4) and near(f.layers[2].rate, 0.9),
        "failed capture reacquires current layers and reaches hold instead of retrying stale layers forever")
    old[1].get_error, old[1].set_error = false, false
    H.release()
end

-- 当前 Motion 仍拥有的层不能因临时读写失败丢弃，原始分数混合率也不能被静音值取代。
do
    local f = fake_face(0xF4, { 0.45, 0.85 })
    frame({ f })
    f.layers[1].get_error, f.layers[1].set_error = true, true
    for _ = 1, 65 do frame({ f }) end
    check(H.active() and H.pose(f.addr, "C_Jaw_LOD02") == nil and f.layers[1].rate == 0,
        "a failing layer still owned by current Motion remains pending rather than being forgotten")
    f.layers[1].get_error, f.layers[1].set_error = false, false
    for _ = 1, 65 do frame({ f }) end
    check(H.pose(f.addr, "C_Jaw_LOD02") ~= nil and near(f.layers[1].rate, 0.45) and near(f.layers[2].rate, 0.85),
        "retry preserves original fractional rates after a current layer recovers")
    H.release()
end

-- 单通道恢复异常不得丢弃动画快照，后续恢复不能覆盖已成功恢复的通道。
do
    H.release()
    local f = fake_face(0xF3, { 1.0 })
    check(wait_hold(f), "pose-release retry fixture reaches hold")
    local j = f.joints[1].joint
    local setter, blocked = j.set_LocalPosition, true
    j.set_LocalPosition = function(self, v)
        if blocked then error("模拟位置恢复失败") end
        return setter(self, v)
    end
    H.release()
    check(H.active() and near(j.pos.y, 0.02) and near(j.rot.x, 0.1) and near(j.scale.x, 1.2),
        "release retains a failed position snapshot while restoring rotation and scale")
    blocked = false
    j.rot, j.scale = { x = 0.2, y = 0, z = 0, w = 0.98 }, { x = 1.3, y = 0.9, z = 1.2 }
    H.prepare()
    check(not H.active() and near(j.pos.y, 0.03) and near(j.rot.x, 0.2) and near(j.scale.x, 1.3),
        "pre-Motion retries only pending PRS channels without overwriting resumed animation")
    j.set_LocalPosition = setter
    H.release()
end

-- API: the expression switch, and the hold setting on a face the adapter cannot read
local st = SKS.state
local function ticks(n)
    for _ = 1, n or 1 do
        SKS.prepare_motion()
        if CB.motion then CB.motion() end
        CB.tick(); CB.frame()
    end
end
-- the mesh's channel list depends on the groups before this one: compare every driven channel
local function snap() local t = {}; for i = 1, #CHANNELS do t[i] = WEIGHTS[i - 1] or 0 end; return t end
local function same(a, b) for i = 1, #a do if not near(a[i], b[i]) then return false end end; return true end
-- base: fcParam all 0 (sculpt values and other layers only); earlier groups leave values in FC
local saved_fc = {}
for k, v in pairs(FC) do saved_fc[k] = v; FC[k] = nil end
SKS.call("rescan"); ticks(80)
SKS.call("auto_match_profile", {}); ticks(3)
local base = snap()
FC[1], FC[2], FC[52], FC[33] = 0.008, 0.008, 0.005, 0.004; ticks(3)
local on = snap()
check(not same(on, base), "fcParam drives some keys with the expression on")
check(st.settings.expression_enabled == true and st.settings.hold_face_bones == false and st.settings.hold_available == true,
    "settings state reports both switches (hold off by default)")
SKS.call("set_setting", { key = "expression_enabled", value = false }); ticks(3)
local off = snap()
check(same(off, base), "expression off leaves only what the other layers write")
local X = require("ShapeKeySystem_Core.Expression")
local real_read, real_compute, reads = X.read, X.compute, 0
X.read = function(...) reads = reads + 1; return real_read(...) end
X.compute = function(...) reads = reads + 1; return real_compute(...) end
ticks(3)
X.read, X.compute = real_read, real_compute
check(reads == 0 and same(snap(), base), "expression off skips face reads and profile evaluation")
local cok = SKS.call("calibrate_eye_neutral", {})
check(cok == false, "eye neutral calibration refuses stale angles while expression is off")
SKS.call("set_setting", { key = "expression_enabled", value = true }); ticks(3)
check(same(snap(), on), "expression on restores the weights")
SKS.call("set_setting", { key = "expression_interval", value = 2.4 })
check(st.settings.expression_interval == 2, "the expression interval is stored as a whole number of frames")
reads = 0
X.read = function(...) reads = reads + 1; return real_read(...) end
ticks(4)
X.read = real_read
check(reads == 2 and same(snap(), on), "interval 2 reads every other frame and keeps the weights in between")
SKS.call("set_setting", { key = "expression_interval", value = 1 })
SKS.call("set_setting", { key = "hold_face_bones", value = true }); ticks(5)
check(not H.capturing() and same(snap(), on) and st.settings.hold_status ~= "",
    "hold on a face without readable bones keeps driving and reports why")
SKS.call("set_setting", { key = "hold_face_bones", value = false }); ticks(2)
check(not H.active() and st.settings.hold_status == "", "hold off releases and clears the status")

-- 用真实 API 调度成功采集：恢复层当帧仍跳过驱动，后续写回修复动画覆盖但保留原始信号。
-- 通用 Transform mock 未模拟地址，补齐 FaceHold 在适配器回调前使用的引擎方法。
local mock_face = ROOT:get_Child()
local original_address = mock_face.get_address
mock_face.get_address = function() return 0xFACE end
local original_joints, original_layers = SKS.adapter.expression_joints, SKS.adapter.face_layers
local models = {}
local function model_of(face)
    local addr = face:get_address()
    if not models[addr] then
        models[addr] = fake_face(addr, { 1.0, 1.0 })
        models[addr].reset_rates = true
    end
    return models[addr]
end
SKS.adapter.expression_joints = function(face) return model_of(face).joints end
SKS.adapter.face_layers = function(face) return model_of(face).layers end
X.read = function(...) reads = reads + 1; return real_read(...) end
SKS.call("set_setting", { key = "hold_face_bones", value = true })
local restored, resumed = false, false
for _ = 1, 12 do
    for _, model in pairs(models) do model.behave() end
    SKS.prepare_motion()
    for _, model in pairs(models) do model.animate() end
    if CB.motion then CB.motion() end
    local waiting = H.capturing()
    local layers_restored = next(models) ~= nil
    for _, model in pairs(models) do layers_restored = layers_restored and model.layers[1].rate == 1.0 end
    local before = snap()
    local muted_fc
    if waiting and layers_restored then
        muted_fc = {}
        for k, v in pairs(FC) do muted_fc[k] = v; FC[k] = nil end
    end
    reads = 0
    CB.tick(); CB.frame()
    if muted_fc then
        for k in pairs(FC) do FC[k] = nil end
        for k, v in pairs(muted_fc) do FC[k] = v end
    end
    if waiting and layers_restored then
        restored = true
        check(reads == 0 and same(snap(), before), "API preserves weights and skips expression reads on the layer restoration frame")
    elseif restored and not waiting then
        resumed = reads > 0
        break
    end
end
check(restored, "API exposes a restored-layer await frame before expression driving resumes")
check(resumed, "API resumes expression reads after the next animation update")

for _, model in pairs(models) do model.behave() end
SKS.prepare_motion()
for _, model in pairs(models) do model.animate() end
if CB.motion then CB.motion() end
for _, model in pairs(models) do
    model.anim = 0.3
    model.animate()
end
CB.tick(); CB.frame()
local repaired, preserved, count = true, true, 0
for addr, model in pairs(models) do
    count = count + 1
    local j = model.joints[1].joint
    repaired = repaired and near(j.pos.y, 0.02) and j.rot.w == 1 and near(j.scale.x, 1.1)
    local p, _, s = H.pose(addr, "C_Jaw_LOD02")
    preserved = preserved and p ~= nil and near(p.y, 0.03) and s ~= nil and near(s.x, 1.2)
end
check(count > 0 and repaired, "API LateUpdateBehavior reapplies captured position rotation and scale after a later overwrite")
check(count > 0 and preserved, "API final reapply does not replace pre-hold animation snapshots")
SKS.call("set_setting", { key = "hold_face_bones", value = false })
X.read = real_read
SKS.adapter.expression_joints, SKS.adapter.face_layers = original_joints, original_layers
ticks(2)
mock_face.get_address = original_address
check(not H.active(), "successful API capture releases all fake engine references when disabled")
for k in pairs(FC) do FC[k] = nil end
for k, v in pairs(saved_fc) do FC[k] = v end

-- reset 的外层保护不能跳过骨骼恢复，即使后续模块清理抛异常。
local reset_face = fake_face(0xFC, { 1.0 })
check(wait_hold(reset_face), "script-reset fixture enters hold before a later cleanup error")
local ActorInstances = require("ShapeKeySystem_Core.ActorInstances")
local release_instances, cleanup_called = ActorInstances.release, false
ActorInstances.release = function()
    cleanup_called = true
    error("模拟角色清理失败")
end
local reset_ok = pcall(CB.reset)
ActorInstances.release = release_instances
check(reset_ok and cleanup_called and not H.active(),
    "script reset releases FaceHold even when another module cleanup throws")
local reset_native = true
for _, entry in ipairs(reset_face.joints) do
    local j = entry.joint
    reset_native = reset_native and near(j.pos.y, 0.03) and near(j.rot.x, 0.1) and near(j.scale.x, 1.2)
end
check(reset_native and reset_face.layers[1].rate == 1.0,
    "exceptional script reset restores all native bone channels and layer rates")

-- 穿戴部件被其它插件逐帧复制（BoneSystem）：固定源之外还须在同一帧写回目标中性，
-- 取消时恢复目标动画副本；未被驱动的部件不能被误写。
H.release(true)
local copied = fake_face(0x201, { 1.0 })
local tjoints = {}
for _, n in ipairs({ "C_Jaw_LOD02", "C_Nose_LOD01" }) do tjoints[n] = fake_bone(n, TARGET_BASE) end
local part = fake_part(0x7001, tjoints)
check(wait_copied_hold(copied, { part }), "copied part fixture reaches hold")
local tjaw = tjoints["C_Jaw_LOD02"]
check(near(tjaw.pos.x, 2) and near(tjaw.pos.y, 3.015) and near(tjaw.pos.z, 4)
    and near(tjaw.rot.x, 0.03) and near(tjaw.rot.y, 0.02) and near(tjaw.rot.w, 0.99875)
    and near(tjaw.scale.x, 0.85) and near(tjaw.scale.y, 1.25) and near(tjaw.scale.z, 1.0),
    "hold writes the target neutral from the native rebase formula")
check(near(copied.joints[1].joint.pos.y, 0.02) and copied.joints[1].joint.rot.w == 1,
    "source is still neutralised while the copied target is held")

copied.anim = 0.2
copied_frame(copied, { part })
check(near(tjaw.pos.y, 3.015), "a held frame re-neutralises the freshly copied target")
local source_jaw = copied.joints[1].joint
source_jaw.pos = { x = 0, y = 0.22, z = 0 }
source_jaw.rot = { x = 0.1, y = 0, z = 0, w = 0.995 }
source_jaw.scale = { x = 1.2, y = 0.9, z = 1.2 }
target_copy(copied, { part })   -- 模拟本次更新之后、渲染之前的再次复制（复制的是动画源）
check(near(tjaw.pos.y, 3.215), "a later native copy can overwrite the held target")
H.reapply()
check(near(tjaw.pos.y, 3.015) and near(tjaw.rot.w, 0.99875), "reapply repairs the target after a later copy")
local ap, ar = H.pose(0x201, "C_Jaw_LOD02")
check(ap and near(ap.y, 0.22) and ar and near(ar.x, 0.1),
    "target hold keeps the source animated signal snapshot for readers")
H.release()
check(near(tjaw.pos.y, 3.215), "release restores the last copied target animation pose")
check(not H.active(), "target hold drops every reference on release")

-- 未被逐帧复制的部件骨骼不能按公式写死：目标姿势不等于复制结果时不接管。
local plain = fake_face(0x202, { 1.0 })
local plain_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
local plain_part = fake_part(0x7002, { C_Jaw_LOD02 = plain_joint })
local plain_hold = false
for _ = 1, 12 do
    plain.behave(); H.prepare(); plain.animate()
    H.update(adapter, { plain }, { [plain:get_address()] = { plain_part } })
    if not H.capturing() and (plain.writes or 0) > 0 then plain_hold = true; break end
end
check(plain_hold and plain_joint.writes == 0, "an undriven part target is never written")
H.release(true)

-- 部件重建后（mesh 地址变化）目标骨骼引用失效：重新采集并固定新的部件骨架。
local rebuilt = fake_face(0x203, { 1.0 })
local old_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
local new_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
check(wait_copied_hold(rebuilt, { fake_part(0x7101, { C_Jaw_LOD02 = old_joint }) }), "target rebuild fixture reaches hold")
local switched = false
for _ = 1, 12 do
    rebuilt.behave(); H.prepare(); rebuilt.animate()
    local new_part = fake_part(0x7102, { C_Jaw_LOD02 = new_joint })
    target_copy(rebuilt, { new_part })
    H.update(adapter, { rebuilt }, { [rebuilt:get_address()] = { new_part } })
    if not H.capturing() and near(new_joint.pos.y, 3.015) then switched = true; break end
end
check(switched, "a rebuilt target set is recaptured and held")
H.release(true)

-- 目标骨骼恢复失败时保留待恢复快照，下一帧重试成功后才放掉引用。
local retry_face = fake_face(0x204, { 1.0 })
local retry_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
local retry_part = fake_part(0x7201, { C_Jaw_LOD02 = retry_joint })
check(wait_copied_hold(retry_face, { retry_part }), "target retry fixture reaches hold")
retry_joint.set_error = true
H.release()
check(H.active(), "a failed target restore keeps the face for retry")
retry_joint.set_error = nil
H.update(adapter, { retry_face }, { [retry_face:get_address()] = { retry_part } })
check(near(retry_joint.pos.y, 3.025) and H.capturing(),
    "target restore retry restores the animation pose before recapture")
H.release(true)

-- rig 被放掉（换装、菜单、角色移除）时先恢复部件目标骨骼，再释放引用。
local dropped = fake_face(0x205, { 1.0 })
local drop_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
local drop_part = fake_part(0x7301, { C_Jaw_LOD02 = drop_joint })
check(wait_copied_hold(dropped, { drop_part }), "dropped-rig fixture reaches hold")
H.update(adapter, {})
check(not H.active() and near(drop_joint.pos.y, 3.025) and dropped.layers[1].rate == 1.0,
    "dropping a rig restores the copied target animation pose")

-- 脚本重置（SKS.shutdown → release(true)）同样恢复目标动画姿势后丢弃引用。
local rs_face = fake_face(0x206, { 1.0 })
local rs_joint = fake_bone("C_Jaw_LOD02", TARGET_BASE)
local rs_part = fake_part(0x7401, { C_Jaw_LOD02 = rs_joint })
check(wait_copied_hold(rs_face, { rs_part }), "target script-reset fixture reaches hold")
local reset_targets_ok = pcall(CB.reset)
check(reset_targets_ok and not H.active() and near(rs_joint.pos.y, 3.025) and rs_face.layers[1].rate == 1.0,
    "script reset restores the copied target pose and layer rates")

print("HOLD FAILS:", hf)
