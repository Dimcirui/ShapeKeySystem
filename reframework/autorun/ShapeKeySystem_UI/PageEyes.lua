-- ShapeKeySystem panel, advanced page "视线": live eye direction, full-weight angles, inversion,
-- neutral calibration and which gaze key sets are driven.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")

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
    D.text_center(string.format("水平 %+.1f°   垂直 %+.1f°", yaw, pitch), x, y + size + 4, size, 24, C.text, W.small())
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
    local h1 = eye_box("右眼", ea.R, full, x, cy, size)
    eye_box("左眼", ea.L, full, x + size + 10, cy, size)
    local fx, fw = x + 2 * (size + 10), w - 2 * (size + 10)
    if fw < 260 then fx, fw = x, w; cy = cy + h1 + 12 end
    local fy = (fx == x) and cy or y
    W.panel_box(fx, fy, fw, 320, true)
    local rx, rw = fx + 12, fw - 24
    local ry = fy + 10
    W.label("映射", rx, ry); ry = ry + 22
    D.text_mid("满权重水平角", rx, ry, 28, C.text, W.small(), 96)
    local c1, v1 = W.slider("yaw", rx + 100, ry, rw - 100, 28, full.yaw, 5, 60, { step = 1, fmt = "%.0f°" })
    if c1 then call("set_eye_cfg", { patch = { full_deg = { yaw = v1 } } }) end
    ry = ry + 32
    D.text_mid("满权重垂直角", rx, ry, 28, C.text, W.small(), 96)
    local c2, v2 = W.slider("pitch", rx + 100, ry, rw - 100, 28, full.pitch, 5, 60, { step = 1, fmt = "%.0f°" })
    if c2 then call("set_eye_cfg", { patch = { full_deg = { pitch = v2 } } }) end
    ry = ry + 36
    local inv = e.invert or {}
    local c3, v3, w3 = W.toggle("水平反转", rx, ry, inv.yaw == true)
    if c3 then call("set_eye_cfg", { patch = { invert = { yaw = v3 } } }) end
    local c4, v4 = W.toggle("垂直反转", rx + w3 + 20, ry, inv.pitch == true)
    if c4 then call("set_eye_cfg", { patch = { invert = { pitch = v4 } } }) end
    ry = ry + 36
    if W.button("把当前朝向设为正前方", rx, ry, nil, 28) then call("calibrate_eye_neutral") end
    ry = ry + 42
    W.label("驱动的形态键组", rx, ry); ry = ry + 22
    local sets = e.sets or {}
    local c5, v5 = W.toggle("EyeLook*（眼睑跟随）", rx, ry, sets.eye_look ~= false)
    if c5 then call("set_eye_cfg", { patch = { sets = { eye_look = v5 } } }) end
    ry = ry + 32
    local c6, v6 = W.toggle("Look*（虹膜平面移动）", rx, ry, sets.look ~= false)
    if c6 then call("set_eye_cfg", { patch = { sets = { look = v6 } } }) end
    ry = ry + 34
    D.text("虹膜仍绑着眼球骨骼权重时，", rx, ry, C.muted, W.small(), rw)
    D.text("会和 Look* 叠加，移动量翻倍。", rx, ry + 18, C.muted, W.small(), rw)
    local bottom = max(y + h1, fy + 320)
    cy = bottom + 12
    D.text("视线强度在「表情」页调整。", x, cy, C.faint, W.small(), w)
    return cy + 22 - y
end

return Page
