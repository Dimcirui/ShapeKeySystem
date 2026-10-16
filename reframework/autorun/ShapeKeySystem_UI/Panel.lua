-- ShapeKeySystem panel (M3): standalone window drawn with reframework-d2d or REFramework's ImGui
-- draw list (Draw.lua). Talks to the backend only through SKS.state / SKS.live / SKS.call
-- (docs/plans/shape-key-system-api.md).
--   re.on_frame  -> Panel.frame() / draw_inputs()  hotkey, input sampling, inline ImGui fields
--   d2d draw / re.on_frame (imgui) -> Panel.draw()   layout + widgets (only while open)

local Perf = require("ShapeKeySystem_Core.Perf")
local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local TextInput = require("ShapeKeySystem_UI.TextInput")
local Blocker = require("ShapeKeySystem_UI.InputBlocker")

local Panel = { open = false }
local C, M = T.c, T.m
local max, min = math.max, math.min

local SKS
local PAGES = {
    { key = "basic",   name = "表情",     mod = "ShapeKeySystem_UI.PageBasic" },
    { key = "sculpt",  name = "捏脸",     mod = "ShapeKeySystem_UI.PageSculpt" },
    { key = "expr",    name = "表情详情", mod = "ShapeKeySystem_UI.PageExpression", adv = true },
    { key = "cond",    name = "条件规则", mod = "ShapeKeySystem_UI.PageConditions", adv = true },
    { key = "debug",   name = "设置与调试", mod = "ShapeKeySystem_UI.PageDebug",    adv = true },
}
local page_impl = {}
-- REFramework resolves autorun modules only while scripts load: require every page now, a lazy
-- require from the draw callback fails with "module not found"
local page_load_err = {}
for _, p in ipairs(PAGES) do
    local ok, m = pcall(require, p.mod)
    if ok then page_impl[p.key] = m else page_impl[p.key] = false; page_load_err[p.key] = tostring(m) end
end
local ui = { page = "basic", toasts = {}, page_state = {}, win = nil, drag = nil, want_signals = false }
Panel.ui = ui

-- ---------------------------------------------------------------- commands
local toast_seq = 0
local function toast(level, text)
    toast_seq = toast_seq + 1
    ui.toasts[#ui.toasts + 1] = { id = "t" .. toast_seq, level = level, text = text, until_t = os.clock() + 6 }
    if #ui.toasts > 4 then table.remove(ui.toasts, 1) end
end
Panel.toast = toast

-- SKS.call with failures shown as a toast
local function call(cmd, args)
    local ok, code, msg, res = SKS.call(cmd, args)
    if not ok then toast("error", string.format("%s：%s %s", cmd, tostring(code), tostring(msg or ""))) end
    return ok, res
end

local function goto_page(key)
    local previous = ui.page_state[ui.page]
    if previous then previous.name_form, previous.clip_form = nil, nil end
    ui.page = key
    W.open_select, W.open_search = nil, nil
    TextInput.clear()
end

local ctx = { call = call, toast = toast, goto_page = goto_page }

local function page_state(key)
    local s = ui.page_state[key]
    if not s then s = {}; ui.page_state[key] = s end
    return s
end

local function get_page(key)
    local impl = page_impl[key]
    if not impl and page_load_err[key] then
        toast("error", "页面加载失败：" .. page_load_err[key])
        page_load_err[key] = nil
    end
    return impl or nil
end

-- ---------------------------------------------------------------- window geometry
local function window()
    if not ui.win then
        local w = SKS.state.settings.window or {}
        ui.win = { x = w.x or 120, y = w.y or 120, w = w.w or 920, h = w.h or 640 }
    end
    return ui.win
end

local function clamp_window(win)
    local sw, sh = D.surface_size()
    win.w = max(M.min_w, min(win.w, sw - 20))
    win.h = max(M.min_h, min(win.h, sh - 20))
    win.x = max(0, min(win.x, sw - 80))
    win.y = max(0, min(win.y, sh - 40))
end

local function save_window()
    local win = ui.win
    call("set_setting", { key = "window", value = { x = math.floor(win.x), y = math.floor(win.y),
                                                     w = math.floor(win.w), h = math.floor(win.h) } })
end

-- ---------------------------------------------------------------- chrome
local function draw_titlebar(st, x, y, w)
    local h = M.title_h
    D.rect(x, y, w, h, C.panel2)
    D.rect(x, y, w, 2, C.brass_dim)
    D.rect(x, y + h - 1, w, 1, C.line)
    local bw = D.text_mid("SHAPEKEYSYSTEM", x + 14, y, h, C.brass, D.font(T.font.title, true))
    D.text_mid("形态键系统", x + 22 + bw, y + 1, h, C.muted, W.small())
    -- right side, right to left
    local rx = x + w - 12 - 26
    if W.close_button(rx, y + 7, 26) then Panel.set_open(false) end
    local rt = st.runtime
    local tw = D.measure(W.body(), "启用") + 38
    rx = rx - 16 - tw
    local ch, v = W.toggle("启用", rx, y + 6, rt.enabled)
    if ch then call("set_enabled", { on = v }) end
    tw = D.measure(W.body(), "进阶") + 38
    rx = rx - 16 - tw
    ch, v = W.toggle("进阶", rx, y + 6, rt.advanced == true)
    if ch then
        call("set_setting", { key = "advanced", value = v })
        if not v then
            for _, p in ipairs(PAGES) do if p.key == ui.page and p.adv then goto_page("basic") end end
        end
    end
    tw = D.measure(W.body(), "翻译形态键") + 38
    rx = rx - 16 - tw
    ch, v = W.toggle("翻译形态键", rx, y + 6, st.settings.translate_keys == true)
    if ch then call("set_setting", { key = "translate_keys", value = v }) end
    W.tooltip("形态键显示中文译名，悬停可看原名；只影响显示", rx, y + 6, tw, 28)
    return rx - 10   -- right end of the drag area
end

local function draw_rail(st, x, y, h)
    local w = M.rail_w
    D.rect(x, y, w, h, C.panel)
    D.rect(x + w - 1, y, 1, h, C.line)
    local cy = y + 10
    local adv = st.runtime.advanced == true
    local section
    for _, p in ipairs(PAGES) do
        if not p.adv or adv then
            local sec = p.adv and "进阶" or "基础"
            if sec ~= section then
                section = sec
                D.text(sec, x + 14, cy + 6, C.faint, W.small())
                cy = cy + 26
            end
            local cur = ui.page == p.key
            local ih = 32
            local hover = I.hit(x, cy, w - 1, ih)
            if cur or hover then D.rect(x, cy, w - 1, ih, C.panel2) end
            if cur then D.rect(x, cy, 2, ih, C.brass) end
            D.text_mid(p.name, x + 14, cy, ih, (cur or hover) and C.text or C.muted, W.body())
            if p.key == "sculpt" and st.sculpt.dirty then D.fill_circle(x + w - 16, cy + ih / 2, 3, C.warn) end
            if I.click(x, cy, w - 1, ih) then goto_page(p.key) end
            cy = cy + ih + 2
        end
    end
end

local function draw_statusbar(st, x, y, w)
    local h = M.status_h
    D.rect(x, y, w, h, C.panel)
    D.rect(x, y, w, 1, C.line)
    local a = st.debug.perf or {}
    local text = string.format("%.2f ms/帧 · 写入 %.1f / 跳过 %.1f", a.total or 0, a.writes or 0, a.skipped or 0)
    local f = W.small()
    local used = D.text_mid(text, x + 12, y, h, C.muted, f, w * 0.6)
    D.text_mid(st.debug.status or "", x + 24 + used, y, h, C.faint, f, w - used - 40)
end

-- notices from the backend + local toasts, newest last. Returns the height used.
local function draw_notices(st, x, y, w)
    local items = {}
    local now_c = os.clock()
    for i = #ui.toasts, 1, -1 do
        if ui.toasts[i].until_t < now_c then table.remove(ui.toasts, i) end
    end
    for _, n in ipairs(st.runtime.notices or {}) do items[#items + 1] = { backend = true, n = n } end
    for _, t in ipairs(ui.toasts) do items[#items + 1] = { n = t } end
    local first = max(1, #items - 2)
    local cy = y
    for i = first, #items do
        local it = items[i]
        local n = it.n
        local col = n.level == "error" and C.error or (n.level == "warn" and C.warn or C.signal)
        D.rrect(x, cy, w, 26, 3, C.ink)
        D.outline(x, cy, w, 26, 3, 1, col)
        D.text_mid(n.text, x + 10, cy, 26, col, W.small(), w - 50)
        if W.close_button(x + w - 25, cy + 3, 20) then
            if it.backend then call("dismiss_notice", { id = n.id })
            else for k, t in ipairs(ui.toasts) do if t == n then table.remove(ui.toasts, k) break end end end
        end
        cy = cy + 30
    end
    return cy - y
end

local function draw_cursor()
    -- while AVM also blocks input its own UI DLL draws the cursor: do not draw a second one
    if not Blocker.enabled or Blocker.others_active() then return end
    local x, y = I.mx, I.my
    if x < 0 then return end
    D.quad(x, y, x, y + 17, x + 4.5, y + 13, x + 11, y + 12, C.ink)
    D.quad(x + 1.2, y + 2.5, x + 1.2, y + 14.5, x + 4.6, y + 11.6, x + 9, y + 11, C.text)
end

-- ---------------------------------------------------------------- frame / draw
function Panel.set_open(on)
    on = on == true
    if on == Panel.open then return end
    Panel.open = on
    I.reset()
    W.open_select, W.open_search = nil, nil
    if not on then
        TextInput.clear()
        for _, state in pairs(ui.page_state) do state.name_form, state.clip_form = nil, nil end
        if ui.win and ui.dirty_window then ui.dirty_window = false; save_window() end
    end
    pcall(Blocker.set_enabled, on and SKS.state.settings.block_input ~= false)
end

-- re.on_frame
local others_were = false
function Panel.frame()
    local st = SKS.state
    pcall(Blocker.frame)
    -- ArmorVariantManager opened its panel while ours is open: the newer one wins
    local others, who = Blocker.others_active()
    if Panel.open and others and not others_were then
        Panel.set_open(false)
        SKS.log("panel closed: %s opened its panel", tostring(who))
    end
    others_were = others
    -- nothing to draw with (no d2d, REFramework too old for the ImGui backend): stay closed
    if not D.available() then
        if Panel.open then Panel.set_open(false) end
        return
    end
    if I.key_pressed(st.settings.hotkey or "Delete") and not TextInput.active then
        Panel.set_open(not Panel.open)
        if Panel.open and others then toast("warn", "ArmorVariantManager 的面板也开着：点击会同时传给两个面板") end
    end
    if Panel.open then
        I.capture()
    end
end

-- 仅由 re.on_frame 调用；d2d 回调登记的输入位置供下一帧使用，ImGui 后端用当帧布局。
function Panel.draw_inputs()
    if not Panel.open then return end
    local ok, e = pcall(TextInput.draw)
    if not ok then TextInput.clear(); toast("error", "输入框：" .. tostring(e)) end
end

function Panel.ui_open() return Panel.open, Panel.open and ui.want_signals end

-- active backend's draw callback (d2d draw / re.on_frame for ImGui)
local function draw()
    TextInput.begin_layout()
    if not Panel.open then return end
    local st, live = SKS.state, SKS.live
    if not D.reset_frame(max(0.5, min(3, tonumber(st.settings.ui_scale) or 1))) then return end
    I.begin_frame()
    local win = window()
    clamp_window(win)
    local x, y, w, h = win.x, win.y, win.w, win.h

    -- window drag / resize (before widgets so a drag does not click through)
    if ui.drag then
        if I.down then
            local d = ui.drag
            if d.kind == "move" then win.x, win.y = I.mx - d.ox, I.my - d.oy
            else win.w, win.h = max(M.min_w, d.w0 + I.mx - d.mx0), max(M.min_h, d.h0 + I.my - d.my0) end
            clamp_window(win)
            x, y, w, h = win.x, win.y, win.w, win.h
        else
            ui.drag = nil
            I.active = nil
            save_window()
        end
    end

    D.rect(x + 4, y + 6, w, h, 0x55000000)        -- shadow
    D.rrect(x, y, w, h, M.radius, C.panel)
    D.outline(x, y, w, h, M.radius, 1, C.line)

    local drag_right = draw_titlebar(st, x, y, w)
    if not ui.drag and I.active == nil and I.clicked and I.hit(x, y, drag_right - x, M.title_h) then
        I.consume(); I.active = "window"
        ui.drag = { kind = "move", ox = I.mx - x, oy = I.my - y }
    end

    local body_y, body_h = y + M.title_h, h - M.title_h - M.status_h
    draw_rail(st, x, body_y, body_h)
    draw_statusbar(st, x, y + h - M.status_h, w)

    -- page
    local cx, cw = x + M.rail_w + M.pad, w - M.rail_w - 2 * M.pad
    local cy = body_y + 10
    cy = cy + draw_notices(st, cx, cy, cw)
    local ch = body_y + body_h - cy - 6
    ui.want_signals = false
    local impl = get_page(ui.page)
    if impl then
        local y0 = W.begin_scroll("page:" .. ui.page, cx - 4, cy, cw + 8, ch)
        ctx.SKS, ctx.st, ctx.live, ctx.state = SKS, st, live, page_state(ui.page)
        ctx.view_h = ch
        local ok, used = pcall(impl.draw, ctx, cx, y0 + 4, cw)
        if not ok then
            local e = tostring(used)
            used = 40
            D.text("页面出错：" .. e, cx, y0 + 4, C.error, W.small(), cw)
            if ctx.state.last_err ~= e then ctx.state.last_err = e; SKS.log("panel page error: %s", e) end
        end
        W.end_scroll((tonumber(used) or 0) + 12)
        if impl.want_signals then ui.want_signals = true end
    end

    -- resize grip
    local gx, gy = x + w - 16, y + h - 16
    D.line(gx + 4, gy + 14, gx + 14, gy + 4, 1, C.faint)
    D.line(gx + 9, gy + 14, gx + 14, gy + 9, 1, C.faint)
    if not ui.drag and I.active == nil and I.click(gx, gy, 16, 16) then
        I.active = "window"
        ui.drag = { kind = "size", w0 = w, h0 = h, mx0 = I.mx, my0 = I.my }
    end

    if W.open_select then TextInput.draw_static() end
    D.flush_deferred()
    if W.open_select or not Panel.open then TextInput.clear() end
    draw_cursor()
end

-- 绑定后端和只读尺寸缓存；输入 hook 不持有或访问 d2d 渲染器。
function Panel.attach(sks)
    SKS = sks
    Blocker.surface = D.surface_pixels
    Blocker.game = sks.adapter and sks.adapter.input
end

-- 绘制失败也记录耗时并向上层传递错误，两种后端共用同一计量入口。
function Panel.draw()
    if not Panel.open then return end
    local started = os.clock()
    local ok, err = pcall(draw)
    Perf.record("ui", os.clock() - started)
    if not ok then error(err, 0) end
end

return Panel
