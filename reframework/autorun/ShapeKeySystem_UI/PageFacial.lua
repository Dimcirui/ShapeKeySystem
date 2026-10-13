-- ShapeKeySystem panel, basic page "整脸表情": one slider per facial preset key, an avatar's own
-- numbered whole-face expressions (Facial.lua; Maya's 1-10). Raising one fades the emote-driven
-- face by the same amount; gaze keeps working (kevin, 2026-10-13).

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local max, floor = math.max, math.floor
local ROW_H = 36

local function visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

local function toolbar(ctx, x, y, w)
    local level = ctx.st.facial.level or 0
    W.panel_box(x, y, w, 60)
    local off = L.t("facial.all_off")
    local bw = D.measure(W.body(), off) + 22
    if W.button(off, x + w - bw - 10, y + 16, bw, 28, { kind = "ghost", disabled = level <= 0 }) then
        ctx.call("clear_facial")
    end
    local tw = w - bw - 36
    D.text(L.t("facial.hint"), x + 12, y + 9, C.muted, W.small(), tw)
    D.text(L.t("facial.keep", floor((1 - level) * 100 + 0.5)), x + 12, y + 31, level > 0 and C.brass or C.text,
        W.small(), tw)
    return 60
end

local function key_row(ctx, k, x, y, w)
    if not visible(y, ROW_H) then return ROW_H end
    if k.value > 0 then D.rect(x, y + 4, 2, ROW_H - 8, C.brass) end
    local nw = max(90, w * 0.12)
    D.text_mid(k.name, x + 10, y + 4, 28, C.text, W.body(), nw - 16)
    local ext = W.external_owner(ctx.st, k.name)
    if ext then
        -- another plugin holds this key: its value wins (External.lua)
        local cw = W.chip(L.t("common.held_by", ext), x + nw, y + 9, C.brass)
        if W.tbutton(L.t("common.take_back"), x + nw + cw + 10, y + 7) then
            ctx.call("external_release", { owner = ext, name = k.name })
        end
    else
        local ch, v = W.slider("fa:" .. k.name, x + nw, y + 4, w - nw - 12, 28, k.value, 0, 1, { step = 0.01, fmt = "%.2f" })
        if ch then ctx.call("set_facial", { name = k.name, value = v }) end
    end
    return ROW_H
end

function Page.draw(ctx, x, y, w)
    local fs = ctx.st.facial
    local cy = y + toolbar(ctx, x, y, w) + 10
    if #fs.keys == 0 then
        D.text(L.t("facial.none"), x, cy, C.muted, W.body(), w)
        return cy + 30 - y
    end
    for _, k in ipairs(fs.keys) do cy = cy + key_row(ctx, k, x, cy, w) end
    return cy - y
end

return Page
