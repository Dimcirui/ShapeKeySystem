-- ShapeKeySystem panel, "自动表情" tab of the 表情 page: the procedural layer's
-- switch and merge mode, then blink, gaze micro-saccades and the idle mouth opening. Drawing only
-- submits `set_procedural`.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local min = math.min

local SWITCH_W = 120
local METER_W = 100

-- one generator: switch | slider label + slider | live value. Returns the row height.
local function row(call, group, label, on, value, rx, ry, rw, slider)
    local ch, v = W.toggle(label, rx, ry, on)
    if ch then call("set_procedural", { patch = { [group] = { enabled = v } } }) end
    local mx = rx + rw - METER_W
    D.text_mid("当前", mx, ry, 28, C.faint, W.small())
    W.meter(mx + 34, ry + 10, METER_W - 34, 9, value, C.signal)
    if slider then
        local sx = rx + SWITCH_W
        D.text_mid(slider.label, sx, ry, 28, C.text, W.small())
        local lw = 64
        local c2, v2 = W.slider(slider.id, sx + lw, ry, mx - 12 - sx - lw, 28, slider.value, slider.lo, slider.hi, slider.opt)
        if c2 then call("set_procedural", { patch = slider.patch(v2) }) end
    end
    return 34
end

function Page.draw(ctx, x, y, w)
    local st, live, call = ctx.st, ctx.live, ctx.call
    local p = st.procedural
    if not p or not p.blink or not p.gaze or not p.breath then return 0 end
    local lp = live.procedural or {}
    local lacking = p.lacking or {}
    local h = 296
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local ry = y + 10

    local c1, v1, w1 = W.toggle("启用", rx, ry, p.enabled == true)
    if c1 then call("set_procedural", { patch = { enabled = v1 } }) end
    local sx = rx + math.max(w1 + 24, SWITCH_W)
    D.text_mid("合成方式", sx, ry, 28, C.text, W.small())
    local labels, cur = {}, 1
    for i, m in ipairs(p.modes) do
        labels[i] = p.mode_names[m]
        if m == p.mode then cur = i end
    end
    local c2, i2 = W.select("proc_mode", sx + 64, ry, min(240, rw - (sx + 64 - rx)), 28, labels, cur)
    if c2 then call("set_procedural", { patch = { mode = p.modes[i2] } }) end
    ry = ry + 40

    -- blink: frequency on the switch row, speed below it
    local b = p.blink
    ry = ry + row(call, "blink", "自动眨眼", b.enabled ~= false, lp.blink or 0, rx, ry, rw,
        { id = "proc_freq", label = "眨眼频率", value = p.frequency, lo = 0.2, hi = 4, opt = { step = 0.05, fmt = "×%.2f" },
          patch = function(v) return { frequency = v } end })
    local spx = rx + SWITCH_W
    D.text_mid("眨眼速度", spx, ry, 28, C.text, W.small())
    local c3, v3 = W.slider("proc_speed", spx + 64, ry, rx + rw - METER_W - 12 - spx - 64, 28, p.speed, 0.25, 3,
        { step = 0.05, fmt = "×%.2f" })
    if c3 then call("set_procedural", { patch = { speed = v3 } }) end
    ry = ry + 32
    local f, sp = p.frequency > 0 and p.frequency or 1, p.speed > 0 and p.speed or 1
    D.text(L.f("约每 %.1f–%.1f 秒眨一次，单次 %.0f 毫秒", b.interval_min / f, b.interval_max / f,
        (b.close + b.hold + b.open) * 1000 / sp), spx, ry, C.muted, W.small(), rw - SWITCH_W)
    ry = ry + 26

    local g = p.gaze
    local gz = lp.gaze or { 0, 0 }
    local amp = g.amplitude > 0 and g.amplitude or 1
    ry = ry + row(call, "gaze", "视线微动", g.enabled ~= false, math.abs(gz[1]) / amp, rx, ry, rw,
        { id = "proc_gaze_amp", label = "微动幅度", value = g.amplitude, lo = 0, hi = 10, opt = { step = 0.5, fmt = "%.1f°" },
          patch = function(v) return { gaze = { amplitude = v } } end })

    local m = p.breath
    local mamp = m.amplitude > 0 and m.amplitude or 1
    ry = ry + row(call, "breath", "微微张嘴", m.enabled ~= false, (lp.mouth or 0) / mamp, rx, ry, rw,
        { id = "proc_mouth_amp", label = "张嘴幅度", value = m.amplitude, lo = 0, hi = 0.3, opt = { step = 0.01, fmt = "%.2f" },
          patch = function(v) return { breath = { amplitude = v } } end })
    D.text(L.f("张嘴约每 %.0f–%.0f 秒一次", m.interval_min, m.interval_max), spx, ry, C.muted, W.small(), rw - SWITCH_W)
    ry = ry + 26

    local blink_lacking = lacking["blink.L"] or lacking["blink.R"]
    D.text(blink_lacking and "本游戏没有可用的眨眼和嘴部待机信号，「游戏缺失时用自动表情」会补上。"
        or "本游戏自带眨眼和嘴部信号；要在此之外再动，请选「叠加」。", rx, ry, C.faint, W.small(), rw)
    ry = ry + 20
    D.text(lacking.gaze and "本游戏读不到眼球角度，视线微动直接驱动视线通道。"
        or "本游戏有眼球角度；要在此之外再微动，也请选「叠加」。", rx, ry, C.faint, W.small(), rw)
    return h
end

return Page
