-- ShapeKeySystem panel, advanced page "视线": live eye direction, full-weight angles, inversion,
-- neutral calibration and which gaze key sets are driven.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local max, min = math.max, math.min

local function eye_box(label, a, full, x, y, size)
    W.panel_box(x, y, size, size + 34)
    D.text(label, x + 12, y + 8, C.muted, W.small())
    local yaw, pitch = a and a.yaw or 0, a and a.pitch or 0

    local cx, cy, r = x + size / 2, y + 34 + (size - 20) / 2, (size - 40) / 2
    D.fill_circle(cx, cy, r, C.ink)
    D.circle(cx, cy, r, 1, C.line)
    D.line(cx - r, cy, cx + r, cy, 1, C.line)
    D.line(cx, cy - r, cx, cy + r, 1, C.line)
    local px = cx + max(-1, min(1, yaw / max(1, full.yaw))) * r
    local py = cy - max(-1, min(1, pitch / max(1, full.pitch))) * r
    D.fill_circle(px, py, 7, C.signal)
    D.text_center(L.t("eyes.angles", yaw, pitch), x, y + size + 4, size, 24, C.text, W.small())
    return size + 34
end

function Page.draw(ctx, x, y, w)
    local st, live, call = ctx.st, ctx.live, ctx.call
    local e = st.eyes
    local cy = y
    local size = min(220, (w - 20) / 3)
    local full = e.full_deg or { yaw = 25, pitch = 20 }
    local ea = live.eye_angle or {}
    -- the face's right eye is drawn on the viewer's left, as in a mirror-free front view
    local h1 = eye_box(L.t("eyes.right"), ea.R, full, x, cy, size)
    eye_box(L.t("eyes.left"), ea.L, full, x + size + 10, cy, size)
    local fx, fw = x + 2 * (size + 10), w - 2 * (size + 10)
    if fw < 260 then fx, fw = x, w; cy = cy + h1 + 12 end
    local fy = (fx == x) and cy or y
    W.panel_box(fx, fy, fw, 320, true)
    local rx, rw = fx + 12, fw - 24
    local ry = fy + 10
    W.label(L.t("eyes.mapping"), rx, ry); ry = ry + 22
    D.text_mid(L.t("eyes.full_yaw"), rx, ry, 28, C.text, W.small(), 96)
    local c1, v1 = W.slider("yaw", rx + 100, ry, rw - 100, 28, full.yaw, 5, 60, { step = 1, fmt = "%.0f°" })
    if c1 then call("set_eye_cfg", { patch = { full_deg = { yaw = v1 } } }) end
    ry = ry + 32
    D.text_mid(L.t("eyes.full_pitch"), rx, ry, 28, C.text, W.small(), 96)
    local c2, v2 = W.slider("pitch", rx + 100, ry, rw - 100, 28, full.pitch, 5, 60, { step = 1, fmt = "%.0f°" })
    if c2 then call("set_eye_cfg", { patch = { full_deg = { pitch = v2 } } }) end
    ry = ry + 36
    local inv = e.invert or {}
    local c3, v3, w3 = W.toggle(L.t("eyes.invert_yaw"), rx, ry, inv.yaw == true)
    if c3 then call("set_eye_cfg", { patch = { invert = { yaw = v3 } } }) end
    local c4, v4 = W.toggle(L.t("eyes.invert_pitch"), rx + w3 + 20, ry, inv.pitch == true)
    if c4 then call("set_eye_cfg", { patch = { invert = { pitch = v4 } } }) end
    ry = ry + 36
    local cal = L.t("eyes.calibrate")
    if W.button(cal, rx, ry, min(rw, D.measure(W.body(), cal) + 22), 28) then call("calibrate_eye_neutral") end
    ry = ry + 42
    W.label(L.t("eyes.sets"), rx, ry); ry = ry + 22
    local sets = e.sets or {}
    local c5, v5 = W.toggle(L.t("eyes.set_eye_look"), rx, ry, sets.eye_look ~= false)
    if c5 then call("set_eye_cfg", { patch = { sets = { eye_look = v5 } } }) end
    ry = ry + 32
    local c6, v6 = W.toggle(L.t("eyes.set_look"), rx, ry, sets.look ~= false)
    if c6 then call("set_eye_cfg", { patch = { sets = { look = v6 } } }) end
    ry = ry + 34
    D.text(L.t("eyes.iris_note1"), rx, ry, C.muted, W.small(), rw)
    D.text(L.t("eyes.iris_note2"), rx, ry + 18, C.muted, W.small(), rw)
    local bottom = max(y + h1, fy + 320)
    cy = bottom + 12
    D.text(L.t("eyes.gain_hint"), x, cy, C.faint, W.small(), w)
    return cy + 22 - y
end

return Page
