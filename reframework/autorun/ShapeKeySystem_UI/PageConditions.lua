-- ShapeKeySystem panel, advanced page "条件规则" (formerly 条件表情; rules can drive sculpt keys
-- too). Only the UI was renamed: the backend keeps "conditions" (cond_* commands, conditions/*.json,
-- binding field) so existing player files still load. Pages: condition sets (pick / new / save / delete),
-- states in priority order with their rules, expression clips (keys, fades, preview) and the
-- live value of every condition. Edits go through cond_edit with a full copy of the set.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")

local Page = {}
local C = T.c
local max, min, floor = math.max, math.min, math.floor

local SOURCE = { user = "用户", mods = "mod 自带" }
local STATUS = { active = { "生效中", C.ok }, outranked = { "命中，但被上面的压着", C.warn }, idle = { "未命中", C.faint },
    off = { "已停用", C.faint } }
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
    if not d then return "未知条件 " .. tostring(c.type) end
    if d.kind == "bool" then return d.label .. (c.value == false and " ＝ 否" or "") end
    if d.kind == "enum" then
        local label = tostring(c.value)
        for _, o in ipairs(d.options or {}) do if o.value == c.value then label = o.label end end
        return string.format("%s %s %s", d.label, c.op == "~=" and "≠" or "＝", label)
    end
    local s = string.format("%s %s %s", d.label, c.op or "<=", tostring(c.value))
    if (tonumber(c.band) or 0) > 0 then s = s .. string.format("（回差 %s）", tostring(c.band)) end
    return s
end

local function live_text(st, live, id)
    local v = live.cond and live.cond.values[id]
    local d = def_of(st, id)
    if v == nil then return "—" end
    if type(v) == "boolean" then return v and "是" or "否" end
    if d and d.kind == "enum" then
        for _, o in ipairs(d.options or {}) do if o.value == v then return o.label end end
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
        labels[#labels + 1] = string.format("%s（%s）", e.name, SOURCE[e.source] or e.source) .. W.default_suffix(ctx, e.id, cs.binding_name)
        ids[#ids + 1] = e.id
        if cur and cur.id == e.id then idx = #ids end
    end
    if cur and idx == 1 then labels[#labels + 1] = cur.name .. "（未保存）"; ids[#ids + 1] = cur.id; idx = #ids end
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
        D.text_mid("删除条件规则配置「" .. pd.name .. "」？", x + 10, y + 56, 28, C.warn, W.body(), w - 200)
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
    local defs = st.conditions.defs or {}
    local labels = {}
    for i, d in ipairs(defs) do labels[i] = d.label end
    f.type_i = f.type_i or 1
    local d = defs[f.type_i]
    D.rrect(x, y, w, 40, 3, C.ink); D.outline(x, y, w, 40, 3, 1, C.line)
    local ch, i = W.select("cf_type", x + 6, y + 6, min(240, w * 0.38), 28, labels, f.type_i)
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
        local t = #cs == 0 and "空规则" or table.concat(cs, r.logic == "OR" and " 或 " or " 且 ")
        if #cs > 1 and #rules > 1 then t = "（" .. t .. "）" end
        parts[#parts + 1] = t
    end
    return #parts == 0 and "没有规则" or table.concat(parts, "  或者  ")
end

-- ---------------------------------------------------------------- states
local function states_section(ctx, x, y, w)
    local st, live, s = ctx.st, ctx.live, ctx.state
    local data = st.conditions.current.data
    local cy = y
    W.h2("状态", x, cy); cy = cy + 28
    D.text("靠上的状态优先生效，同一个状态的规则满足一种即生效；组合选「-」可临时停用", x, cy, C.faint, W.small(), w); cy = cy + 24
    local clip_ids = {}
    for id in pairs(data.clips) do clip_ids[#clip_ids + 1] = id end
    table.sort(clip_ids)
    local clip_labels = { UNBOUND }
    for k, id in ipairs(clip_ids) do clip_labels[k + 1] = id end
    local status = live.cond and live.cond.status or {}
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
            local chx = x + 48 + min(200, w * 0.3)
            local chw = W.chip(stx[1], chx, cy + 13, stx[2])
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
                D.text_mid("规则 " .. ri, x + 14, ry + 4, 26, C.muted, W.small())
                D.text_mid("条件结束后保持", x + 80, ry + 4, 26, C.muted, W.small())
                local c6, v6 = W.slider("hold" .. si .. "_" .. ri, x + 180, ry + 4, min(180, w - 300), 26, r.hold or 0, 0, 5,
                    { step = 0.1, fmt = "%.1fs", value_w = 44 })
                if c6 then edit(ctx, function(d) d.states[si].rules[ri].hold = v6 end) end
                if W.tbutton("删除规则", x + w - 80, ry + 6, { kind = "danger" }) then
                    edit(ctx, function(d) table.remove(d.states[si].rules, ri) end)
                end
                ry = ry + 34
                for ci2, c in ipairs(r.conditions) do
                    -- and / or between conditions: click to switch (one connective per rule)
                    if ci2 > 1 and W.tbutton(r.logic == "OR" and "或" or "且", x + 14, ry + 1, { kind = "ghost" }) then
                        edit(ctx, function(d) local rr = d.states[si].rules[ri]; rr.logic = (rr.logic == "OR") and "AND" or "OR" end)
                    end
                    D.text_mid(cond_text(st, c), x + 44, ry, 24, C.text, W.small(), w * 0.55)
                    D.text_mid("当前：" .. live_text(st, live, c.type), x + w * 0.62, ry, 24, C.faint, W.small(), w * 0.25)
                    if W.tbutton("移除", x + w - 56, ry + 1) then
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
        end
        cy = cy + h + 8
    end
    if #clip_ids == 0 then
        D.text("先在下面新建一个表情组合，再添加状态。", x, cy, C.muted, W.small()); cy = cy + 24
    elseif W.button("＋ 添加状态", x, cy, nil, 28) then
        edit(ctx, function(d) table.insert(d.states, { clip = clip_ids[1], rules = {} }) end)
        s.closed[#data.states + 1] = false
    end
    return cy + 36 - y
end

-- ---------------------------------------------------------------- clips
local function clips_section(ctx, x, y, w)
    local st, live, s = ctx.st, ctx.live, ctx.state
    local data = st.conditions.current.data
    local cy = y
    W.h2("表情组合", x, cy)
    if W.button("＋ 新建组合", x + w - 110, cy - 2, 110, 26, { font = W.small() }) then
        W.start_text(s, "clip_form", { title = "新建表情组合", on_submit = function(name)
            if name == "" then return end
            edit(ctx, function(d) if not d.clips[name] then d.clips[name] = { values = {}, fade_in = 0.15, fade_out = 0.3 } end end)
            s.open_clip = name
        end })
    end
    cy = cy + 32
    cy = cy + W.text_form(s, "clip_form", "conditions_clip", x, cy, w)
    local ids = {}
    for id in pairs(data.clips) do ids[#ids + 1] = id end
    table.sort(ids)
    local playing = live.cond and live.cond.playing
    -- keys a clip can use: every merged mesh key
    local key_names = {}
    for _, k in ipairs(st.sculpt.keys or {}) do key_names[#key_names + 1] = k.name end
    for _, id in ipairs(ids) do
        local c = data.clips[id]
        local open = s.open_clip == id
        local keys = {}
        for k in pairs(c.values) do keys[#keys + 1] = k end
        table.sort(keys)
        local h = 44 + (open and (40 + #keys * 30 + 40) or 0)
        if visible(cy, h) then
            W.panel_box(x, cy, w, h, playing == id)
            local clicked = W.header(id, x + 8, cy + 9, min(260, w * 0.35), open, string.format("%d 个形态键", #keys))
            if clicked then
                if open then s.open_clip = nil else s.open_clip = id end
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
                    local c3, v3 = W.slider("kv_" .. id .. k, x + w * 0.34, oy, w * 0.45, 28, c.values[k], 0, 1, { step = 0.01, fmt = "%.2f" })
                    if c3 then edit(ctx, function(d) d.clips[id].values[k] = v3 end) end
                    if W.tbutton("移除", x + w - 56, oy + 3) then edit(ctx, function(d) d.clips[id].values[k] = nil end) end
                    oy = oy + 30
                end
                if #key_names > 0 then
                    local c4, i4 = W.select("addkey_" .. id, x + 20, oy + 4, min(260, w * 0.4), 28, key_names, nil,
                        { placeholder = "＋ 添加形态键…" })
                    if c4 and key_names[i4] then edit(ctx, function(d) d.clips[id].values[key_names[i4]] = 1.0 end) end
                else
                    D.text_mid("先在「捏脸」页扫描装备，才能选择形态键", x + 20, oy + 4, 28, C.faint, W.small())
                end
            end
        end
        cy = cy + h + 8
    end
    if #ids == 0 then D.text("还没有表情组合。", x, cy, C.faint, W.small()); cy = cy + 24 end
    return cy - y
end

-- ---------------------------------------------------------------- live values
local function live_section(ctx, x, y, w)
    local st, live = ctx.st, ctx.live
    local defs = st.conditions.defs or {}
    local cols = w >= 640 and 3 or 2
    local cw = w / cols
    local rows = math.ceil(#defs / cols)
    local h = 44 + rows * 22
    W.panel_box(x, y, w, h, true)
    W.h2("实时条件", x + 12, y + 10)
    if not (live.cond and live.cond.sampled) then
        D.text("（只在游戏中、主角色可操作时读取）", x + 100, y + 13, C.faint, W.small())
    end
    for i, d in ipairs(defs) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        local cx, cy = x + 12 + col * cw, y + 40 + row * 22
        local v = live.cond and live.cond.values[d.id]
        D.text(d.label, cx, cy, C.muted, W.small(), cw * 0.62)
        D.text(live_text(st, live, d.id), cx + cw * 0.64, cy, (v == true) and C.ok or C.text, W.small(), cw * 0.34)
    end
    return h
end

function Page.draw(ctx, x, y, w)
    local st = ctx.st
    local cy = y + top_bar(ctx, x, y, w) + 10
    if not st.conditions.current then
        D.text("满足一定条件时应用指定表情。", x, cy, C.muted, W.small(), w)
        cy = cy + 30
        return cy + live_section(ctx, x, cy, w) - y
    end
    cy = cy + states_section(ctx, x, cy, w) + 6
    cy = cy + clips_section(ctx, x, cy, w) + 10
    cy = cy + live_section(ctx, x, cy, w)
    return cy - y
end

Page.want_cond = true

return Page
