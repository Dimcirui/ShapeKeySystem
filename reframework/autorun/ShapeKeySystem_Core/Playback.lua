-- 管理录制列表、播放时钟和测试命令。
--
-- 本模块拥有解码帧与采样表，引擎对象归游戏适配器所有；UI 只提交命令，更新回调执行连接和恢复。
-- `final` 只覆盖匹配会话的主角色输入，其他角色继续读取自身信号。
local U = require("ShapeKeySystem_Core.Util")
local Recording = require("ShapeKeySystem_Core.Recording")
local Analysis = require("ShapeKeySystem_Core.PlaybackAnalysis")
local Perf = require("ShapeKeySystem_Core.Perf")
local clock = os.clock
local R = { state = { rev = 0, files = {}, status = "stopped", elapsed = 0, duration = 0,
    speed = 1, loop = false, mode = "raw", message = "", supported = false }, epoch = 0 }
local adapter, clip, values, last_time, catalog
local pending = {}
local analysis, preparation

-- 停止后仍刷新当前配置的绑定，已累计的命中次数不变。
local function update_analysis_bindings()
    if not analysis or not R.context then return end
    analysis:bindings(R.context())
end

-- JSON 解析由 REFramework 同步执行，单独计时以区分文件加载和可分片的准备工作。
local function load_recording(path)
    local started = clock()
    local data = U.load_json(path)
    Perf.record("playback_load", clock() - started)
    return data
end

-- 注册列表中的 ID 才能用于播放，命令不能指定外部文件路径。
function R.refresh()
    local s = R.state
    s.rev = s.rev + 1
    s.files = {}
    if not adapter then return true end
    local seen = {}
    local dirs = {
        { source = "builtin", path = "builtin\\" .. s.game .. "\\recordings" },
        { source = "user", path = "user\\recordings" },
        { source = "user", path = "user\\games\\" .. s.game .. "\\recordings" },
    }
    for _, dir in ipairs(dirs) do
        for _, file in ipairs(U.list_json(dir.path)) do
            local id = dir.source .. ":" .. file.file
            -- 旧用户目录只作读取回退；同名录制以新目录为准，播放 ID 保持不变。
            if not seen[id] then
                seen[id] = true
                local data = load_recording(file.path)
                s.files[#s.files + 1] = { id = id, name = file.base,
                    path = file.path, source = dir.source,
                    duration = data and Recording.finite(data.duration, 300) and data.duration or 0,
                    final = data and (data.final_scale ~= nil or (data.schema == "fcparam.recording/1"
                        and type(data.frames) == "table" and type(data.frames[1]) == "table" and data.frames[1].final ~= nil)) or false }
            end
        end
    end
    return true
end

-- 释放当前会话并保留进度和分析；`restore` 为 false 时适配器不得写回旧对象。
function R.stop(restore, message)
    local was_active = clip ~= nil
    local restore_error
    if adapter then
        local ok, result, err = pcall(adapter.stop, restore)
        if not ok then restore_error = result elseif result == false then restore_error = err end
    end
    clip, values, pending, last_time, preparation = nil, nil, {}, nil, nil
    R.state.preparation_progress = nil
    R.state.status, R.state.message = "stopped", message or "播放已停止，已恢复游戏动画"
    R.state.rev = R.state.rev + 1
    if analysis then
        analysis:finish()
        update_analysis_bindings()
        if was_active and R.log then
            local top = analysis.state.rows[1]
            R.log("recording analysis: %d sampled frames, %d active signals, %d unbound; top %s (%d hits)",
                analysis.state.sampled_frames, analysis.state.active_signals, analysis.state.unbound_signals,
                top and top.label or "none", top and top.hits or 0)
        end
    end
    if restore_error then
        R.state.message = R.state.message .. " · 输入恢复失败：" .. tostring(restore_error)
        if R.log then R.log("recording restore: %s", tostring(restore_error)) end
    end
    R.epoch = R.epoch + 1
    if was_active and R.log then R.log("recording stopped: %s", R.state.message) end
end

function R.fail(message)
    R.stop(true, "播放失败：" .. tostring(message))
    if R.log then R.log("recording playback: %s", tostring(message)) end
end

-- 按游戏时钟推进；暂停也更新时钟基线，恢复时不得补计暂停的时间。
local function advance()
    if not clip then return end
    local s = R.state
    adapter.healthy(s.mode)
    local now = adapter.now()
    assert(now >= last_time, "游戏计时器发生回退")
    if s.status == "playing" then s.elapsed = s.elapsed + (now - last_time) * s.speed end
    last_time = now
    if s.elapsed > clip.duration then
        if s.loop then
            local loops = math.floor(s.elapsed / clip.duration)
            s.elapsed = s.elapsed % clip.duration; R.epoch = R.epoch + 1
            analysis:advance(s.elapsed, loops)
        else
            s.elapsed = clip.duration; analysis:advance(s.elapsed, 0)
            R.stop(true, "重播完成，已恢复游戏动画"); return
        end
    else
        analysis:advance(s.elapsed, 0)
    end
    -- 替换完整采样表，面部回调不读取正在生成的样本。
    values = Recording.sample(clip, s.elapsed)
end

-- 准备任务只持有录制数据；停止和重新播放直接丢弃任务，不触碰新游戏对象。
local function start(a)
    local file
    for _, f in ipairs(R.state.files) do if f.id == a.id then file = f; break end end
    assert(file, "所选录制不存在，请刷新录制列表")
    local data = load_recording(file.path)
    R.stop(true)
    analysis, R.state.analysis = nil, nil
    preparation = { file = file, job = Recording.prepare(data, a.mode or "raw", catalog, R.state.game,
        function(decoded, checkpoint)
            return Analysis.new(decoded, decoded.track == "raw" and adapter.raw_unit or 1, file.name, R.raw_label, checkpoint)
        end) }
    local s = R.state
    s.status, s.elapsed, s.duration, s.file, s.file_id, s.mode = "preparing", 0, 0, file.name, file.id, a.mode or "raw"
    s.message, s.preparation_progress = "正在准备面部动画…", 0
end

-- 每次更新恢复一片准备工作；校验、统计全部完成后才连接适配器并发布新会话。
local function prepare_tick()
    if not preparation then return end
    local task = preparation
    local slice_start = clock()
    local done, decoded, ready_analysis = task.job:step()
    Perf.record("playback_prepare", clock() - slice_start)
    R.state.preparation_progress = task.job.progress
    R.state.message = (task.job.stage == "analysis" and "正在分析录制信号… " or "正在校验录制帧… ")
        .. string.format("%.0f%%", task.job.progress * 100)
    if not done then return end
    local missing = {}
    for _, param in ipairs(R.params and R.params() or {}) do
        if not decoded.map[param] then missing[#missing + 1] = string.format("%03d", param) end
    end
    adapter.connect(decoded)
    local now = adapter.now()
    clip, values, last_time, analysis, preparation = decoded, Recording.sample(decoded, 0), now, ready_analysis, nil
    local s = R.state
    s.status, s.elapsed, s.duration, s.mode = task.paused and "paused" or "playing", 0, decoded.duration, decoded.track
    s.preparation_progress, s.analysis = nil, analysis.state
    s.channels, s.frames, s.missing = decoded.n, #decoded.frames, table.concat(missing, ", ")
    update_analysis_bindings()
    s.message = decoded.track == "raw" and "重播原版输入，SKS 读取游戏求值后的信号"
        or "直接测试最终信号；眼球角度固定为零，缺失参数置零"
    if #missing > 0 then s.message = s.message .. " · 配置未覆盖参数：" .. s.missing end
    s.rev, R.epoch = s.rev + 1, R.epoch + 1
    if R.log then R.log("recording started: %s / %s / %s (%d frames, %d params, %.3fs)",
        s.game, task.file.name, decoded.track, s.frames, s.channels, s.duration) end
end

-- 只验证并排队，保持同帧连续命令的提交顺序。
function R.request(action, a)
    a = a or {}
    if not adapter then return false, "E_UNSUPPORTED", R.state.message end
    if action == "refresh" then return R.refresh() end
    if #pending >= 64 then return false, "E_BAD_ARGS", "播放命令队列已满，请等待游戏更新" end
    local command
    if action == "options" then
        if a.speed ~= nil and (not Recording.finite(a.speed, 2) or a.speed < 0.25) then
            return false, "E_BAD_ARGS", "速度必须在 0.25～2 之间"
        end
        if a.loop ~= nil and type(a.loop) ~= "boolean" then return false, "E_BAD_ARGS", "循环必须是布尔值" end
        command = { action = action, speed = a.speed, loop = a.loop }
    elseif action == "play" then
        if a.mode ~= nil and a.mode ~= "raw" and a.mode ~= "final" then return false, "E_BAD_ARGS", "未知播放模式" end
        local found
        for _, f in ipairs(R.state.files) do if f.id == a.id then found = f end end
        if not found then return false, "E_NOT_FOUND", "录制不存在" end
        if a.mode == "final" and not found.final then return false, "E_BAD_ARGS", "此录制没有 final 最终信号" end
        command = { action = action, id = a.id, mode = a.mode }
    elseif action == "stop" or action == "pause" or action == "resume" then command = { action = action }
    elseif action == "seek" then
        if not clip or not Recording.finite(a.time, clip.duration) or a.time < 0 then return false, "E_BAD_ARGS", "进度无效" end
        command = { action = action, time = a.time }
    else return false, "E_BAD_ARGS", "未知播放操作" end
    pending[#pending + 1] = command
    return true
end

function R.inject()
    if clip and clip.track == "raw" and values then adapter.inject(values) end
end

-- 由游戏更新回调调用；推进或注入失败时停止会话并保留错误原因。
function R.tick(inject)
    if not adapter then return end
    local tick_start = clock()
    local ok, err = pcall(function()
        local commands = pending
        pending = {}
        for _, a in ipairs(commands) do
            R.state.rev = R.state.rev + 1
            if a.action == "play" then start(a)
            elseif a.action == "stop" then R.stop(true)
            else
                advance()
                if a.action == "options" then
                    if a.speed ~= nil then R.state.speed = a.speed end
                    if a.loop ~= nil then R.state.loop = a.loop == true end
                elseif preparation then
                    if a.action == "pause" then preparation.paused = true
                    elseif a.action == "resume" then preparation.paused = false end
                elseif clip then
                    if a.action == "pause" then R.state.status = "paused"
                    elseif a.action == "resume" then R.state.status = "playing"
                    elseif a.action == "seek" then
                        R.state.elapsed = a.time; R.epoch = R.epoch + 1
                        analysis:seek(a.time)
                    end
                end
            end
        end
        prepare_tick()
        advance()
        update_analysis_bindings()
        if inject then R.inject() end
    end)
    if not ok then R.fail(err) end
    Perf.record("playback_tick", clock() - tick_start)
end

-- 仅覆盖匹配会话的角色输入；缺失参数置零，眼球角度不参与最终信号测试。
function R.apply(rig, P, inv_full)
    if not clip or clip.track ~= "final" or not adapter.matches(rig) then return false end
    for param in pairs(P) do P[param] = nil end
    for param, column in pairs(clip.map) do P[param] = values[column] * adapter.final_unit * inv_full end
    rig.angles.L[1], rig.angles.L[2], rig.angles.R[1], rig.angles.R[2] = 0, 0, 0, 0
    return true
end

-- 加载阶段接入所选游戏适配器；没有 `playback` 接口时不注册播放回调。
function R.init(game, log, params, context)
    if adapter then R.stop(true) end
    R.log, R.params, R.context = log, params, context
    adapter = game.playback
    R.raw_label = game.raw and game.raw.label or tostring
    R.state.game, R.state.game_name, R.state.supported = game.id, game.name, false
    if not adapter then R.state.message = "当前游戏尚未提供面部动画测试适配器：" .. game.id; return end
    local ok, result = pcall(adapter.catalog)
    if not ok then R.state.message = tostring(result); adapter = nil; return end
    catalog = result
    adapter.attach({ tick = R.tick, inject = R.inject, fail = R.fail })
    R.state.supported = true
    R.refresh()
end
return R
