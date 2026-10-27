-- ShapeKeySystem panel page: "96条原生Deform"
-- 实时监视与显示 RE9 原生 96 条 FACS 轨道的真实物理数值。

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Defs = require("ShapeKeySystem_Games.RE9.Native96Def")
local Signals = require("ShapeKeySystem_Games.RE9.Signals")
local VF = require("ShapeKeySystem_Games.RE9.VirtualFACS")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")

local Page = { want_signals = true }
local C = T.c
local max, min, floor = math.max, math.min, math.floor

local DEF_LIST = Defs.DEFINITIONS

local function visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

function Page.draw(ctx, x, y, w)
    local s = ctx.state
    if s.filter == nil then s.filter = "" end
    if s.hide_zero == nil then s.hide_zero = false end
    if s.sort_val == nil then s.sort_val = false end
    if s.peaks == nil then s.peaks = {} end

    local cy = y

    -- 1. Header & Status Card
    local head = R.find()
    local mesh = head and (head.mesh or (head.face and R.mesh(head.face)))
    local cn = head and head.count or (mesh and (R.call(mesh, "get_BlendShapeChannelNum") or R.call(mesh, "getBlendShapeChannelNum"))) or 0
    local is_mod = (cn ~= 96)

    local card_h = 92
    W.panel_box(x, cy, w, card_h, true)
    local rx, rw = x + 14, w - 28

    W.h2("RE9 原生 96 条 FACS Deform 实时监视器", rx, cy + 10)

    local status_text = ""
    local status_color = C.ok
    if head then
        if is_mod then
            status_text = string.format("已连接 Mod 网格 [%s] (形态键数: %d) · 底层数据源: RE9 面部骨骼投影 + Driver", head.identity or "Mod", cn)
            status_color = C.signal
        else
            status_text = string.format("已连接 原版里昂 [%s] (96 原生 FACS 通道)", head.identity or "Leon")
            status_color = C.ok
        end
    else
        status_text = "正在搜寻面部实体 (cp_A000 / ch0100)..."
        status_color = C.warn
    end
    D.text(status_text, rx, cy + 38, status_color, W.small(), rw)

    -- Filter and Toggles toolbar
    local ty = cy + 60
    local tw = min(220, rw * 0.32)
    W.text_box("n96_filter", rx, ty, tw, 24, s.filter, "搜索序号/名称/说明...", function(v) s.filter = v end)

    local tx = rx + tw + 14
    local ch1, v1 = W.toggle("仅显示有数值(>0.001)", tx, ty, s.hide_zero)
    if ch1 then s.hide_zero = v1 end

    tx = tx + 180
    local ch2, v2 = W.toggle("按实时数值降序", tx, ty, s.sort_val)
    if ch2 then s.sort_val = v2 end

    tx = tx + 150
    if W.button("重置峰值", tx, ty, 80, 24, { font = W.small() }) then
        s.peaks = {}
    end

    cy = cy + card_h + 12

    -- 2. Fetch live values from all available channels
    local snap_vals = nil
    if head then
        local ok, sv = pcall(Signals.snapshot, { include_native_outputs = true })
        if ok and sv then
            snap_vals = sv.outputs or sv
        end
    end
    local vf_vals = VF.get_all() or {}

    local active_count = 0
    local max_val = 0.0
    local max_item = nil

    -- Track peaks & stats
    local channel_values = {}
    for i = 0, #DEF_LIST do
        local item = DEF_LIST[i]
        local val = 0.0
        local short = item.short

        -- 1. Try native output rule from bone projection
        if snap_vals then
            val = snap_vals["re9.native." .. short] or snap_vals[short] or snap_vals[item.name] or 0.0
        end

        -- Direct bone solver fallback
        if (not val or val <= 0.0001) and head then
            local bval = Bones.read(head, "re9.native." .. short)
            if bval and bval > 0.0001 then
                val = bval
            end
        end

        -- 2. Fallbacks to corresponding standard gesture signals if specific sub-track is idle
        if val <= 0.0001 and snap_vals then
            if short == "JwOpn_00_L" or short == "JwOpn_00_R" then
                val = snap_vals["jawOpen"] or snap_vals["re9VowelA"] or 0.0
            elseif short == "Strtch_04_L" or short == "Strtch_03_L" then
                val = snap_vals["mouthStretchLeft"] or 0.0
            elseif short == "Strtch_04_R" or short == "Strtch_03_R" then
                val = snap_vals["mouthStretchRight"] or 0.0
            elseif short == "Pkr_01_L" or short == "Pkr_02_L" or short == "Pkr_03_L" then
                val = snap_vals["mouthPucker"] or snap_vals["re9VowelU"] or 0.0
            elseif short == "Pkr_01_R" or short == "Pkr_02_R" or short == "Pkr_03_R" then
                val = snap_vals["mouthPucker"] or snap_vals["re9VowelU"] or 0.0
            elseif short == "Fnl_04_L" or short == "Fnl_04_R" then
                val = snap_vals["mouthFunnel"] or 0.0
            elseif short:find("^CrnPl_0") then
                val = short:find("_L") and (snap_vals["mouthSmileLeft"] or 0.0) or (snap_vals["mouthSmileRight"] or 0.0)
            elseif short:find("Sqnt_06") or short:find("UprLdDn_05") then
                val = short:find("_L") and (snap_vals["eyeBlinkLeft"] or 0.0) or (snap_vals["eyeBlinkRight"] or 0.0)
            elseif short:find("BrInDn") or short:find("BrLr") then
                val = short:find("_L") and (snap_vals["browDownLeft"] or 0.0) or (snap_vals["browDownRight"] or 0.0)
            elseif short:find("BrInRs") then
                val = snap_vals["browInnerUp"] or 0.0
            elseif short:find("BrOutRs") then
                val = short:find("_L") and (snap_vals["browOuterUpLeft"] or 0.0) or (snap_vals["browOuterUpRight"] or 0.0)
            end
        end

        -- 3. Fallback to VirtualFACS / Motion deform
        if val <= 0.0001 and vf_vals[i] then
            val = vf_vals[i]
        end

        val = max(0.0, min(1.0, val or 0.0))
        channel_values[i] = val

        if val > (s.peaks[i] or 0.0) then s.peaks[i] = val end
        if val > 0.001 then
            active_count = active_count + 1
            if val > max_val then
                max_val = val
                max_item = item
            end
        end
    end

    -- Stats summary bar
    local stats_h = 32
    W.panel_box(x, cy, w, stats_h, false)
    local s_text = string.format("活跃通道: %d / 96   |   最高信号: %s (%.3f)",
        active_count,
        max_item and (max_item.short .. " - " .. (max_item.desc or "")) or "无",
        max_val)
    D.text_mid(s_text, rx, cy, stats_h, C.text, W.small(), rw)
    cy = cy + stats_h + 12

    -- 3. Prepare filtered list
    local list = {}
    local f_low = (s.filter or ""):lower()
    for i = 0, #DEF_LIST do
        local item = DEF_LIST[i]
        if item then
            local val = channel_values[i] or 0.0
            local peak = s.peaks[i] or 0.0
            local match = true
            if f_low ~= "" then
                local search_str = string.format("[%02d] %s %s", i, item.short or "", item.desc or ""):lower()
                if not search_str:find(f_low, 1, true) then match = false end
            end
            if s.hide_zero and val < 0.001 and peak < 0.001 then
                match = false
            end
            if match then
                table.insert(list, {
                    idx = i,
                    short = item.short or "",
                    name = item.name or "",
                    desc = item.desc or "",
                    val = val,
                    peak = peak,
                })
            end
        end
    end

    if s.sort_val then
        table.sort(list, function(a, b) return a.val > b.val end)
    else
        table.sort(list, function(a, b) return a.idx < b.idx end)
    end

    -- 4. Table Header
    local th_h = 24
    D.rect(x, cy, w, th_h, C.panel3)
    D.outline(x, cy, w, th_h, 0, 1, C.line)
    D.text_mid("序号", rx, cy, th_h, C.muted, W.small(), 40)
    D.text_mid("原生通道名", rx + 44, cy, th_h, C.muted, W.small(), 150)
    D.text_mid("中文功能说明", rx + 200, cy, th_h, C.muted, W.small(), 170)
    D.text_mid("实时值", rx + 375, cy, th_h, C.muted, W.small(), 60)
    D.text_mid("峰值", rx + 440, cy, th_h, C.muted, W.small(), 60)
    D.text_mid("实时动态指示条", rx + 505, cy, th_h, C.muted, W.small(), rw - 505)
    cy = cy + th_h + 2

    -- 5. Channels Table Rows
    local row_h = 26
    for _, row in ipairs(list) do
        if visible(cy, row_h) then
            local is_active = row.val > 0.001
            local row_bg = is_active and C.panel2 or (row.idx % 2 == 0 and C.ink or C.panel)
            D.rect(x, cy, w, row_h, row_bg)
            D.line(x, cy + row_h - 1, x + w, cy + row_h - 1, 1, C.line)

            -- Color code by intensity
            local val_color = C.faint
            local bar_color = C.signal_dim
            if row.val >= 0.70 then
                val_color = C.error
                bar_color = C.error
            elseif row.val >= 0.30 then
                val_color = C.brass
                bar_color = C.brass
            elseif row.val > 0.001 then
                val_color = C.signal
                bar_color = C.signal
            end

            -- Index
            D.text_mid(string.format("[%02d]", row.idx), rx, cy, row_h, is_active and C.text or C.faint, W.small(), 40)

            -- Short Name
            D.text_mid(row.short, rx + 44, cy, row_h, is_active and C.text or C.muted, W.small(), 150)

            -- Description
            D.text_mid(row.desc, rx + 200, cy, row_h, is_active and C.brass or C.muted, W.small(), 170)

            -- Live Value
            D.text_mid(string.format("%.3f", row.val), rx + 375, cy, row_h, val_color, W.mono(), 60)

            -- Peak Value
            D.text_mid(string.format("%.3f", row.peak), rx + 440, cy, row_h, row.peak > 0.001 and C.muted or C.faint, W.mono(), 60)

            -- Visual Meter Bar
            local bar_w = max(60, rw - 510)
            W.meter(rx + 505, cy + 6, bar_w, 14, row.val, bar_color)
        end
        cy = cy + row_h
    end

    if #list == 0 then
        D.rect(x, cy, w, 40, C.panel)
        D.text_mid("无匹配的 Deform 通道 (请检查过滤条件)", rx, cy, 40, C.muted, W.small(), rw)
        cy = cy + 40
    end

    return cy - y
end

return Page
