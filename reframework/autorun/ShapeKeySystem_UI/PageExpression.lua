-- 表情详情：共用两种绘制后端，按部位显示实时权重；映射草稿由 MappingEditor 编辑和提交。

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local Eyes = require("ShapeKeySystem_UI.PageEyes")   -- gaze settings, drawn as a section here
local Mapping = require("ShapeKeySystem_UI.MappingEditor")
local I = require("ShapeKeySystem_UI.Input")

local Page = {}
local C = T.c
local max, min = math.max, math.min

local function visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

local function top_bars(ctx, x, y, w)
    local st, call, s = ctx.st, ctx.call, ctx.state
    local ex = st.expression
    local cy = y
    local bar_h = w < 800 and 78 or 44
    W.panel_box(x, cy, w, bar_h)
    local plist, labels, cur = st.presets.expression or {}, {}, nil
    for i, p in ipairs(plist) do
        labels[i] = string.format("%s（%s）", p.name, p.source)
            .. W.default_suffix(ctx, p.id, st.presets.binding and st.presets.binding.profile_id)
        if ex.profile and p.id == ex.profile.id then cur = i end
    end
    D.text_mid("表情配置", x + 10, cy + 8, 28, C.muted, W.small())
    local sw = min(280, w * 0.4)
    -- choosing shows that profile below at once (read-only, preview_profile); 应用 switches the
    -- face to it. Browsing the list never changes the face.
    local pick = s.pick_profile
    if pick and (not plist[pick] or pick == cur) then pick = nil; s.pick_profile = nil; call("preview_profile", {}) end
    local ch, idx = W.select("expr_profile", x + 70, cy + 8, sw, 28, labels, pick or cur)
    if ch then
        s.pick_profile = (idx ~= cur) and idx or nil; pick = s.pick_profile
        call("preview_profile", { id = pick and plist[pick].id or nil })
    end
    local bx = x + 80 + sw
    if pick then
        local _, aw = W.button("应用", bx, cy + 8, nil, 28, { kind = "primary" })
        if _ and call("set_profile", { id = plist[pick].id }) then s.pick_profile = nil; call("preview_profile", {}) end
        local c2, cw2 = W.button("取消", bx + aw + 6, cy + 8, nil, 28, { kind = "ghost" })
        if c2 then s.pick_profile = nil; call("preview_profile", {}) end
        bx = bx + aw + cw2 + 18
    end
    local bnd = st.presets.binding
    local by = cy + 8
    if w < 800 then bx, by = x + 10, cy + 42 end
    if not pick then
        local dw = W.default_button(ctx, bx, by, "expression", ex.profile and ex.profile.id, bnd and bnd.profile_id)
        if dw > 0 then bx = bx + dw + 16 end
    end
    local created, create_w = W.button("新建", bx, by, nil, 28)
    if created then
        if s.mapping_draft or st.mapping.dirty then
            ctx.toast("warn", "请先保存或恢复映射，并应用或取消当前草稿，再新建配置")
        else
            W.start_text(s, "profile_form", { title = "新建表情配置", confirm_text_color = 0xFFFFFFFF, on_submit = function(name)
                if call("create_profile", { name = name }) then
                    s.pick_profile, s.mapping_draft, s.name_form, s.confirm_restore = nil, nil, nil, nil
                    s.filter, s.only_active, s.collapsed = "", false, {}
                    call("preview_profile", {})
                    W.reset_scroll("page:expr")
                end
            end })
        end
    end
    bx = bx + create_w + 6
    local tu = ex.tuning
    -- gains / gaze follow the outfit: with a binding they are saved into it, otherwise they are
    -- the global settings (saved automatically)
    if tu and tu.source == "binding" then
        local c3, b3 = W.button("保存到当前套装", bx, by, nil, 28, { kind = tu.dirty and "primary" or nil, disabled = not tu.dirty })
        if c3 then call("save_tuning") end
        W.tooltip("把强度、增益和视线设置保存到当前绑定", bx, by, b3, 28)
        bx = bx + b3 + 10
    end
    cy = cy + bar_h + 6
    cy = cy + W.text_form(s, "profile_form", "expression_profile_name", x, cy, w)
    local pv = pick and ex.preview and ex.preview.id == plist[pick].id and ex.preview or nil
    s.browsing = pv
    if s.mapping_draft and not pv then return cy - y end
    if pv then
        W.panel_box(x, cy, w, 34, true)
        D.text_mid(string.format("正在浏览：%s（未应用）· 当前装备的网格匹配 %d / %d 个通道", pv.name, pv.present, pv.total),
            x + 12, cy + 3, 28, C.brass, W.small(), w - 24)
        cy = cy + 42
    end
    -- one info line: coverage, gains tuned for another profile
    if not pv then
    local info = {}
    local cov = ex.coverage
    if cov then info[#info + 1] = string.format("ARKit 覆盖 %d/%d · 扩展 %d", cov.arkit_hit or 0, cov.arkit_total or 0, cov.extra or 0) end
    if tu and tu.profile_mismatch then info[#info + 1] = "单通道增益属于 " .. tostring(tu.for_profile) .. "，切回它时生效" end
    if tu and tu.source == "binding" and tu.dirty then info[#info + 1] = "调整未保存" end
    if #info > 0 then
        D.text(table.concat(info, " · "), x + 2, cy, (tu and (tu.profile_mismatch or tu.dirty)) and C.warn or C.muted, W.small(), w)
        cy = cy + 22
    end
    end

    W.panel_box(x, cy, w, 44)
    local fw = min(180, w * 0.25)
    W.text_box("expression_filter", x + 10, cy + 8, fw, 28, s.filter, "筛选通道…", function(t) s.filter = t end)
    local c1, v1, w1 = W.toggle(pv and "只看网格里有的" or "只看活跃", x + 22 + fw, cy + 8, s.only_active == true)
    if c1 then s.only_active = v1 end
    local sx = x + 40 + fw + w1
    local groups_now = (pv or ex).groups or {}
    if not pv then
        D.text_mid("平滑", sx, cy + 8, 28, C.muted, W.small())
        local c2, v2 = W.slider("smooth", sx + 36, cy + 8, min(200, x + w - sx - 200), 28, ex.smoothing or 0, 0, 1,
            { step = 0.01, fmt = "%.2f" })
        if c2 then call("set_smoothing", { value = v2 }) end
    end
    if W.button("全部收起", x + w - 92, cy + 8, 82, 28, { kind = "ghost", font = W.small() }) then
        for _, g in ipairs(groups_now) do s.collapsed[g.key] = true end
    end
    if W.button("全部展开", x + w - 180, cy + 8, 82, 28, { kind = "ghost", font = W.small() }) then s.collapsed = {} end
    cy = cy + 52
    if pv then return cy - y end

    -- region strengths, two per row
    W.panel_box(x, cy, w, 12 + math.ceil(#(ex.regions or {}) / 2) * 34)
    local cw = (w - 30) / 2
    for i, r in ipairs(ex.regions or {}) do
        local rx = x + 10 + ((i - 1) % 2) * (cw + 10)
        local ry = cy + 8 + math.floor((i - 1) / 2) * 34
        D.text_mid(r.name .. " 强度", rx, ry, 28, C.text, W.small(), 80)
        local c3, v3 = W.slider("region:" .. r.key, rx + 84, ry, cw - 84, 28, r.gain, 0, 2, { step = 0.01, fmt = "%.2f" })
        if c3 then call("set_region_gain", { region = r.key, value = v3 }) end
    end
    cy = cy + 20 + math.ceil(#(ex.regions or {}) / 2) * 34
    return cy - y
end

local function channel_row(ctx, c, x, y, w)
    local h = 40
    if not visible(y, h) then return h end
    local live, call = ctx.live, ctx.call
    local v = live.weight[c.slot] or 0
    local nw = max(170, w * 0.3)
    local fg = c.present and C.text or C.faint
    local nx = x + 8 + D.text(c.name, x + 8, y + 3, fg, W.body(), nw - 60)
    D.icon_tri(x + 3, y + 12, 3, ctx.state.mapping_draft and ctx.state.mapping_draft.original_name == c.canonical, C.brass)
    if I.click(x, y, nw, h) then
        if ctx.state.mapping_draft and ctx.state.mapping_draft.original_name == c.canonical then ctx.state.mapping_draft = nil
        else Mapping.open(ctx, c.canonical) end
    end
    if c.guessed then W.chip("推测", nx + 6, y + 4, C.warn, 16) end
    D.text((c.source_text or "") .. (c.present and "" or "  · 网格里没有"), x + 8, y + 22, C.faint, W.small(), nw - 12)
    W.tooltip((c.source_text or "") .. (c.note and ("\n" .. c.note) or ""), x, y, nw, h)
    local mx = x + nw
    local mw = max(60, (w - nw) * 0.36)
    W.meter(mx, y + 15, mw, 9, v, c.forced and C.brass or (c.has_signal and C.signal or C.faint))
    D.text(string.format("%.2f", v), mx + mw + 6, y + 12, C.text, W.mono())
    local gx = mx + mw + 50
    local gw = x + w - 70 - gx
    local ext = W.external_owner(ctx.st, c.canonical) or W.external_owner(ctx.st, c.name)
    if ext then
        W.chip("由 " .. ext .. " 控制", gx, y + 11, C.brass)
        if W.tbutton("收回", x + w - 52, y + 9) then call("external_release", { owner = ext, name = c.canonical }) end
        return h
    end
    local ch, g = W.slider("gain:" .. c.canonical, gx, y + 6, gw, 28, c.gain or 1, 0, 3, { step = 0.05, fmt = "×%.2f", value_w = 46 })
    if ch then call("set_channel_gain", { name = c.canonical, value = g }) end
    if W.tbutton("测试", x + w - 52, y + 9, { pressed = c.forced }) then call("force_channel", { name = c.canonical, on = not c.forced }) end
    return h
end

-- a channel of a profile being browsed: what it is and whether the worn mesh has it
local function preview_row(ctx, c, x, y, w)
    local h = 40
    if not visible(y, h) then return h end
    local nw = max(170, w * 0.3)
    local fg = c.present and C.text or C.faint
    local nx = x + 8 + D.text(c.name, x + 8, y + 3, fg, W.body(), nw - 60)
    if c.guessed then W.chip("推测", nx + 6, y + 4, C.warn, 16) end
    if c.extension then W.chip("扩展", nx + 6 + (c.guessed and 44 or 0), y + 4, C.faint, 16) end
    D.text(c.present and ("网格：" .. c.name) or "网格里没有", x + 8, y + 22, C.faint, W.small(), nw - 12)
    D.text(c.source_text or "", x + nw, y + 12, C.muted, W.small(), w - nw - 12)
    W.tooltip((c.source_text or "") .. (c.note and ("\n" .. c.note) or ""), x, y, w, h)
    return h
end

function Page.draw(ctx, x, y, w)
    local st, live, s = ctx.st, ctx.live, ctx.state
    s.collapsed = s.collapsed or {}
    local ex = st.expression
    local cy = y + top_bars(ctx, x, y, w) + 8
    cy = cy + Mapping.toolbar(ctx, x, cy, w)
    if s.mapping_draft and not s.browsing then
        return cy + Mapping.draw_draft(ctx, x, cy, w) - y
    end
    if not s.browsing then
        D.text("点击形态键名称展开映射配置", x + 2, cy, C.faint, W.small(), w)
        cy = cy + 24
    end
    local filter = (s.filter or ""):lower()
    local pv = s.browsing
    local src = pv or ex
    -- 以同一份通道/分组快照完成本次绘制，避免应用或删除映射时新旧 slot 混用。
    local channels, groups = src.channels, src.groups
    for _, g in ipairs(groups or {}) do
        local rows = {}
        for _, slot in ipairs(g.channel_slots) do
            local c = channels[slot]
            local keep = pv and (not s.only_active or c.present) or (not pv and (not s.only_active or (live.weight[slot] or 0) > 0.01))
            local editing = c and not pv and s.mapping_draft and s.mapping_draft.original_name == c.canonical
            if c and (editing or (keep and (filter == "" or c.name:lower():find(filter, 1, true) or c.canonical:lower():find(filter, 1, true)))) then
                rows[#rows + 1] = c
            end
        end
        if #rows > 0 then
            local draft = s.mapping_draft
            local entry = draft and draft.original_name and st.mapping.entries[draft.original_name]
            local editing_group = entry and entry.group == g.key
            local open = not s.collapsed[g.key] or filter ~= "" or editing_group
            local clicked, hh = W.header(g.name, x, cy, w, open, string.format("%d 个", #rows))
            if clicked then s.collapsed[g.key] = open end
            cy = cy + hh + 2
            if open then
                for _, c in ipairs(rows) do
                    cy = cy + (pv and preview_row or channel_row)(ctx, c, x, cy, w)
                end
            end
        end
    end
    if pv then return cy - y end
    -- gaze settings (was its own page): rarely changed, so closed until opened
    cy = cy + 10
    local gopen = s.gaze_open == true
    local clicked, hh = W.header("视线设置", x, cy, w, gopen)
    if clicked then s.gaze_open = not gopen end
    cy = cy + hh + 6
    if gopen then cy = cy + Eyes.draw(ctx, x, cy, w) end
    return cy - y
end

Page.want_signals = true

return Page
