-- ShapeKeySystem: temporary imgui debug panel (M1). Uses only SKS.state / SKS.live / SKS.call,
-- like the d2d panel will (M3). Labels follow settings.language (I18n.lua); every translated
-- label carries a fixed "##id" so imgui keeps its open / active state across a language switch.

local L = require("ShapeKeySystem_Core.I18n")

local D = {}

local SKS
local drawn = false
local want_signals = false
local last_err = ""
local edit = { channel = 1, text = "", loaded_for = nil }
local save_name = ""

local function call(cmd, args)
    local ok, code, msg = SKS.call(cmd, args)
    if not ok then last_err = string.format("%s: %s %s", cmd, tostring(code), tostring(msg or "")) end
    return ok
end

local function encode(v, indent)
    -- small JSON encoder for node trees (display + editing)
    local t = type(v)
    if t == "table" then
        if #v > 0 then
            local parts = {}
            for i, x in ipairs(v) do parts[i] = encode(x) end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q: %s", k, encode(v[k])) end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "number" then
        return string.format("%g", v)
    end
    return tostring(v)
end

local function draw_channels(st, live)
    local ex = st.expression
    for _, g in ipairs(ex.groups) do
        if imgui.tree_node(string.format("%s (%d)##grp_%s", L.field(g, "name"), #g.channel_slots, g.key)) then
            for _, s in ipairs(g.channel_slots) do
                local c = ex.channels[s]
                local tags = (c.present and "" or L.t("dbg.tag_no_mesh")) .. (c.has_signal and "" or L.t("dbg.tag_no_signal"))
                    .. (c.guessed and L.t("dbg.tag_guessed") or "") .. (c.edited and L.t("dbg.tag_edited") or "")
                local changed, v = imgui.slider_float(string.format("%-22s %.2f%s##g%d", c.name, live.weight[s] or 0, tags, s),
                    c.gain, 0.0, 3.0)
                if changed then call("set_channel_gain", { name = c.canonical, value = v }) end
                imgui.same_line()
                changed, v = imgui.checkbox(L.t("dbg.test") .. "##t" .. s, c.forced)
                if changed then call("force_channel", { name = c.canonical, on = v }) end
                local note = L.field(c, "note")
                if imgui.is_item_hovered() then imgui.set_tooltip(c.source_text .. (note and ("\n" .. note) or "")) end
            end
            imgui.tree_pop()
        end
    end
end

local function draw_mapping(st, live)
    local ex, m = st.expression, st.mapping
    local names = {}
    for i, c in ipairs(ex.channels) do names[i] = c.canonical end
    if #names == 0 then return end
    local changed, idx = imgui.combo(L.t("dbg.channel") .. "##map", edit.channel, names)
    if changed then edit.channel = idx; edit.loaded_for = nil end
    local name = names[edit.channel] or names[1]
    if edit.loaded_for ~= name then
        edit.text = encode(m.nodes[name] or {})
        edit.loaded_for = name
    end
    local c = ex.channels[edit.channel]
    if c then imgui.text(L.t("dbg.source", c.source_text)) end
    changed, edit.text = imgui.input_text(L.t("dbg.node_json") .. "##node", edit.text)
    if imgui.button(L.t("dbg.apply") .. "##node") then
        local ok, node = pcall(json.load_string, edit.text)
        if ok and type(node) == "table" then call("edit_node", { name = name, node = node })
        else last_err = L.t("dbg.json_error") end
    end
    imgui.same_line()
    if imgui.button(L.t("dbg.revert") .. "##node") then
        if call("revert_node", { name = name }) then edit.loaded_for = nil end
    end
    changed, save_name = imgui.input_text(L.t("dbg.save_as") .. "##pname", save_name)
    imgui.same_line()
    if imgui.button(L.t("dbg.save") .. "##profile") then
        call("save_profile", { as_name = (save_name ~= "" and save_name or nil) })
    end

    imgui.text(L.t("dbg.active_signals"))
    local act = {}
    for i, sd in ipairs(m.signals) do
        local v = live.signal[i] or 0
        if v > 0.02 then act[#act + 1] = { sd, v } end
    end
    table.sort(act, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(#act, 24) do
        local sd, v = act[i][1], act[i][2]
        imgui.text(string.format("  %-18s %s  %.2f  %s%s", sd.name, sd.bone or string.format("fc%03d", sd.param), v, L.field(sd, "note") or "",
            sd.guessed and L.t("dbg.tag_guessed") or ""))
    end
end

local sculpt_name = ""
local sculpt_general = false

local function primary_part_id(st)
    local b = st.presets.binding
    if b and b.part then return b.part end
    local best
    for _, p in ipairs(st.scene.parts) do if not best or p.channels > best.channels then best = p end end
    return best and best.id or nil
end

local function draw_sculpt(st)
    local sc = st.sculpt
    if imgui.button(L.t("dbg.scan") .. "##sculpt") then call("sculpt_scan") end
    imgui.same_line()
    local changed, v = imgui.checkbox(L.t("dbg.force") .. "##sks_force", sc.edit_mode)
    if changed then call("set_edit_mode", { on = v }) end
    imgui.same_line()
    changed, v = imgui.checkbox(L.t("dbg.ab") .. "##sks_ab", sc.ab_preview)
    if changed then call("set_ab_preview", { on = v }) end
    if imgui.button(L.t("dbg.undo") .. "##sculpt") then call("sculpt_undo") end
    imgui.same_line()
    if imgui.button(L.t("dbg.redo") .. "##sculpt") then call("sculpt_redo") end
    imgui.same_line()
    imgui.text(L.t("dbg.current_config", sc.dirty and L.t("dbg.unsaved") or L.t("dbg.saved"),
        sc.preset and (sc.preset.name .. " (" .. sc.preset.source .. ")") or L.t("dbg.none")))
    local scan = sc.scan
    if scan then
        imgui.text(L.t("dbg.scan_line", table.concat(scan.parts, ", "), scan.keys, scan.expression_keys or 0))
    end
    for _, g in ipairs(sc.groups) do
        if imgui.tree_node(string.format("%s (%d)##sg_%s", g.name, #g.key_indices, g.key)) then
            for _, i in ipairs(g.key_indices) do
                local k = sc.keys[i]
                if k.locked then
                    imgui.text(L.t("dbg.locked_key", k.name))
                else
                    local extra = ""
                    for p, ov in pairs(k.overrides) do extra = extra .. string.format("  [%s=%.2f]", p, ov) end
                    changed, v = imgui.slider_float(string.format("%s%s##sk%d", k.name, extra, i), k.value, k.range[1], k.range[2])
                    if changed then call("set_sculpt_key", { name = k.name, value = v }) end
                    imgui.same_line()
                    if imgui.button(L.t("dbg.default") .. "##sr" .. i) then call("reset_sculpt_key", { name = k.name }) end
                    if imgui.is_item_hovered() then imgui.set_tooltip(L.t("dbg.mod_default", k.default)) end
                end
            end
            imgui.tree_pop()
        end
    end
    changed, sculpt_name = imgui.input_text(L.t("dbg.sculpt_name") .. "##sname", sculpt_name)
    imgui.same_line()
    changed, v = imgui.checkbox(L.t("dbg.save_general") .. "##sks_general", sculpt_general)
    if changed then sculpt_general = v end
    if imgui.button(L.t("dbg.save") .. "##sculpt") and sculpt_name ~= "" then
        call("save_sculpt", { name = sculpt_name, general = sculpt_general })
    end
    local part = primary_part_id(st)
    if part then
        imgui.same_line()
        if imgui.button(L.t("dbg.save_bind", part) .. "##sks_savebind") and sculpt_name ~= "" then
            if call("save_sculpt", { name = sculpt_name, general = sculpt_general }) then
                call("write_binding", { part = part, expression = st.expression.profile and st.expression.profile.id,
                                        sculpt = sculpt_name, gains = true })
            end
        end
    end
end

local function draw_presets(st)
    local pr = st.presets
    local b = pr.binding
    local part = primary_part_id(st)
    if b then
        imgui.text(L.t("dbg.binding_line", b.hit, b.part,
            tostring(L.field(b, "expression") or "-"), tostring(b.sculpt or "-"), b.fingerprint_ok and "" or L.t("dbg.fingerprint_bad")))
        for _, c in ipairs(b.chain) do
            local err = c.error_key and L.t(c.error_key) or c.error
            imgui.text(string.format("   %s %s%s", c.hit and "→" or (c.exists and "·" or " "), c.path,
                err and L.t("dbg.chain_error", err) or ""))
        end
    else
        imgui.text(L.t("dbg.no_binding"))
    end
    if part then
        if imgui.button(L.t("dbg.write_binding", part) .. "##sks_wb") then
            call("write_binding", { part = part, expression = st.expression.profile and st.expression.profile.id,
                                    sculpt = st.sculpt.preset and st.sculpt.preset.name or nil, gains = true })
        end
        imgui.same_line()
        if imgui.button(L.t("dbg.restore_mod") .. "##rmb") then call("restore_mod_binding", { part = part }) end
    end
    local tu = st.expression.tuning
    if tu then
        imgui.text(L.t("dbg.tuning_from",
            tu.source == "binding" and tostring(tu.path) or L.t("dbg.global_settings"),
            tu.dirty and ("  " .. L.t("dbg.unsaved")) or "",
            tu.profile_mismatch and L.t("dbg.gains_other", tostring(tu.for_profile)) or ""))
        if tu.source == "binding" then
            imgui.same_line()
            if imgui.button(L.t("dbg.save_tuning") .. "##tune") then call("save_tuning") end
        end
    end
    imgui.text(L.t("dbg.sculpt_list"))
    for i, e in ipairs(pr.sculpt) do
        if imgui.button(string.format("%s##sl%d", e.name, i)) then call("load_sculpt", { name = e.name, folder = e.folder }) end
        imgui.same_line()
        imgui.text(string.format("(%s, %s%s)", e.source, e.folder or L.t("dbg.general"), e.target_part and (", " .. e.target_part) or ""))
        if e.source == "user" then
            imgui.same_line()
            if imgui.button(L.t("dbg.delete") .. "##sd" .. i) then call("request_delete", { kind = "sculpt", name = e.name, folder = e.folder }) end
        end
    end
    local pd = pr.pending_delete
    if pd then
        imgui.text_colored(L.t("dbg.confirm_delete", pd.kind, pd.name), 0xFF5555FF)
        imgui.same_line()
        if imgui.button(L.t("dbg.confirm") .. "##del") then call("confirm_delete") end
        imgui.same_line()
        if imgui.button(L.t("dbg.cancel") .. "##del") then call("cancel_delete") end
    end
end

function D.draw()
    if not imgui.tree_node("ShapeKeySystem (M1 debug)") then return end
    drawn = true
    local st, live = SKS.state, SKS.live
    local rt, ex, eyes, dbg = st.runtime, st.expression, st.eyes, st.debug

    imgui.text(dbg.status)
    local a = dbg.perf
    imgui.text(string.format("avg ms/frame: total %.3f | read %.3f  compute %.3f  write %.3f  scan %.3f | writes %.1f  skipped %.1f",
        a.total, a.read, a.compute, a.write, a.scan, a.writes, a.skipped))
    if last_err ~= "" then imgui.text_colored(L.t("dbg.last_error", last_err), 0xFF5555FF) end
    for _, n in ipairs(rt.notices) do
        imgui.text(string.format("[%s] %s", n.level, L.notice_text(n)))
        imgui.same_line()
        if imgui.button("x##n" .. n.id) then call("dismiss_notice", { id = n.id }) end
    end

    local changed, v = imgui.checkbox(L.t("dbg.enabled") .. "##sks_on", rt.enabled)
    if changed then call("set_enabled", { on = v }) end
    imgui.same_line()
    if imgui.button(L.t("dbg.rescan") .. "##sks_rescan") then call("rescan") end

    -- profile
    local plist, labels, cur = st.presets.expression, {}, 1
    for i, p in ipairs(plist) do
        labels[i] = string.format("%s [%s]", L.field(p, "name"), p.source)
        if ex.profile and p.id == ex.profile.id and p.source == ex.profile.source then cur = i end
    end
    if #labels > 0 then
        changed, v = imgui.combo(L.t("dbg.profile") .. "##sks_profile", cur, labels)
        if changed then call("set_profile", { id = plist[v].id }) end
    end
    local cov = ex.coverage
    if cov then
        imgui.text(L.t("dbg.coverage", cov.arkit_hit, cov.arkit_total, cov.extra, tostring(cov.recommended)))
    end

    changed, v = imgui.slider_float(L.t("dbg.master") .. "##sks_master", ex.master_gain, 0, 2); if changed then call("set_master_gain", { value = v }) end
    changed, v = imgui.slider_float(L.t("dbg.gaze") .. "##sks_gaze", ex.gaze_gain, 0, 2); if changed then call("set_gaze_gain", { value = v }) end
    changed, v = imgui.slider_float(L.t("dbg.smoothing") .. "##sks_smooth", ex.smoothing, 0, 1); if changed then call("set_smoothing", { value = v }) end
    for i, r in ipairs(ex.regions) do
        changed, v = imgui.slider_float(L.t("dbg.region", L.field(r, "name"), live.region_activity[i] or 0) .. "##rg" .. r.key, r.gain, 0, 2)
        if changed then call("set_region_gain", { region = r.key, value = v }) end
    end

    if imgui.tree_node(L.t("dbg.channels") .. "##sks_channels") then draw_channels(st, live); imgui.tree_pop() end

    if imgui.tree_node(L.t("dbg.gaze_tree") .. "##sks_gaze_tree") then
        changed, v = imgui.slider_float(L.t("dbg.full_yaw") .. "##sks_fy", eyes.full_deg.yaw, 5, 60)
        if changed then call("set_eye_cfg", { patch = { full_deg = { yaw = v } } }) end
        changed, v = imgui.slider_float(L.t("dbg.full_pitch") .. "##sks_fp", eyes.full_deg.pitch, 5, 60)
        if changed then call("set_eye_cfg", { patch = { full_deg = { pitch = v } } }) end
        changed, v = imgui.checkbox(L.t("dbg.invert_yaw") .. "##sks_iy", eyes.invert.yaw)
        if changed then call("set_eye_cfg", { patch = { invert = { yaw = v } } }) end
        imgui.same_line()
        changed, v = imgui.checkbox(L.t("dbg.invert_pitch") .. "##sks_ip", eyes.invert.pitch)
        if changed then call("set_eye_cfg", { patch = { invert = { pitch = v } } }) end
        changed, v = imgui.checkbox(L.t("dbg.set_eye_look") .. "##sks_el", eyes.sets.eye_look)
        if changed then call("set_eye_cfg", { patch = { sets = { eye_look = v } } }) end
        changed, v = imgui.checkbox(L.t("dbg.set_look") .. "##sks_lk", eyes.sets.look)
        if changed then call("set_eye_cfg", { patch = { sets = { look = v } } }) end
        for _, s in ipairs({ "L", "R" }) do
            local e = live.eye_angle[s]
            imgui.text(string.format("%s  yaw %.2f  pitch %.2f", s, e.yaw, e.pitch))
        end
        if imgui.button(L.t("dbg.calibrate") .. "##sks_cal") then call("calibrate_eye_neutral") end
        imgui.tree_pop()
    end

    local map_open = imgui.tree_node(L.t("dbg.mapping") .. "##sks_mapping")
    want_signals = map_open
    if map_open then draw_mapping(st, live); imgui.tree_pop() end

    if imgui.tree_node(L.t("dbg.sculpt") .. "##sks_sculpt") then draw_sculpt(st); imgui.tree_pop() end
    if imgui.tree_node(L.t("dbg.presets") .. "##sks_presets") then draw_presets(st); imgui.tree_pop() end

    if imgui.tree_node(L.t("dbg.scene") .. "##sks_scene") then
        for _, r in ipairs(st.scene.rigs) do
            local t = {}
            for _, x in ipairs(r.targets) do t[#t + 1] = string.format("%s (%d ch, %d idx)", x.name, x.channels, x.writes) end
            imgui.text((r.primary and "★ " or "  ") .. r.label .. L.t("dbg.rig_reads", r.reads or 0) .. table.concat(t, ", "))
        end
        for _, p in ipairs(st.scene.parts) do
            imgui.text(L.t("dbg.part_line", p.id, p.channels, p.fingerprint))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.t("dbg.settings") .. "##sks_settings") then
        local se = st.settings
        local langs, lcur = {}, 1
        for i, lang in ipairs(L.LANGS) do
            langs[i] = L.LANG_NAMES[lang] or lang
            if lang == (se.language or L.lang) then lcur = i end
        end
        changed, v = imgui.combo(L.t("dbg.language") .. "##sks_lang", lcur, langs)
        if changed and L.LANGS[v] then call("set_setting", { key = "language", value = L.LANGS[v] }) end
        changed, v = imgui.slider_int(L.t("dbg.periodic") .. "##sks_periodic", se.periodic_scan_sec, 0, 60)
        if changed then call("set_setting", { key = "periodic_scan_sec", value = v }) end
        changed, v = imgui.slider_float(L.t("dbg.epsilon") .. "##sks_eps", se.write_epsilon, 0, 0.01, "%.4f")
        if changed then call("set_setting", { key = "write_epsilon", value = v }) end
        changed, v = imgui.checkbox(L.t("dbg.clamp") .. "##sks_clamp", se.clamp)
        if changed then call("set_setting", { key = "clamp", value = v }) end
        changed, v = imgui.checkbox(L.t("dbg.scene_search") .. "##sks_scene_all", se.scene_search_always)
        if changed then call("set_setting", { key = "scene_search_always", value = v }) end
        changed, v = imgui.slider_float(L.t("dbg.sculpt_max") .. "##sks_smax", se.sculpt_max or 1, 1, 5, "%.1f")
        if changed then call("set_setting", { key = "sculpt_max", value = v }) end
        changed, v = imgui.checkbox(L.t("dbg.cutscene") .. "##sks_cutscene", se.cutscene_drive)
        if changed then call("set_setting", { key = "cutscene_drive", value = v }) end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.t("dbg.probe") .. "##sks_probe") then
        if imgui.button(L.t("dbg.probe_run") .. "##sks_probe_run") then SKS.request_probe() end
        for _, line in ipairs(dbg.probe or {}) do imgui.text(line) end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.t("dbg.log") .. "##sks_log") then
        local l = dbg.log
        for i = #l, math.max(1, #l - 40), -1 do imgui.text(l[i].time .. "  " .. l[i].text) end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end

-- called once per frame after drawing: tells the backend whether a panel is visible (this one or
-- the d2d panel: panel_open / panel_signals)
function D.end_frame(panel_open, panel_signals)
    SKS.set_ui_open(drawn or panel_open == true, (drawn and want_signals) or panel_signals == true)
    drawn = false
end

function D.attach(sks) SKS = sks end

return D
