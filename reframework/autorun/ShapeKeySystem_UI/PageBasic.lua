-- ShapeKeySystem panel, basic page "表情": face navigator and the overall expression / gaze strength.
-- The face image is for interactions only (2026-10-10): tap the forehead / a cheek / an eye to play
-- that zone's reaction, drag the mouth to pull it, press and drag inside an eye to aim the gaze
-- (backend Touch.lua / gaze_hold). The region whose strength is edited is picked with the pills on
-- the right. Face art comes from the selected style (setting face_style, see
-- Faces.lua): each zone has idle / hover / selected / glow layers, since d2d images cannot be tinted.
-- Zones are hit-tested with ellipses in image pixels.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local Faces = require("ShapeKeySystem_UI.Faces")

local Page = {}
local C = T.c
local max, min = math.max, math.min

-- the zone pills under the controls (fixed, whatever the face style draws)
local PILLS = { "brow", "eye", "nose_cheek", "mouth" }

local function img(style, name) return D.image_res(style.prefix .. "face_" .. name .. ".png") end

local function region_index(ex, key)
    for i, r in ipairs(ex.regions or {}) do if r.key == key then return i, r end end
end

-- zone under the mouse, and the ellipse that was hit
local function zone_at(style, fx, fy, s)
    local mx, my = (I.mx - fx) / s, (I.my - fy) / s
    for _, z in ipairs(style.zones) do
        for _, e in ipairs(z.ells) do
            local dx, dy = (mx - e[1]) / e[3], (my - e[2]) / e[4]
            if dx * dx + dy * dy <= 1 then return z, e end
        end
    end
end

-- forehead: not a style zone (no art layer); an ellipse above the brows, derived from them
local function forehead_of(style)
    for _, z in ipairs(style.zones) do
        if z.key == "brow" and #z.ells > 0 then
            local x0, x1, top, ry = math.huge, -math.huge, math.huge, 0
            for _, e in ipairs(z.ells) do
                x0, x1 = min(x0, e[1] - e[3]), max(x1, e[1] + e[3])
                top, ry = min(top, e[2] - e[4]), max(ry, e[4])
            end
            local fry = ry * 2
            return { (x0 + x1) / 2, top - fry * 1.1, (x1 - x0) / 2 * 0.9, fry }
        end
    end
end

local function in_ell(px, py, e)
    local dx, dy = (px - e[1]) / e[3], (py - e[2]) / e[4]
    return dx * dx + dy * dy <= 1
end

-- tap zone -> Touch zone
local TAP = { brow = "forehead", forehead = "forehead", nose_cheek = "cheek", eye = "eye" }

-- one press handler for the whole image: press + release without moving = tap, press + move =
-- drag (eye: gaze, mouth: pull). A drag stops on release.
local PRESS_ID = "basic_face_press"
local DRAG_PX = 4
local function face_press(ctx, style, fx, fy, s, hover, hover_e, fore)
    local p = ctx.state.press
    local ix, iy = (I.mx - fx) / s, (I.my - fy) / s
    if not p and I.active == nil and I.clicked and I.hit(fx, fy, style.w * s, style.h * s) then
        local zone, e
        if hover then zone, e = hover.key, hover_e
        elseif fore and in_ell(ix, iy, fore) then zone, e = "forehead", fore end
        if zone then
            I.consume()
            I.active = PRESS_ID
            p = { zone = zone, e = e, x0 = I.mx, y0 = I.my, drag = false }
            ctx.state.press = p
        end
    end
    if not p then return end
    if I.active ~= PRESS_ID or not I.down then
        if p.drag then
            if p.zone == "eye" then ctx.call("gaze_release", {})
            elseif p.zone == "mouth" then ctx.call("touch_release", {}) end
        elseif TAP[p.zone] then
            ctx.call("touch_poke", { zone = TAP[p.zone] })
        end
        ctx.state.press = nil
        if I.active == PRESS_ID then I.active = nil end
        return
    end
    if not p.drag and (math.abs(I.mx - p.x0) > DRAG_PX or math.abs(I.my - p.y0) > DRAG_PX) then p.drag = true end
    if not p.drag then return end
    local e = p.e
    local cx, cy = fx + e[1] * s, fy + e[2] * s
    if p.zone == "eye" then
        -- both eyes look where the mouse is relative to the pressed eye (ellipse edge = full_deg)
        local nx, ny = (ix - e[1]) / e[3], (iy - e[2]) / e[4]
        local len = math.sqrt(nx * nx + ny * ny)
        if len > 1 then nx, ny = nx / len, ny / len end
        local fd = (ctx.st.eyes and ctx.st.eyes.full_deg) or { yaw = 25, pitch = 20 }
        -- the face looks at the viewer: the viewer's right is the face's own left (-yaw); screen y is down
        ctx.call("gaze_hold", { yaw = -nx * fd.yaw, pitch = -ny * fd.pitch })
        local ax, ay = fx + (e[1] + nx * e[3]) * s, fy + (e[2] + ny * e[4]) * s
        D.circle(cx, cy, 2, 1, C.brass_dim)
        D.line(cx, cy, ax, ay, 1, C.brass_dim)
        D.fill_circle(ax, ay, 3.5, C.brass)
    elseif p.zone == "mouth" then
        -- full pull at 2.5 mouth half-widths from the centre
        local reach = e[3] * 2.5
        local nx, ny = (ix - e[1]) / reach, (iy - e[2]) / reach
        local len = math.sqrt(nx * nx + ny * ny)
        if len > 1 then nx, ny = nx / len, ny / len end
        ctx.call("touch_drag", { x = nx, y = ny })
        local ax, ay = cx + nx * reach * s, cy + ny * reach * s
        D.line(cx, cy, ax, ay, 2, C.brass)
        D.fill_circle(cx, cy, 3, C.brass_dim)
        D.fill_circle(ax, ay, 5, C.brass)
    end
end

local function draw_face(ctx, x, y, w)
    local st, live = ctx.st, ctx.live
    local ex = st.expression
    local style = Faces.get(st.settings.face_style)
    if not style then
        W.panel_box(x, y, w, 80)
        D.text("缺少面部图：reframework/data/ShapeKeySystem/faces/*.json", x + 10, y + 10, C.warn, W.small(), w - 20)
        return 80
    end
    local s = (w - 20) / style.w
    local iw, ih = style.w * s, style.h * s
    local h = ih + 20
    W.panel_box(x, y, w, h)
    local fx, fy = x + 10, y + 10
    local lines = img(style, "lines")
    if not lines then
        D.text("缺少图片 reframework/images/" .. style.prefix .. "face_lines.png", fx, fy, C.warn, W.small(), w - 20)
    else
        D.image(lines, fx, fy, iw, ih)
    end
    local hover, hover_e
    if I.hit(fx, fy, iw, ih) then hover, hover_e = zone_at(style, fx, fy, s) end
    local fore = forehead_of(style)
    local hover_fore = not hover and fore and I.hit(fx, fy, iw, ih) and in_ell((I.mx - fx) / s, (I.my - fy) / s, fore)
    local press = ctx.state.press
    if press then hover = nil; hover_fore = false end   -- no hover highlight while pressing
    for _, z in ipairs(style.zones) do
        local state = (ctx.state.zone == z.key) and "sel" or (hover == z and "hover" or "idle")
        local layer = img(style, z.img .. "_" .. state)
        if layer then D.image(layer, fx, fy, iw, ih) end
        local i = region_index(ex, z.key)
        local act = i and live.region_activity[i] or 0
        -- live activity: neutral glow on unselected zones only (selected stays pure gold)
        if act > 0.02 and state ~= "sel" then
            local glow = img(style, z.img .. "_glow")
            if glow then D.image(glow, fx, fy, iw, ih, min(1, act) * 0.8) end
        end
    end
    -- the interactions are an easter egg (user 2026-10-10): no hint text, no forehead outline
    face_press(ctx, style, fx, fy, s, hover, hover_e, fore)
    return h
end

local function big_slider(ctx, id, label, x, y, w, value, lo, hi)
    D.text_mid(label, x, y, 30, C.text, W.body(), 92)
    local ch, v = W.slider(id, x + 100, y, w - 100, 30, value, lo, hi, { step = 0.01, fmt = "%.2f", value_w = 48 })
    return ch, v
end

local function draw_controls(ctx, x, y, w)
    local st, live, call = ctx.st, ctx.live, ctx.call
    local ex = st.expression
    local cy = y
    if ex.no_signals then
        D.text("本游戏目前暂不支持表情", x, cy, C.warn, W.body(), w)
        cy = cy + 30
    end
    -- profile
    local plist, labels, cur = st.presets.expression or {}, {}, nil
    for i, p in ipairs(plist) do
        labels[i] = p.name
        if ex.profile and p.id == ex.profile.id then cur = i end
    end
    D.text_mid("表情配置", x, cy, 28, C.muted, W.small())
    local sw = min(260, w - 160)
    local ch, idx = W.select("basic_profile", x + 70, cy, sw, 28, labels, cur, { placeholder = "（无）" })
    if ch and plist[idx] then call("set_profile", { id = plist[idx].id }) end
    local mx = x + 70 + sw + 8
    local matched, match_w = W.button("自动匹配", mx, cy, nil, 28)
    W.tooltip("切换到与当前部件匹配度最高的表情配置", mx, cy, match_w, 28)
    if matched then call("auto_match_profile", {}) end
    if ex.binding_source then W.chip("来自绑定", mx + match_w + 10, cy + 5, C.brass) end
    cy = cy + 40

    -- selected region
    local key = ctx.state.zone
    local i, r = region_index(ex, key)
    local card_h = 86
    W.panel_box(x, cy, w, card_h, true)
    if r then
        local tw = W.h2(r.name, x + 14, cy + 12)
        W.chip(string.format("实时 %.2f", live.region_activity[i] or 0), x + 26 + tw, cy + 11, C.signal)
        if st.runtime.advanced then
            local label = string.format("在表情详情中查看 %d 个通道", #r.channel_slots)
            local bw = D.measure(W.small(), label) + 22
            if W.button(label, x + w - bw - 12, cy + 8, bw, 24, { kind = "ghost", font = W.small() }) then
                ctx.goto_page("expr")
            end
        end
        local c2, v = big_slider(ctx, "rg_" .. key, "强度", x + 14, cy + 44, w - 28, r.gain, 0, 2)
        if c2 then call("set_region_gain", { region = key, value = v }) end
    else
        D.text("当前表情配置没有这个部位。", x + 14, cy + 14, C.muted, W.body())
    end
    cy = cy + card_h + 12

    -- overall
    local se = st.settings
    W.panel_box(x, cy, w, 140, true)
    W.h2("整体", x + 14, cy + 10)
    local tx = x + 14
    local c5, v5, w5 = W.toggle("表情驱动", tx, cy + 38, se.expression_enabled ~= false)
    if c5 then call("set_setting", { key = "expression_enabled", value = v5 }) end
    W.tooltip("关闭后游戏表情不再驱动形态键；捏脸、条件规则和面部互动照常生效", tx, cy + 38, w5, 28)
    if se.hold_available then
        tx = tx + w5 + 24
        local c6, v6, w6 = W.toggle("禁用骨骼表情", tx, cy + 38, se.hold_face_bones == true)
        if c6 then call("set_setting", { key = "hold_face_bones", value = v6 }) end
        W.tooltip("禁用骨骼驱动的表情，只用形态键控制", tx, cy + 38, w6, 28)
        if se.hold_face_bones and (se.hold_status or "") ~= "" then
            tx = tx + w6 + 12
            D.text_mid(se.hold_status, tx, cy + 38, 28, C.muted, W.small(), x + w - 14 - tx)
        end
    end
    local c3, v3 = big_slider(ctx, "master", "表情强度", x + 14, cy + 70, w - 28, ex.master_gain or 1, 0, 2)
    if c3 then call("set_master_gain", { value = v3 }) end
    local c4, v4 = big_slider(ctx, "gaze", "视线强度", x + 14, cy + 102, w - 28, ex.gaze_gain or 1, 0, 2)
    if c4 then call("set_gaze_gain", { value = v4 }) end
    cy = cy + 152

    -- zone pills
    local pw = (w - 8) / 2
    for k, zkey in ipairs(PILLS) do
        local z = { key = zkey }
        local zi, zr = region_index(ex, z.key)
        local px = x + ((k - 1) % 2) * (pw + 8)
        local py = cy + math.floor((k - 1) / 2) * 52
        local sel = ctx.state.zone == z.key
        D.rrect(px, py, pw, 44, 3, C.panel)
        D.outline(px, py, pw, 44, 3, 1, sel and C.brass or C.line)
        D.text((zr and zr.name) or z.key, px + 10, py + 6, C.text, W.body())
        if zr then
            local g = string.format("×%.2f", zr.gain)
            D.text(g, px + pw - 10 - D.measure(W.mono(), g), py + 8, C.muted, W.mono())
        end
        W.meter(px + 10, py + 30, pw - 20, 5, zi and live.region_activity[zi] or 0, T.c.zone[z.key])
        if I.click(px, py, pw, 44) then ctx.state.zone = z.key end
    end
    cy = cy + 104
    return cy - y
end

function Page.draw(ctx, x, y, w)
    ctx.state.zone = ctx.state.zone or "mouth"
    -- the face art is decoration (the zone pills select regions too): left out without images (ImGui)
    if not D.images() then return draw_controls(ctx, x, y, w) end
    if w >= 600 then
        local fw = min(300, max(220, w * 0.36))
        local h2 = draw_controls(ctx, x + fw + 18, y, w - fw - 18)
        local h1 = draw_face(ctx, x, y, fw)
        return max(h1, h2)
    end
    local style = Faces.get(ctx.st.settings.face_style)
    local h1 = style and ((min(w, 300) - 20) / style.w * style.h + 20) or 80
    local h2 = draw_controls(ctx, x, y + h1 + 14, w)
    draw_face(ctx, x, y, min(w, 300))
    return h1 + 14 + h2
end

return Page
