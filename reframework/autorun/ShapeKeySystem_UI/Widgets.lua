-- ShapeKeySystem panel: immediate-mode widgets drawn with d2d. Each widget draws itself and
-- returns what the user did this draw. Ids only matter for widgets that keep state across draws
-- (slider drag, open dropdown, scroll offset).

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")

local W = {}
local C = T.c
local max, min, floor, abs = math.max, math.min, math.floor, math.abs

W.open_select = nil      -- id of the open dropdown
local scroll = {}        -- id -> offset
local scroll_stack = {}

local function small() return D.font(T.font.small) end
local function body() return D.font(T.font.body) end
local function mono() return D.font(T.font.small, false, true) end
W.small, W.body, W.mono = small, body, mono

-- ---------------------------------------------------------------- basics
function W.panel_box(x, y, w, h, top_accent)
    D.rrect(x, y, w, h, T.m.radius, C.panel2)
    D.outline(x, y, w, h, T.m.radius, 1, C.line)
    if top_accent then D.rect(x + 1, y, w - 2, 2, C.brass_dim) end
end

function W.label(text, x, y, color, max_w)
    return D.text(text, x, y, color or C.muted, small(), max_w)
end

function W.h2(text, x, y, max_w)
    return D.text(text, x, y, C.text, D.font(T.font.big, true), max_w)
end

function W.chip(text, x, y, color, h)
    h = h or 18
    local f = small()
    local tw = D.measure(f, text)
    local w = tw + 14
    D.rrect(x, y, w, h, h / 2, C.ink)
    D.outline(x, y, w, h, h / 2, 1, color or C.line)
    D.text_center(text, x, y, w, h, color or C.muted, f)
    return w
end

function W.meter(x, y, w, h, v, color)
    D.rect(x, y, w, h, C.ink)
    D.outline(x, y, w, h, 0, 1, C.line)
    v = max(0, min(1, v or 0))
    if v > 0 then D.rect(x + 1, y + 1, (w - 2) * v, h - 2, color or C.signal) end
end

function W.separator(x, y, w) D.rect(x, y, w, 1, C.line) end

-- hover tooltip, drawn above everything
function W.tooltip(text, x, y, w, h)
    if not text or text == "" or I.active or not I.hit(x, y, w, h) then return end
    D.defer(function()
        local f = small()
        local tw, th = D.measure(f, text)
        local sw = D.surface_size()
        local tx = min(I.mx + 14, sw - tw - 20)
        local ty = I.my + 18
        D.rrect(tx, ty, tw + 12, th + 8, 3, C.ink)
        D.outline(tx, ty, tw + 12, th + 8, 3, 1, C.line)
        D.text(text, tx + 6, ty + 4, C.text, f)
    end)
end

-- owner of a key held by another plugin (state.external.by_norm), or nil
function W.external_owner(st, name)
    local by = st.external and st.external.by_norm
    if not by or not name or next(by) == nil then return nil end
    return by[(name:gsub("[%s_%-%.]", ""):lower())]
end

-- Outfit defaults (bindings). The dropdown marks the default entry (W.default_suffix); next to it
-- W.default_button makes the selected config the default of the outfit worn (hidden when it is).
--   kind: "sculpt" | "expression" | "conditions"; cur: the config selected now (name / id);
--   bound: the config the binding names for this kind (nil = none)
-- Returns the width used.
function W.default_button(ctx, x, y, kind, cur, bound)
    local bi = ctx.st.presets and ctx.st.presets.bind
    if not bi or not cur or cur == "" then return 0 end
    local f = small()
    if bi.active and bound and cur == bound then return 0 end   -- the dropdown already says "· 默认"
    -- only the global default applies: the button says whose default it becomes
    local label = bi.global_default and ("设为 " .. bi.display .. " 的默认") or "设为默认"
    local clicked, bw = W.button(label, x, y, nil, 28, { font = f })
    if clicked then ctx.call("bind_config", { kind = kind, name = cur }) end
    W.tooltip("穿上 " .. bi.display .. " 时自动使用左边选中的配置", x, y, bw, 28)
    return bw
end

-- suffix for a dropdown entry: " · 默认" for the outfit's default, " · 全局默认" when only the
-- global default applies, "" otherwise. id: the entry's config name / id; bound: the bound one
function W.default_suffix(ctx, id, bound)
    local bi = ctx.st.presets and ctx.st.presets.bind
    if not bi or not bound or id ~= bound then return "" end
    if bi.active then return " · 默认" end
    if bi.global_default then return " · 全局默认" end
    return ""
end

-- ---------------------------------------------------------------- buttons
-- opt: kind = "primary" | "ghost" | "danger", disabled, pressed, font
function W.button(label, x, y, w, h, opt)
    opt = opt or {}
    local f = opt.font or body()
    if not w then w = D.measure(f, label) + 22 end
    h = h or T.m.row_h
    local hover = not opt.disabled and I.hit(x, y, w, h) and not I.active
    local bg, border, fg = C.panel3, C.line, C.text
    if opt.kind == "primary" then bg, border, fg = C.brass_dim, C.brass, 0xFFFFF6E2
    elseif opt.kind == "ghost" then bg = 0x00000000
    elseif opt.kind == "danger" then bg, border, fg = 0x00000000, C.warn, C.warn end
    if opt.pressed then border, fg = C.brass, C.brass end
    if hover then border = (opt.kind == "danger") and C.warn or C.muted end
    if opt.disabled then fg = C.faint end
    if bg ~= 0 then D.rrect(x, y, w, h, 3, bg) end
    D.outline(x, y, w, h, 3, 1, border)
    D.text_center(label, x, y, w, h, fg, f)
    local clicked = not opt.disabled and I.click(x, y, w, h)
    return clicked, w
end

-- square button with a drawn ✕
function W.close_button(x, y, s)
    local hover = I.hit(x, y, s, s) and not I.active
    D.outline(x, y, s, s, 3, 1, hover and C.muted or C.line)
    D.icon_x(x + s / 2, y + s / 2, s * 0.22, hover and C.text or C.muted)
    return I.click(x, y, s, s)
end

-- small text button (row actions)
function W.tbutton(label, x, y, opt)
    opt = opt or {}
    opt.font = small()
    opt.kind = opt.kind or "ghost"
    return W.button(label, x, y, nil, 22, opt)
end

-- switch + label. Returns changed, value, width
function W.toggle(label, x, y, value, opt)
    opt = opt or {}
    local f = opt.font or body()
    local lw = label and label ~= "" and (D.measure(f, label) + 8) or 0
    local h = opt.h or T.m.row_h
    local w = 30 + lw
    local sy = y + (h - 16) / 2
    local disabled = opt.disabled
    D.rrect(x, sy, 30, 16, 8, value and C.brass_dim or C.panel3)
    D.outline(x, sy, 30, 16, 8, 1, value and C.brass or C.line)
    D.fill_circle(value and (x + 22) or (x + 8), sy + 8, 6, value and C.brass or C.muted)
    if lw > 0 then D.text_mid(label, x + 38, y, h, (value and not disabled) and C.text or C.muted, f) end
    if not disabled and I.click(x, y, w, h) then return true, not value, w end
    return false, value, w
end

-- ---------------------------------------------------------------- slider
-- opt: step, disabled, fmt (string.format pattern for the value text drawn right), value_w
-- Returns changed, value
function W.slider(id, x, y, w, h, value, lo, hi, opt)
    opt = opt or {}
    h = h or T.m.row_h
    local vw = opt.fmt and (opt.value_w or 44) or 0
    local tw = w - vw - (vw > 0 and 8 or 0)
    local ty = y + h / 2 - 2
    local range = max(1e-6, hi - lo)
    value = value or lo
    local changed = false
    if not opt.disabled then
        if I.active == nil and I.click(x - 6, y, tw + 12, h) then I.active = id end
        if I.active == id then
            if I.down then
                local r = max(0, min(1, (I.mx - x) / tw))
                local v = lo + r * range
                if opt.step and opt.step > 0 then v = floor(v / opt.step + 0.5) * opt.step end
                v = max(lo, min(hi, v))
                if abs(v - value) > 1e-9 then value, changed = v, true end
            else
                I.active = nil
            end
        end
    end
    local r = max(0, min(1, (value - lo) / range))
    local hover = not opt.disabled and (I.active == id or (I.active == nil and I.hit(x - 6, y, tw + 12, h)))
    D.rrect(x, ty, tw, 4, 2, C.panel3)
    if r > 0 then D.rrect(x, ty, tw * r, 4, 2, opt.disabled and C.faint or C.brass_dim) end
    local kx = x + tw * r
    D.rrect(kx - 6, ty - 5, 12, 14, 3, opt.disabled and C.faint or (hover and 0xFFF0C070 or C.brass))
    if vw > 0 then
        D.text_mid(string.format(opt.fmt, value), x + tw + 8, y, h, opt.disabled and C.faint or C.text, mono())
    end
    return changed, value
end

-- ---------------------------------------------------------------- dropdown
-- labels: list of strings. Returns changed, index
function W.select(id, x, y, w, h, labels, index, opt)
    opt = opt or {}
    h = h or T.m.row_h
    local open = W.open_select == id
    local hover = I.hit(x, y, w, h)
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, (open or hover) and C.muted or C.line)
    D.text_mid(labels[index] or opt.placeholder or "-", x + 8, y, h, C.text, body(), w - 28)
    D.icon_tri(x + w - 13, y + h / 2, 4, true, C.muted)
    -- a choice made in the popup arrives one draw later (the popup draws deferred); it must be
    -- picked up even though the popup has closed by then
    W.pending = W.pending or {}
    local p = W.pending[id]
    W.pending[id] = nil
    if I.click(x, y, w, h) then
        -- (not `open and nil or id`: that is always id)
        if open then W.open_select = nil else W.open_select = id end
        open = not open
    end
    if not open then
        if p and p ~= index then return true, p end
        return false, index
    end
    local ih = 24
    local n = #labels
    local sw, sh = D.surface_size()
    local ph = min(n * ih, 360)
    local py = y + h + 2
    if py + ph > sh - 10 then py = y - ph - 2 end
    local first = 1
    local visible = floor(ph / ih)
    if index and index > visible then first = index - visible + 1 end
    I.add_overlay(x, py, w, ph)
    local result
    D.defer(function()
        I.in_overlay = true
        D.rrect(x, py, w, ph, 3, C.panel2)
        D.outline(x, py, w, ph, 3, 1, C.muted)
        for k = 0, visible - 1 do
            local i = first + k
            if i > n then break end
            local iy = py + k * ih
            local hov = I.inside(x, iy, w, ih)
            if hov or i == index then D.rect(x + 1, iy, w - 2, ih, hov and C.panel3 or C.ink) end
            D.text_mid(labels[i], x + 8, iy, ih, i == index and C.brass or C.text, body(), w - 16)
            if I.clicked and hov then result = i; I.consume() end
        end
        I.in_overlay = false
    end)
    -- the popup is drawn at the end of the frame: its click is applied there, and returned on the
    -- next call through W.pending
    D.defer(function()
        if result then
            W.pending[id] = result
            W.open_select = nil
        elseif I.clicked and not I.inside(x, py, w, ph) and not I.inside(x, y, w, h) then
            W.open_select = nil
        end
    end)
    if p and p ~= index then return true, p end
    return false, index
end

-- ---------------------------------------------------------------- collapsible group header
function W.header(label, x, y, w, open, stat)
    local h = 26
    local f = body()
    D.icon_tri(x + 7, y + h / 2, 4, open, C.brass)
    local lw = D.text_mid(label, x + 18, y, h, C.text, f)
    local sx = x + 26 + lw
    if stat then sx = sx + D.text_mid(stat, sx, y, h, C.muted, small()) + 10 end
    D.rect(sx, y + h / 2, max(0, x + w - sx), 1, C.line)
    return I.click(x, y, w, h), h
end

-- ---------------------------------------------------------------- text box (opens a prompt)
function W.text_box(x, y, w, h, value, placeholder)
    h = h or T.m.row_h
    local hover = I.hit(x, y, w, h)
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, hover and C.muted or C.line)
    if value and value ~= "" then D.text_mid(value, x + 8, y, h, C.text, body(), w - 16)
    else D.text_mid(placeholder or "", x + 8, y, h, C.faint, body(), w - 16) end
    return I.click(x, y, w, h)
end

-- ---------------------------------------------------------------- scroll area
-- local y0 = W.begin_scroll(id, x, y, w, h) ... W.end_scroll(content_h)
-- Content is drawn starting at y0 (= y - offset); everything is clipped to the area.
function W.begin_scroll(id, x, y, w, h)
    local off = scroll[id] or 0
    scroll_stack[#scroll_stack + 1] = { id = id, x = x, y = y, w = w, h = h }
    D.push_clip(x, y, w, h)
    return y - off
end

function W.end_scroll(content_h)
    local s = table.remove(scroll_stack)
    D.pop_clip()
    local maxoff = max(0, content_h - s.h)
    local off = min(scroll[s.id] or 0, maxoff)
    if I.wheel ~= 0 and I.inside(s.x, s.y, s.w, s.h) and not I.over_overlay() then
        off = max(0, min(maxoff, off - I.wheel * 60))
        I.wheel = 0
    end
    -- scrollbar (drag the thumb)
    if maxoff > 0 then
        local bx, bw = s.x + s.w - 6, 4
        local th = max(24, s.h * s.h / content_h)
        local ty = s.y + (s.h - th) * (off / maxoff)
        local key = "sb:" .. s.id
        if I.active == nil and I.click(bx - 4, s.y, bw + 8, s.h) then I.active = key end
        if I.active == key and I.down then
            off = max(0, min(maxoff, (I.my - s.y - th / 2) / (s.h - th) * maxoff))
            ty = s.y + (s.h - th) * (off / maxoff)
        end
        D.rrect(bx, ty, bw, th, 2, I.active == key and C.muted or C.faint)
    end
    scroll[s.id] = off
end

function W.reset_scroll(id) scroll[id] = 0 end

return W
