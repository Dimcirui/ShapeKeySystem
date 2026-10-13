-- ShapeKeySystem panel, advanced page "预设": the parent preset (binding) in effect and its lookup
-- chain, where the gains come from, sculpt presets (load / delete) and expression profiles.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local max, min = math.max, math.min

-- source -> message id
local SOURCE = { builtin = "src.builtin", mod = "src.mods", mods = "src.mods", user = "src.user" }
local function source_text(src) return SOURCE[src] and L.t(SOURCE[src]) or src end

local function primary_part(st)
    local b = st.presets.binding
    if b and b.part then return b.part end
    local best
    for _, p in ipairs(st.scene.parts or {}) do if not best or p.channels > best.channels then best = p end end
    return best and best.id or nil
end

local function confirm_bar(ctx, x, y, w)
    local pd = ctx.st.presets.pending_delete
    if not pd then return 0 end
    D.rrect(x, y, w, 40, 3, C.ink)
    D.outline(x, y, w, 40, 3, 1, C.warn)
    D.text_mid(L.t("files.delete_confirm", pd.name), x + 12, y + 6, 28, C.warn, W.body(), w - 200)
    if W.button(L.t("common.delete"), x + w - 170, y + 6, 76, 28, { kind = "danger" }) then ctx.call("confirm_delete") end
    if W.button(L.t("common.cancel"), x + w - 86, y + 6, 76, 28, { kind = "ghost" }) then ctx.call("cancel_delete") end
    return 48
end

local function binding_card(ctx, x, y, w)
    local st, call = ctx.st, ctx.call
    local b = st.presets.binding
    local part = primary_part(st)
    local rows = b and #b.chain or 0
    local h = 60 + rows * 30 + (b and 50 or 30) + 44
    W.panel_box(x, y, w, h, true)
    local cy = y + 10
    local tw = W.h2(L.t("files.binding_title"), x + 12, cy)
    D.text(part and L.t("files.part", part) or L.t("files.no_parts"), x + 24 + tw, cy + 2, C.muted, W.small(), w - tw - 40)
    cy = cy + 30
    if b then
        for i, c in ipairs(b.chain) do
            local bg = c.hit and C.panel3 or C.panel
            D.rrect(x + 12, cy, w - 24, 26, 3, bg)
            D.outline(x + 12, cy, w - 24, 26, 3, 1, c.hit and C.brass or C.line)
            D.text_mid(tostring(i), x + 20, cy, 26, C.faint, W.mono())
            D.text_mid(c.path, x + 40, cy, 26, c.exists and C.text or C.faint, W.mono(), w - 200)
            local err = c.error_key and L.t(c.error_key) or c.error
            local tag = err and L.t("files.error", err) or (c.hit and L.t("files.hit") or (c.exists and L.t("files.exists_unused") or "—"))
            local col = c.error and C.error or (c.hit and C.ok or C.muted)
            local tw2 = D.measure(W.small(), tag)
            D.text_mid(tag, x + w - 24 - tw2, cy, 26, col, W.small())
            cy = cy + 30
        end
        cy = cy + 4
        D.text(L.t("files.configs", tostring(L.field(b, "expression") or "-"), tostring(b.sculpt or "-")),
            x + 12, cy, C.text, W.body(), w - 24)
        cy = cy + 22
        if not b.fingerprint_ok then D.text(L.t("files.fingerprint_bad"), x + 12, cy, C.warn, W.small(), w - 24) end
        cy = cy + 24
    else
        D.text(L.t("files.no_binding"), x + 12, cy, C.muted, W.body(), w - 24)
        cy = cy + 30
    end
    if part then
        local bx = x + 12
        local _, bw = W.button(L.t("files.write_binding"), bx, cy, nil, 30, { kind = "primary" })
        if _ then
            call("write_binding", { part = part, expression = st.expression.profile and st.expression.profile.id,
                                    sculpt = st.sculpt.preset and st.sculpt.preset.name or nil, gains = true })
        end
        if W.button(L.t("files.restore_mod"), bx + bw + 10, cy, nil, 30, { kind = "ghost" }) then
            call("restore_mod_binding", { part = part })
        end
    end
    return h
end

local function tuning_line(ctx, x, y, w)
    local tu = ctx.st.expression.tuning
    if not tu then return 0 end
    local text = L.t("files.tuning_from", tu.source == "binding" and tostring(tu.path) or L.t("files.global_settings"))
        .. (tu.dirty and L.t("files.unsaved_tail") or "")
        .. (tu.profile_mismatch and L.t("files.gains_other_tail", tostring(tu.for_profile)) or "")
    local bw = 0
    if tu.source == "binding" then
        bw = 150
        if W.button(L.t("files.save_to_binding"), x + w - bw, y, bw, 28, { kind = tu.dirty and "primary" or nil }) then ctx.call("save_tuning") end
    end
    D.text_mid(text, x, y, 28, tu.dirty and C.warn or C.muted, W.small(), w - bw - 10)
    return 36
end

local function list_box(ctx, title, x, y, w, items, row)
    local h = 36 + max(1, #items) * 32 + 6
    D.rrect(x, y, w, h, 3, C.panel)
    D.outline(x, y, w, h, 3, 1, C.line)
    D.rect(x + 1, y + 1, w - 2, 34, C.panel2)
    W.label(title, x + 10, y + 10)
    if #items == 0 then D.text(L.t("common.empty"), x + 10, y + 44, C.faint, W.small()) end
    for i, it in ipairs(items) do
        local ry = y + 36 + (i - 1) * 32
        if i > 1 then D.rect(x + 1, ry, w - 2, 1, C.line) end
        row(it, x + 10, ry, w - 20)
    end
    return h
end

function Page.draw(ctx, x, y, w)
    local st, call = ctx.st, ctx.call
    local pr = st.presets
    local cy = y
    cy = cy + confirm_bar(ctx, x, cy, w)
    cy = cy + binding_card(ctx, x, cy, w) + 10
    cy = cy + tuning_line(ctx, x, cy, w)

    local two = w >= 640
    local lw = two and (w - 12) / 2 or w
    local cur_sculpt = st.sculpt.preset
    -- row buttons, right to left; a longer (English) label pushes the next one further left
    local function rbtn_x(bx, label) return bx - max(0, D.measure(W.small(), label) + 22 - 46) end
    local h1 = list_box(ctx, L.t("files.sculpt_list"), x, cy, lw, pr.sculpt or {}, function(e, rx, ry, rw)
        local cur = cur_sculpt and cur_sculpt.name == e.name and cur_sculpt.folder == e.folder
        D.text_mid(e.name, rx, ry, 32, cur and C.brass or C.text, W.body(), rw * 0.45)
        local meta = source_text(e.source) .. " · " .. (e.folder or L.t("files.general"))
        D.text_mid(meta, rx + rw * 0.45, ry, 32, C.faint, W.small(), rw * 0.3)
        local bx = rx + rw - 46
        if e.source == "user" then
            local l_del = L.t("common.delete")
            bx = rbtn_x(bx, l_del)
            if W.tbutton(l_del, bx, ry + 5, { kind = "danger" }) then
                call("request_delete", { kind = "sculpt", name = e.name, folder = e.folder })
            end
            bx = bx - 50
        end
        local l_load = L.t("files.load")
        if W.tbutton(l_load, rbtn_x(bx, l_load), ry + 5) then call("load_sculpt", { name = e.name, folder = e.folder }) end
    end)
    local ex = st.expression
    local lx, ly = x + (two and lw + 12 or 0), two and cy or (cy + h1 + 12)
    local h2 = list_box(ctx, L.t("files.profile_list"), lx, ly, lw, pr.expression or {}, function(e, rx, ry, rw)
        local cur = ex.profile and ex.profile.id == e.id
        D.text_mid(L.field(e, "name"), rx, ry, 32, cur and C.brass or C.text, W.body(), rw * 0.5)
        D.text_mid(source_text(e.source) .. (e.extends and L.t("files.extends", e.extends) or ""), rx + rw * 0.5, ry, 32,
            C.faint, W.small(), rw * 0.3)
        local bx = rx + rw - 46
        if e.source == "user" then
            local l_del = L.t("common.delete")
            bx = rbtn_x(bx, l_del)
            if W.tbutton(l_del, bx, ry + 5, { kind = "danger" }) then call("request_delete", { kind = "profile", name = e.id }) end
            bx = bx - 50
        end
        local l_use = L.t("files.use")
        if not cur and W.tbutton(l_use, rbtn_x(bx, l_use), ry + 5) then call("set_profile", { id = e.id }) end
    end)
    if two then cy = cy + max(h1, h2) else cy = ly + h2 end
    cy = cy + 10
    return cy + 22 - y
end

return Page
