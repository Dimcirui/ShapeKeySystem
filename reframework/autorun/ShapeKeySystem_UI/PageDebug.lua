-- ShapeKeySystem panel, advanced page "设置与调试": settings, per-stage timing, scan info, log.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local Faces = require("ShapeKeySystem_UI.Faces")
local Version = require("ShapeKeySystem_Core.Version")
local I18n = require("ShapeKeySystem_Core.I18n")
local L = I18n

local Page = { want_signals = true }
local C = T.c
local max, min = math.max, math.min

-- free keys first. Not offered: Insert (REFramework menu). Last, for whoever wants them anyway:
-- Home (ArmorVariantManager), End (game pause). PageUp / PageDown move REFramework's free camera.
local HOTKEYS = { "Delete", "NumPad0", "NumPad1", "NumPad2", "NumPad3", "NumPad4", "NumPad5", "NumPad6",
                  "NumPad7", "NumPad8", "NumPad9", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9",
                  "F10", "F11", "F12", "PageUp", "PageDown", "Home", "End" }

local MODS = { "Ctrl", "Shift", "Alt" }

local function setting(ctx, k, v) ctx.call("set_setting", { key = k, value = v }) end

-- a settings card: title, rows of label + control (32 px each), then toggles (34 px each).
-- Returns the row helper and the card's height for `rows` rows, `toggles` toggle lines and `extra` px.
local function card(x, y, w, title, rows, toggles, extra)
    local h = 50 + rows * 32 + toggles * 34 + (extra or 0)
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local c = { x = rx, w = rw, y = y + 40 }
    W.h2(title, rx, y + 10)
    local lw = 150
    function c.row(label, fn)
        D.text_mid(label, rx, c.y, 28, C.text, W.small(), lw - 8)
        fn(rx + lw, rw - lw)
        c.y = c.y + 32
    end
    return c, h
end

-- a slider whose value is applied on release: the layout under the mouse changes with it
local function release_slider(ctx, id, key, sx, cy, sw, value, lo, hi, step)
    local pend = ctx.state.pending or {}
    ctx.state.pending = pend
    local ch, v = W.slider(id, sx, cy, min(320, sw), 28, pend[key] or value, lo, hi, { step = step, fmt = "%.2f" })
    if ch then pend[key] = v end
    if pend[key] and not require("ShapeKeySystem_UI.Input").down then
        setting(ctx, key, pend[key]); pend[key] = nil
    end
end

local function ui_settings_card(ctx, x, y, w)
    local se = ctx.st.settings
    local img = D.images()
    local combo = se.hotkey_combo == true
    local unblocked = se.block_input == false
    local c, h = card(x, y, w, "界面设置", (img and 6 or 5) + (combo and 1 or 0), 2, unblocked and 22 or 0)
    c.row("语言 / Language", function(sx, sw)
        -- each language in its own script, whatever the interface language is
        local labels, cur = {}, 1
        for i, k in ipairs(I18n.LANGS) do
            labels[i] = I18n.LANG_NAMES[k]
            if k == (se.language or "zh") then cur = i end
        end
        local ch, i = W.select("language", sx, c.y, min(160, sw), 28, labels, cur)
        if ch then setting(ctx, "language", I18n.LANGS[i]) end
    end)
    local cc, vc = W.toggle("启用组合快捷键", c.x, c.y, combo)
    if cc then setting(ctx, "hotkey_combo", vc) end
    c.y = c.y + 34
    if combo then c.row("组合键", function(sx, sw)
        local cur = 1
        for i, k in ipairs(MODS) do if k == (se.hotkey_mod or "Ctrl") then cur = i end end
        local ch, i = W.select("hotkey_mod", sx, c.y, min(160, sw), 28, MODS, cur)
        if ch then setting(ctx, "hotkey_mod", MODS[i]) end
    end) end
    c.row("打开面板的按键", function(sx, sw)
        local cur
        for i, k in ipairs(HOTKEYS) do if k == se.hotkey then cur = i end end
        local ch, i = W.select("hotkey", sx, c.y, min(160, sw), 28, HOTKEYS, cur)
        if ch then setting(ctx, "hotkey", HOTKEYS[i]) end
    end)
    c.row("界面缩放", function(sx, sw)
        release_slider(ctx, "ui_scale", "ui_scale", sx, c.y, sw, se.ui_scale or 1, 0.75, 2, 0.05)
    end)
    c.row("字体大小", function(sx, sw)
        release_slider(ctx, "font_scale", "font_scale", sx, c.y, sw, se.font_scale or 1, 0.8, 1.6, 0.05)
    end)
    c.row("绘制方式", function(sx, sw)
        local labels = { "自动", "reframework-d2d", "ImGui（REFramework 自带）" }
        local cur = 1
        for i, k in ipairs(D.BACKENDS) do if k == se.ui_backend then cur = i end end
        -- the closed select shows what is actually drawing (auto, or a wanted backend that is missing)
        local now = D.backend == "imgui" and "ImGui" or "d2d"
        if cur == 1 then labels[1] = L.f("自动：%s", now)
        elseif D.BACKENDS[cur] ~= D.backend then labels[cur] = L.f("%s（缺失，用 %s）", L.tr(labels[cur]), now) end
        local ch, i = W.select("ui_backend", sx, c.y, min(260, sw), 28, labels, cur)
        if ch then setting(ctx, "ui_backend", D.BACKENDS[i]) end
    end)
    if img then c.row("立绘风格", function(sx, sw)
        local list, labels, cur = Faces.list(), {}, nil
        local active = Faces.get(se.face_style)
        for i, f in ipairs(list) do
            labels[i] = f.name
            if active and f.id == active.id then cur = i end
        end
        local ch, i = W.select("face_style", sx, c.y, min(200, sw), 28, labels, cur, { placeholder = "（无）" })
        if ch and list[i] then setting(ctx, "face_style", list[i].id) end
    end) end
    local cb, vb = W.toggle("打开菜单时屏蔽游戏操控", c.x, c.y, not unblocked)
    if cb then setting(ctx, "block_input", vb) end
    if unblocked then
        D.text("可在打开游戏菜单、地图、REF菜单等状态下解锁光标，并启用此选项", c.x, c.y + 32, C.warn, W.small(), c.w)
    end
    return h
end

local function sks_settings_card(ctx, x, y, w)
    local se = ctx.st.settings
    local scene_search = se.scene_search_available ~= false
    local c, h = card(x, y, w, "SKS 设置", 3, scene_search and 2 or 1)
    c.row("捏脸滑块上限", function(sx, sw)
        local ch, v = W.slider("sculpt_max", sx, c.y, min(320, sw), 28, se.sculpt_max or 1, 1, 5, { step = 0.1, fmt = "%.1f" })
        if ch then setting(ctx, "sculpt_max", v) end
    end)
    c.row("扫描间隔（秒，0=关）", function(sx, sw)
        local ch, v = W.slider("periodic", sx, c.y, min(320, sw), 28, se.periodic_scan_sec or 5, 0, 60, { step = 1, fmt = "%.0f" })
        if ch then setting(ctx, "periodic_scan_sec", v) end
    end)
    c.row("写入阈值", function(sx, sw)
        local ch, v = W.slider("eps", sx, c.y, min(320, sw), 28, se.write_epsilon or 0.001, 0, 0.01, { step = 0.0005, fmt = "%.4f", value_w = 56 })
        if ch then setting(ctx, "write_epsilon", v) end
    end)
    local bx = c.x
    local c1, v1, w1 = W.toggle("权重截断到 0..1", bx, c.y, se.clamp ~= false)
    if c1 then setting(ctx, "clamp", v1) end
    bx = bx + w1 + 24
    local c2, v2 = W.toggle("过场动画中驱动", bx, c.y, se.cutscene_drive == true)
    if c2 then setting(ctx, "cutscene_drive", v2) end
    if scene_search then
        c.y = c.y + 34
        local c3, v3 = W.toggle("始终搜索整个场景（其他猎人；名片和菜单自动）", c.x, c.y, se.scene_search_always == true)
        if c3 then setting(ctx, "scene_search_always", v3) end
    end
    return h
end

local function settings_card(ctx, x, y, w)
    local h1 = ui_settings_card(ctx, x, y, w)
    return h1 + 12 + sks_settings_card(ctx, x, y + h1 + 12, w)
end

local function perf_card(ctx, x, y, w)
    local st = ctx.st
    local a = st.debug.perf or {}
    local details = ctx.state.perf_details == true
    local h = details and 426 or 200
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local cy = y + 10
    local hw = W.h2("性能", rx, cy) + 12
    D.text(L.f("写入 %.1f / 跳过 %.1f 每帧", a.writes or 0, a.skipped or 0), rx + hw, cy + 3, C.muted, W.small(), rw - hw)
    cy = cy + 30
    local total = max(0.3, a.total or 0)
    for _, k in ipairs({ { "read", "读取" }, { "compute", "计算" }, { "write", "写入" }, { "scan", "扫描读取" }, { "total", "完整更新" } }) do
        local v = a[k[1]] or 0
        D.text_mid(k[2], rx, cy, 22, C.text, W.small(), 60)
        W.meter(rx + 60, cy + 6, rw - 140, 10, v / total, C.brass)
        D.text_mid(string.format("%.3f ms", v), rx + rw - 72, cy, 22, C.text, W.mono())
        cy = cy + 26
    end
    if W.button(details and "收起耗时详情" or "展开耗时详情", rx, cy, 128, 26, { font = W.small(), kind = "ghost" }) then
        ctx.state.perf_details = not details
    end
    W.tooltip("上方按 60 帧显示分类均值。完整更新包含 SKS 的播放、条件、扫描和保存；绘制与游戏动画回调另外计量。", rx + 140, cy, rw - 140, 26)
    if details then
        cy = cy + 32
        D.text_mid("最近 60 次：平均 / 最大 / P95（毫秒）", rx, cy, 22, C.muted, W.small(), rw)
        cy = cy + 24
        for _, item in ipairs({ { "tick", "完整更新" }, { "scan", "完整扫描" }, { "ui", "面板绘制" },
            { "playback_load", "文件读取" }, { "playback_prepare", "准备分片" },
            { "playback_tick", "播放更新" }, { "raw_inject", "原版注入" } }) do
            local metric = (a.timings or {})[item[1]] or {}
            D.text_mid(item[2], rx, cy, 22, C.text, W.small(), 82)
            local text = string.format("%.3f / %.3f / %.3f", metric.avg or 0, metric.max or 0, metric.p95 or 0)
            D.text_mid(text, rx + 86, cy, 22, C.text, W.mono(), rw - 86)
            W.tooltip(L.f("%s：%s ms。分类存在重叠，不相加；P95 每 60 次调用更新。", L.tr(item[2]), text), rx, cy, rw, 22)
            cy = cy + 24
        end
    end
    return h
end

local function scene_card(ctx, x, y, w)
    local st, call = ctx.st, ctx.call
    local sc = st.scene
    local lines = {}
    local ls = sc.last_scan
    if ls then
        lines[#lines + 1] = L.f("最近扫描 %s · %.1f ms · 脸 %d（缓存跳过 %d）%s", os.date("%H:%M:%S", ls.time or 0),
            ls.ms or 0, ls.faces or 0, ls.cached_skip or 0, ls.preview and L.tr(" · 名片") or "")
    end
    for _, r in ipairs(sc.rigs or {}) do
        local t = {}
        for _, x2 in ipairs(r.targets or {}) do t[#t + 1] = L.f("%s（%d 通道）", x2.display or x2.name, x2.channels) end
        lines[#lines + 1] = L.f("%s%s：%s", r.primary and "★ " or "   ", L.tr(r.label), table.concat(t, L.tr("，")))
    end
    local additional = sc.additional or {}
    for _, actor in ipairs(additional.instances or {}) do
        lines[#lines + 1] = L.f("实例 %s · Profile %s · %d 通道 · %s", actor.label,
            actor.profile, actor.channels, L.tr(actor.ready and "驱动中" or "等待网格就绪"))
        if actor.binding then lines[#lines + 1] = L.f("  绑定 %s", actor.binding) end
        for _, warning in ipairs(actor.warnings or {}) do lines[#lines + 1] = "  " .. warning end
    end
    for _, message in ipairs(additional.errors or {}) do lines[#lines + 1] = L.f("实例：%s", message) end
    for _, p in ipairs(sc.parts or {}) do
        lines[#lines + 1] = L.f("部件 %s · %d 通道 · 指纹 %s%s", p.display ~= p.id and p.display and L.f("%s（%s）", p.display, p.id) or p.id, p.channels, tostring(p.fingerprint),
            p.binding and L.f(" · 绑定 %s", p.binding) or "")
        if p.weights then
            lines[#lines + 1] = L.f("  权重数量 %s / 通道 %d · 列表长度 %s",
                tostring(p.weights.count or L.tr("不可读")), p.weights.channels, tostring(p.weights.length or L.tr("不可读")))
        end
    end
    local h = 50 + max(1, #lines) * 20
    W.panel_box(x, y, w, h, true)
    local tw = W.h2("场景", x + 12, y + 10)
    if W.button("重新扫描", x + w - 100, y + 8, 88, 26, { font = W.small() }) then call("rescan") end
    if W.button("哈希探针", x + w - 196, y + 8, 88, 26, { font = W.small(), kind = "ghost" }) then ctx.SKS.request_probe() end
    local cy = y + 42
    if #lines == 0 then D.text("还没有扫描结果", x + 12, cy, C.muted, W.small()) end
    for _, l in ipairs(lines) do D.text(l, x + 12, cy, C.text, W.small(), w - 24); cy = cy + 20 end
    return h
end

local function native_card(ctx, x, y, w)
    local ns = ctx.st.native_signals
    if not ns or not ns.available then return 0 end
    local rows = ns.rows or {}
    local shown = min(#rows, 8)
    local actions = ns.recording and { {"停止并保存", "stop"} }
        or { {"开始录制", "start"}, {"记录中立位", "baseline"}, {"保存快照", "snapshot"}, {"重试保存", "retry"} }
    local columns = max(1, math.floor((w - 16) / 108))
    local h = 188 + shown * 20 + (math.ceil(#actions / columns) - 1) * 32
    W.panel_box(x, y, w, h, true)
    local rx, rw, cy = x + 12, w - 24, y + 10
    W.h2("原生信号诊断与录制", rx, cy); cy = cy + 30
    W.text_box("native_label", rx, cy, min(260, rw), 26, ctx.state.native_label or "",
        "录制名称：待机、眨眼、说话等", function(v) ctx.state.native_label = v end)
    cy = cy + 34
    local bx = rx
    for _, action in ipairs(actions) do
        if bx + 100 > rx + rw then cy = cy + 32; bx = rx end
        if W.button(action[1], bx, cy, 100, 26, {font = W.small()}) then
            local ok, _, msg = ctx.call("native_signals", {action = action[2], label = ctx.state.native_label or ""})
            ctx.state.native_error = not ok and msg or nil
        end
        bx = bx + 108
    end
    cy = cy + 34
    D.text(L.f("骨骼 %d · 原生通道 %d · 缺失 %d · %.1f 秒 / %d 帧",
        ns.joints or 0, ns.taps or 0, ns.missing or 0, ns.elapsed or 0, ns.samples or 0), rx, cy, C.text, W.small(), rw)
    cy = cy + 22
    D.text(ctx.state.native_error or ns.status or "", rx, cy, C.muted, W.small(), rw); cy = cy + 22
    D.text("相对当前中立位：位移 mm / 旋转 °（峰值）", rx, cy, C.muted, W.small(), rw); cy = cy + 22
    for i = 1, shown do
        local row = rows[i]
        D.text(L.f("%s  %.3f / %.2f（%.3f / %.2f）", row.name, row.mm, row.deg, row.peak_mm, row.peak_deg),
            rx, cy, C.text, W.small(), rw)
        cy = cy + 20
    end
    return h
end

local function external_card(ctx, x, y, w)
    local held = ctx.st.external and ctx.st.external.held or {}
    local h = 50 + max(1, #held) * 24
    W.panel_box(x, y, w, h, true)
    local tw = W.h2("其他插件的控制", x + 12, y + 10)
    D.text("（ShapeKeySystemAPI）", x + 18 + tw, y + 13, C.faint, W.small())
    if #held > 0 and W.button("全部收回", x + w - 100, y + 8, 88, 26, { font = W.small(), kind = "danger" }) then
        ctx.call("external_release", {})
    end
    local cy = y + 42
    if #held == 0 then D.text("没有插件在控制形态键", x + 12, cy, C.muted, W.small()) end
    for _, e in ipairs(held) do
        D.text_mid(e.name, x + 12, cy, 22, C.text, W.small(), w * 0.4)
        D.text_mid(e.owner, x + 12 + w * 0.42, cy, 22, C.brass, W.small(), w * 0.3)
        D.text_mid(string.format("%.2f", e.value or 0), x + w - 120, cy, 22, C.text, W.mono())
        if W.tbutton("收回", x + w - 56, cy) then ctx.call("external_release", { owner = e.owner, name = e.name }) end
        cy = cy + 24
    end
    return h
end

local function log_card(ctx, x, y, w)
    local l = ctx.st.debug.log or {}
    local n = min(#l, 30)
    local h = 44 + max(1, n) * 18
    W.panel_box(x, y, w, h, true)
    W.h2("日志", x + 12, y + 10)
    local cy = y + 38
    for i = #l, #l - n + 1, -1 do
        D.text(l[i].time .. "  " .. l[i].text, x + 12, cy, C.muted, W.small(), w - 24)
        cy = cy + 18
    end
    for _, line in ipairs(ctx.st.debug.probe or {}) do
        -- probe output is appended below the log when present
        D.text(line, x + 12, cy, C.faint, W.small(), w - 24); cy = cy + 18; h = h + 18
    end
    return h
end

-- the items of a version's notes ("；"-separated), one line each so a narrow card does not cut them
local function note_lines(notes)
    local out = {}
    -- 「；」是三个字节，不能放进 [^...] 字符类，否则会切开含这些字节的汉字
    local s, start = tostring(notes or ""), 1
    while true do
        local i, j = s:find("；", start, true)
        local part = s:sub(start, (i or 0) - 1)
        if part ~= "" then out[#out + 1] = part end
        if not i then return out end
        start = j + 1
    end
end

-- author, version and the latest two release notes; h = the space it may use (fills the gap under
-- the performance card in the two-column layout), grown to fit every line
local function about_card(ctx, x, y, w, h)
    local shown = {}
    for i = 1, min(2, #Version.history) do shown[i] = note_lines(Version.history[i].notes) end
    local lines = 0
    for _, l in ipairs(shown) do lines = lines + max(1, #l) end
    h = max(h or 0, 10 + 30 + 44 + lines * 22 + 6)
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local cy = y + 10
    W.h2("关于", rx, cy)
    cy = cy + 30
    D.text(string.format("%s v%s", Version.name, Version.number), rx, cy, C.muted, W.small(), rw)
    cy = cy + 22
    D.text(L.f("作者 %s", Version.author), rx, cy, C.muted, W.small(), rw)
    cy = cy + 22
    for i, parts in ipairs(shown) do
        local e = Version.history[i]
        D.text(string.format("%s v%s", L.tr(i == 1 and "本版" or "上一版"), e.version), rx, cy, i == 1 and C.brass or C.faint, W.small(), 110)
        if #parts == 0 then cy = cy + 22 end
        for _, part in ipairs(parts) do
            D.text(part, rx + 110, cy, i == 1 and C.text or C.muted, W.small(), rw - 110)
            cy = cy + 22
        end
    end
    return h
end

function Page.draw(ctx, x, y, w)
    local cy = y
    local two = w >= 760
    if two then
        local lw = (w - 12) * 0.55
        local h1 = settings_card(ctx, x, cy, lw)
        local h2 = perf_card(ctx, x + lw + 12, cy, w - lw - 12)
        local h3 = about_card(ctx, x + lw + 12, cy + h2 + 12, w - lw - 12, h1 - h2 - 12)
        cy = cy + max(h1, h2 + 12 + h3) + 12
    else
        cy = cy + settings_card(ctx, x, cy, w) + 12
        cy = cy + perf_card(ctx, x, cy, w) + 12
        cy = cy + about_card(ctx, x, cy, w) + 12
    end
    cy = cy + external_card(ctx, x, cy, w) + 12
    cy = cy + scene_card(ctx, x, cy, w) + 12
    local nh = native_card(ctx, x, cy, w)
    if nh > 0 then cy = cy + nh + 12 end
    cy = cy + log_card(ctx, x, cy, w)
    return cy - y
end

return Page
