-- ShapeKeySystem panel, advanced page "驱动": driver groups whose rows drive shape keys or hold
-- variables by a waveform or a formula (Drivers.lua). Drawing only submits `drivers`; values and
-- errors come from state.drivers.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")
local I = require("ShapeKeySystem_UI.Input")

local Page = {}
local C = T.c
local min, max = math.min, math.max

local LW = 44        -- slider label column
local METER_W = 90

local function patch(call, g, r, p) call("drivers", { op = "patch", index = g, row = r, patch = p }) end

-- label | slider in a column of width cw; returns the row height
local function slider(id, label, value, lo, hi, opt, x, y, cw, on_change)
    D.text_mid(label, x, y, 28, C.text, W.small(), LW - 6)
    local ch, v = W.slider(id, x + LW, y, cw - LW, 28, value, lo, hi, opt)
    if ch then on_change(v) end
end

-- one row of group g at y; returns its height
local function row_block(ctx, g, r, row, v, rx, y, rw)
    local call = ctx.call
    local dv = ctx.st.drivers
    local id = g .. ":" .. r
    local cy = y

    -- kind | key picker or variable name | waveform | live value | up | delete
    local kind_w, wave_w, del_w = 90, 130, 56
    local up_w = r > 1 and (D.measure(W.small(), L.tr("上移")) + 22) or 0
    local nx = rx + kind_w + 12
    local nw = max(140, rw - kind_w - wave_w - METER_W - 40 - up_w - del_w - 60)
    local wx = nx + nw + 12
    local mx = wx + wave_w + 12
    local klabels, kcur = {}, 1
    for j, k in ipairs(dv.kinds) do
        klabels[j] = dv.kind_names[k]
        if k == row.kind then kcur = j end
    end
    local wlabels, wcur = {}, 1
    for j, wv in ipairs(dv.waves) do
        wlabels[j] = dv.wave_names[wv]
        if wv == row.wave then wcur = j end
    end
    local c1, k1 = W.select("drv_kind:" .. id, rx, cy, kind_w, 28, klabels, kcur)
    if c1 then patch(call, g, r, { kind = dv.kinds[k1] }) end
    local c2, j2 = W.select("drv_wave:" .. id, wx, cy, wave_w, 28, wlabels, wcur)
    if c2 then
        local p = { wave = dv.waves[j2] }
        -- switching to a formula starts from the waveform it replaces
        if p.wave == "expr" and (row.expr or "") == "" then p.expr = v.formula end
        patch(call, g, r, p)
    end
    local value = v.value or 0
    W.meter(mx, cy + 10, METER_W, 9, max(0, min(1, value)), row.kind == "var" and C.muted or C.signal)
    D.text_mid(string.format("%.2f", value), mx + METER_W + 6, cy, 28, C.muted, W.small())
    if r > 1 and W.tbutton("上移", rx + rw - del_w - up_w - 8, cy) then
        call("drivers", { op = "move_row", index = g, row = r, to = r - 1 })
    end
    if W.button("删除", rx + rw - del_w, cy, del_w, 28, { kind = "danger", font = W.small() }) then
        call("drivers", { op = "remove_row", index = g, row = r })
    end
    local kh = 28
    if row.kind == "var" then
        W.text_box("drv_var:" .. id, nx, cy, nw, 28, row.var, "变量名，例如 u",
            function(t) patch(call, g, r, { var = t }) end)
    else
        ctx.state.search = ctx.state.search or {}
        local ch, name, h = W.search_select(ctx.state.search, "drv_key:" .. id, nx, cy, nw, W.shape_key_items(ctx.st.sculpt, ctx.state),
            row.key ~= "" and row.key or nil, { selected = row.key, placeholder = "选择或输入形态键名称…",
                empty = "没有匹配的已扫描形态键，可保留输入的名称",
                on_query = function(t) patch(call, g, r, { key = t }) end })
        if ch then patch(call, g, r, { key = name }) end
        kh = h
    end
    cy = cy + max(34, kh)

    if row.wave ~= "expr" then
        local cw = (rw - 24) / 2
        local top = ctx.st.settings.sculpt_max or 1
        local x2 = rx + cw + 24
        slider("drv_period:" .. id, "周期", row.period, 0.1, 10, { step = 0.05, fmt = "%.2f s", value_w = 60 }, rx, cy, cw,
            function(nv) patch(call, g, r, { period = nv }) end)
        slider("drv_phase:" .. id, "相位", row.phase, 0, 1, { step = 0.01, fmt = "%.2f", value_w = 60 }, x2, cy, cw,
            function(nv) patch(call, g, r, { phase = nv }) end)
        cy = cy + 32
        slider("drv_lo:" .. id, "最低", row.lo, 0, top, { step = 0.01, fmt = "%.2f", value_w = 60 }, rx, cy, cw,
            function(nv) patch(call, g, r, { lo = nv }) end)
        slider("drv_hi:" .. id, "最高", row.hi, 0, top, { step = 0.01, fmt = "%.2f", value_w = 60 }, x2, cy, cw,
            function(nv) patch(call, g, r, { hi = nv }) end)
        cy = cy + 34
        local bw = D.measure(W.small(), L.tr("改为公式")) + 22
        D.text_mid(L.f("公式：%s", v.formula or ""), rx, cy, 22, C.faint, W.small(), rw - bw - 12)
        if W.tbutton("改为公式", rx + rw - bw, cy) then patch(call, g, r, { wave = "expr", expr = v.formula }) end
        cy = cy + 26
    else
        W.text_box("drv_expr:" .. id, rx, cy, rw, 28, row.expr, "输入公式，例如 0.5 + 0.5 * sin(t * 2)",
            function(t) patch(call, g, r, { expr = t }) end)
        cy = cy + 34
    end
    if v.err then
        D.text(L.f(v.err[1], v.err[2], v.err[3]), rx, cy, C.warn, W.small(), rw)
        cy = cy + 22
    elseif v.owner then
        D.text(v.owner == "?" and "这个形态键在本游戏不能写入" or L.f("被 %s 占用，暂不驱动", v.owner),
            rx, cy, C.warn, W.small(), rw)
        cy = cy + 22
    elseif v.dup then
        D.text(L.f("与第 %s 组第 %s 行是同一个形态键，未生效", v.dup[1], v.dup[2]), rx, cy, C.warn, W.small(), rw)
        cy = cy + 22
    end
    return cy - y
end

local function group_card(ctx, g, grp, vg, x, y, w)
    local call = ctx.call
    local dv = ctx.st.drivers
    -- the box goes under the content, so it takes the height the card had last frame
    local hs = ctx.state.card_h or {}
    ctx.state.card_h = hs
    W.panel_box(x, y, w, hs[g] or 120)
    local rx, rw = x + 12, w - 24
    local cy = y + 10

    -- groups start collapsed, keyed by the group table so removing one leaves the others as they were;
    -- a group added from this page opens
    local closed = ctx.state.closed
    if not closed then closed = setmetatable({}, { __mode = "k" }); ctx.state.closed = closed end
    if closed[grp] == nil then closed[grp] = ctx.state.open_new ~= g end
    local is_closed = closed[grp]
    D.icon_tri(rx + 4, cy + 14, 4, not is_closed, C.brass)
    if I.click(rx - 4, cy, 18, 28) then closed[grp] = not is_closed end
    rx, rw = rx + 16, rw - 16

    -- switch | name | (summary when collapsed) | add variable | add shape key | delete group
    local c1, on = W.toggle("", rx, cy, grp.enabled)
    if c1 then patch(call, g, nil, { enabled = on }) end
    local full = #grp.rows >= (dv.max_rows or 32)
    local del_w = D.measure(W.small(), L.tr("删除组")) + 22
    local bx = rx + rw - del_w
    if W.button("删除组", bx, cy, del_w, 28, { kind = "danger", font = W.small() }) then
        call("drivers", { op = "remove", index = g })
    end
    if not is_closed then
        for _, b in ipairs({ { "添加形态键", "out" }, { "添加变量", "var" } }) do
            local bw = D.measure(W.small(), L.tr(b[1])) + 22
            bx = bx - bw - 8
            if W.button(b[1], bx, cy, bw, 28, { font = W.small(), disabled = full }) then
                call("drivers", { op = "add_row", index = g, kind = b[2] })
            end
        end
    end
    local nw = max(120, min(240, bx - rx - 52))
    W.text_box("drv_name:" .. g, rx + 40, cy, nw, 28, grp.name, "组名（选填）",
        function(t) patch(call, g, nil, { name = t }) end)
    cy = cy + 36

    if is_closed then
        -- one line: how many rows, which keys they write, whether a row has an error
        local keys, err = {}, false
        for r, row in ipairs(grp.rows) do
            if row.kind == "out" and row.key ~= "" then keys[#keys + 1] = row.key end
            if (vg.rows[r] or {}).err then err = true end
        end
        local tx = rx + 40 + nw + 12
        local tw = max(0, bx - 8 - tx)
        local summary = err and L.f("%s 行，有错误", #grp.rows)
            or (#keys > 0 and L.f("%s 行，写入 %s", #grp.rows, table.concat(keys, ", ")) or L.f("%s 行", #grp.rows))
        D.text_mid(summary, tx, cy - 36, 28, err and C.warn or C.muted, W.small(), tw)
        W.tooltip(summary, tx, cy - 36, tw, 28)
        cy = cy - 4
        hs[g] = cy - y
        return cy - y
    end

    for r, row in ipairs(grp.rows) do
        if r > 1 then
            D.rect(rx, cy, rw, 1, C.line)
            cy = cy + 8
        end
        cy = cy + row_block(ctx, g, r, row, vg.rows[r] or {}, rx, cy, rw)
    end
    if #grp.rows == 0 then
        D.text("这个组还没有行。", rx, cy, C.faint, W.small(), rw)
        cy = cy + 22
    end
    cy = cy + 4
    hs[g] = cy - y
    return cy - y
end

function Page.draw(ctx, x, y, w)
    local dv = ctx.st.drivers
    if not dv or not dv.cfg then return 0 end
    local call = ctx.call
    local cy = y
    local c1, on, tw = W.toggle("启用驱动", x, cy, dv.cfg.enabled == true)
    if c1 then call("drivers", { op = "patch", patch = { enabled = on } }) end
    local full = #dv.cfg.groups >= (dv.max_groups or 32)
    -- with several characters the page lists the edited character's groups; the others keep running
    local ac = ctx.st.actors
    local actor = ac and ac.enabled and ac.selected or nil
    if W.button("添加驱动", x + tw + 24, cy, nil, 28, { kind = "primary", disabled = full }) then
        ctx.state.open_new = #dv.cfg.groups + 1
        call("drivers", { op = "add", actor = actor })
    end
    cy = cy + 36
    D.text("每个驱动组从上到下逐行计算：变量行算出一个值给下面的行用，形态键行把值写到形态键上。",
        x, cy, C.muted, W.small(), w)
    cy = cy + 22
    D.text("驱动优先于表情和捏脸；面捕或其他插件正在控制的形态键会先让给它们。", x, cy, C.muted, W.small(), w)
    cy = cy + 22
    D.text("t 是秒数，公式可以读上面各行的名称；比较 < <= > >= == != 得 1 或 0；rand(x) 在同一个整数内取同一个随机值",
        x, cy, C.faint, W.small(), w)
    cy = cy + 22
    D.text("osc / tri / saw / square / noise 以 1 为一个周期，输出 0–1", x, cy, C.faint, W.small(), w)
    cy = cy + 28
    local shown, others = 0, 0
    for g, grp in ipairs(dv.cfg.groups) do
        local mine = not actor or ((grp.actor ~= nil and grp.actor ~= "") and grp.actor or ac.player_id) == actor
        if mine then
            local vg = dv.groups[g] or { rows = {} }
            cy = cy + group_card(ctx, g, grp, vg, x, cy, w) + 10
            shown = shown + 1
        else
            others = others + 1
        end
    end
    if shown == 0 then
        D.text("还没有驱动。点「添加驱动」，选一个形态键和波形即可。", x, cy, C.faint, W.small(), w)
        cy = cy + 24
    end
    if others > 0 then
        D.text(L.f("其他角色还有 %s 组驱动，切换到那个角色可查看", others), x, cy, C.faint, W.small(), w)
        cy = cy + 24
    end
    return cy - y
end

return Page
