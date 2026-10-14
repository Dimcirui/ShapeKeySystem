-- 绘制面部动画测试控件和播放分析。
--
-- 页面拥有筛选和分页状态，播放数据归后端所有；两种后端共用控件，不持有引擎引用。
local D = require("ShapeKeySystem_UI.Draw")
local T = require("ShapeKeySystem_UI.Theme")
local W = require("ShapeKeySystem_UI.Widgets")
local Mapping = require("ShapeKeySystem_UI.MappingEditor")
local P = {}
local C = T.c

local function draw_analysis(ctx, x, y, w)
    local a, s = ctx.st.playback.analysis, ctx.state
    local cy = y + 8
    W.separator(x + 8, y, w - 16)
    W.label("本次播放分析", x + 8, cy, C.text)
    cy = cy + 26
    if not a then
        W.label("播放录制后显示信号命中次数与形态键绑定。", x + 8, cy, C.muted, w - 16)
        return cy - y + 28
    end
    if s.playback_analysis ~= a then
        s.playback_analysis, s.playback_analysis_page = a, 1
    end
    local summary = string.format("%s · %s · %s · 已统计 %d 帧", a.file,
        a.mode == "raw" and "原版输入" or "最终信号", a.finished and "已结束" or "统计中", a.sampled_frames)
    D.text_mid(summary, x + 8, cy, 24, C.text, W.small(), w - 16)
    W.tooltip(summary, x + 8, cy, w - 16, 24)
    cy = cy + 24
    local binding_summary = string.format("当前配置：%s · 活跃 %d · 已绑定 %d · 未绑定 %d",
        a.profile or "无表情配置", a.active_signals, a.bound_signals, a.unbound_signals)
    D.text_mid(binding_summary, x + 8, cy, 24, C.muted, W.small(), w - 16)
    W.tooltip(binding_summary, x + 8, cy, w - 16, 24)
    cy = cy + 24
    local metric = "按录制帧统计幅值 > 1%；暂停不计，循环累计。"
    D.text_mid(metric, x + 8, cy, 24, C.faint, W.small(), w - 16)
    W.tooltip("统计录制轨道的绝对幅值，跳转只计目标帧，停止保留、重新播放清零。raw 为原版输入，不代表游戏求值后的最终信号；绑定为当前已应用配置的依赖关系。",
        x + 8, cy, w - 16, 24)
    cy = cy + 28
    local ch, only = W.toggle("只看未绑定", x + 8, cy, s.playback_analysis_unbound == true, { h = 26, font = W.small() })
    if ch then s.playback_analysis_unbound, s.playback_analysis_page = only, 1 end
    local rows = {}
    for rank, row in ipairs(a.rows) do
        if not s.playback_analysis_unbound or #row.mappings == 0 then rows[#rows + 1] = { rank = rank, row = row } end
    end
    local pages = math.max(1, math.ceil(#rows / 5))
    local page = math.max(1, math.min(pages, s.playback_analysis_page or 1))
    if W.button("上一页", x + w - 214, cy, 62, 26, { disabled = page <= 1, font = W.small() }) then page = page - 1 end
    D.text_center(page .. " / " .. pages, x + w - 148, cy, 66, 26, C.muted, W.small())
    if W.button("下一页", x + w - 78, cy, 62, 26, { disabled = page >= pages, font = W.small() }) then page = page + 1 end
    s.playback_analysis_page = page
    cy = cy + 32
    if #rows == 0 then
        W.label(s.playback_analysis_unbound and "没有未绑定的活跃信号。" or "尚无超过阈值的信号。", x + 8, cy, C.muted, w - 16)
        return cy - y + 28
    end
    for i = (page - 1) * 5 + 1, math.min(page * 5, #rows) do
        local item, rh = rows[i], 78
        local row = item.row
        -- 右侧统计和操作共用一列，保持命中次数与“添加映射”按钮的左右边缘一致。
        local action_w, action_x = 120, x + w - 132
        D.rrect(x + 8, cy, w - 16, rh - 4, 3, C.panel2)
        local label = item.rank .. ". " .. row.label
        D.text_mid(label, x + 16, cy, 24, C.text, W.small(), action_x - x - 24)
        W.tooltip(label, x + 16, cy, action_x - x - 24, 24)
        D.text_center(string.format("%d 次 · %.1f%%", row.hits, 100 * row.hits / math.max(1, a.sampled_frames)),
            action_x, cy, action_w, 24, C.brass, W.small())
        local names = {}
        for _, mapping in ipairs(row.mappings) do
            names[#names + 1] = mapping.name .. (mapping.present and "" or "（当前模型缺失）")
        end
        local bound = #names > 0 and ("已绑定：" .. table.concat(names, "、")) or "未绑定形态键映射"
        if #names > 0 then
            D.text_mid(bound, x + 16, cy + 24, 24, C.muted, W.small(), action_x - x - 24)
            W.tooltip(bound, x + 16, cy + 24, action_x - x - 24, 24)
        else
            D.text_mid(bound, x + 16, cy + 24, 24, C.warn, W.small(), action_x - x - 24)
            if W.button("添加映射", action_x, cy + 22, action_w, 24, { font = W.small() }) then
                Mapping.open(ctx, nil, row.signal)
            end
            W.tooltip("新建形态键映射，并自动使用 " .. (row.signal or row.label) .. " 作为面部信号", x + 16, cy + 24, action_x - x - 24, 24)
        end
        local purpose = (row.guessed and "用途（推测）：" or "用途：") .. row.purpose
        D.text_mid(purpose, x + 16, cy + 48, 24, C.faint, W.small(), w - 32)
        W.tooltip(purpose, x + 16, cy + 48, w - 32, 24)
        cy = cy + rh
    end
    return cy - y + 6
end

function P.draw(ctx, x, y, w)
    local r, s = ctx.st.playback, ctx.state
    if not r then return 0 end
    local preparing = r.status == "preparing"
    local active = r.status ~= "stopped"
    local open = active or s.playback_open == true
    local clicked, height = W.header("面部动画测试", x, y, w, open,
        active and ((preparing and "准备中" or r.status == "paused" and "暂停" or "播放中") .. " · " .. (r.file or "")
            .. (r.mode == "final" and " · 最终信号" or " · 原版输入")) or nil)
    if clicked and not active then s.playback_open = not open end
    local cy = y + height + 6
    if not open then return cy - y end
    if not r.supported then
        D.text_mid(r.message, x + 8, cy, 28, C.warn, W.small(), w - 16)
        return cy - y + 36
    end
    s.playback_id = s.playback_id or r.file_id
    s.playback_mode = s.playback_mode or r.mode
    local labels, pick = {}, nil
    for i, file in ipairs(r.files) do
        labels[i] = file.name .. (file.source == "user" and " · 用户" or " · 内置")
        if file.id == s.playback_id then pick = i end
    end
    if not pick and r.files[1] then pick, s.playback_id = 1, r.files[1].id end
    local changed, index = W.select("recording_file", x + 8, cy, w - 108, 28, labels, pick,
        { placeholder = "没有当前游戏的录制文件" })
    if changed then s.playback_id = r.files[index].id; pick = index end
    if W.button("刷新列表", x + w - 92, cy, 84, 28, { font = W.small() }) then ctx.call("playback", { action = "refresh" }) end
    cy = cy + 34
    local file = pick and r.files[pick]
    changed, index = W.select("recording_mode", x + 8, cy, math.min(220, w - 16), 28,
        { "原版输入重播（raw）", "最终信号测试（final）" }, s.playback_mode == "final" and 2 or 1)
    if changed then s.playback_mode = index == 2 and "final" or "raw" end
    local mode = s.playback_mode or "raw"
    local hint = file and string.format("%.2f 秒 · %s", file.duration or 0, file.final and "含最终信号" or "仅原版输入") or "请添加录制后刷新"
    if w >= 480 then D.text_mid(hint, x + 240, cy, 28, C.muted, W.small(), w - 248)
    else cy = cy + 32; D.text_mid(hint, x + 8, cy, 24, C.muted, W.small(), w - 16) end
    cy = cy + 34
    local disabled = not file or (mode == "final" and not file.final) or ctx.st.runtime.enabled == false
    if W.button(active and "重新播放" or "播放录制", x + 8, cy, 94, 28, { kind = "primary", disabled = disabled, font = W.small() }) then
        ctx.call("playback", { action = "play", id = s.playback_id, mode = mode })
    end
    if W.button(r.status == "paused" and "继续" or "暂停", x + 110, cy, 66, 28, { disabled = not active or preparing, font = W.small() }) then
        ctx.call("playback", { action = r.status == "paused" and "resume" or "pause" })
    end
    if W.button("停止", x + 184, cy, 66, 28, { disabled = not active, font = W.small() }) then ctx.call("playback", { action = "stop" }) end
    local ch, loop = W.toggle("循环", x + 262, cy, r.loop, { h = 28 })
    if ch then ctx.call("playback", { action = "options", loop = loop }) end
    cy = cy + 34
    D.text_mid("速度", x + 8, cy, 28, C.muted, W.small(), 42)
    local ch_speed, speed = W.slider("recording_speed", x + 54, cy, w - 62, 28, r.speed, 0.25, 2,
        { step = 0.05, fmt = "×%.2f", value_w = 52 })
    if ch_speed then ctx.call("playback", { action = "options", speed = speed }) end
    cy = cy + 34
    if active and r.duration > 0 then
        D.text_mid("进度", x + 8, cy, 28, C.muted, W.small(), 42)
        local ch_time, time = W.slider("recording_time", x + 54, cy, w - 62, 28, r.elapsed, 0, r.duration,
            { step = 0.01, fmt = "%.2fs", value_w = 65, disabled = not active })
        if ch_time then ctx.call("playback", { action = "seek", time = time }) end
        cy = cy + 34
    end
    local message = r.message
    if mode == "final" and file and not file.final then message = "此录制没有 final，无法直接测试最终信号；请选择 raw" end
    D.text_mid(message, x + 8, cy, 24, C.muted, W.small(), w - 16)
    W.tooltip(message, x + 8, cy, w - 16, 24)
    cy = cy + 26
    D.text_mid("只测试当前主角色；沿用当前映射、增益和覆盖设置，不含声音或动作。", x + 8, cy, 24, C.faint, W.small(), w - 16)
    cy = cy + 30
    cy = cy + draw_analysis(ctx, x, cy, w)
    return cy - y
end
return P
