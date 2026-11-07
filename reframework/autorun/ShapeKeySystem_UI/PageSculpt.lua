-- ShapeKeySystem panel, basic page "捏脸": merged sculpt keys with sliders, search, per-part
-- values, undo / redo, compare with the initial (mod default) values, save (and bind) a sculpt preset.
-- The preset's key groups sit above the parts: an integer per group picks one set of keys.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local max, min, abs = math.max, math.min, math.abs

local function visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

local function primary_part(st)
    local b = st.presets.binding
    if b and b.part then return b.part end
    local best
    for _, p in ipairs(st.scene.parts or {}) do if not best or p.channels > best.channels then best = p end end
    return best and best.id or nil
end

local function toolbar(ctx, x, y, w)
    local st, call, s = ctx.st, ctx.call, ctx.state
    local sc = st.sculpt
    local cy = y
    W.panel_box(x, cy, w, 44)
    local _, bw = W.button("扫描装备", x + 10, cy + 8, nil, 28, { kind = "primary" })
    if _ then call("sculpt_scan") end
    local scan = sc.scan
    local info = scan and L.f("%d 个部件 · %d 项（已合并同名，%d 项由表情驱动）", #(scan.parts or {}), scan.keys or 0,
        scan.expression_keys or 0) or "还没有扫描"
    local tw = D.measure(W.body(), "强制覆盖") + 38
    D.text_mid(info, x + 22 + bw, cy + 8, 28, C.muted, W.small(), w - bw - tw - 50)
    local ch, v = W.toggle("强制覆盖", x + w - tw - 10, cy + 8, sc.edit_mode)
    if ch then call("set_edit_mode", { on = v }) end
    W.tooltip("平时改动只在数值变化时写一次就生效；其他插件也在改同一个形态键、值被抢回去时再打开，打开后每帧都写入",
        x + w - tw - 10, cy + 8, tw, 28)
    cy = cy + 52

    -- sculpt preset: pick (loads it) or start a new one from the current values
    local pr = st.presets.sculpt or {}
    local labels, cur = {}, nil
    for i, e in ipairs(pr) do
        -- presets of this outfit's model are plain names; general ones say so
        labels[i] = e.name .. L.tr(W.default_suffix(ctx, e.name, st.presets.binding and st.presets.binding.sculpt))
            .. (e.folder and "" or L.tr("（通用）"))
        if sc.preset and sc.preset.name == e.name and sc.preset.folder == e.folder then cur = i end
    end
    W.panel_box(x, cy, w, 44)
    D.text_mid("捏脸配置", x + 12, cy + 8, 28, C.muted, W.small())
    local lw = D.measure(W.small(), "捏脸配置") + 22
    local sel_w = min(260, w * 0.3)
    local chp, ip = W.select("sculpt_preset", x + lw, cy + 8, sel_w, 28, labels, cur,
        { placeholder = #pr > 0 and "（未选择）" or "（还没有配置）" })
    if chp and pr[ip] then
        if call("load_sculpt", { name = pr[ip].name, folder = pr[ip].folder }) then s.name_form = nil end
    end
    local bx = x + lw + sel_w + 10
    local preset = sc.preset
    local own = preset and preset.source == "user"
    local bnd = st.presets.binding
    local dw = W.default_button(ctx, bx, cy + 8, "sculpt", preset and preset.name, bnd and bnd.sculpt)
    if dw > 0 then bx = bx + dw + 16 end
    local function save_as(title)
        W.start_text(s, "name_form", { title = title, text = preset and preset.name or "",
            extra = { label = "存为通用配置（不属于这套装备）", value = false },
            on_submit = function(name, general)
                if name ~= "" and call("save_sculpt", { name = name, general = general }) then ctx.toast("info", L.f("已保存：%s", name)) end
            end })
    end
    -- 保存: your own config is overwritten in place; a mod's (read-only) or none asks for a name
    local c1, b1 = W.button("保存", bx, cy + 8, nil, 28, { kind = sc.dirty and "primary" or nil,
        disabled = not sc.scan or (own and not sc.dirty) })
    if c1 then
        if own then
            if call("save_sculpt", { name = preset.name, general = preset.folder == nil }) then ctx.toast("info", L.f("已保存：%s", preset.name)) end
        else
            save_as(preset and "保存为新配置（mod 自带的配置不能覆盖）" or "保存捏脸配置")
        end
    end
    bx = bx + b1 + 6
    local c2, b2 = W.button("另存为…", bx, cy + 8, nil, 28, { disabled = not sc.scan })
    if c2 then save_as("另存为") end
    bx = bx + b2 + 6
    if own and not sc.dirty then
        local c3, b3 = W.button("删除", bx, cy + 8, nil, 28, { kind = "danger" })
        if c3 then call("request_delete", { kind = "sculpt", name = preset.name, folder = preset.folder }) end
        bx = bx + b3 + 6
    end
    cy = cy + 52
    cy = cy + W.text_form(s, "name_form", "sculpt_name", x, cy, w)
    local pd = st.presets.pending_delete
    if pd and pd.kind == "sculpt" then
        D.rrect(x, cy, w, 36, 3, C.ink); D.outline(x, cy, w, 36, 3, 1, C.warn)
        D.text_mid(L.f("删除捏脸配置「%s」？", pd.name), x + 10, cy + 4, 28, C.warn, W.body(), w - 200)
        if W.button("删除", x + w - 160, cy + 4, 70, 28, { kind = "danger" }) then call("confirm_delete") end
        if W.button("取消", x + w - 82, cy + 4, 70, 28, { kind = "ghost" }) then call("cancel_delete") end
        cy = cy + 44
    end

    -- the action buttons go to a second row when they do not fit beside the filters
    local part = primary_part(st)
    local ab_label = sc.ab_preview and "正在看：初始" or "对比初始"
    local f = W.body()
    local sw = min(200, w * 0.28)
    local left_w = sw + 12 + D.measure(f, "只看已修改") + 50 + D.measure(f, "隐藏表情通道") + 50 + D.measure(f, "隐藏非预设通道") + 50
        + D.measure(f, "隐藏键组占用") + 50
    local right_w = 0
    for _, l in ipairs({ ab_label, "归零", "重置", "重做", "撤销" }) do right_w = right_w + D.measure(f, l) + 28 end
    local wrap = left_w + right_w > w - 20
    W.panel_box(x, cy, w, wrap and 82 or 44)
    local bx = x + 10
    W.text_box("sculpt_filter", bx, cy + 8, sw, 28, s.filter, "搜索形态键…", function(t) s.filter = t end)
    bx = bx + sw + 12
    local c1, v1, w1 = W.toggle("只看已修改", bx, cy + 8, s.only_modified == true)
    if c1 then s.only_modified = v1 end
    bx = bx + w1 + 12
    -- hiding is the user's choice: every key is listed by default, held ones say who holds them
    local c2, v2, w2 = W.toggle("隐藏表情通道", bx, cy + 8, s.hide_expression == true)
    if c2 then s.hide_expression = v2 end
    bx = bx + w2 + 12
    local c3, v3, w3 = W.toggle("隐藏非预设通道", bx, cy + 8, s.hide_unpreset == true)
    if c3 then s.hide_unpreset = v3 end
    W.tooltip("只显示 mod 自带或当前捏脸配置里用到的形态键", bx, cy + 8, w3, 28)
    bx = bx + w3 + 12
    local c4, v4, w4 = W.toggle("隐藏键组占用", bx, cy + 8, s.hide_held == true)
    if c4 then s.hide_held = v4 end
    bx = bx + w4 + 12
    -- right side
    local rx = x + w - 10
    local ry = wrap and (cy + 46) or (cy + 8)
    local function rbtn(label, opt)
        local bw2 = D.measure(f, label) + 22
        rx = rx - bw2
        local clicked = W.button(label, rx, ry, bw2, 28, opt)
        rx = rx - 6
        return clicked
    end
    if rbtn(ab_label, { pressed = sc.ab_preview }) then
        call("set_ab_preview", { on = not sc.ab_preview })
    end
    W.tooltip("临时显示初始值（mod 默认值），再点一次回到当前值", rx + 6, ry, D.measure(f, ab_label) + 22, 28)
    -- 归零 / 重置: every key to 0 / back to the mod default, one undo step each (red: they touch everything)
    if rbtn("归零", { kind = "danger", disabled = not sc.scan }) then call("zero_sculpt_all") end
    W.tooltip("所有形态键归零，可以撤销", rx + 6, ry, D.measure(f, "归零") + 22, 28)
    if rbtn("重置", { kind = "danger", disabled = not sc.scan }) then call("reset_sculpt_all") end
    W.tooltip("所有形态键恢复为 mod 默认值，可以撤销", rx + 6, ry, D.measure(f, "重置") + 22, 28)
    if rbtn("重做", { kind = "ghost", disabled = not sc.can_redo }) then call("sculpt_redo") end
    if rbtn("撤销", { kind = "ghost", disabled = not sc.can_undo }) then call("sculpt_undo") end
    cy = cy + (wrap and 90 or 52)

    if sc.dirty then
        D.text("有未保存的修改", x + 2, cy, C.warn, W.small(), w)
        cy = cy + 22
    end
    return cy - y
end

local function key_row(ctx, k, x, y, w)
    local call, s = ctx.call, ctx.state
    local multi = #k.parts > 1
    local expanded = multi and s.expanded[k.name]
    local nparts = expanded and #k.parts or 0
    local has_ovr = next(k.overrides or {}) ~= nil
    -- second line only for what the group header does not already say
    local sub = {}
    if k.key_group and not k.held_by then sub[#sub + 1] = L.f("键组「%s」", k.key_group) end
    if k.mixed then sub[#sub + 1] = L.tr("表情叠加") end
    if multi then sub[#sub + 1] = table.concat(k.part_labels or k.parts, " · ") end
    if has_ovr then sub[#sub + 1] = L.tr("有部件单独值") end
    local h = (#sub > 0 and 42 or 34) + nparts * 30
    if not visible(y, h) then return h end
    local modified = abs(k.value - (k.default or 0)) > 1e-6
    local rh = (#sub > 0) and 42 or 34
    if modified then D.rect(x, y + 2, 2, rh - 4, C.brass) end
    local nw = max(150, w * 0.34)
    local title = k.label or k.name
    if #sub > 0 then
        D.text(title, x + 10, y + 4, C.text, W.body(), nw - 16)
        D.text(table.concat(sub, " · "), x + 10, y + 23, has_ovr and C.brass or C.faint, W.small(), nw - 16)
    else
        D.text_mid(title, x + 10, y + 3, 28, C.text, W.body(), nw - 16)
    end
    if k.label then W.tooltip(L.f("形态键名：%s", k.name), x, y, nw, rh) end
    local oy0 = (rh - 42) / 2   -- controls stay centred on the shorter row
    -- right-aligned buttons sized by their (translated) labels
    local f = W.small()
    local bw = D.measure(f, "默认") + 22
    local bx = x + w - bw - 2
    local ax = min(x + w - 106, bx - 8 - (D.measure(f, "按部件") + 22))
    local ext = W.external_owner(ctx.st, k.name)
    if k.held_by and not ext then
        -- the selected option of its key group holds it; free again when the group is set to 无
        local cw = W.chip(L.f("键组「%s」· %s", k.held_by.group, k.held_by.option), x + nw, y + 11 + oy0, C.brass)
        D.text_mid(string.format("%.2f", k.value), x + nw + cw + 10, y + 7 + oy0, 28, C.faint, W.mono())
        W.tooltip("键组设为「无」后可以自由调整", x + nw, y + 11 + oy0, cw, 22)
    elseif ext then
        local cw = W.chip(L.f("由 %s 控制", ext), x + nw, y + 11 + oy0, C.brass)
        D.text_mid(string.format("%.2f", k.value), x + nw + cw + 10, y + 7 + oy0, 28, C.faint, W.mono())
        local rw = D.measure(f, "收回") + 22
        if W.tbutton("收回", x + w - rw - 2, y + 10 + oy0) then call("external_release", { owner = ext, name = k.name }) end
        W.tooltip("另一个插件正在控制这个形态键；收回后恢复捏脸的值", x + w - rw - 2, y + 10 + oy0, rw, 22)
    else
        local ch, v = W.slider("sk:" .. k.name, x + nw, y + 7 + oy0, ax - x - nw - 12, 28, k.value, k.range[1], k.range[2],
            { step = 0.01, fmt = "%.2f" })
        if ch then call("set_sculpt_key", { name = k.name, value = v }) end
        if multi and W.tbutton("按部件", ax, y + 10 + oy0, { pressed = expanded }) then s.expanded[k.name] = not expanded end
        if W.tbutton("默认", bx, y + 10 + oy0, { disabled = not modified }) then call("reset_sculpt_key", { name = k.name }) end
        W.tooltip(L.f("恢复为 mod 默认值 %.2f", k.default or 0), bx, y + 10 + oy0, bw, 22)
    end
    if expanded and not ext and not k.held_by then
        local oy = y + rh
        for i, p in ipairs(k.parts) do
            local ov = k.overrides[p]
            D.rect(x + 16, oy, 1, 30, C.line)
            D.text_mid(k.part_labels and k.part_labels[i] or p, x + 26, oy, 30, ov ~= nil and C.text or C.muted, W.small(), nw - 30)
            local ch, v = W.slider("ov:" .. k.name .. "|" .. p, x + nw, oy + 2, ax - x - nw - 12, 26, ov or k.value,
                k.range[1], k.range[2], { step = 0.01, fmt = "%.2f" })
            if ch then call("set_sculpt_override", { name = k.name, part = p, value = v }) end
            if W.tbutton("跟随合并值", ax - 12, oy + 4, { disabled = ov == nil }) then
                call("set_sculpt_override", { name = k.name, part = p })
            end
            oy = oy + 30
        end
    end
    return h
end

-- one key of option oi of group g: its fixed value there, 移出
local function group_key_row(ctx, g, oi, k, x, y, w)
    local call = ctx.call
    local h = 30
    if not visible(y, h) then return h end
    local nw = max(150, w * 0.34)
    D.rect(x + 16, y, 1, h, C.line)
    local tw = D.text_mid(k.label or k.name, x + 26, y, h, k.missing and C.faint or C.text, W.small(), nw - 30)
    if k.label then W.tooltip(L.f("形态键名：%s", k.name), x, y, nw, h) end
    -- an expression key still moves with the expression on top of its fixed value
    if k.mixed then W.chip("与表情冲突", x + 30 + tw, y + 5, C.warn, 20)
    elseif k.missing then D.text_mid("身上的部件没有这个形态键", x + 34 + tw, y, h, C.faint, W.small()) end
    local rw = D.measure(W.small(), "移出") + 22
    local ch, v = W.slider("kg:" .. g.name .. ":" .. oi .. ":" .. k.name, x + nw, y + 2, w - nw - rw - 14, 26, k.value, 0, ctx.st.settings.sculpt_max or 1,
        { step = 0.01, fmt = "%.2f" })
    if ch then call("key_group_set_key", { group = g.name, option = oi, name = k.name, value = v }) end
    if W.tbutton("移出", x + w - rw - 2, y + 4) then
        call("key_group_unassign", { group = g.name, option = oi, name = k.name })
    end
    W.tooltip("移出这个选项；不在本组其他选项里的形态键离开键组并保留当前值", x + w - rw - 2, y + 4, rw, 22)
    return h
end

-- the key groups of the loaded preset, above the part groups: each switches between its options
local function key_groups(ctx, x, y, w)
    local st, call, s = ctx.st, ctx.call, ctx.state
    local sc = st.sculpt
    local list = sc.key_groups or {}
    local cy = y
    local open = not s.collapsed["\0key_groups"]
    local clicked, hh = W.header("键组", x, cy, w, open, L.f("%d 组", #list))
    if clicked then s.collapsed["\0key_groups"] = open end
    cy = cy + hh + 2
    if not open then return cy - y end
    s.kg_edit = s.kg_edit or {}
    s.kg_search, s.kg_items = s.kg_search or {}, s.kg_items or {}
    -- key name -> the group holding it
    local group_of_key = {}
    for _, g in ipairs(list) do
        for _, o in ipairs(g.options) do for _, k in ipairs(o.keys) do group_of_key[k.name] = g.name end end
    end
    local f = W.small()
    local function ask_name(title, text, submit)
        W.start_text(s, "kg_form", { title = title, text = text or "", on_submit = submit })
    end
    for gi, g in ipairs(list) do
        local editing = s.kg_edit[g.name]
        local nw = max(150, w * 0.34)
        if visible(cy, 34) then
            D.text_mid(g.name, x + 10, cy + 3, 28, C.text, W.body(), nw - 16)
            local ew = D.measure(f, editing and "完成" or "编辑") + 22
            if W.tbutton(editing and "完成" or "编辑", x + w - ew - 2, cy + 6, { pressed = editing }) then
                s.kg_edit[g.name] = not editing
            end
            -- 关 + the option names; a dropdown when they do not fit
            local labels = { L.tr("关") }
            local need = D.measure(f, labels[1]) + 28
            for i, o in ipairs(g.options) do
                labels[i + 1] = L.f("%d %s", i, o.name)
                need = need + D.measure(f, labels[i + 1]) + 28
            end
            local room = w - nw - ew - 12
            if need <= room then
                local bx = x + nw
                for i, label in ipairs(labels) do
                    local c, bw = W.tbutton(label, bx, cy + 6, { pressed = g.value == i - 1 })
                    if c and g.value ~= i - 1 then call("key_group_set", { group = g.name, value = i - 1 }) end
                    bx = bx + bw + 6
                end
            else
                local c, i = W.select("kg_sel:" .. g.name, x + nw, cy + 3, min(room, 260), 28, labels, g.value + 1)
                if c and i then call("key_group_set", { group = g.name, value = i - 1 }) end
            end
        end
        cy = cy + 34
        if editing then
            local bx = x + 16
            local full = #g.options >= (sc.max_options or 8)
            local c1, b1 = W.tbutton("新增选项", bx, cy + 4, { disabled = full })
            if c1 then
                ask_name(L.f("键组「%s」的新选项", g.name), L.f("选项 %d", #g.options + 1), function(name)
                    call("key_group_option_add", { group = g.name, name = name })
                end)
            end
            if full then W.tooltip(L.f("一个键组最多 %d 个选项", sc.max_options or 8), bx, cy + 4, b1, 22) end
            bx = bx + b1 + 6
            local c2, b2 = W.tbutton("重命名", bx, cy + 4)
            if c2 then
                ask_name("重命名键组", g.name, function(name)
                    if call("key_group_rename", { group = g.name, name = name }) then
                        s.kg_edit[name], s.kg_edit[g.name] = true, nil
                    end
                end)
            end
            bx = bx + b2 + 6
            local c3, b3 = W.tbutton("删除键组", bx, cy + 4, { kind = "danger" })
            if c3 then call("key_group_delete", { group = g.name }) end
            W.tooltip("删除这个键组，里面的形态键回到下面的列表并保留当前值", bx, cy + 4, b3, 22)
            cy = cy + 30
            for oi, o in ipairs(g.options) do
                if visible(cy, 30) then
                    D.rect(x + 16, cy, 1, 30, C.line)
                    D.text_mid(L.f("%d %s", oi, o.name), x + 26, cy, 30, g.value == oi and C.brass or C.muted, W.body(),
                        w * 0.3)
                    local rx = x + w - 2
                    local function rbtn(label, opt)
                        local bw = D.measure(f, label) + 22
                        rx = rx - bw
                        local c = W.tbutton(label, rx, cy + 4, opt)
                        rx = rx - 6
                        return c, bw
                    end
                    if rbtn("删除", { kind = "danger" }) then call("key_group_option_delete", { group = g.name, option = oi }) end
                    if rbtn("重命名") then
                        ask_name("重命名选项", o.name, function(name)
                            call("key_group_option_rename", { group = g.name, option = oi, name = name })
                        end)
                    end
                    local ca, ba = rbtn("收入已修改的键")
                    if ca then
                        if call("key_group_assign", { group = g.name, option = oi, names = "modified" }) then ctx.toast("info", L.f("已收入选项「%s」", o.name)) end
                    end
                    W.tooltip("把下面列表里改过的形态键按当前值放进这个选项", rx + 6, cy + 4, ba, 22)
                end
                cy = cy + 30
                if #o.keys == 0 then
                    if visible(cy, 26) then
                        D.text_mid("还没有形态键：先在下面调好，再点「收入已修改的键」，或用下面的搜索框添加",
                            x + 26, cy, 26, C.faint, W.small(), w - 40)
                    end
                    cy = cy + 26
                end
                for _, k in ipairs(o.keys) do cy = cy + group_key_row(ctx, g, oi, k, x + 10, cy, w - 10) end
                -- any key outside the other groups, including ones another option of this group uses
                local items = {}
                local here = {}
                for _, k in ipairs(o.keys) do here[k.name] = true end
                for _, item in ipairs(W.shape_key_items(sc, s.kg_items)) do
                    local owner = group_of_key[item.value]
                    if not here[item.value] and (owner == nil or owner == g.name) then items[#items + 1] = item end
                end
                local add, name, ah = W.search_select(s.kg_search, "kg_add:" .. g.name .. ":" .. oi, x + 36, cy + 2,
                    min(320, w * 0.5), items, nil, { placeholder = "添加形态键…", empty = "没有可添加的形态键" })
                if add and name then call("key_group_assign", { group = g.name, option = oi, names = { name } }) end
                cy = cy + ah + 2
            end
            cy = cy + 4
        end
    end
    if #list == 0 and visible(cy, 26) then
        D.text_mid("键组用一个整数在几组形态键之间切换，比如几种发型。", x + 10, cy, 26, C.faint, W.small(), w - 140)
    end
    local nb = D.measure(f, "新建键组") + 22
    if W.tbutton("新建键组", x + w - nb - 2, cy + 2) then
        ask_name("新键组的名称", L.f("键组 %d", #list + 1), function(name)
            if call("key_group_new", { name = name }) then s.kg_edit[name] = true end
        end)
    end
    cy = cy + 30
    cy = cy + W.text_form(s, "kg_form", "kg_name", x, cy, w)
    return cy - y + 6
end

function Page.draw(ctx, x, y, w)
    local st, s = ctx.st, ctx.state
    s.expanded = s.expanded or {}
    s.collapsed = s.collapsed or {}
    local sc = st.sculpt
    local cy = y + toolbar(ctx, x, y, w) + 8
    if not sc.scan then
        D.text("点「扫描装备」读取身上部件的形态键。", x, cy, C.muted, W.body())
        return cy + 30 - y
    end
    cy = cy + key_groups(ctx, x, cy, w)
    local filter = (s.filter or ""):lower()
    local shown = 0
    -- "hide non-preset keys" only means something when some key is named by a preset
    local any_preset = false
    for _, k in ipairs(sc.keys or {}) do if k.in_preset then any_preset = true; break end end
    local hide_np = s.hide_unpreset == true and any_preset
    for _, g in ipairs(sc.groups or {}) do
        local rows = {}
        -- section titles (display only): shown above the first listed key of the section, not
        -- while searching
        local section, shown_section = nil, nil
        for _, i in ipairs(g.key_indices) do
            local k = sc.keys[i]
            if k.section then section = k.section end
            local mod = abs(k.value - (k.default or 0)) > 1e-6
            -- a search finds every key, whatever is hidden
            local ok
            if filter ~= "" then
                ok = k.name:lower():find(filter, 1, true) or (k.label and k.label:lower():find(filter, 1, true))
            else
                ok = not (s.hide_expression and k.mixed) and not (hide_np and not k.in_preset)
                    and not (s.hide_held and k.held_by)
            end
            ok = ok and (not s.only_modified or mod)
            if ok then
                if filter == "" and section and section ~= shown_section then
                    rows[#rows + 1] = { head = section }
                    shown_section = section
                end
                rows[#rows + 1] = k
            end
        end
        local nkeys = 0
        for _, k in ipairs(rows) do if not k.head then nkeys = nkeys + 1 end end
        if nkeys > 0 then
            local open = not s.collapsed[g.key] or filter ~= ""
            -- a named part keeps its id next to the count (binding files are named by it)
            local stat = g.name ~= g.key and L.f("%s · %d 项", g.key, nkeys) or L.f("%d 项", nkeys)
            local clicked, hh = W.header(g.name, x, cy, w, open, stat)
            if clicked then s.collapsed[g.key] = open end
            cy = cy + hh + 2
            if open then
                for _, k in ipairs(rows) do
                    if k.head then
                        D.text(k.head, x + 12, cy + 6, C.faint, W.small(), w - 24)
                        cy = cy + 24
                    else
                        cy = cy + key_row(ctx, k, x, cy, w)
                    end
                end
            end
            shown = shown + nkeys
        end
    end
    if shown == 0 then D.text("没有匹配的形态键。", x, cy + 4, C.muted, W.body()); cy = cy + 30 end
    return cy - y
end

return Page
