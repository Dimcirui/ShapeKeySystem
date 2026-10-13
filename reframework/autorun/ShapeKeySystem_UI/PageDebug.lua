-- ShapeKeySystem panel, advanced page "设置与调试": settings, per-stage timing, scan info, log.

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local Files = require("ShapeKeySystem_UI.PagePresets")   -- binding lookup + config files, shown here
local Faces = require("ShapeKeySystem_UI.Faces")
local Version = require("ShapeKeySystem_Core.Version")
local L = require("ShapeKeySystem_Core.I18n")

local Page = {}
local C = T.c
local max, min = math.max, math.min

-- free keys first. Not offered: Insert (REFramework menu). Last, for whoever wants them anyway:
-- Home (ArmorVariantManager), End (game pause). PageUp / PageDown move REFramework's free camera.
local HOTKEYS = { "Delete", "NumPad0", "NumPad1", "NumPad2", "NumPad3", "NumPad4", "NumPad5", "NumPad6",
                  "NumPad7", "NumPad8", "NumPad9", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9",
                  "F10", "F11", "F12", "PageUp", "PageDown", "Home", "End" }

local function setting(ctx, k, v) ctx.call("set_setting", { key = k, value = v }) end

local function settings_card(ctx, x, y, w)
    local se = ctx.st.settings
    local h = 364
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local cy = y + 10
    W.h2(L.t("debug.settings"), rx, cy); cy = cy + 30
    local lw = 150
    local function row(label, fn)
        D.text_mid(label, rx, cy, 28, C.text, W.small(), lw - 8)
        fn(rx + lw, rw - lw)
        cy = cy + 32
    end
    -- interface language; the label names it in both languages so it can be found in either
    row(L.t("debug.language"), function(sx, sw)
        local labels, cur = {}, nil
        for i, lang in ipairs(L.LANGS) do
            labels[i] = L.LANG_NAMES[lang] or lang
            if lang == (se.language or L.lang) then cur = i end
        end
        local ch, i = W.select("language", sx, cy, min(160, sw), 28, labels, cur)
        if ch and L.LANGS[i] then setting(ctx, "language", L.LANGS[i]) end
    end)
    row(L.t("debug.hotkey"), function(sx, sw)
        local cur
        for i, k in ipairs(HOTKEYS) do if k == se.hotkey then cur = i end end
        local ch, i = W.select("hotkey", sx, cy, min(160, sw), 28, HOTKEYS, cur)
        if ch then setting(ctx, "hotkey", HOTKEYS[i]) end
    end)
    row(L.t("debug.ui_scale"), function(sx, sw)
        local ch, v = W.slider("ui_scale", sx, cy, min(320, sw), 28, ctx.state.pending_scale or se.ui_scale or 1, 0.75, 2, { step = 0.05, fmt = "%.2f" })
        if ch then ctx.state.pending_scale = v end
        -- apply on release: the layout under the mouse changes with the scale
        if ctx.state.pending_scale and not require("ShapeKeySystem_UI.Input").down then
            setting(ctx, "ui_scale", ctx.state.pending_scale); ctx.state.pending_scale = nil
        end
    end)
    row(L.t("debug.face_style"), function(sx, sw)
        local list, labels, cur = Faces.list(), {}, nil
        local active = Faces.get(se.face_style)
        for i, f in ipairs(list) do
            labels[i] = L.field(f, "name")
            if active and f.id == active.id then cur = i end
        end
        local ch, i = W.select("face_style", sx, cy, min(200, sw), 28, labels, cur, { placeholder = L.t("common.none") })
        if ch and list[i] then setting(ctx, "face_style", list[i].id) end
    end)
    row(L.t("debug.sculpt_max"), function(sx, sw)
        local ch, v = W.slider("sculpt_max", sx, cy, min(320, sw), 28, se.sculpt_max or 1, 1, 5, { step = 0.1, fmt = "%.1f" })
        if ch then setting(ctx, "sculpt_max", v) end
    end)
    row(L.t("debug.periodic"), function(sx, sw)
        local ch, v = W.slider("periodic", sx, cy, min(320, sw), 28, se.periodic_scan_sec or 10, 0, 60, { step = 1, fmt = "%.0f" })
        if ch then setting(ctx, "periodic_scan_sec", v) end
    end)
    row(L.t("debug.epsilon"), function(sx, sw)
        local ch, v = W.slider("eps", sx, cy, min(320, sw), 28, se.write_epsilon or 0.001, 0, 0.01, { step = 0.0005, fmt = "%.4f", value_w = 56 })
        if ch then setting(ctx, "write_epsilon", v) end
    end)
    local bx = rx
    local c1, v1, w1 = W.toggle(L.t("debug.clamp"), bx, cy, se.clamp ~= false)
    if c1 then setting(ctx, "clamp", v1) end
    bx = bx + w1 + 24
    local c2, v2, w2 = W.toggle(L.t("debug.cutscene"), bx, cy, se.cutscene_drive == true)
    if c2 then setting(ctx, "cutscene_drive", v2) end
    cy = cy + 34
    local c3, v3 = W.toggle(L.t("debug.scene_search"), rx, cy, se.scene_search_always == true)
    if c3 then setting(ctx, "scene_search_always", v3) end
    return h
end

local function perf_card(ctx, x, y, w)
    local st = ctx.st
    local a = st.debug.perf or {}
    local h = 200
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local cy = y + 10
    local pw = W.h2(L.t("debug.perf"), rx, cy) or 36
    local px = rx + max(60, pw + 12)
    D.text(L.t("debug.perf_line", a.writes or 0, a.skipped or 0), px, cy + 3, C.muted, W.small(), rx + rw - px)
    cy = cy + 30
    local total = max(0.3, a.total or 0)
    for _, k in ipairs({ { "read", "debug.t_read" }, { "compute", "debug.t_compute" }, { "write", "debug.t_write" },
                         { "scan", "debug.t_scan" }, { "total", "debug.t_total" } }) do
        local v = a[k[1]] or 0
        D.text_mid(L.t(k[2]), rx, cy, 22, C.text, W.small(), 60)
        W.meter(rx + 60, cy + 6, rw - 140, 10, v / total, C.brass)
        D.text_mid(string.format("%.3f ms", v), rx + rw - 72, cy, 22, C.text, W.mono())
        cy = cy + 26
    end
    return h
end

local function scene_card(ctx, x, y, w)
    local st, call = ctx.st, ctx.call
    local sc = st.scene
    local lines = {}
    local ls = sc.last_scan
    if ls then
        lines[#lines + 1] = L.t("debug.last_scan", os.date("%H:%M:%S", ls.time or 0),
            ls.ms or 0, ls.faces or 0, ls.cached_skip or 0, ls.guild_card and L.t("debug.guild_card") or "")
    end
    for _, r in ipairs(sc.rigs or {}) do
        local t = {}
        for _, x2 in ipairs(r.targets or {}) do t[#t + 1] = L.t("debug.target", x2.name, x2.channels) end
        lines[#lines + 1] = (r.primary and "★ " or "   ") .. L.t("debug.rig_line", r.label, table.concat(t, L.t("debug.list_sep")))
    end
    for _, p in ipairs(sc.parts or {}) do
        lines[#lines + 1] = L.t("debug.part_line", p.id, p.channels, tostring(p.fingerprint),
            p.binding and L.t("debug.part_binding", p.binding) or "")
    end
    local h = 50 + max(1, #lines) * 20
    W.panel_box(x, y, w, h, true)
    local tw = W.h2(L.t("debug.scene"), x + 12, y + 10)
    if W.button(L.t("debug.rescan"), x + w - 100, y + 8, 88, 26, { font = W.small() }) then call("rescan") end
    if W.button(L.t("debug.probe"), x + w - 196, y + 8, 88, 26, { font = W.small(), kind = "ghost" }) then ctx.SKS.request_probe() end
    local cy = y + 42
    if #lines == 0 then D.text(L.t("debug.no_scan"), x + 12, cy, C.muted, W.small()) end
    for _, l in ipairs(lines) do D.text(l, x + 12, cy, C.text, W.small(), w - 24); cy = cy + 20 end
    return h
end

local function external_card(ctx, x, y, w)
    local held = ctx.st.external and ctx.st.external.held or {}
    local h = 50 + max(1, #held) * 24
    W.panel_box(x, y, w, h, true)
    local tw = W.h2(L.t("debug.external"), x + 12, y + 10)
    D.text(L.t("debug.api_hint"), x + 18 + tw, y + 13, C.faint, W.small())
    if #held > 0 and W.button(L.t("debug.release_all"), x + w - 100, y + 8, 88, 26, { font = W.small(), kind = "danger" }) then
        ctx.call("external_release", {})
    end
    local cy = y + 42
    if #held == 0 then D.text(L.t("debug.no_external"), x + 12, cy, C.muted, W.small()) end
    for _, e in ipairs(held) do
        D.text_mid(e.name, x + 12, cy, 22, C.text, W.small(), w * 0.4)
        D.text_mid(e.owner, x + 12 + w * 0.42, cy, 22, C.brass, W.small(), w * 0.3)
        local tb = L.t("common.take_back")
        local tbx = x + w - 56 - max(0, D.measure(W.small(), tb) + 22 - 46)
        D.text_mid(string.format("%.2f", e.value or 0), min(x + w - 120, tbx - 44), cy, 22, C.text, W.mono())
        if W.tbutton(tb, tbx, cy) then
            ctx.call("external_release", { owner = e.owner, name = e.name })
        end
        cy = cy + 24
    end
    return h
end

local function log_card(ctx, x, y, w)
    local l = ctx.st.debug.log or {}
    local n = min(#l, 30)
    local h = 44 + max(1, n) * 18
    W.panel_box(x, y, w, h, true)
    W.h2(L.t("debug.log"), x + 12, y + 10)
    local cy = y + 38
    for i = #l, #l - n + 1, -1 do
        D.text(l[i].time .. "  " .. l[i].text, x + 12, cy, C.muted, W.small(), w - 24)
        cy = cy + 18
    end
    for _, line in ipairs(ctx.st.debug.probe or {}) do
        -- probe output is appended below the log when present
        D.text(line, x + 12, cy, C.faint, W.small(), w - 24); cy = cy + 18; h = h + 18
    end
    return h
end

-- author, version and the latest release notes; h = the space it may use (fills the gap under
-- the performance card in the two-column layout)
local function about_card(ctx, x, y, w, h)
    h = max(h or 0, 96)
    W.panel_box(x, y, w, h, true)
    local rx, rw = x + 12, w - 24
    local cy = y + 10
    local tw = W.h2(L.t("debug.about"), rx, cy) or 36
    D.text(L.t("debug.about_line", Version.name, Version.number, L.field(Version, "author")), rx + tw + 12, cy + 3, C.muted,
        W.small(), rw - tw - 12)
    cy = cy + 30
    for i, e in ipairs(Version.history) do
        if cy + 20 > y + h - 6 then break end
        local label = (i == 1) and L.t("debug.this_version") or L.t("debug.prev_version")
        D.text(string.format("%s v%s", label, e.version), rx, cy, i == 1 and C.brass or C.faint, W.small(), 110)
        D.text(L.field(e, "notes") or "", rx + 110, cy, i == 1 and C.text or C.muted, W.small(), rw - 110)
        cy = cy + 22
        if i >= 2 then break end
    end
    return h
end

function Page.draw(ctx, x, y, w)
    local cy = y
    local two = w >= 760
    if two then
        local lw = (w - 12) * 0.55
        local h1 = settings_card(ctx, x, cy, lw)
        local h2 = perf_card(ctx, x + lw + 12, cy, w - lw - 12)
        local h3 = about_card(ctx, x + lw + 12, cy + h2 + 12, w - lw - 12, h1 - h2 - 12)
        cy = cy + max(h1, h2 + 12 + h3) + 12
    else
        cy = cy + settings_card(ctx, x, cy, w) + 12
        cy = cy + perf_card(ctx, x, cy, w) + 12
        cy = cy + about_card(ctx, x, cy, w) + 12
    end
    cy = cy + external_card(ctx, x, cy, w) + 12
    cy = cy + scene_card(ctx, x, cy, w) + 12
    -- binding lookup chain and the config files (was the 预设 page): for troubleshooting
    local fopen = ctx.state.files_open == true
    local clicked, hh = W.header(L.t("debug.files"), x, cy, w, fopen)
    if clicked then ctx.state.files_open = not fopen end
    cy = cy + hh + 6
    if fopen then cy = cy + Files.draw(ctx, x, cy, w) + 12 end
    cy = cy + log_card(ctx, x, cy, w)
    return cy - y
end

return Page
