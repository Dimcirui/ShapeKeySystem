-- ShapeKeySystem panel, advanced page "面捕": iFacialMocap face and head tracking (Mocap.lua).
-- Drawing only submits `mocap` / `mocap_calibrate`; the values shown come from state.mocap.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")

local Page = {}
local C = T.c
local min = math.min

local LW = 120   -- label column
local AXES = { { "pitch", "俯仰" }, { "yaw", "左右转" }, { "roll", "歪头" } }
local SOURCES = { "head#1", "head#2", "head#3" }

local function patch(call, p) call("mocap", { patch = p }) end

-- label | slider; returns the row height
local function slider_row(id, label, value, lo, hi, opt, rx, ry, rw, on_change)
    D.text_mid(label, rx, ry, 28, C.text, W.small(), LW - 8)
    local ch, v = W.slider(id, rx + LW, ry, min(360, rw - LW), 28, value, lo, hi, opt)
    if ch then on_change(v) end
    return 32
end

local function face_card(ctx, x, y, w)
    local m, call = ctx.st.mocap, ctx.call
    local c = m.cfg
    local h = 344
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10
    W.h2("面捕（iFacialMocap）", rx, ry); ry = ry + 32

    local ch, v, tw = W.toggle("启用", rx, ry, c.enabled)
    if ch then patch(call, { enabled = v }) end
    ch, v = W.toggle("左右镜像", rx + tw + 28, ry, c.mirror)
    if ch then patch(call, { mirror = v }) end
    ry = ry + 36

    local input
    if m.age == nil then input = "还没有收到数据"
    elseif m.live then input = string.format("接收中 %.0f Hz", m.rx_hz)
    else input = string.format("%.1f 秒没有新数据", m.age) end
    D.text(string.format("%s · %s · 淡入 %d%%", m.status, input, math.floor(m.fade * 100 + 0.5)),
        rx, ry, m.live and C.signal or C.muted, W.small(), rw)
    ry = ry + 22
    D.text(string.format("当前部件能接住 %d / 52 个 ARKit 通道；读取 %.2f 毫秒/帧", m.resolved, m.read_ms),
        rx, ry, C.faint, W.small(), rw)
    ry = ry + 28

    ry = ry + slider_row("mocap_gain", "整体强度", c.gain, 0, 3, { step = 0.01, fmt = "×%.2f" }, rx, ry, rw,
        function(nv) patch(call, { gain = nv }) end)
    ry = ry + slider_row("mocap_smooth", "平滑", c.smoothing, 0, 1, { step = 0.01, fmt = "%.2f" }, rx, ry, rw,
        function(nv) patch(call, { smoothing = nv }) end)
    ry = ry + slider_row("mocap_fade", "淡入淡出", c.fade_sec, 0, 2, { step = 0.05, fmt = "%.2fs" }, rx, ry, rw,
        function(nv) patch(call, { fade_sec = nv }) end)
    ry = ry + 4

    local bx = rx
    local clicked, bw = W.button("校准中性脸", bx, ry, nil, 28, { kind = m.live and "primary" or nil, disabled = not m.live })
    if clicked then call("mocap_calibrate", { what = "face" }) end
    bx = bx + bw + 8
    clicked, bw = W.button("清除校准", bx, ry, nil, 28, { disabled = next(c.neutral) == nil })
    if clicked then call("mocap_calibrate", { what = "clear" }) end
    D.text_mid("放松面部、正对手机时点校准", bx + bw + 12, ry, 28, C.faint, W.small(), rw - (bx + bw + 12 - rx))
    ry = ry + 40

    -- the game cannot open sockets: a helper on the PC turns the phone's stream into a file
    for _, line in ipairs({
        "手机打开 iFacialMocap，电脑上运行：",
        "python reframework\\data\\ShapeKeySystem\\builtin\\mocap\\ifm_bridge.py <手机 IP>",
        "把 reframework\\data\\ShapeKeySystem\\mocap 加入 Windows Defender 排除项，否则每帧读取要多花约 5 毫秒。",
    }) do
        D.text(line, rx, ry, C.faint, W.small(), rw)
        ry = ry + 20
    end
    return h
end

local function head_card(ctx, x, y, w)
    local m, call = ctx.st.mocap, ctx.call
    local hc = m.cfg.head
    local h = 384
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10
    W.h2("头部转动", rx, ry); ry = ry + 32

    local ch, v = W.toggle("启用", rx, ry, hc.enabled)
    if ch then patch(call, { head = { enabled = v } }) end
    D.text_mid(m.head_status or "-", rx + 120, ry, 28, C.muted, W.small(), rw - 120)
    ry = ry + 34
    local ho = m.head_out
    D.text(string.format("原始 %.1f / %.1f / %.1f  →  俯仰 %.1f°  左右转 %.1f°  歪头 %.1f°",
        m.head_raw[1], m.head_raw[2], m.head_raw[3], ho.pitch, ho.yaw, ho.roll), rx, ry, C.faint, W.small(), rw)
    ry = ry + 26

    ry = ry + slider_row("mocap_head_gain", "强度", hc.gain, 0, 2, { step = 0.01, fmt = "×%.2f" }, rx, ry, rw,
        function(nv) patch(call, { head = { gain = nv } }) end)
    ry = ry + slider_row("mocap_head_max", "最大角度", hc.max_deg, 5, 90, { step = 1, fmt = "%.0f°" }, rx, ry, rw,
        function(nv) patch(call, { head = { max_deg = nv } }) end)
    ry = ry + slider_row("mocap_head_smooth", "平滑", hc.smoothing, 0, 1, { step = 0.01, fmt = "%.2f" }, rx, ry, rw,
        function(nv) patch(call, { head = { smoothing = nv } }) end)

    -- per axis: which head# value feeds it, and its sign
    for _, a in ipairs(AXES) do
        local ax, name = a[1], a[2]
        D.text_mid(name, rx, ry, 28, C.text, W.small(), LW - 8)
        local cs, i = W.select("mocap_src_" .. ax, rx + LW, ry, 110, 28, SOURCES, hc.order[ax])
        if cs then patch(call, { head = { order = { [ax] = i } } }) end
        local ci, iv = W.toggle("反向", rx + LW + 124, ry, hc.invert[ax] == true)
        if ci then patch(call, { head = { invert = { [ax] = iv } } }) end
        ry = ry + 32
    end
    ry = ry + 4
    local clicked = W.button("校准正前方", rx, ry, nil, 28, { disabled = not m.live })
    if clicked then call("mocap_calibrate", { what = "head" }) end
    ry = ry + 36

    -- fixed pose without the phone, for checking the axes
    local t = m.test
    local ct, tv, tw = W.toggle("测试姿势（不用手机）", rx, ry, t.on == true)
    if ct then patch(call, { test = { on = tv } }) end
    if t.on then
        local sx = rx + tw + 20
        local sw = (rx + rw - sx - 16) / 3
        for k, a in ipairs(AXES) do
            local cx = sx + (k - 1) * (sw + 8)
            local cs, sv = W.slider("mocap_test_" .. a[1], cx, ry, sw, 28, t[a[1]], -60, 60, { step = 1, fmt = "%.0f°", value_w = 40 })
            if cs then patch(call, { test = { [a[1]] = sv } }) end
        end
    end
    return h
end

local function channels(ctx, x, y, w)
    local m, call = ctx.st.mocap, ctx.call
    local gains = m.cfg.channel_gains
    local cy = y
    local nw = 170
    local mw = 80
    for i, n in ipairs(m.names) do
        D.text_mid(n, x, cy, 24, C.text, W.small(), nw - 8)
        W.meter(x + nw, cy + 8, mw, 8, m.raw[i] or 0, C.muted)
        W.meter(x + nw + mw + 8, cy + 8, mw, 8, m.out[i] or 0, C.signal)
        local sx = x + nw + 2 * mw + 24
        local ch, v = W.slider("mocap_ch_" .. n, sx, cy - 2, min(260, x + w - sx), 28, tonumber(gains[n]) or 1, 0, 3,
            { step = 0.01, fmt = "×%.2f" })
        if ch then patch(call, { channel_gains = { [n] = v } }) end
        cy = cy + 26
    end
    return cy - y
end

function Page.draw(ctx, x, y, w)
    if not ctx.st.mocap then return 0 end
    local cy = y
    cy = cy + face_card(ctx, x, cy, w) + 12
    cy = cy + head_card(ctx, x, cy, w) + 12
    local open = ctx.state.channels_open == true
    local clicked, hh = W.header("各通道强度", x, cy, w, open, "灰：手机原始值  亮：写入值")
    if clicked then ctx.state.channels_open = not open end
    cy = cy + hh + 6
    if open then cy = cy + channels(ctx, x, cy, w) + 12 end
    return cy - y
end

return Page
