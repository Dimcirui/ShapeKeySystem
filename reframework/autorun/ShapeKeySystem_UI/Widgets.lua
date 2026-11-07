-- ShapeKeySystem panel: immediate-mode widgets drawn with d2d. Each widget draws itself and
-- returns what the user did this draw. Ids only matter for widgets that keep state across draws
-- (slider drag, open dropdown, scroll offset).

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local TextInput = require("ShapeKeySystem_UI.TextInput")
local L = require("ShapeKeySystem_Core.I18n")
local select_offsets = {}

local W = {}
local C = T.c
local max, min, floor, abs = math.max, math.min, math.floor, math.abs
local select_grab = 0

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
--   kind: "sculpt" | "expression" | "conditions" | "drivers"; cur: the config selected now (name / id);
--   bound: the config the binding names for this kind (nil = none)
-- Returns the width used.
function W.default_button(ctx, x, y, kind, cur, bound)
    local bi = ctx.st.presets and ctx.st.presets.bind
    if not bi or not cur or cur == "" then return 0 end
    local f = small()
    if bi.active and bound and cur == bound then return 0 end   -- the dropdown already says "· 默认"
    -- only the global default applies: the button says whose default it becomes
    local label = bi.global_default and L.f("设为 %s 的默认", bi.display) or "设为默认"
    local clicked, bw = W.button(label, x, y, nil, 28, { font = f })
    if clicked then ctx.call("bind_config", { kind = kind, name = cur }) end
    W.tooltip(L.f("穿上 %s 时自动使用左边选中的配置", bi.display), x, y, bw, 28)
    return bw
end

-- suffix for a dropdown entry: " · 默认" for the outfit's default, " · 全局默认" when only the
-- global default applies, "" otherwise. id: the entry's config name / id; bound: the bound one
function W.default_suffix(ctx, id, bound)
    local bi = ctx.st.presets and ctx.st.presets.bind
    if not bi or not bound or id ~= bound then return "" end
    -- translated here: callers append the suffix to a config name
    if bi.active then return L.tr(" · 默认") end
    if bi.global_default then return L.tr(" · 全局默认") end
    return ""
end

-- ---------------------------------------------------------------- buttons
-- opt: kind = "primary" | "ghost" | "danger", disabled, pressed, font, text_color
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
    fg = opt.text_color or fg
    if bg ~= 0 then D.rrect(x, y, w, h, 3, bg) end
    D.outline(x, y, w, h, 3, 1, border)
    D.text_center(label, x, y, w, h, fg, f)
    local clicked = not opt.disabled and I.click(x, y, w, h)
    return clicked, w
end

-- tab row: tabs = { { key, label }, ... }, the shown key kept in state.tab. A key no longer in
-- the list (an advanced tab after 进阶 is turned off) falls back to the first tab; a single tab
-- draws no row. Returns the shown key and the height used.
function W.tabs(state, x, y, w, tabs)
    local cur = tabs[1] and tabs[1][1]
    for _, t in ipairs(tabs) do if t[1] == state.tab then cur = t[1] end end
    state.tab = cur
    if #tabs < 2 then return cur, 0 end
    local bx, by = x, y
    for _, t in ipairs(tabs) do
        local bw = D.measure(body(), t[2]) + 22
        if bx > x and bx + bw > x + w then bx, by = x, by + 36 end
        if W.button(t[2], bx, by, bw, 28, { kind = cur == t[1] and "primary" or nil }) then state.tab = t[1] end
        bx = bx + bw + 8
    end
    return cur, by - y + 40
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

-- 候选列表独立处理滚轮和滚动条拖动；命中受父级裁剪限制，滚轮不传给页面。
local function selection_scroll(id, x, y, w, h, content_h, offset, step)
    local limit = max(0, content_h - h)
    offset = max(0, min(offset or 0, limit))
    if I.wheel ~= 0 and I.hit(x, y, w, h) then
        offset = max(0, min(limit, offset - I.wheel * step))
        I.wheel = 0
    end
    if limit == 0 then return offset, 0 end
    local bx, bw = x + w - 10, 6
    local th = min(h, max(24, h * h / content_h))
    local travel = h - th
    local ty = y + travel * offset / limit
    local key = "select-sb:" .. id
    if I.active == nil and I.click(bx - 2, y, bw + 4, h) then
        select_grab = I.my >= ty and I.my < ty + th and (I.my - ty) or th / 2
        I.active = key
    end
    if I.active == key and I.down and travel > 0 then
        offset = max(0, min(limit, (I.my - y - select_grab) / travel * limit))
        ty = y + travel * offset / limit
    end
    D.rrect(bx, y, bw, h, 2, C.ink)
    D.rrect(bx, ty, bw, th, 2, I.active == key and C.muted or C.faint)
    return offset, 14
end

-- 下拉选择：完整候选列表通过滚轮及滚动条浏览；延迟绘制浮层，选择结果在下一次布局返回。
-- labels 为名称列表，返回 changed / index；页面仍使用同一套后端无关的控件。
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
        if open then W.open_select = nil else W.open_select = id; W.open_search = nil end
        open = not open
        if #labels == 0 then W.open_select, open = nil, false end
    end
    if not open then
        if p and p ~= index then return true, p end
        return false, index
    end
    local ih, hh = 24, 22
    -- opt.headers[i]: a gray heading above item i (not selectable)
    local rows, total, index_bottom = {}, 0, ih
    for i in ipairs(labels) do
        local head = opt.headers and opt.headers[i]
        if head then rows[#rows + 1] = { y = total, head = head }; total = total + hh end
        rows[#rows + 1] = { y = total, i = i }
        total = total + ih
        if i == index then index_bottom = total end
    end
    local sw, sh = D.surface_size()
    local ph = min(total, 360, max(ih, sh - 66))
    local py = y + h + 2
    if py + ph > sh - 10 then py = y - ph - 2 end
    py = max(10, min(py, sh - ph - 10))
    local offset = select_offsets[id] or max(0, index_bottom - ph)
    I.add_overlay(x, py, w, ph)
    local result
    D.defer(function()
        I.in_overlay = true
        D.rrect(x, py, w, ph, 3, C.panel2)
        D.outline(x, py, w, ph, 3, 1, C.muted)
        local gutter
        offset, gutter = selection_scroll(id, x, py, w, ph, total, offset, ih * 3)
        select_offsets[id] = offset
        D.push_clip(x + 1, py, w - gutter - 2, ph)
        for _, row in ipairs(rows) do
            local iy = py + row.y - offset
            if row.head then
                if iy + hh > py and iy < py + ph then
                    D.text_mid(row.head, x + 8, iy + 2, hh, C.faint, small(), w - gutter - 16)
                end
            elseif iy + ih > py and iy < py + ph then
                local i = row.i
                local hov = I.active == nil and I.hit(x, iy, w - gutter, ih)
                if hov or i == index then D.rect(x + 1, iy, w - gutter - 2, ih, hov and C.panel3 or C.ink) end
                D.text_mid(labels[i], x + 8, iy, ih, i == index and C.brass or C.text, body(), w - gutter - 16)
                if I.active == nil and I.click(x, iy, w - gutter, ih) then result = i end
            end
        end
        D.pop_clip()
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

-- 原位置输入框：自绘边框与占位文字，标准 ImGui InputText 负责文字、选择、剪贴板和 IME。
-- shown：输入框为空且未激活时代替占位符显示的正常文字（搜索框收起时显示已选值）。
function W.text_box(id, x, y, w, h, value, placeholder, on_change, shown)
    h = h or T.m.row_h
    local hover = I.hit(x, y, w, h)
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, hover and C.muted or C.line)
    local registered = TextInput.register(id, x, y, w, h, value, on_change)
    if not registered and value and value ~= "" then D.text_mid(value, x + 8, y, h, C.text, body(), w - 16)
    elseif (not value or value == "") and TextInput.active ~= id then
        if shown and shown ~= "" then D.text_mid(shown, x + 8, y, h, C.text, body(), w - 16)
        else D.text_mid(placeholder or "", x + 8, y, h, C.faint, body(), w - 16) end
    end
    -- 只消费自绘控件的点击队列；ImGui 收到鼠标时自己激活，收不到时由这次点击代为激活。
    if I.click(x, y, w, h) and registered and I.device_click then TextInput.focus(id) end
end

-- 可搜索选择框：页面持有搜索状态，布局线程只登记原位 InputText；候选项内联展开。
-- 输入只过滤候选，选择才提交；on_query 可用于允许自由命名的形态键，信号绑定不使用它。
-- 不处理 Enter/Esc，避免拦截输入法选字；完整候选在限高区域内滚动，搜索变化时回到顶部。
function W.search_select(state, id, x, y, w, items, value, opt)
    opt = opt or {}
    state[id] = state[id] or { query = "", offset = 0 }
    local s = state[id]
    local open = W.open_search == id
    local field_w = w - 30
    if I.click(x, y, field_w, 28) then
        if not open then s.query, s.offset = "", 0 end
        W.open_search, open = id, true
    end
    if W.button("", x + field_w + 2, y, 28, 28, { font = small() }) then
        if open then W.open_search, open = nil, false
        else W.open_search, open, s.query, s.offset = id, true, "", 0 end
    end
    D.icon_tri(x + w - 14, y + 14, 4, open, C.muted)
    -- 收起时 ImGui 缓冲区登记为空、已选值只做自绘显示：d2d 布局晚于 ImGui 一帧，
    -- 点开那一下 ImGui 用的是上一次登记的文字，登记已选值会让搜索从旧值开始追加。
    W.text_box(id, x, y, field_w, 28, open and s.query or "",
        opt.placeholder or "输入文字搜索…", function(text)
            -- after a pick ImGui still holds the typed text for a frame and reports it; a closed
            -- list ignores it, or the typed text would reopen the list and replace the pick
            if W.open_search ~= id then return end
            s.query, s.offset = text, 0
            if opt.on_query then opt.on_query(text) end
        end, (not open) and value or nil)
    if not open then return false, nil, 34 end
    local matches, query = {}, s.query:lower()
    -- 前缀匹配优先，其他匹配维持原有顺序；plain=true，不把玩家输入当作 Lua 模式。
    local other = {}
    for _, item in ipairs(items) do
        local hay = (item.search or item.label):lower()
        local at = query == "" and 1 or hay:find(query, 1, true)
        if at then
            local list = at == 1 and matches or other
            list[#list + 1] = item
        end
    end
    for _, item in ipairs(other) do matches[#matches + 1] = item end
    local cy = y + 34
    local chosen
    local content_h = max(1, #matches) * 32
    local list_h = min(content_h, opt.max_height or 256)
    W.panel_box(x, cy, w, list_h + 8)
    cy = cy + 4
    local gutter
    s.offset, gutter = selection_scroll(id, x + 4, cy, w - 8, list_h, content_h, s.offset, 64)
    D.push_clip(x + 4, cy, w - 8 - gutter, list_h)
    for i, item in ipairs(matches) do
        local iy = cy + (i - 1) * 32 - s.offset
        if iy + 28 > cy and iy < cy + list_h then
            if W.button(item.label, x + 4, iy, w - 8 - gutter, 28,
                { kind = "ghost", font = small(), pressed = item.value == opt.selected }) then chosen = item.value end
            W.tooltip(item.label, x + 4, iy, w - 8 - gutter, 28)
        end
    end
    if #matches == 0 then
        D.text_mid(opt.empty or "没有匹配的候选项", x + 8, cy, 28, C.faint, small(), w - 16)
    end
    D.pop_clip()
    cy = cy + list_h
    if chosen ~= nil then
        W.open_search = nil
        TextInput.remove(id) -- 选择后释放旧搜索框，下一布局显示已选值，不残留搜索焦点。
        return true, chosen, cy - y + 8
    end
    if I.clicked and not I.inside(x, y, w, cy - y + 8) then W.open_search = nil end
    return false, nil, cy - y + 8
end

-- Search items for the scanned shape keys (state.sculpt.keys): label "label（name）" when a key has
-- a display label. cache holds the list until the sculpt state revision changes.
function W.shape_key_items(sculpt, cache)
    if cache.keys_rev == sculpt.rev and cache.keys then return cache.keys end
    local items, seen = {}, {}
    for _, k in ipairs(sculpt.keys or {}) do
        if not seen[k.name] then
            seen[k.name] = true
            local label = (k.label and k.label ~= k.name) and L.f("%s（%s）", L.tr(k.label), k.name) or k.name
            items[#items + 1] = { value = k.name, label = label, search = label .. " " .. k.name }
        end
    end
    table.sort(items, function(a, b) return a.value < b.value end)
    cache.keys, cache.keys_rev = items, sculpt.rev
    return items
end

-- 命名表单由所属页面保存草稿；布局在操作栏下展开，不建立弹窗或全屏输入遮罩。
function W.start_text(state, key, req)
    req.text = req.text or ""
    state[key] = req
end
function W.text_form(state, key, id, x, y, w)
    local r = state[key]
    if not r then return 0 end
    local h = r.extra and 102 or 70
    W.panel_box(x, y, w, h)
    D.text_mid(r.title or "名称", x + 10, y + 4, 24, C.muted, small(), w - 20)
    W.text_box(id, x + 10, y + 32, w - 190, 28, r.text, "点击输入名称…", function(t) r.text = t end)
    local yes = W.button("确定", x + w - 164, y + 32, 70, 28, { kind = "primary", text_color = r.confirm_text_color, disabled = r.text == "" })
    local no = W.button("取消", x + w - 82, y + 32, 70, 28)
    if r.extra then
        local changed, v = W.toggle(r.extra.label, x + 10, y + 68, r.extra.value == true)
        if changed then r.extra.value = v end
    end
    if yes or no then state[key] = nil; TextInput.remove(id) end
    if yes and r.on_submit then r.on_submit(r.text, r.extra and r.extra.value) end
    return h + 8
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
