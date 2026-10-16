-- ShapeKeySystem panel, "自动表情" section of the expression details page: the procedural blink
-- switch, merge mode, frequency and speed. Drawing only submits `set_procedural`.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")

local Page = {}
local C = T.c
local min = math.min

function Page.draw(ctx, x, y, w)
    local st, live, call = ctx.st, ctx.live, ctx.call
    local p = st.procedural
    if not p or not p.blink then return 0 end
    local h = 196
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10
    local c1, v1, w1 = W.toggle("自动眨眼", rx, ry, p.enabled == true)
    if c1 then call("set_procedural", { patch = { enabled = v1 } }) end
    local mx = rx + w1 + 24
    local v = (live.procedural and live.procedural.blink) or 0
    W.meter(mx, ry + 10, min(160, rw - (mx - rx)), 9, v, C.signal)
    ry = ry + 36

    D.text_mid("合成方式", rx, ry, 28, C.text, W.small(), 96)
    local labels, cur = {}, 1
    for i, m in ipairs(p.modes) do
        labels[i] = p.mode_names[m]
        if m == p.mode then cur = i end
    end
    local c2, i2 = W.select("proc_mode", rx + 100, ry, min(260, rw - 100), 28, labels, cur)
    if c2 then call("set_procedural", { patch = { mode = p.modes[i2] } }) end
    ry = ry + 34

    local b = p.blink
    D.text_mid("眨眼频率", rx, ry, 28, C.text, W.small(), 96)
    local c3, v3 = W.slider("proc_freq", rx + 100, ry, rw - 100, 28, p.frequency, 0.2, 4, { step = 0.05, fmt = "×%.2f" })
    if c3 then call("set_procedural", { patch = { frequency = v3 } }) end
    ry = ry + 32
    D.text_mid("眨眼速度", rx, ry, 28, C.text, W.small(), 96)
    local c4, v4 = W.slider("proc_speed", rx + 100, ry, rw - 100, 28, p.speed, 0.25, 3, { step = 0.05, fmt = "×%.2f" })
    if c4 then call("set_procedural", { patch = { speed = v4 } }) end
    ry = ry + 34

    local f, s = p.frequency > 0 and p.frequency or 1, p.speed > 0 and p.speed or 1
    D.text(string.format("约每 %.1f–%.1f 秒眨一次，单次 %.0f 毫秒", b.interval_min / f, b.interval_max / f,
        (b.close + b.hold + b.open) * 1000 / s), rx, ry, C.muted, W.small(), rw)
    ry = ry + 20
    local lacking = p.lacking and (p.lacking["blink.L"] or p.lacking["blink.R"])
    D.text(lacking and "本游戏没有可用的眨眼信号，「游戏缺失时用自动表情」会补上眨眼。"
        or "本游戏自带眨眼；要在此之外再眨眼，请选「叠加」。", rx, ry, C.faint, W.small(), rw)
    return h
end

return Page
