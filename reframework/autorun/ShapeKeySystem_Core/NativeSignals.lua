-- ShapeKeySystem: observe native inputs and save diagnostic recordings.
--
-- Adapters return plain snapshots before weight writes. Recordings retain no engine objects;
-- unavailable sources end the recording, so character rebuilds never join two rigs in one take.
local U = require("ShapeKeySystem_Core.Util")
local N = {}
N.state = { available = false, recording = false, samples = 0, elapsed = 0, rows = {}, status = "" }
local state = N.state
local recording, baseline, summary = nil, nil, {}
local pending, next_sample, next_live = nil, 0, 0
local sequence = 0

local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

local function observe(snapshot)
    baseline = baseline or snapshot.joints
    local rows = {}
    for name, pose in pairs(snapshot.joints or {}) do
        local base = baseline[name]
        if base then
            local mm = math.sqrt((pose[1]-base[1])^2 + (pose[2]-base[2])^2 + (pose[3]-base[3])^2) * 1000
            local aa, bb, dot = 0, 0, 0
            for i = 4, 7 do aa = aa + pose[i]^2; bb = bb + base[i]^2; dot = dot + pose[i]*base[i] end
            local deg = aa > 0 and bb > 0 and math.deg(2 * math.acos(math.min(1, math.abs(dot)/math.sqrt(aa*bb)))) or 0
            local s = summary[name] or { position_mm = 0, rotation_deg = 0 }
            s.position_mm, s.rotation_deg = math.max(s.position_mm, mm), math.max(s.rotation_deg, deg)
            summary[name] = s
            rows[#rows+1] = { name = name, mm = mm, deg = deg, peak_mm = s.position_mm, peak_deg = s.rotation_deg }
        end
    end
    table.sort(rows, function(a, b)
        local av, bv = math.max(a.mm, a.deg), math.max(b.mm, b.deg)
        return av > bv or (av == bv and a.name < b.name)
    end)
    state.rows, state.joints, state.taps = rows, count(snapshot.joints), count(snapshot.taps)
    state.missing = count(snapshot.status)
end

function N.finish(reason)
    if not recording then return true end
    local r = recording
    recording, state.recording = nil, false
    r.reason, r.summary = r.reason or reason or "手动停止", r.summary or U.copy(summary)
    r.duration = r.duration or state.elapsed
    if #r.samples == 0 then state.status = "没有采样数据"; return false end
    sequence = sequence + 1
    local path = U.path("native_signals_" .. r.game .. "_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. sequence .. ".json")
    -- Existing files are preserved even when a script reset restarts the sequence.
    while U.file_exists(path) do
        sequence = sequence + 1
        path = U.path("native_signals_" .. r.game .. "_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. sequence .. ".json")
    end
    local ok = U.save_json(path, r)
    state.status = ok and ("已保存：" .. path) or "保存失败，可点击重试保存"
    if ok then state.file, N.unsaved = path, nil else N.unsaved = r end
    return ok
end

function N.command(adapter, args)
    if not adapter.native_snapshot then return false, "E_UNSUPPORTED", "此游戏未提供原生信号采样" end
    local action = args.action
    if action ~= "start" and action ~= "stop" and action ~= "baseline" and action ~= "snapshot" and action ~= "retry" then
        return false, "E_BAD_ARGS", "未知诊断操作"
    end
    if action == "start" and (recording or N.unsaved) then return false, "E_BAD_ARGS", "请先停止录制或保存上一段数据" end
    if action == "baseline" and recording then return false, "E_BAD_ARGS", "请先停止录制再更新中立位" end
    pending = { action = action, label = tostring(args.label or ""):sub(1, 80) }
    return true
end

function N.tick(adapter, stable)
    state.available = type(adapter.native_snapshot) == "function"
    if not state.available then return end
    local cmd = pending
    pending = nil
    if cmd and cmd.action == "retry" and N.unsaved then
        recording, N.unsaved = N.unsaved, nil
        N.finish("重试保存")
        return
    end
    if cmd and cmd.action == "stop" then N.finish(); return end
    if not stable then
        N.finish("角色暂不可用")
        baseline, summary, state.rows = nil, {}, {}
        state.ready = false
        if cmd then state.status = "角色尚未就绪" end
        return
    end
    if cmd and cmd.action == "start" then
        baseline, summary = nil, {}
        state.source = nil
        recording = { schema = "sks.native-signals/1", game = adapter.id, label = cmd.label,
            rate_hz = 20, position_unit = "metre", rotation_order = "xyzw", samples = {}, started = os.clock() }
        state.recording, state.samples, state.elapsed, state.status = true, 0, 0, "录制中（最长 90 秒）"
        next_sample = 0
    end
    if cmd and cmd.action == "baseline" then baseline, summary = nil, {} end
    local now = os.clock()
    local due = recording and now >= next_sample or cmd ~= nil or N.viewing and now >= next_live
    if not due then return end
    local ok, snapshot, why = pcall(adapter.native_snapshot)
    if not ok or not snapshot then
        N.finish("采样中断")
        state.ready, state.status = false, tostring(ok and why or snapshot)
        return
    end
    state.ready = true
    if state.source ~= snapshot.source then
        if state.source ~= nil then N.finish("角色或部件已重建") end
        baseline, summary = nil, {}
        state.source = snapshot.source
    end
    next_live = now + 0.2
    observe(snapshot)
    if cmd and cmd.action == "baseline" then state.status = "已记录当前中立位" end
    if cmd and cmd.action == "snapshot" then
        sequence = sequence + 1
        local path = U.path("native_snapshot_" .. adapter.id .. "_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. sequence .. ".json")
        while U.file_exists(path) do sequence = sequence + 1; path = path:gsub("_%d+%.json$", "_" .. sequence .. ".json") end
        local saved = U.save_json(path, {schema = "sks.native-snapshot/1", game = adapter.id, snapshot = snapshot})
        state.status = saved and ("已保存：" .. path) or "快照保存失败"
        if saved then state.file = path end
    end
    if recording and now >= next_sample then
        local r = recording
        next_sample = now + 0.05
        local t = now - r.started
        r.calibration = r.calibration or snapshot.calibration
        snapshot.calibration = nil
        r.samples[#r.samples+1] = { t = t, values = snapshot }
        state.samples, state.elapsed = #r.samples, t
        if t >= 90 or #r.samples >= 1801 then N.finish("达到录制时长") end
    end
end

return N
