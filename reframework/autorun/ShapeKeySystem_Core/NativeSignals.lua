-- ShapeKeySystem: observe native inputs and save diagnostic recordings.
--
-- Adapters return plain snapshots before weight writes. Recordings retain no engine objects;
-- unavailable sources end a diagnostic recording, so character rebuilds never join two rigs in one take.
-- An adapter with `native_export` converts the take into its playback format instead of the
-- diagnostic file and keeps it running through gaps; `native_sample` trims what each sample keeps.
local U = require("ShapeKeySystem_Core.Util")
local N = {}
N.state = { available = false, recording = false, samples = 0, elapsed = 0, rows = {}, status = "" }
local state = N.state
local recording, baseline, summary = nil, nil, {}
local export   -- the recording adapter's native_export, kept for a retried save
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
    local data, dir, prefix = r, nil, "native_signals_" .. r.game
    if export then
        local ok, converted, folder = pcall(export, r)
        -- a take that cannot be converted cannot be retried either
        if not ok then N.unsaved = nil; state.status = "录制无法转换：" .. tostring(converted):gsub("^.-:%d+: ", ""); return false end
        data, dir, prefix = converted, folder, r.game
    end
    local function name()
        local file = prefix .. "_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. sequence .. ".json"
        return dir and U.path(dir, file) or U.path(file)
    end
    sequence = sequence + 1
    local path = name()
    -- Existing files are preserved even when a script reset restarts the sequence.
    while U.file_exists(path) do sequence = sequence + 1; path = name() end
    local ok = U.save_json(path, data)
    state.status = ok and ((export and "已保存，可在面部动画测试中播放：" or "已保存：") .. path) or "保存失败，可点击重试保存"
    if ok then state.file, N.unsaved = path, nil else N.unsaved = r end
    if ok and export and N.on_export then N.on_export() end
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

local function begin(adapter, cmd)
    baseline, summary = nil, {}
    state.source = nil
    recording = { schema = "sks.native-signals/1", game = adapter.id, label = cmd.label,
        rate_hz = 20, position_unit = "metre", rotation_order = "xyzw", samples = {}, started = os.clock() }
    state.recording, state.samples, state.elapsed, state.status = true, 0, 0, "录制中（最长 90 秒）"
    next_sample, export = 0, adapter.native_export
end

-- Appends a sample at the recording rate; values nil marks a gap (no readable source).
local function append(now, values, status)
    local r = recording
    if not r or now < next_sample then return end
    next_sample = now + 0.05
    local t = now - r.started
    r.samples[#r.samples+1] = { t = t, values = values }
    state.samples, state.elapsed, state.status = #r.samples, t, status
    if t >= 90 or #r.samples >= 1801 then N.finish("达到录制时长") end
end

-- stable: true samples, false ends the take, "hold" pauses sampling (a cutscene segment settling).
-- context.face is the face SKS currently drives. A take saved through `native_export` ends only on
-- stop or at the limit: unreadable stretches and source changes are recorded as gaps instead.
function N.tick(adapter, stable, context)
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
    local now = os.clock()
    if stable ~= true then
        if adapter.native_export and cmd and cmd.action == "start" then begin(adapter, cmd); cmd = nil end
        if recording and export then
            pending = cmd
            append(now, nil, "录制中 · " .. (stable == "hold" and "等待过场片段稳定" or "角色暂不可用") .. "，此段记为 0")
            return
        end
    end
    if stable == "hold" then
        pending = cmd
        if recording or cmd then state.status = (recording and "录制中 · " or "") .. "等待过场片段稳定" end
        return
    end
    if not stable then
        N.finish("角色暂不可用")
        baseline, summary, state.rows = nil, {}, {}
        state.ready = false
        if cmd then state.status = "角色尚未就绪" end
        return
    end
    if cmd and cmd.action == "start" then begin(adapter, cmd) end
    if cmd and cmd.action == "baseline" then baseline, summary = nil, {} end
    local due = recording and now >= next_sample or cmd ~= nil or N.viewing and now >= next_live
    if not due then return end
    local ok, snapshot, why = pcall(adapter.native_snapshot, context)
    if not ok or not snapshot then
        local reason = tostring(ok and why or snapshot)
        state.ready = false
        if recording and export then append(now, nil, "录制中 · 暂无信号，此段记为 0：" .. reason); return end
        N.finish("采样中断")
        state.status = reason
        return
    end
    state.ready = true
    if state.source ~= snapshot.source then
        if state.source ~= nil and not (recording and export) then N.finish("角色或部件已重建") end
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
        recording.calibration = recording.calibration or snapshot.calibration
        snapshot.calibration = nil
        append(now, adapter.native_sample and adapter.native_sample(snapshot) or snapshot, "录制中（最长 90 秒）")
    end
end

return N
