-- ShapeKeySystem panel, advanced page "驱动": shape keys driven by a waveform or a formula
-- (Drivers.lua). Drawing only submits `drivers`; values and errors come from state.drivers.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local min, max = math.min, math.max

local LW = 44        -- slider label column
local METER_W = 90

local function patch(call, i, p) call("drivers", { op = "patch", index = i, patch = p }) end

-- scanned shape key names for the key picker, once per sculpt state revision
local function key_items(ctx)
    local sc = ctx.st.sculpt
    local s = ctx.state
    if s.keys_rev == sc.rev and s.keys then return s.keys end
    local items, seen = {}, {}
    for _, k in ipairs(sc.keys or {}) do
        if not seen[k.name] then
            seen[k.name] = true
            local label = (k.label and k.label ~= k.name) and L.f("%s（%s）", L.tr(k.label), k.name) or k.name
            items[#items + 1] = { value = k.name, label = label, search = label .. " " .. k.name }
        end
    end
    table.sort(items, function(a, b) return a.value < b.value end)
    s.keys, s.keys_rev = items, sc.rev
    return items
end

-- label | slider in a column of width cw; returns the row height
local function slider(id, label, value, lo, hi, opt, x, y, cw, on_change)
    D.text_mid(label, x, y, 28, C.text, W.small(), LW - 6)
    local ch, v = W.slider(id, x + LW, y, cw - LW, 28, value, lo, hi, opt)
    if ch then on_change(v) end
end

local function driver_card(ctx, i, it, v, x, y, w)
    local call = ctx.call
    local dv = ctx.st.drivers
    -- the box goes under the content, so it takes the height the card had last frame
    local hs = ctx.state.card_h or {}
    ctx.state.card_h = hs
    W.panel_box(x, y, w, hs[i] or 120)
    local rx, rw = x + 12, w - 24
    local cy = y + 10

    -- switch | key picker | waveform | live value | delete
    local c1, on = W.toggle("", rx, cy, it.enabled)
    if c1 then patch(call, i, { enabled = on }) end
    local kx = rx + 40
    local del_w = 56
    local wave_w = 130
    -- key | 12 | wave | 12 | meter + value text (40) | 12 | delete
    local kw = max(160, rw - 40 - wave_w - METER_W - 40 - del_w - 36)
    local wx = kx + kw + 12
    local labels, cur = {}, 1
    for j, wv in ipairs(dv.waves) do
        labels[j] = dv.wave_names[wv]
        if wv == it.wave then cur = j end
    end
    local c2, j2 = W.select("drv_wave:" .. i, wx, cy, wave_w, 28, labels, cur)
    if c2 then
        local p = { wave = dv.waves[j2] }
        -- switching to a formula starts from the waveform it replaces
        if p.wave == "expr" and (it.expr or "") == "" then p.expr = v.formula end
        patch(call, i, p)
    end
    local mx = wx + wave_w + 12
    W.meter(mx, cy + 10, METER_W, 9, min(1, v.value or 0), C.signal)
    D.text_mid(string.format("%.2f", v.value or 0), mx + METER_W + 6, cy, 28, C.muted, W.small())
    if W.button("删除", rx + rw - del_w, cy, del_w, 28, { kind = "danger", font = W.small() }) then
        call("drivers", { op = "remove", index = i })
    end
    ctx.state.search = ctx.state.search or {}
    local ch, name, kh = W.search_select(ctx.state.search, "drv_key:" .. i, kx, cy, kw, key_items(ctx),
        it.key ~= "" and it.key or nil, { selected = it.key, placeholder = "选择或输入形态键名称…",
            empty = "没有匹配的已扫描形态键，可保留输入的名称",
            on_query = function(t) patch(call, i, { key = t }) end })
    if ch then patch(call, i, { key = name }) end
    cy = cy + max(34, kh)

    if it.wave ~= "expr" then
        local cw = (rw - 24) / 2
        local top = ctx.st.settings.sculpt_max or 1
        local x2 = rx + cw + 24
        slider("drv_period:" .. i, "周期", it.period, 0.1, 10, { step = 0.05, fmt = "%.2f s", value_w = 60 }, rx, cy, cw,
            function(nv) patch(call, i, { period = nv }) end)
        slider("drv_phase:" .. i, "相位", it.phase, 0, 1, { step = 0.01, fmt = "%.2f", value_w = 60 }, x2, cy, cw,
            function(nv) patch(call, i, { phase = nv }) end)
        cy = cy + 32
        slider("drv_lo:" .. i, "最低", it.lo, 0, top, { step = 0.01, fmt = "%.2f", value_w = 60 }, rx, cy, cw,
            function(nv) patch(call, i, { lo = nv }) end)
        slider("drv_hi:" .. i, "最高", it.hi, 0, top, { step = 0.01, fmt = "%.2f", value_w = 60 }, x2, cy, cw,
            function(nv) patch(call, i, { hi = nv }) end)
        cy = cy + 34
        local bw = D.measure(W.small(), L.tr("改为公式")) + 22
        D.text_mid(L.f("公式：%s", v.formula or ""), rx, cy, 22, C.faint, W.small(), rw - bw - 12)
        if W.tbutton("改为公式", rx + rw - bw, cy) then patch(call, i, { wave = "expr", expr = v.formula }) end
        cy = cy + 26
    else
        W.text_box("drv_expr:" .. i, rx, cy, rw, 28, it.expr, "输入公式，例如 0.5 + 0.5 * sin(t * 2)",
            function(t) patch(call, i, { expr = t }) end)
        cy = cy + 34
        if v.err then
            D.text(L.f(v.err[1], v.err[2], v.err[3]), rx, cy, C.warn, W.small(), rw)
        else
            D.text("t 是秒数；osc / tri / saw / square / noise 以 1 为一个周期，输出 0–1", rx, cy, C.faint, W.small(), rw)
        end
        cy = cy + 22
    end

    if v.owner then
        D.text(v.owner == "?" and "这个形态键在本游戏不能写入" or L.f("被 %s 占用，暂不驱动", v.owner),
            rx, cy, C.warn, W.small(), rw)
        cy = cy + 22
    elseif v.dup then
        D.text(L.f("与第 %s 条驱动是同一个形态键，未生效", v.dup), rx, cy, C.warn, W.small(), rw)
        cy = cy + 22
    end
    cy = cy + 4
    hs[i] = cy - y
    return cy - y
end

function Page.draw(ctx, x, y, w)
    local dv = ctx.st.drivers
    if not dv or not dv.cfg then return 0 end
    local call = ctx.call
    local cy = y
    local c1, on, tw = W.toggle("启用驱动", x, cy, dv.cfg.enabled == true)
    if c1 then call("drivers", { op = "patch", patch = { enabled = on } }) end
    local full = #dv.cfg.items >= (dv.max_items or 32)
    -- with several characters the page lists the edited character's drivers; the others keep running
    local ac = ctx.st.actors
    local actor = ac and ac.enabled and ac.selected or nil
    if W.button("添加驱动", x + tw + 24, cy, nil, 28, { kind = "primary", disabled = full }) then
        call("drivers", { op = "add", actor = actor })
    end
    cy = cy + 36
    D.text("每条驱动让一个形态键按波形或公式随时间变化，优先于表情和捏脸；面捕或其他插件正在控制的形态键会先让给它们。",
        x, cy, C.muted, W.small(), w)
    cy = cy + 28
    local shown, others = 0, 0
    for i, it in ipairs(dv.cfg.items) do
        local mine = not actor or ((it.actor ~= nil and it.actor ~= "") and it.actor or ac.player_id) == actor
        if mine then
            local v = dv.items[i] or {}
            cy = cy + driver_card(ctx, i, it, v, x, cy, w) + 10
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
        D.text(L.f("其他角色还有 %s 条驱动，切换到那个角色可查看", others), x, cy, C.faint, W.small(), w)
        cy = cy + 24
    end
    return cy - y
end

return Page
