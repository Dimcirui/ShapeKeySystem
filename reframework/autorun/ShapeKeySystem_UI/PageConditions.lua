-- ShapeKeySystem panel, advanced page "条件规则" (formerly 条件表情; rules can drive sculpt keys
-- too). Only the UI was renamed: the backend keeps "conditions" (cond_* commands, conditions/*.json,
-- binding field) so existing player files still load. Condition sets (pick / new / save / delete) on
-- top, then the tab 条件状态 (states in priority order with their rules) or 形态键配置组合
-- (expression clips: keys, fades, preview); the live value of every condition is shown on both.
-- Edits go through cond_edit with a full copy of the set.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

-- width of a small text button, for right-aligned row actions (labels differ by language)
local function tbw(label) return D.measure(W.small(), label) + 22 end

local Page = {}
local C = T.c
local max, min, floor = math.max, math.min, math.floor

local SOURCE = { user = "用户", mods = "mod 自带" }
-- each status has its own text, colour and marker shape, so neither colour nor text alone tells them apart
local STATUS = { active = { "生效", C.ok, "dot" }, outranked = { "被覆盖", C.error, "tri" },
    idle = { "未命中", C.faint, "ring" }, off = { "已停用", C.faint, "square" } }
local MARK_W = 14

-- status marker centred at (cx, cy): ● active, ▲ outranked, ○ idle, ■ off
local function status_mark(shape, cx, cy, color)
    if shape == "dot" then D.fill_circle(cx, cy, 4, color)
    elseif shape == "tri" then D.quad(cx, cy - 4.5, cx + 5, cy + 4, cx - 5, cy + 4, cx, cy - 4.5, color)
    elseif shape == "ring" then D.outline(cx - 4, cy - 4, 8, 8, 4, 1.5, color)
    else D.rect(cx - 3.5, cy - 3.5, 7, 7, color) end
end
local UNBOUND = "-"
local NUM_OPS = { "<=", "<", ">=", ">", "==" }
local ENUM_OPS = { "==", "~=" }

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

local function def_of(st, id)
    for _, d in ipairs(st.conditions.defs or {}) do if d.id == id then return d end end
end

-- 列出的条件：隐藏的旧条件仍能求值、已有规则照常显示，只是不能新选
local function listed(st)
    local out = {}
    for _, d in ipairs(st.conditions.defs or {}) do if not d.hidden then out[#out + 1] = d end end
    return out
end

local function visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

-- edit helper: f(data) mutates a copy, then it is sent as the new working copy
local function edit(ctx, f)
    local cur = ctx.st.conditions.current
    if not cur then return end
    local d = copy(cur.data)
    f(d)
    ctx.call("cond_edit", { data = d })
end

local function cond_text(st, c)
    local d = def_of(st, c.type)
    if not d then return L.f("未知条件 %s", tostring(c.type)) end
    -- labels of the game's condition defs are translated here: they are joined into one line
    local dl = L.tr(d.label)
    if d.kind == "bool" then return c.value == false and L.f("%s ＝ 否", dl) or dl end
    if d.kind == "enum" then
        local label = tostring(c.value)
        for _, o in ipairs(d.options or {}) do if o.value == c.value then label = L.tr(o.label) end end
        return string.format("%s %s %s", dl, c.op == "~=" and "≠" or "＝", label)
    end
    local s = string.format("%s %s %s", dl, c.op or "<=", tostring(c.value))
    if (tonumber(c.band) or 0) > 0 then s = s .. L.f("（回差 %s）", tostring(c.band)) end
    return s
end

local function live_text(st, live, id)
    local v = live.cond and live.cond.values[id]
    local d = def_of(st, id)
    if v == nil then return "—" end
    if type(v) == "boolean" then return L.tr(v and "是" or "否") end
    if d and d.kind == "enum" then
        for _, o in ipairs(d.options or {}) do if o.value == v then return L.tr(o.label) end end
    end
    if type(v) == "number" then return string.format("%.1f", v) end
    return tostring(v)
end

-- ---------------------------------------------------------------- top bar
local function top_bar(ctx, x, y, w)
    local st, call, s = ctx.st, ctx.call, ctx.state
    local cs = st.conditions
    local cur = cs.current
    W.panel_box(x, y, w, 44)
    local labels, ids, idx = { "（不使用）" }, { "" }, 1
    for _, e in ipairs(cs.sets or {}) do
        labels[#labels + 1] = L.f("%s（%s）", e.name, L.tr(SOURCE[e.source] or e.source)) .. W.default_suffix(ctx, e.id, cs.binding_name)
        ids[#ids + 1] = e.id
        if cur and cur.id == e.id then idx = #ids end
    end
    if cur and idx == 1 then labels[#labels + 1] = L.f("%s（未保存）", cur.name); ids[#ids + 1] = cur.id; idx = #ids end
    D.text_mid("配置", x + 10, y + 8, 28, C.muted, W.small())
    local sw = min(260, w * 0.36)
    local ch, i = W.select("cond_set", x + 46, y + 8, sw, 28, labels, idx)
    if ch then
        local ok = call("cond_select", { name = ids[i] })
        if not ok then ctx.toast("warn", "当前配置有未保存的修改：先保存或还原")
        else s.name_form, s.clip_form, s.closed = nil, nil, nil end
    end
    local bx = x + 56 + sw
    local dw = W.default_button(ctx, bx, y + 8, "conditions", (cur and not cur.dirty) and cur.id or nil, cs.binding_name)
    if dw > 0 then bx = bx + dw + 16 end
    local function btn(label, opt)
        local clicked, bw = W.button(label, bx, y + 8, nil, 28, opt)
        bx = bx + bw + 6
        return clicked
    end
    if btn("新建") then
        W.start_text(s, "name_form", { title = "新建条件规则配置", on_submit = function(name)
            if name ~= "" then call("cond_new", { name = name }) end
        end })
    end
    if cur then
        if btn("保存", { kind = cur.dirty and "primary" or nil, disabled = not cur.dirty and cur.source == "user" }) then
            if cur.source == "user" then call("cond_save", {})
            else W.start_text(s, "name_form", { title = "另存为（mod 自带的配置不能覆盖）", text = cur.name, on_submit = function(n)
                if n ~= "" then call("cond_save", { as_name = n }) end end }) end
        end
        if btn("另存为") then
            W.start_text(s, "name_form", { title = "另存为", text = cur.name, on_submit = function(n)
                if n ~= "" then call("cond_save", { as_name = n }) end end })
        end
        if cur.dirty and btn("还原", { kind = "ghost" }) then call("cond_revert") end
        if cur.source == "user" and not cur.dirty and btn("删除", { kind = "danger" }) then
            call("request_delete", { kind = "conditions", name = cur.id })
        end
        local auto = cur.data.auto ~= false
        local c2, v2 = W.toggle("自动", x + w - 90, y + 8, auto)
        if c2 then edit(ctx, function(d) d.auto = v2 end) end
        W.tooltip("关闭后规则暂停（拍照、试表情时用）", x + w - 90, y + 8, 80, 28)
    end
    -- pending delete confirmation
    local pd = st.presets.pending_delete
    local h = 52
    if pd and pd.kind == "conditions" then
        D.rrect(x, y + 52, w, 36, 3, C.ink); D.outline(x, y + 52, w, 36, 3, 1, C.warn)
        D.text_mid(L.f("删除条件规则配置「%s」？", pd.name), x + 10, y + 56, 28, C.warn, W.body(), w - 200)
        if W.button("删除", x + w - 160, y + 56, 70, 28, { kind = "danger" }) then call("confirm_delete") end
        if W.button("取消", x + w - 82, y + 56, 70, 28, { kind = "ghost" }) then call("cancel_delete") end
        h = 96
    end
    return h + W.text_form(s, "name_form", "conditions_name", x, y + h, w)
end

-- ---------------------------------------------------------------- add-condition form
local function condition_form(ctx, x, y, w, si, ri)
    local st, s = ctx.st, ctx.state
    local f = s.form
    local defs = listed(st)
    local labels, headers = {}, {}
    for i, d in ipairs(defs) do
        labels[i] = d.label
        if d.category and d.category ~= (defs[i - 1] and defs[i - 1].category) then headers[i] = d.category end
    end
    f.type_i = f.type_i or 1
    local d = defs[f.type_i]
    D.rrect(x, y, w, 40, 3, C.ink); D.outline(x, y, w, 40, 3, 1, C.line)
    local ch, i = W.select("cf_type", x + 6, y + 6, min(240, w * 0.38), 28, labels, f.type_i, { headers = headers })
    if ch then f.type_i, f.op, f.value, f.band = i, nil, nil, nil; d = defs[i] end
    local bx = x + 12 + min(240, w * 0.38)
    if d and d.kind == "bool" then
        local c2, v2, tw = W.toggle(f.value == false and "否" or "是", bx, y + 6, f.value ~= false)
        if c2 then f.value = v2 end
        bx = bx + tw + 10
    elseif d and d.kind == "enum" then
        local oi = (f.op == "~=") and 2 or 1
        local c3, i3 = W.select("cf_op", bx, y + 6, 56, 28, { "＝", "≠" }, oi)
        if c3 then f.op = ENUM_OPS[i3] end
        local ol, cur_i = {}, 1
        for k, o in ipairs(d.options or {}) do ol[k] = o.label; if o.value == f.value then cur_i = k end end
        if f.value == nil and d.options and d.options[1] then f.value = d.options[1].value end
        local c4, i4 = W.select("cf_val", bx + 62, y + 6, min(170, w - bx + x - 150), 28, ol, cur_i)
        if c4 then f.value = d.options[i4].value end
        bx = bx + 62 + min(170, w - bx + x - 150) + 8
    elseif d then
        local oi = 1
        for k, o in ipairs(NUM_OPS) do if o == f.op then oi = k end end
        local c3, i3 = W.select("cf_op", bx, y + 6, 56, 28, NUM_OPS, oi)
        if c3 then f.op = NUM_OPS[i3] end
        f.value = f.value or floor(((d.min or 0) + (d.max or 100)) / 2)
        local sw = max(80, min(200, w - (bx - x) - 230))
        local c4, v4 = W.slider("cf_num", bx + 62, y + 6, sw, 28, f.value, d.min or 0, d.max or 100,
            { step = (d.max or 100) > 10 and 1 or 0.1, fmt = "%.1f" })
        if c4 then f.value = v4 end
        bx = bx + 62 + sw + 8
        local c5, v5 = W.slider("cf_band", bx, y + 6, 70, 28, f.band or 0, 0, (d.max or 100) / 10,
            { step = (d.max or 100) > 10 and 1 or 0.1, fmt = "±%.0f", value_w = 34 })
        if c5 then f.band = v5 end
        W.tooltip("回差：命中后要越过阈值这么多才算结束，避免数值卡在阈值附近时来回闪", bx, y + 6, 110, 28)
        bx = bx + 112
    end
    if W.button("添加", x + w - 112, y + 6, 50, 28, { kind = "primary", font = W.small() }) and d then
        local c = { type = d.id }
        if d.kind == "bool" then c.value = f.value ~= false
        elseif d.kind == "enum" then c.op = f.op or "=="; c.value = f.value
        else c.op = f.op or "<="; c.value = f.value; c.band = (f.band or 0) > 0 and f.band or nil end
        edit(ctx, function(dd) table.insert(dd.states[si].rules[ri].conditions, c) end)
        s.form = nil
    end
    if W.button("取消", x + w - 56, y + 6, 50, 28, { kind = "ghost", font = W.small() }) then s.form = nil end
    return 46
end

-- one line for a collapsed state: rules joined by 或者, a rule's conditions by its connective
local function rules_text(st, rules)
    local parts = {}
    for _, r in ipairs(rules) do
        local cs = {}
        for _, c in ipairs(r.conditions) do cs[#cs + 1] = cond_text(st, c) end
        local t = #cs == 0 and L.tr("空规则") or table.concat(cs, L.tr(r.logic == "OR" and " 或 " or " 且 "))
        if #cs > 1 and #rules > 1 then t = L.f("（%s）", t) end
        parts[#parts + 1] = t
    end
    return #parts == 0 and L.tr("没有规则") or table.concat(parts, L.tr("  或者  "))
end

local function section_head(title, stat, x, y)
    local tw = W.h2(title, x, y)
    if stat then D.text(stat, x + 10 + tw, y + 2, C.muted, W.small()) end
end

-- ---------------------------------------------------------------- states
local function states_section(ctx, x, y, w)
    local st, live, s = ctx.st, ctx.live, ctx.state
    local data = st.conditions.current.data
    local cy = y
    section_head("状态", L.f("%d 个", #data.states), x, cy)
    cy = cy + 28
    D.text("命中的状态同时生效，同一个形态键由靠上的状态决定；同一个状态的规则满足一种即生效；组合选「-」可临时停用", x, cy, C.faint, W.small(), w); cy = cy + 24
    local clip_ids = {}
    for id in pairs(data.clips) do clip_ids[#clip_ids + 1] = id end
    table.sort(clip_ids)
    local clip_labels = { UNBOUND }
    for k, id in ipairs(clip_ids) do clip_labels[k + 1] = id end
    local status = live.cond and live.cond.status or {}
    local status_by = live.cond and live.cond.status_by or {}
    s.closed = s.closed or {}
    for si, state in ipairs(data.states) do
        -- states start collapsed; only an explicit false keeps one open
        local closed = s.closed[si] ~= false
        local rh = 0
        for ri, r in ipairs(state.rules) do rh = rh + (ri > 1 and 22 or 0) + 34 + #r.conditions * 26 + 30 end
        local form_here = s.form and s.form.si == si
        local h = closed and 44 or (44 + rh + 34 + (form_here and 46 or 0))
        if visible(cy, h) then
            W.panel_box(x, cy, w, h, status[si] == "active")
            D.icon_tri(x + 12, cy + 22, 4, not closed, C.brass)
            if I.click(x + 4, cy + 8, 18, 28) then s.closed[si] = not closed end
            D.text_mid(tostring(si), x + 22, cy + 8, 28, C.faint, W.mono())
            -- "-" binds no combination: the backend skips the state, so it works as a switch-off
            local ci = state.clip == "" and 1 or nil
            for k, id in ipairs(clip_ids) do if id == state.clip then ci = k + 1 end end
            local ch, i = W.select("st_clip" .. si, x + 38, cy + 8, min(200, w * 0.3), 28, clip_labels, ci, { placeholder = state.clip })
            if ch then edit(ctx, function(d) d.states[si].clip = i == 1 and "" or clip_ids[i - 1] end) end
            local stx = STATUS[status[si] or (state.clip == "" and "off" or "idle")]
            local by = status[si] == "outranked" and status_by[si] and data.states[status_by[si]]
            local stext = by and L.f("被「%s」覆盖", by.clip) or stx[1]
            local chx = x + 48 + min(200, w * 0.3)
            status_mark(stx[3], chx + 5, cy + 22, stx[2])
            local chw = MARK_W + W.chip(stext, chx + MARK_W, cy + 13, stx[2])
            local bx = x + w - 10
            if closed then
                -- the summary stops before the move / delete buttons drawn right to left below
                local bw_all = 0
                for _, label in ipairs({ "删除状态", si < #data.states and "下移" or nil, si > 1 and "上移" or nil }) do
                    bw_all = bw_all + D.measure(W.small(), label) + 26
                end
                local tx = chx + chw + 10
                local tw = max(0, bx - bw_all - 8 - tx)
                local summary = rules_text(st, state.rules)
                D.text_mid(summary, tx, cy + 8, 28, C.muted, W.small(), tw)
                W.tooltip(summary, tx, cy + 8, tw, 28)
            end
            local function rbtn(label, opt)
                local bw = D.measure(W.small(), label) + 22
                bx = bx - bw
                local clicked = W.button(label, bx, cy + 10, bw, 24, opt or { kind = "ghost", font = W.small() })
                bx = bx - 4
                return clicked
            end
            if rbtn("删除状态", { kind = "danger", font = W.small() }) then edit(ctx, function(d) table.remove(d.states, si) end) end
            if si < #data.states and rbtn("下移") then
                edit(ctx, function(d) d.states[si], d.states[si + 1] = d.states[si + 1], d.states[si] end)
            end
            if si > 1 and rbtn("上移") then
                edit(ctx, function(d) d.states[si], d.states[si - 1] = d.states[si - 1], d.states[si] end)
            end
            local ry = cy + 44
            for ri, r in ipairs(closed and {} or state.rules) do
                if ri > 1 then
                    -- rules of one state are alternatives: any rule that matches makes the state match
                    D.text_mid("或者", x + 14, ry, 22, C.brass, W.small())
                    ry = ry + 22
                end
                D.rect(x + 12, ry, w - 24, 1, C.line)
                D.text_mid(L.f("规则 %d", ri), x + 14, ry + 4, 26, C.muted, W.small())
                D.text_mid("条件结束后保持", x + 80, ry + 4, 26, C.muted, W.small())
                local c6, v6 = W.slider("hold" .. si .. "_" .. ri, x + 180, ry + 4, min(180, w - 300), 26, r.hold or 0, 0, 5,
                    { step = 0.1, fmt = "%.1fs", value_w = 44 })
                if c6 then edit(ctx, function(d) d.states[si].rules[ri].hold = v6 end) end
                if W.tbutton("删除规则", x + w - tbw("删除规则") - 10, ry + 6, { kind = "danger" }) then
                    edit(ctx, function(d) table.remove(d.states[si].rules, ri) end)
                end
                ry = ry + 34
                for ci2, c in ipairs(r.conditions) do
                    -- and / or between conditions: click to switch (one connective per rule)
                    if ci2 > 1 and W.tbutton(r.logic == "OR" and "或" or "且", x + 14, ry + 1, { kind = "ghost" }) then
                        edit(ctx, function(d) local rr = d.states[si].rules[ri]; rr.logic = (rr.logic == "OR") and "AND" or "OR" end)
                    end
                    D.text_mid(cond_text(st, c), x + 44, ry, 24, C.text, W.small(), w * 0.55)
                    D.text_mid(L.f("当前：%s", live_text(st, live, c.type)), x + w * 0.62, ry, 24, C.faint, W.small(), w * 0.25)
                    if W.tbutton("移除", x + w - tbw("移除") - 10, ry + 1) then
                        edit(ctx, function(d) table.remove(d.states[si].rules[ri].conditions, ci2) end)
                    end
                    ry = ry + 26
                end
                if form_here and s.form.ri == ri then
                    ry = ry + condition_form(ctx, x + 20, ry + 2, w - 40, si, ri)
                elseif W.tbutton("＋ 添加条件", x + 40, ry + 2) then
                    s.form = { si = si, ri = ri }
                end
                ry = ry + 30
            end
            if not closed and W.tbutton("＋ 添加规则", x + 14, ry + 4) then
                edit(ctx, function(d) table.insert(d.states[si].rules, { logic = "AND", hold = 0, conditions = {} }) end)
                s.form = { si = si, ri = #state.rules + 1 }
            end
            if not closed then
                -- exclusive: while this state matches, the states below it do not play at all
                local label = "独占状态"
                local tx = x + w - 24 - (D.measure(W.body(), label) + 38)
                local ch, on = W.toggle(label, tx, ry + 2, state.exclusive == true)
                W.tooltip("开启后，这个状态生效时下面的状态都不播放；关闭时，下面的状态可以控制它没用到的形态键", tx, ry + 2, x + w - tx, 28)
                if ch then edit(ctx, function(d) d.states[si].exclusive = on end) end
            end
        end
        cy = cy + h + 8
    end
    -- without a combination the state starts unbound ("-"): its rules can be written first
    if W.button("＋ 添加状态", x, cy, nil, 28) then
        edit(ctx, function(d) table.insert(d.states, { clip = clip_ids[1] or "", rules = {} }) end)
        s.closed[#data.states + 1] = false
    end
    return cy + 36 - y
end

-- ---------------------------------------------------------------- clips
local function clips_section(ctx, x, y, w)
    local st, live, s = ctx.st, ctx.live, ctx.state
    local data = st.conditions.current.data
    local cy = y
    local ids = {}
    for id in pairs(data.clips) do ids[#ids + 1] = id end
    table.sort(ids)
    section_head("形态键配置组合", L.f("%d 个", #ids), x, cy)
    if W.button("＋ 新建组合", x + w - 110, cy - 2, 110, 26, { font = W.small() }) then
        W.start_text(s, "clip_form", { title = "新建形态键配置组合", on_submit = function(name)
            if name == "" then return end
            edit(ctx, function(d) if not d.clips[name] then d.clips[name] = { values = {}, fade_in = 0.15, fade_out = 0.3 } end end)
            s.open_clip = name
        end })
    end
    cy = cy + 32
    cy = cy + W.text_form(s, "clip_form", "conditions_clip", x, cy, w)
    local playing_set = live.cond and live.cond.playing_set or {}
    -- keys a clip can use: every merged mesh key
    local key_items = W.shape_key_items(st.sculpt, s)
    s.search = s.search or {}
    -- the open search list of a clip adds its height to that clip's box
    local list_h = s.addkey_h or {}
    s.addkey_h = list_h
    -- sculpt presets to import from: only those with keys on the scanned meshes
    local presets = {}
    for _, e in ipairs(st.presets.sculpt or {}) do if (e.hits or 0) > 0 then presets[#presets + 1] = e end end
    s.import = s.import or {}
    for _, id in ipairs(ids) do
        local c = data.clips[id]
        local open = s.open_clip == id
        local keys = {}
        for k in pairs(c.values) do keys[#keys + 1] = k end
        table.sort(keys)
        local h = 44 + (open and (40 + #keys * 30 + max(40, (list_h[id] or 34) + 6) + (#presets > 0 and 36 or 0)) or 0)
        if visible(cy, h) then
            W.panel_box(x, cy, w, h, playing_set[id] == true)
            local clicked = W.header(id, x + 8, cy + 9, min(260, w * 0.35), open, L.f("%d 个形态键", #keys))
            if clicked then
                if open then s.open_clip = nil else s.open_clip = id end
            end
            if W.tbutton("重命名", x + w - 158 - tbw("重命名"), cy + 11) then
                W.start_text(s, "clip_form", { title = "重命名形态键配置组合", text = id, on_submit = function(name)
                    if name == "" or name == id then return end
                    if data.clips[name] then ctx.toast("warn", L.f("已有名为「%s」的形态键配置组合", name)); return end
                    -- the states that play it follow the new name
                    edit(ctx, function(d)
                        d.clips[name], d.clips[id] = d.clips[id], nil
                        for _, ds in ipairs(d.states) do if ds.clip == id then ds.clip = name end end
                    end)
                    if s.open_clip == id then s.open_clip = name end
                    if s.preview == id then s.preview = name; ctx.call("cond_preview", { clip = name }) end
                end })
            end
            local previewing = s.preview == id
            if W.tbutton(previewing and "停止预览" or "预览", x + w - 150, cy + 11, { pressed = previewing }) then
                s.preview = (not previewing) and id or nil
                ctx.call("cond_preview", { clip = s.preview })
            end
            if W.tbutton("删除", x + w - 60, cy + 11, { kind = "danger" }) then
                -- states keep their rules and fall back to "-" (switched off)
                edit(ctx, function(d)
                    d.clips[id] = nil
                    for _, ds in ipairs(d.states) do if ds.clip == id then ds.clip = "" end end
                end)
            end
            if open then
                local oy = cy + 44
                D.text_mid("淡入", x + 14, oy, 28, C.muted, W.small())
                local c1, v1 = W.slider("fi_" .. id, x + 50, oy, min(160, w * 0.25), 28, c.fade_in, 0, 2, { step = 0.05, fmt = "%.2fs", value_w = 48 })
                if c1 then edit(ctx, function(d) d.clips[id].fade_in = v1 end) end
                local fx = x + 70 + min(160, w * 0.25) + 60
                D.text_mid("淡出", fx, oy, 28, C.muted, W.small())
                local c2, v2 = W.slider("fo_" .. id, fx + 36, oy, min(160, w * 0.25), 28, c.fade_out, 0, 3, { step = 0.05, fmt = "%.2fs", value_w = 48 })
                if c2 then edit(ctx, function(d) d.clips[id].fade_out = v2 end) end
                oy = oy + 40
                for _, k in ipairs(keys) do
                    D.text_mid(k, x + 20, oy, 28, C.text, W.small(), w * 0.3)
                    -- values imported from a sculpt preset may be above 1 (sculpt_max)
                    local c3, v3 = W.slider("kv_" .. id .. k, x + w * 0.34, oy, w * 0.45, 28, c.values[k], 0, max(1, c.values[k]), { step = 0.01, fmt = "%.2f" })
                    if c3 then edit(ctx, function(d) d.clips[id].values[k] = v3 end) end
                    if W.tbutton("移除", x + w - tbw("移除") - 10, oy + 3) then edit(ctx, function(d) d.clips[id].values[k] = nil end) end
                    oy = oy + 30
                end
                if #key_items > 0 then
                    local c4, name, kh = W.search_select(s.search, "addkey_" .. id, x + 20, oy + 4, min(320, w * 0.5),
                        key_items, nil, { placeholder = "＋ 添加形态键（输入文字搜索）…",
                            empty = "没有匹配的已扫描形态键" })
                    list_h[id] = kh
                    if c4 and name then edit(ctx, function(d) d.clips[id].values[name] = 1.0 end) end
                else
                    D.text_mid("先在「捏脸」页扫描装备，才能选择形态键", x + 20, oy + 4, 28, C.faint, W.small())
                end
                -- copy a sculpt preset's non-zero values, or one option of its key groups, into this
                -- combination: one list picks the preset, the second its values or a group option
                if #presets > 0 then
                    local iy = oy + max(40, (list_h[id] or 34) + 6)
                    local pick = s.import[id] or {}
                    s.import[id] = pick
                    local labels, pi = {}, nil
                    for i, e in ipairs(presets) do
                        labels[i] = e.name .. (e.folder and "" or L.tr("（通用）"))
                        if e.name == pick.name and e.folder == pick.folder then pi = i end
                    end
                    local e = pi and presets[pi]
                    local parts, part_labels = { {} }, { L.tr("预设值") }
                    for _, g in ipairs(e and e.key_groups or {}) do
                        for oi, o in ipairs(g.options) do
                            parts[#parts + 1] = { group = g.name, option = oi }
                            part_labels[#part_labels + 1] = g.name .. " / " .. o
                        end
                    end
                    if not parts[pick.part or 1] then pick.part = 1 end
                    D.text_mid("从捏脸配置导入", x + 20, iy, 28, C.muted, W.small())
                    local px = x + 20 + tbw("从捏脸配置导入") + 8
                    local bw = tbw("导入") + 16
                    local sw = max(80, min(240, (x + w - px - bw - 26) / 2))
                    local c5, i5 = W.select("import_" .. id, px, iy, sw, 28, labels, pi, { placeholder = "选择捏脸配置…" })
                    if c5 and presets[i5] then pick.name, pick.folder, pick.part = presets[i5].name, presets[i5].folder, 1 end
                    local c6, i6 = W.select("import_part_" .. id, px + sw + 6, iy, sw, 28, part_labels, pick.part or 1)
                    if c6 then pick.part = i6 end
                    W.tooltip("把该捏脸配置里所有不为 0 的形态键值，或它某个键组选项里的值，原样加入这个组合；组合里已有的同名键会被覆盖",
                        px, iy, sw * 2 + 6, 28)
                    if W.button("导入", px + sw * 2 + 12, iy, bw, 28, { disabled = e == nil }) and e then
                        local p = parts[pick.part or 1]
                        ctx.call("cond_import_sculpt", { clip = id, name = e.name, folder = e.folder, group = p.group, option = p.option })
                    end
                end
            end
        end
        cy = cy + h + 8
    end
    if #ids == 0 then D.text("还没有形态键配置组合。", x, cy, C.faint, W.small()); cy = cy + 24 end
    return cy - y
end

-- ---------------------------------------------------------------- live values
local function live_cols(w) return w >= 640 and 3 or w >= 340 and 2 or 1 end

-- cells of the live grid: a game that sorts its conditions into categories gets a gray heading
-- above each one, and each category starts on a new row
local function live_layout(defs, cols)
    local cells, row, col, prev = {}, 0, 0, nil
    for i, d in ipairs(defs) do
        if d.category and d.category ~= prev then
            if col > 0 then row, col = row + 1, 0 end
            cells[#cells + 1] = { head = d.category, row = row }
            row = row + 1
        end
        prev = d.category
        cells[#cells + 1] = { d = d, row = row, col = col }
        col = col + 1
        if col == cols then row, col = row + 1, 0 end
    end
    return cells, row + (col > 0 and 1 or 0)
end

local function live_height(ctx, w)
    local _, rows = live_layout(listed(ctx.st), live_cols(w))
    return 44 + rows * 22
end

local function live_section(ctx, x, y, w)
    local st, live = ctx.st, ctx.live
    local defs = listed(st)
    local cols = live_cols(w)
    local cw = w / cols
    local h = live_height(ctx, w)
    W.panel_box(x, y, w, h, true)
    W.h2("实时条件", x + 12, y + 10)
    if not (live.cond and live.cond.sampled) then
        D.text("（只在游戏中、主角色可操作时读取）", x + 100, y + 13, C.faint, W.small(), w - 112)
    end
    for _, cell in ipairs((live_layout(defs, cols))) do
        local cy = y + 40 + cell.row * 22
        if cell.head then
            D.text(cell.head, x + 12, cy + 2, C.faint, W.small(), w - 24)
        else
            local d = cell.d
            local cx = x + 12 + cell.col * cw
            local v = live.cond and live.cond.values[d.id]
            D.text(d.label, cx, cy, C.muted, W.small(), cw * 0.62)
            D.text(live_text(st, live, d.id), cx + cw * 0.64, cy, (v == true) and C.ok or C.text, W.small(), cw * 0.34)
        end
    end
    return h
end

local TABS = { { "states", "条件状态" }, { "clips", "形态键配置组合" } }

function Page.draw(ctx, x, y, w)
    local st = ctx.st
    local tab, th = W.tabs(ctx.state, x, y, w, TABS)
    local cy = y + th
    cy = cy + top_bar(ctx, x, cy, w) + 10
    if not st.conditions.current then
        D.text("满足一定条件时应用指定表情。", x, cy, C.muted, W.small(), w)
        cy = cy + 30
        return cy + live_section(ctx, x, cy, w) - y
    end
    local section = tab == "clips" and clips_section or states_section
    if w < 900 then
        cy = cy + section(ctx, x, cy, w) + 10
        cy = cy + live_section(ctx, x, cy, w)
        return cy - y
    end
    -- wide: live values in a right column that stays in view while the left column scrolls
    local rw = min(400, max(300, floor(w * 0.32)))
    local lw = w - rw - 12
    local top = cy
    local ly = top + section(ctx, x, top, lw)
    local lh = ly - top
    local rh = live_height(ctx, rw)
    local clip = D.get_clip()
    local ry = top
    if clip and lh > rh then ry = min(max(top, clip[2] + 8), top + lh - rh) end
    live_section(ctx, x + lw + 12, ry, rw)
    return max(lh, rh) + cy - y
end

Page.want_cond = true

return Page
