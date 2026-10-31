-- ShapeKeySystem panel, advanced page "面捕": face and head tracking from a phone (Mocap.lua), and,
-- on games that have one, the face mirror in a second tab.
-- Drawing only submits `mocap` / `mocap_calibrate`; the values shown come from state.mocap.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local min = math.min

local LW = 120   -- label column
local AXES = { { "pitch", "俯仰" }, { "yaw", "左右转" }, { "roll", "歪头" } }
local SOURCES = { "head#1", "head#2", "head#3" }

local function patch(call, p) call("mocap", { patch = p }) end

local function current_scheme(m)
    for i, sc in ipairs(m.schemes) do
        if sc.id == m.cfg.scheme then return sc, i end
    end
    return m.schemes[1], 1
end

-- label | slider; returns the row height
local function slider_row(id, label, value, lo, hi, opt, rx, ry, rw, on_change)
    D.text_mid(label, rx, ry, 28, C.text, W.small(), LW - 8)
    local ch, v = W.slider(id, rx + LW, ry, min(360, rw - LW), 28, value, lo, hi, opt)
    if ch then on_change(v) end
    return 32
end

-- what only the selected scheme has: its app, its transport and how it is doing.
-- With the native receiver the game listens itself and the phone app is pointed at this PC;
-- without it a bridge program has to run.
local DEST = { ifacialmocap = { "Destination IP address", 49983 }, rhylive = { "发送地址", 9000 } }

-- returns the lines and the index of the 本机 IP line (gets the refresh button) or nil
local function setup_lines(m, sc)
    local nv = m.native
    if sc.id == "vmc" then
        -- usually sent from this PC and has no bridge script: only the native receiver takes it
        if not nv.available then return { "VMC 需要游戏内接收插件 ShapeKeySystem_Mocap.dll。" } end
        local port = nv.port > 0 and nv.port or 39539
        return { L.f("让支持 VMC 协议的软件发到 127.0.0.1、端口 %s，游戏内直接接收。", port),
                 "ARKit 52 个名字（Perfect Sync）按表情配置驱动；其他表情名直接写入同名形态键。",
                 L.f("其他表情名：正在写入 %s 个", m.extra_n or 0) }
    end
    if not nv.available then return { L.f("手机打开 %s，并启用相应的收发程序。", L.tr(sc.name)) } end
    local d = DEST[sc.id] or { "发送地址", 0 }
    local port = nv.port > 0 and nv.port or d[2]
    local ips = #nv.ips > 0 and table.concat(nv.ips, L.tr("、")) or L.tr("（未取到）")
    return { L.f("在 %s 里把 %s 设为本机 IP、端口 %s，游戏内直接接收。", L.tr(sc.name), L.tr(d[1]), port),
             L.f("本机 IP：%s", ips) }, 2
end

local function scheme_box_h(m, sc) return 60 + 22 * #setup_lines(m, sc) end

local function scheme_box(ctx, m, sc, x, y, w)
    local call = ctx.call
    local h = scheme_box_h(m, sc)
    D.rrect(x, y, w, h, 3, C.panel2)
    D.outline(x, y, w, h, 3, 1, C.line)
    local rx, rw = x + 10, w - 20
    local ry = y + 8
    D.text(L.f("基础配置 · %s", L.tr(sc.name)), rx, ry, C.text, W.small(), rw); ry = ry + 24
    local lines, ip_line = setup_lines(m, sc)
    for i, line in ipairs(lines) do
        local lw = D.text(line, rx, ry, C.faint, W.small(), rw)
        -- the IP line gets a refresh: the lookup runs once after load, Wi-Fi may change later
        if i == ip_line then
            if W.tbutton("刷新", rx + (tonumber(lw) or 200) + 8, ry - 3) then call("mocap_refresh_ips") end
        end
        ry = ry + 22
    end
    local input
    if m.age == nil then input = "还没有收到数据"
    elseif m.live then input = L.f("接收中 %.0f Hz", m.rx_hz)
    else input = L.f("%.1f 秒没有新数据", m.age) end
    local nv, line = m.native, nil
    if nv.available then
        if nv.running then
            line = L.f("%s · 游戏内接收，UDP %d%s", L.tr(input), nv.port,
                nv.sender ~= "" and L.f(" · 来自 %s", nv.sender) or "")
        else
            line = L.f("游戏内接收没有启动（错误 %d，端口可能被占用）", nv.error or 0)
        end
    else
        line = L.f("%s · 读取 %.2f 毫秒/帧", L.tr(input), m.read_ms)
    end
    D.text(line, rx, ry, m.live and C.signal or C.muted, W.small(), rw)
    return h
end

local function face_card(ctx, x, y, w)
    local m, call = ctx.st.mocap, ctx.call
    local c = m.cfg
    local sc, cur = current_scheme(m)
    local h = 298 + scheme_box_h(m, sc)
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10
    W.h2("面捕总配置", rx, ry); ry = ry + 32

    local ch, v, tw = W.toggle("启用", rx, ry, c.enabled)
    if ch then patch(call, { enabled = v }) end
    ch, v = W.toggle("左右镜像", rx + tw + 28, ry, c.mirror)
    if ch then patch(call, { mirror = v }) end
    ry = ry + 36

    D.text_mid("面捕方案", rx, ry, 28, C.text, W.small(), LW - 8)
    local labels = {}
    for i, s2 in ipairs(m.schemes) do labels[i] = s2.name end
    local cs, si = W.select("mocap_scheme", rx + LW, ry, min(240, rw - LW), 28, labels, cur)
    if cs and m.schemes[si] then patch(call, { scheme = m.schemes[si].id }) end
    ry = ry + 36
    ry = ry + scheme_box(ctx, m, sc, rx, ry, rw) + 12

    D.text(L.f("%s · 淡入 %d%% · ARKit 通道 %d / 52 · 经游戏信号驱动 %d 个", L.tr(m.status),
        math.floor(m.fade * 100 + 0.5), m.resolved, m.signals or 0), rx, ry, m.live and C.signal or C.muted, W.small(), rw)
    ry = ry + 28

    ry = ry + slider_row("mocap_gain", "整体强度", c.gain, 0, 3, { step = 0.01, fmt = "×%.2f" }, rx, ry, rw,
        function(nv) patch(call, { gain = nv }) end)
    ry = ry + slider_row("mocap_smooth", "平滑", c.smoothing, 0, 1, { step = 0.01, fmt = "%.2f" }, rx, ry, rw,
        function(nv) patch(call, { smoothing = nv }) end)
    ry = ry + slider_row("mocap_fade", "淡入淡出", c.fade_sec, 0, 2, { step = 0.05, fmt = "%.2fs" }, rx, ry, rw,
        function(nv) patch(call, { fade_sec = nv }) end)
    ry = ry + 4

    local bx = rx
    local clicked, bw = W.button("校准面部", bx, ry, nil, 28, { kind = m.live and "primary" or nil, disabled = not m.live })
    if clicked then call("mocap_calibrate", { what = "face" }) end
    bx = bx + bw + 8
    clicked, bw = W.button("清除校准", bx, ry, nil, 28, { disabled = next(c.neutral) == nil })
    if clicked then call("mocap_calibrate", { what = "clear" }) end
    D.text_mid("放松面部、正对手机时点校准", bx + bw + 12, ry, 28, C.faint, W.small(), rw - (bx + bw + 12 - rx))
    return h
end

-- fixed pose without the phone, for checking the axes
local function test_pose(m, call, rx, ry, rw)
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
    D.text(L.f("原始 %.1f / %.1f / %.1f  →  俯仰 %.1f°  左右转 %.1f°  歪头 %.1f°",
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
    test_pose(m, call, rx, ry, rw)
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

-- face mirror (state.face_mirror, only on games whose adapter has one): a second camera on the
-- player's face, shown in a window on screen
local function mirror_patch(call, p) call("face_mirror", { patch = p }) end

-- label | three sliders for x / y / z of one table in the current joint's rig
local function xyz_row(call, id, label, bind, key, value, lo, hi, opt, rx, ry, rw)
    D.text_mid(label, rx, ry, 28, C.text, W.small(), LW - 8)
    local sx = rx + LW
    local sw = (min(rw, LW + 480) - LW - 16) / 3
    for k, ax in ipairs({ "x", "y", "z" }) do
        local o = { step = opt.step, fmt = ax:upper() .. " " .. opt.fmt, value_w = 64 }
        local cs, sv = W.slider(id .. ax, sx + (k - 1) * (sw + 8), ry, sw, 28, value[ax], lo, hi, o)
        if cs then mirror_patch(call, { rigs = { [bind] = { [key] = { [ax] = sv } } } }) end
    end
    return 32
end

local function mirror_card(ctx, x, y, w)
    local fm, call = ctx.st.face_mirror, ctx.call
    local c = fm.cfg
    local rig = c.rigs[c.bind]
    local per_row = 4
    local part_rows = math.ceil(#fm.parts / per_row)
    local h = 10 + 32 + 36 + 36 + 10 * 32 + 36 + 36 + part_rows * 36 + 4
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10
    W.h2("表情镜", rx, ry); ry = ry + 32

    local ch, v = W.toggle("启用", rx, ry, c.enabled)
    if ch then mirror_patch(call, { enabled = v }) end
    D.text_mid(fm.status or "-", rx + 120, ry, 28, C.muted, W.small(), rw - 120)
    ry = ry + 36

    D.text_mid("定位点", rx, ry, 28, C.text, W.small(), LW - 8)
    local labels, cur = {}, 1
    for i, b in ipairs(fm.binds) do
        labels[i] = b.name
        if b.id == c.bind then cur = i end
    end
    local cs, si = W.select("mirror_bind", rx + LW, ry, min(240, rw - LW), 28, labels, cur)
    if cs and fm.binds[si] then mirror_patch(call, { bind = fm.binds[si].id }) end
    ry = ry + 36

    local function row(id, label, value, lo, hi, opt, key)
        ry = ry + slider_row(id, label, value, lo, hi, opt, rx, ry, rw, function(nv) mirror_patch(call, { [key] = nv }) end)
    end
    row("mirror_size", "窗口大小", c.size, 100, 800, { step = 1, fmt = "%.0f" }, "size")
    row("mirror_x", "窗口位置 X", c.x, -200, 2120, { step = 1, fmt = "%.0f" }, "x")
    row("mirror_y", "窗口位置 Y", c.y, -200, 1280, { step = 1, fmt = "%.0f" }, "y")
    ry = ry + slider_row("mirror_dist", "镜头距离", rig.dist, 0.2, 2.5, { step = 0.01, fmt = "%.2f m" }, rx, ry, rw,
        function(nv) mirror_patch(call, { rigs = { [c.bind] = { dist = nv } } }) end)
    row("mirror_fov", "视野", c.fov, 5, 60, { step = 0.5, fmt = "%.1f°" }, "fov")
    ry = ry + xyz_row(call, "mirror_aim_", "对准点", c.bind, "aim", rig.aim, -1, 1, { step = 0.005, fmt = "%.3f" }, rx, ry, rw)
    ry = ry + xyz_row(call, "mirror_rot_", "镜头角度", c.bind, "rot", rig.rot, -180, 180, { step = 1, fmt = "%.0f°" }, rx, ry, rw)
    row("mirror_ev", "曝光补偿（越小越亮）", c.ev, -4, 4, { step = 0.05, fmt = "%.2f EV" }, "ev")
    row("mirror_clip_front", "保留范围·前", c.clip_front, 0.05, 1, { step = 0.01, fmt = "%.2f m" }, "clip_front")
    row("mirror_clip_back", "保留范围·后", c.clip_back, 0.05, 2, { step = 0.01, fmt = "%.2f m" }, "clip_back")

    ch, v = W.toggle("曝光跟随主画面测光", rx, ry, c.follow_meter)
    if ch then mirror_patch(call, { follow_meter = v }) end
    ry = ry + 36
    -- parts the mirror leaves out (the head always shows); the game decides which parts there are
    D.text_mid("隐藏部位", rx, ry, 28, C.text, W.small(), LW - 8)
    local cw = math.floor((min(rw, LW + 480) - LW) / per_row)
    for i, p in ipairs(fm.parts) do
        local col, line = (i - 1) % per_row, (i - 1) // per_row
        local cp, pv = W.toggle(p.name, rx + LW + col * cw, ry + line * 36, c.hide[p.id] == true)
        if cp then mirror_patch(call, { hide = { [p.id] = pv } }) end
    end
    ry = ry + part_rows * 36

    local bx = rx
    local clicked, bw = W.button("对准定位点", bx, ry, nil, 28)
    if clicked then call("face_mirror_reset", { what = "aim" }) end
    bx = bx + bw + 8
    clicked, bw = W.button("恢复此骨骼的默认镜头", bx, ry, nil, 28)
    if clicked then call("face_mirror_reset", { what = "rig" }) end
    bx = bx + bw + 8
    clicked = W.button("全部恢复默认", bx, ry, nil, 28)
    if clicked then call("face_mirror_reset", { what = "all" }) end
    return h
end

-- 面捕 | 表情镜 tabs, only on games with a face mirror
local TABS = { { "mocap", "面捕" }, { "mirror", "表情镜" } }

function Page.draw(ctx, x, y, w)
    if not ctx.st.mocap then return 0 end
    local cy = y
    if ctx.st.face_mirror then
        local tab, th = W.tabs(ctx.state, x, cy, w, TABS)
        cy = cy + th
        if tab == "mirror" then return cy - y + mirror_card(ctx, x, cy, w) + 12 end
    end
    cy = cy + face_card(ctx, x, cy, w) + 12
    -- a scheme without head data has no head turn at all (Mocap.wants_head)
    if current_scheme(ctx.st.mocap).head ~= false then cy = cy + head_card(ctx, x, cy, w) + 12 end
    local open = ctx.state.channels_open == true
    local clicked, hh = W.header("各通道强度", x, cy, w, open, "灰：手机原始值  亮：写入值")
    if clicked then ctx.state.channels_open = not open end
    cy = cy + hh + 6
    if open then cy = cy + channels(ctx, x, cy, w) + 12 end
    return cy - y
end

return Page
