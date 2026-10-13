-- ShapeKeySystem panel, basic page "捏脸": merged sculpt keys with sliders, search, per-part
-- values, undo / redo, compare with the initial (mod default) values, save (and bind) a sculpt preset.

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
    local _, bw = W.button(L.t("sculpt.scan"), x + 10, cy + 8, nil, 28, { kind = "primary" })
    if _ then call("sculpt_scan") end
    local scan = sc.scan
    local info = scan and L.t("sculpt.scan_info", #(scan.parts or {}), scan.keys or 0,
        scan.expression_keys or 0) or L.t("sculpt.not_scanned")
    local force = L.t("sculpt.force")
    local tw = D.measure(W.body(), force) + 38
    D.text_mid(info, x + 22 + bw, cy + 8, 28, C.muted, W.small(), w - bw - tw - 50)
    local ch, v = W.toggle(force, x + w - tw - 10, cy + 8, sc.edit_mode)
    if ch then call("set_edit_mode", { on = v }) end
    W.tooltip(L.t("sculpt.force_tip"), x + w - tw - 10, cy + 8, tw, 28)
    cy = cy + 52

    -- sculpt preset: pick (loads it) or start a new one from the current values
    local pr = st.presets.sculpt or {}
    local labels, cur = {}, nil
    for i, e in ipairs(pr) do
        -- presets of this outfit's model are plain names; general ones say so
        labels[i] = e.name .. W.default_suffix(ctx, e.name, st.presets.binding and st.presets.binding.sculpt)
            .. (e.folder and "" or L.t("sculpt.general_suffix"))
        if sc.preset and sc.preset.name == e.name and sc.preset.folder == e.folder then cur = i end
    end
    local cfg_label = L.t("sculpt.config")
    local lw = D.measure(W.small(), cfg_label) + 22
    local preset = sc.preset
    local own = preset and preset.source == "user"
    local bnd = st.presets.binding
    -- the buttons right of the dropdown; when they do not fit (narrow window, longer English
    -- labels) the dropdown gives up width, and below 120 the buttons move to a second row
    local bf = W.body()
    local dw0 = W.default_button_width(ctx, preset and preset.name, bnd and bnd.sculpt)
    local need = (dw0 > 0 and dw0 + 16 or 0) + D.measure(bf, L.t("common.save")) + 28 + D.measure(bf, L.t("sculpt.save_as")) + 28
        + ((own and not sc.dirty) and (D.measure(bf, L.t("common.delete")) + 28) or 0)
    local two_rows = lw + 130 + need > w - 10
    local row_h = two_rows and 82 or 44
    W.panel_box(x, cy, w, row_h)
    D.text_mid(cfg_label, x + 12, cy + 8, 28, C.muted, W.small())
    local sel_w = two_rows and min(260, w - lw - 12) or max(120, min(260, w * 0.3, w - lw - 20 - need))
    local chp, ip = W.select("sculpt_preset", x + lw, cy + 8, sel_w, 28, labels, cur,
        { placeholder = #pr > 0 and L.t("sculpt.none_selected") or L.t("sculpt.no_configs") })
    if chp and pr[ip] then call("load_sculpt", { name = pr[ip].name, folder = pr[ip].folder }) end
    local bx = two_rows and (x + 10) or (x + lw + sel_w + 10)
    local by = two_rows and (cy + 46) or (cy + 8)
    local dw = W.default_button(ctx, bx, by, "sculpt", preset and preset.name, bnd and bnd.sculpt)
    if dw > 0 then bx = bx + dw + 16 end
    local function save_as(title)
        ctx.prompt({ title = title, text = preset and preset.name or "",
            extra = { label = L.t("sculpt.save_general"), value = false },
            on_submit = function(name, general)
                if name ~= "" and call("save_sculpt", { name = name, general = general }) then ctx.toast("info", { k = "common.saved", args = { name } }) end
            end })
    end
    -- 保存: your own config is overwritten in place; a mod's (read-only) or none asks for a name
    local c1, b1 = W.button(L.t("common.save"), bx, by, nil, 28, { kind = sc.dirty and "primary" or nil,
        disabled = not sc.scan or (own and not sc.dirty) })
    if c1 then
        if own then
            if call("save_sculpt", { name = preset.name, general = preset.folder == nil }) then ctx.toast("info", { k = "common.saved", args = { preset.name } }) end
        else
            save_as(preset and L.t("sculpt.save_new_title") or L.t("sculpt.save_title"))
        end
    end
    bx = bx + b1 + 6
    local c2, b2 = W.button(L.t("sculpt.save_as"), bx, by, nil, 28, { disabled = not sc.scan })
    if c2 then save_as(L.t("common.save_as")) end
    bx = bx + b2 + 6
    if own and not sc.dirty then
        local c3, b3 = W.button(L.t("common.delete"), bx, by, nil, 28, { kind = "danger" })
        if c3 then call("request_delete", { kind = "sculpt", name = preset.name, folder = preset.folder }) end
        bx = bx + b3 + 6
    end
    cy = cy + row_h + 8
    local pd = st.presets.pending_delete
    if pd and pd.kind == "sculpt" then
        D.rrect(x, cy, w, 36, 3, C.ink); D.outline(x, cy, w, 36, 3, 1, C.warn)
        D.text_mid(L.t("sculpt.delete_confirm", pd.name), x + 10, cy + 4, 28, C.warn, W.body(), w - 200)
        if W.button(L.t("common.delete"), x + w - 160, cy + 4, 70, 28, { kind = "danger" }) then call("confirm_delete") end
        if W.button(L.t("common.cancel"), x + w - 82, cy + 4, 70, 28, { kind = "ghost" }) then call("cancel_delete") end
        cy = cy + 44
    end

    -- flow layout: the search box, then the toggles while they fit (the rest on the next row); the
    -- action buttons, right-aligned, go to a row of their own when they do not fit after the toggles
    local part = primary_part(st)
    local ab_label = sc.ab_preview and L.t("sculpt.ab_on") or L.t("sculpt.ab_off")
    local l_mod, l_locked, l_unpreset = L.t("sculpt.only_modified"), L.t("sculpt.show_locked"), L.t("sculpt.hide_unpreset")
    local l_zero, l_reset, l_redo, l_undo = L.t("sculpt.zero"), L.t("sculpt.reset"), L.t("sculpt.redo"), L.t("sculpt.undo")
    local f = W.body()
    local sw = min(200, w * 0.28)
    local right_w = 0
    for _, l in ipairs({ ab_label, l_zero, l_reset, l_redo, l_undo }) do right_w = right_w + D.measure(f, l) + 28 end
    local pos, row, fx = {}, 0, x + 10 + sw + 12
    for i, l in ipairs({ l_mod, l_locked, l_unpreset }) do
        local tw = D.measure(f, l) + 38
        if fx + tw > x + w - 10 and fx > x + 10 then row = row + 1; fx = x + 10 end
        pos[i] = { fx, cy + 8 + row * 38 }
        fx = fx + tw + 12
    end
    local brow = (fx + right_w <= x + w - 10) and row or row + 1
    W.panel_box(x, cy, w, 44 + brow * 38)
    if W.text_box(x + 10, cy + 8, sw, 28, s.filter, L.t("sculpt.search")) then
        ctx.prompt({ title = L.t("sculpt.search_title"), text = s.filter or "", live = true,
                     on_change = function(t) s.filter = t end, on_submit = function(t) s.filter = t end })
    end
    local c1, v1 = W.toggle(l_mod, pos[1][1], pos[1][2], s.only_modified == true)
    if c1 then s.only_modified = v1 end
    local c2, v2 = W.toggle(l_locked, pos[2][1], pos[2][2], s.show_locked == true)
    if c2 then s.show_locked = v2 end
    -- keys no preset names (whole parts like a leg mesh's corrective keys) hidden by default
    local c3, v3, w3 = W.toggle(l_unpreset, pos[3][1], pos[3][2], s.hide_unpreset ~= false)
    if c3 then s.hide_unpreset = v3 end
    W.tooltip(L.t("sculpt.hide_unpreset_tip"), pos[3][1], pos[3][2], w3, 28)
    -- right side
    local rx = x + w - 10
    local ry = cy + 8 + brow * 38
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
    W.tooltip(L.t("sculpt.ab_tip"), rx + 6, ry, D.measure(f, ab_label) + 22, 28)
    -- 归零 / 重置: every key to 0 / back to the mod default, one undo step each (red: they touch everything)
    if rbtn(l_zero, { kind = "danger", disabled = not sc.scan }) then call("zero_sculpt_all") end
    W.tooltip(L.t("sculpt.zero_tip"), rx + 6, ry, D.measure(f, l_zero) + 22, 28)
    if rbtn(l_reset, { kind = "danger", disabled = not sc.scan }) then call("reset_sculpt_all") end
    W.tooltip(L.t("sculpt.reset_tip"), rx + 6, ry, D.measure(f, l_reset) + 22, 28)
    if rbtn(l_redo, { kind = "ghost", disabled = not sc.can_redo }) then call("sculpt_redo") end
    if rbtn(l_undo, { kind = "ghost", disabled = not sc.can_undo }) then call("sculpt_undo") end
    cy = cy + 52 + brow * 38

    if sc.dirty then
        D.text(L.t("sculpt.unsaved"), x + 2, cy, C.warn, W.small(), w)
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
    if k.mixed then sub[#sub + 1] = L.t("sculpt.mixed") end
    if multi then sub[#sub + 1] = table.concat(k.parts, " · ") end
    if has_ovr then sub[#sub + 1] = L.t("sculpt.has_overrides") end
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
    -- row buttons right-aligned (longer English labels grow to the left); x of a button, its width
    local function right_btn(label)
        local bw = D.measure(W.small(), label) + 22
        return x + w - 42 - max(0, bw - 46), bw
    end
    local l_default, l_per_part = L.t("sculpt.default"), L.t("sculpt.per_part")
    local dx, dw = right_btn(l_default)
    local ax = min(x + w - 106, dx - 6 - (D.measure(W.small(), l_per_part) + 22))
    local ext = W.external_owner(ctx.st, k.name)
    if ext then
        local cw = W.chip(L.t("common.held_by", ext), x + nw, y + 11 + oy0, C.brass)
        D.text_mid(string.format("%.2f", k.value), x + nw + cw + 10, y + 7 + oy0, 28, C.faint, W.mono())
        local tb = L.t("common.take_back")
        local tx, tw = right_btn(tb)
        if W.tbutton(tb, tx, y + 10 + oy0) then call("external_release", { owner = ext, name = k.name }) end
        W.tooltip(L.t("sculpt.external_tip"), tx, y + 10 + oy0, tw, 22)
    else
        local ch, v = W.slider("sk:" .. k.name, x + nw, y + 7 + oy0, ax - x - nw - 12, 28, k.value, k.range[1], k.range[2],
            { step = 0.01, fmt = "%.2f" })
        if ch then call("set_sculpt_key", { name = k.name, value = v }) end
        if multi and W.tbutton(l_per_part, ax, y + 10 + oy0, { pressed = expanded }) then s.expanded[k.name] = not expanded end
        if W.tbutton(l_default, dx, y + 10 + oy0, { disabled = not modified }) then call("reset_sculpt_key", { name = k.name }) end
        W.tooltip(L.t("sculpt.default_tip", k.default or 0), dx, y + 10 + oy0, dw, 22)
    end
    if expanded and not ext then
        local oy = y + rh
        for _, p in ipairs(k.parts) do
            local ov = k.overrides[p]
            D.rect(x + 16, oy, 1, 30, C.line)
            D.text_mid(p, x + 26, oy, 30, ov ~= nil and C.text or C.muted, W.small(), nw - 30)
            local ch, v = W.slider("ov:" .. k.name .. "|" .. p, x + nw, oy + 2, ax - x - nw - 12, 26, ov or k.value,
                k.range[1], k.range[2], { step = 0.01, fmt = "%.2f" })
            if ch then call("set_sculpt_override", { name = k.name, part = p, value = v }) end
            if W.tbutton(L.t("sculpt.follow_merged"), ax - 12, oy + 4, { disabled = ov == nil }) then
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
        D.text(L.t("sculpt.scan_hint"), x, cy, C.muted, W.body(), w)
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
            local clicked, hh = W.header(g.name, x, cy, w, open, L.t("sculpt.count", #rows))
            if clicked then s.collapsed[g.key] = open end
            cy = cy + hh + 2
            if open then
                for _, k in ipairs(rows) do cy = cy + key_row(ctx, k, x, cy, w) end
            end
            shown = shown + #rows
        end
    end
    if shown == 0 then D.text(L.t("sculpt.no_match"), x, cy + 4, C.muted, W.body(), w); cy = cy + 30 end
    return cy - y
end

return Page
