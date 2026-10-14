-- 录制播放器：拥有文件目录、解码样本、播放时钟和命令队列；引擎对象完全归游戏适配器所有。
-- UI 只提交命令，连接/恢复和推进仅在游戏更新回调执行；final 仅覆盖主角色的计算输入。
local U = require("ShapeKeySystem_Core.Util")
local Recording = require("ShapeKeySystem_Core.Recording")
local Games = require("ShapeKeySystem_Game.Registry")
local Analysis = require("ShapeKeySystem_Core.PlaybackAnalysis")
local R = { state = { rev = 0, files = {}, status = "stopped", elapsed = 0, duration = 0,
    speed = 1, loop = false, mode = "raw", message = "", supported = false }, epoch = 0 }
local adapter, clip, values, last_time, catalog
local pending = {}
local analysis

-- 仅修订变化时解析当前配置绑定；停止后仍刷新映射标记，但不再增加命中次数。
local function update_analysis_bindings()
    if not analysis or not R.context then return end
    analysis:bindings(R.context())
end

-- 仅列出当前游戏的内置/用户目录；API 以目录登记的 ID 查找，不接受任意外部路径。
function R.refresh()
    local s = R.state
    s.rev = s.rev + 1
    s.files = {}
    if not adapter then return true end
    for _, source in ipairs({ "builtin", "user" }) do
        local dir = source == "builtin" and ("games\\" .. s.game .. "\\recordings")
            or ("user\\games\\" .. s.game .. "\\recordings")
        for _, file in ipairs(U.list_json(dir)) do
            local data = U.load_json(file.path)
            s.files[#s.files + 1] = { id = source .. ":" .. file.file, name = file.base,
                path = file.path, source = source,
                duration = data and Recording.finite(data.duration, 300) and data.duration or 0,
                final = data and (data.final_scale ~= nil or (data.schema == "fcparam.recording/1"
                    and type(data.frames) == "table" and type(data.frames[1]) == "table" and data.frames[1].final ~= nil)) or false }
        end
    end
    return true
end

-- 结束只释放当前会话；自然结束保留末尾进度，失效对象释放时禁止恢复旧指针。
function R.stop(restore, message)
    local was_active = clip ~= nil
    local restore_error
    if adapter then
        local ok, result, err = pcall(adapter.stop, restore)
        if not ok then restore_error = result elseif result == false then restore_error = err end
    end
    clip, values, pending, last_time = nil, nil, {}, nil
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

-- 稳定时钟推进，不以帧号或 sample_hz 计时；暂停保持样本，循环和跳转重置平滑代次。
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
    -- 生成新表再交换，面部回调只读取已完成的样本，不与游标推进共写同一表。
    values = Recording.sample(clip, s.elapsed)
end

local function start(a)
    local file
    for _, f in ipairs(R.state.files) do if f.id == a.id then file = f; break end end
    assert(file, "所选录制不存在，请刷新录制列表")
    local decoded = Recording.decode(U.load_json(file.path), a.mode or "raw", catalog, R.state.game)
    local missing = {}
    for _, param in ipairs(R.params and R.params() or {}) do
        if not decoded.map[param] then missing[#missing + 1] = string.format("%03d", param) end
    end
    R.stop(true)
    adapter.connect(decoded)
    local now = adapter.now()
    clip, values, last_time = decoded, Recording.sample(decoded, 0), now
    local s = R.state
    s.status, s.elapsed, s.duration, s.mode, s.file, s.file_id = "playing", 0, decoded.duration, decoded.track, file.name, file.id
    s.channels, s.frames, s.missing = decoded.n, #decoded.frames, table.concat(missing, ", ")
    analysis = Analysis.new(decoded, decoded.track == "raw" and adapter.raw_unit or 1, file.name)
    s.analysis = analysis.state
    update_analysis_bindings()
    s.message = decoded.track == "raw" and "重播原版输入，SKS 读取游戏求值后的信号"
        or "直接测试最终信号；眼球角度固定为零，缺失参数置零"
    if #missing > 0 then s.message = s.message .. " · 配置未覆盖参数：" .. s.missing end
    R.epoch = R.epoch + 1
    if R.log then R.log("recording started: %s / %s / %s (%d frames, %d params, %.3fs)",
        s.game, file.name, decoded.track, s.frames, s.channels, s.duration) end
end

-- 接受参数时不写入引擎；按提交顺序处理，连续调速/播放/暂停不会相互覆盖。
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

-- 本函数由 UpdateMotion / SKS tick 调用，所有错误停止当前测试并保留可读原因。
function R.tick(inject)
    if not adapter then return end
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
        advance()
        update_analysis_bindings()
        if inject then R.inject() end
    end)
    if not ok then R.fail(err) end
end

-- final 数据以游戏适配器定义的单位归一化；仅主猎人匹配会话时替换其独立输入表。
function R.apply(rig, P, inv_full)
    if not clip or clip.track ~= "final" or not adapter.matches(rig) then return false end
    for param in pairs(P) do P[param] = nil end
    for param, column in pairs(clip.map) do P[param] = values[column] * adapter.final_unit * inv_full end
    rig.angles.L[1], rig.angles.L[2], rig.angles.R[1], rig.angles.R[2] = 0, 0, 0, 0
    return true
end

-- 注册在脚本加载阶段，满足 REF 的 require 限制；未知游戏不安装荒野回调。
function R.init(log, params, context)
    R.log, R.params, R.context = log, params, context
    local game, message
    adapter, game, message = Games.load()
    R.state.game = game
    if not adapter then R.state.message = message; return end
    R.state.game_name = adapter.name
    local ok, result = pcall(adapter.catalog)
    if not ok then R.state.message = tostring(result); adapter = nil; return end
    catalog = result
    adapter.attach({ tick = R.tick, inject = R.inject, fail = R.fail })
    R.state.supported = true
    R.refresh()
end
return R
