-- ShapeKeySystem panel, basic page "捏脸": merged sculpt keys with sliders, search, per-part
-- values, undo / redo, compare with the initial (mod default) values, save (and bind) a sculpt preset.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")

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
    local info = scan and string.format("%d 个部件 · %d 项（已合并同名，%d 项由表情驱动）", #(scan.parts or {}), scan.keys or 0,
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
        labels[i] = e.name .. W.default_suffix(ctx, e.name, st.presets.binding and st.presets.binding.sculpt)
            .. (e.folder and "" or "（通用）")
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
                if name ~= "" and call("save_sculpt", { name = name, general = general }) then ctx.toast("info", "已保存：" .. name) end
            end })
    end
    -- 保存: your own config is overwritten in place; a mod's (read-only) or none asks for a name
    local c1, b1 = W.button("保存", bx, cy + 8, nil, 28, { kind = sc.dirty and "primary" or nil,
        disabled = not sc.scan or (own and not sc.dirty) })
    if c1 then
        if own then
            if call("save_sculpt", { name = preset.name, general = preset.folder == nil }) then ctx.toast("info", "已保存：" .. preset.name) end
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
        D.text_mid("删除捏脸配置「" .. pd.name .. "」？", x + 10, cy + 4, 28, C.warn, W.body(), w - 200)
        if W.button("删除", x + w - 160, cy + 4, 70, 28, { kind = "danger" }) then call("confirm_delete") end
        if W.button("取消", x + w - 82, cy + 4, 70, 28, { kind = "ghost" }) then call("cancel_delete") end
        cy = cy + 44
    end

    -- the action buttons go to a second row when they do not fit beside the filters
    local part = primary_part(st)
    local ab_label = sc.ab_preview and "正在看：初始" or "对比初始"
    local f = W.body()
    local sw = min(200, w * 0.28)
    local left_w = sw + 12 + D.measure(f, "只看已修改") + 50 + D.measure(f, "显示表情通道") + 50 + D.measure(f, "隐藏非预设通道") + 50
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
    local c2, v2, w2 = W.toggle("显示表情通道", bx, cy + 8, s.show_locked == true)
    if c2 then s.show_locked = v2 end
    bx = bx + w2 + 12
    -- keys no preset names (whole parts like a leg mesh's corrective keys) hidden by default
    local c3, v3, w3 = W.toggle("隐藏非预设通道", bx, cy + 8, s.hide_unpreset ~= false)
    if c3 then s.hide_unpreset = v3 end
    W.tooltip("只显示 mod 自带或当前捏脸配置里用到的形态键（改过的键总会显示）", bx, cy + 8, w3, 28)
    bx = bx + w3 + 12
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
    if k.mixed then sub[#sub + 1] = "表情叠加" end
    if multi then sub[#sub + 1] = table.concat(k.part_labels or k.parts, " · ") end
    if has_ovr then sub[#sub + 1] = "有部件单独值" end
    local h = (#sub > 0 and 42 or 34) + nparts * 30
    if not visible(y, h) then return h end
    local modified = abs(k.value - (k.default or 0)) > 1e-6
    local rh = (#sub > 0) and 42 or 34
    if modified then D.rect(x, y + 2, 2, rh - 4, C.brass) end
    local nw = max(150, w * 0.34)
    if #sub > 0 then
        D.text(k.name, x + 10, y + 4, C.text, W.body(), nw - 16)
        D.text(table.concat(sub, " · "), x + 10, y + 23, has_ovr and C.brass or C.faint, W.small(), nw - 16)
    else
        D.text_mid(k.name, x + 10, y + 3, 28, C.text, W.body(), nw - 16)
    end
    local oy0 = (rh - 42) / 2   -- controls stay centred on the shorter row
    local ax = x + w - 106
    local ext = W.external_owner(ctx.st, k.name)
    if ext then
        local cw = W.chip("由 " .. ext .. " 控制", x + nw, y + 11 + oy0, C.brass)
        D.text_mid(string.format("%.2f", k.value), x + nw + cw + 10, y + 7 + oy0, 28, C.faint, W.mono())
        if W.tbutton("收回", x + w - 42, y + 10 + oy0) then call("external_release", { owner = ext, name = k.name }) end
        W.tooltip("另一个插件正在控制这个形态键；收回后恢复捏脸的值", x + w - 42, y + 10 + oy0, 40, 22)
    else
        local ch, v = W.slider("sk:" .. k.name, x + nw, y + 7 + oy0, ax - x - nw - 12, 28, k.value, k.range[1], k.range[2],
            { step = 0.01, fmt = "%.2f" })
        if ch then call("set_sculpt_key", { name = k.name, value = v }) end
        if multi and W.tbutton("按部件", ax, y + 10 + oy0, { pressed = expanded }) then s.expanded[k.name] = not expanded end
        if W.tbutton("默认", x + w - 42, y + 10 + oy0, { disabled = not modified }) then call("reset_sculpt_key", { name = k.name }) end
        W.tooltip(string.format("恢复为 mod 默认值 %.2f", k.default or 0), x + w - 42, y + 10 + oy0, 40, 22)
    end
    if expanded and not ext then
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
    local filter = (s.filter or ""):lower()
    local shown = 0
    -- "hide non-preset keys" only means something when some key is named by a preset
    local any_preset = false
    for _, k in ipairs(sc.keys or {}) do if k.in_preset then any_preset = true; break end end
    local hide_np = s.hide_unpreset ~= false and any_preset
    for _, g in ipairs(sc.groups or {}) do
        local rows = {}
        for _, i in ipairs(g.key_indices) do
            local k = sc.keys[i]
            local mod = abs(k.value - (k.default or 0)) > 1e-6
            -- expression keys: listed when asked for, or when they carry a sculpt value
            local ok = (s.show_locked or not k.mixed or mod or k.value > 0)
                and (not hide_np or k.in_preset or mod)
                and (filter == "" or k.name:lower():find(filter, 1, true))
                and (not s.only_modified or mod)
            if ok then rows[#rows + 1] = k end
        end
        if #rows > 0 then
            local open = not s.collapsed[g.key] or filter ~= ""
            -- a named part keeps its id next to the count (binding files are named by it)
            local stat = g.name ~= g.key and string.format("%s · %d 项", g.key, #rows) or string.format("%d 项", #rows)
            local clicked, hh = W.header(g.name, x, cy, w, open, stat)
            if clicked then s.collapsed[g.key] = open end
            cy = cy + hh + 2
            if open then
                for _, k in ipairs(rows) do cy = cy + key_row(ctx, k, x, cy, w) end
            end
            shown = shown + #rows
        end
    end
    if shown == 0 then D.text("没有匹配的形态键。", x, cy + 4, C.muted, W.body()); cy = cy + 30 end
    return cy - y
end

return Page
