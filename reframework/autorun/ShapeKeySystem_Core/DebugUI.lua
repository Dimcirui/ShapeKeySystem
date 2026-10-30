-- ShapeKeySystem: temporary imgui debug panel (M1). Uses only SKS.state / SKS.live / SKS.call,
-- like the d2d panel will (M3).

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
        if imgui.tree_node(string.format("%s (%d)##grp_%s", L.tr(g.name), #g.channel_slots, g.key)) then
            for _, s in ipairs(g.channel_slots) do
                local c = ex.channels[s]
                local tags = (c.present and "" or L.tr(" [mesh 无]")) .. (c.has_signal and "" or L.tr(" [无信号]"))
                    .. (c.guessed and L.tr(" [推测]") or "") .. (c.edited and L.tr(" [已改]") or "")
                local changed, v = imgui.slider_float(string.format("%-22s %.2f%s##g%d", c.name, live.weight[s] or 0, tags, s),
                    c.gain, 0.0, 3.0)
                if changed then call("set_channel_gain", { name = c.canonical, value = v }) end
                imgui.same_line()
                changed, v = imgui.checkbox(L.tr("测试") .. "##t" .. s, c.forced)
                if changed then call("force_channel", { name = c.canonical, on = v }) end
                if imgui.is_item_hovered() then imgui.set_tooltip(c.source_text .. (c.note and ("\n" .. L.tr(c.note)) or "")) end
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
    local changed, idx = imgui.combo(L.tr("通道") .. "##map", edit.channel, names)
    if changed then edit.channel = idx; edit.loaded_for = nil end
    local name = names[edit.channel] or names[1]
    if edit.loaded_for ~= name then
        edit.text = encode(m.nodes[name] or {})
        edit.loaded_for = name
    end
    local c = ex.channels[edit.channel]
    if c then imgui.text(L.f("来源: %s", c.source_text)) end
    changed, edit.text = imgui.input_text(L.tr("节点 JSON") .. "##node", edit.text)
    if imgui.button(L.tr("应用") .. "##node") then
        local ok, node = pcall(json.load_string, edit.text)
        if ok and type(node) == "table" then call("edit_node", { name = name, node = node })
        else last_err = L.tr("JSON 解析失败") end
    end
    imgui.same_line()
    if imgui.button(L.tr("恢复") .. "##node") then
        if call("revert_node", { name = name }) then edit.loaded_for = nil end
    end
    changed, save_name = imgui.input_text(L.tr("另存为") .. "##pname", save_name)
    imgui.same_line()
    if imgui.button(L.tr("保存") .. "##profile") then
        call("save_profile", { as_name = (save_name ~= "" and save_name or nil) })
    end

    imgui.text(L.tr("活跃信号（归一化）："))
    local act = {}
    for i, sd in ipairs(m.signals) do
        local v = live.signal[i] or 0
        if v > 0.02 then act[#act + 1] = { sd, v } end
    end
    table.sort(act, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(#act, 24) do
        local sd, v = act[i][1], act[i][2]
        imgui.text(string.format("  %-18s %s  %.2f  %s%s", sd.name, L.tr(sd.label), v, L.tr(sd.note), sd.guessed and L.tr(" [推测]") or ""))
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
    if imgui.button(L.tr("扫描") .. "##sculpt") then call("sculpt_scan") end
    imgui.same_line()
    local changed, v = imgui.checkbox(L.tr("强制覆盖（每帧写入）"), sc.edit_mode)
    if changed then call("set_edit_mode", { on = v }) end
    imgui.same_line()
    changed, v = imgui.checkbox(L.tr("A/B：显示 mod 默认值"), sc.ab_preview)
    if changed then call("set_ab_preview", { on = v }) end
    if imgui.button(L.tr("撤销") .. "##sculpt") then call("sculpt_undo") end
    imgui.same_line()
    if imgui.button(L.tr("重做") .. "##sculpt") then call("sculpt_redo") end
    imgui.same_line()
    imgui.text(L.f("%s  当前配置：%s", L.tr(sc.dirty and "[未保存]" or "[已保存]"),
        sc.preset and (sc.preset.name .. " (" .. sc.preset.source .. ")") or L.tr("无")))
    local scan = sc.scan
    if scan then
        imgui.text(L.f("部件 %s  形态键 %d  （其中 %d 个由表情驱动，锁定）",
            table.concat(scan.parts, ", "), scan.keys, scan.expression_keys or 0))
    end
    for _, g in ipairs(sc.groups) do
        if imgui.tree_node(string.format("%s (%d)##sg_%s", g.name, #g.key_indices, g.key)) then
            for _, i in ipairs(g.key_indices) do
                local k = sc.keys[i]
                if k.locked then
                    imgui.text(L.f("   %s  （表情驱动，锁定）", k.name))
                elseif k.in_group then
                    imgui.text(L.f("   %s  %.2f（由键组控制）", k.name, k.value))
                else
                    local extra = ""
                    for p, ov in pairs(k.overrides) do extra = extra .. string.format("  [%s=%.2f]", p, ov) end
                    changed, v = imgui.slider_float(string.format("%s%s##sk%d", k.name, extra, i), k.value, k.range[1], k.range[2])
                    if changed then call("set_sculpt_key", { name = k.name, value = v }) end
                    imgui.same_line()
                    if imgui.button(L.tr("默认") .. "##sr" .. i) then call("reset_sculpt_key", { name = k.name }) end
                    if imgui.is_item_hovered() then imgui.set_tooltip(L.f("mod 默认值 %.2f", k.default)) end
                end
            end
            imgui.tree_pop()
        end
    end
    changed, sculpt_name = imgui.input_text(L.tr("捏脸配置名") .. "##sname", sculpt_name)
    imgui.same_line()
    changed, v = imgui.checkbox(L.tr("存为通用预设（不属于某件装备）"), sculpt_general)
    if changed then sculpt_general = v end
    if imgui.button(L.tr("保存") .. "##sculpt") and sculpt_name ~= "" then
        call("save_sculpt", { name = sculpt_name, general = sculpt_general })
    end
    local part = primary_part_id(st)
    if part then
        imgui.same_line()
        if imgui.button(L.f("保存并绑定到 %s", part)) and sculpt_name ~= "" then
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
        imgui.text(L.f("生效的父预设：%s（部件 %s）  表情：%s  捏脸：%s%s", b.hit, b.part,
            tostring(b.expression or "-"), tostring(b.sculpt or "-"), b.fingerprint_ok and "" or L.tr("  [捏脸配置与网格通道不一致]")))
        for _, c in ipairs(b.chain) do
            imgui.text(string.format("   %s %s%s", c.hit and "→" or (c.exists and "·" or " "), c.path,
                c.error and L.f("  错误：%s", L.tr(c.error)) or ""))
        end
    else
        imgui.text(L.tr("没有命中的父预设（使用全局设置）"))
    end
    if part then
        if imgui.button(L.f("把当前表情配置和增益写入 %s 的父预设", part)) then
            call("write_binding", { part = part, expression = st.expression.profile and st.expression.profile.id,
                                    sculpt = st.sculpt.preset and st.sculpt.preset.name or nil, gains = true })
        end
        imgui.same_line()
        if imgui.button(L.tr("恢复 mod 自带的父预设") .. "##rmb") then call("restore_mod_binding", { part = part }) end
    end
    local tu = st.expression.tuning
    if tu then
        imgui.text(L.f("表情增益与视线设置来自：%s%s%s",
            tu.source == "binding" and tostring(tu.path) or L.tr("全局设置 settings.json"),
            tu.dirty and L.tr("  [未保存]") or "",
            tu.profile_mismatch and L.f("  [通道增益是为 %s 调的，暂不生效]", tostring(tu.for_profile)) or ""))
        if tu.source == "binding" then
            imgui.same_line()
            if imgui.button(L.tr("保存到这个部件的父预设") .. "##tune") then call("save_tuning") end
        end
    end
    imgui.text(L.tr("捏脸配置（点名字加载，不改父预设）："))
    for i, e in ipairs(pr.sculpt) do
        if imgui.button(string.format("%s##sl%d", e.name, i)) then call("load_sculpt", { name = e.name, folder = e.folder }) end
        imgui.same_line()
        imgui.text(string.format("(%s, %s%s)", e.source, e.folder or L.tr("通用"), e.target_part and (", " .. e.target_part) or ""))
        if e.source == "user" then
            imgui.same_line()
            if imgui.button(L.tr("删除") .. "##sd" .. i) then call("request_delete", { kind = "sculpt", name = e.name, folder = e.folder }) end
        end
    end
    local pd = pr.pending_delete
    if pd then
        imgui.text_colored(L.f("确认删除 %s：%s？", pd.kind, pd.name), 0xFF5555FF)
        imgui.same_line()
        if imgui.button(L.tr("确认") .. "##del") then call("confirm_delete") end
        imgui.same_line()
        if imgui.button(L.tr("取消") .. "##del") then call("cancel_delete") end
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
    if last_err ~= "" then imgui.text_colored(L.f("最近错误: %s", last_err), 0xFF5555FF) end
    for _, n in ipairs(rt.notices) do
        imgui.text(string.format("[%s] %s", n.level, L.tr(n.text)))
        imgui.same_line()
        if imgui.button("x##n" .. n.id) then call("dismiss_notice", { id = n.id }) end
    end

    local changed, v = imgui.checkbox(L.tr("启用"), rt.enabled)
    if changed then call("set_enabled", { on = v }) end
    imgui.same_line()
    changed, v = imgui.checkbox(L.tr("表情驱动"), st.settings.expression_enabled ~= false)
    if changed then call("set_setting", { key = "expression_enabled", value = v }) end
    if st.settings.hold_available then
        imgui.same_line()
        changed, v = imgui.checkbox(L.tr("禁用骨骼表情"), st.settings.hold_face_bones == true)
        if changed then call("set_setting", { key = "hold_face_bones", value = v }) end
        if st.settings.hold_face_bones and (st.settings.hold_status or "") ~= "" then
            imgui.same_line(); imgui.text(L.tr(st.settings.hold_status))
        end
    end
    imgui.same_line()
    if imgui.button(L.tr("重新扫描")) then call("rescan") end

    -- profile
    local plist, labels, cur = st.presets.expression, {}, 1
    for i, p in ipairs(plist) do
        labels[i] = string.format("%s [%s]", p.name, p.source)
        if ex.profile and p.id == ex.profile.id and p.source == ex.profile.source then cur = i end
    end
    if #labels > 0 then
        changed, v = imgui.combo(L.tr("表情配置"), cur, labels)
        if changed then call("set_profile", { id = plist[v].id }) end
        imgui.same_line()
        if imgui.button(L.tr("自动匹配")) then call("auto_match_profile", {}) end
    end

    changed, v = imgui.slider_float(L.tr("整体表情强度"), ex.master_gain, 0, 2); if changed then call("set_master_gain", { value = v }) end
    changed, v = imgui.slider_float(L.tr("视线强度"), ex.gaze_gain, 0, 2); if changed then call("set_gaze_gain", { value = v }) end
    changed, v = imgui.slider_float(L.tr("平滑"), ex.smoothing, 0, 1); if changed then call("set_smoothing", { value = v }) end
    for i, r in ipairs(ex.regions) do
        changed, v = imgui.slider_float(L.f("%s  (活跃 %.2f)", L.tr(r.name), live.region_activity[i] or 0) .. "##rg" .. r.key, r.gain, 0, 2)
        if changed then call("set_region_gain", { region = r.key, value = v }) end
    end

    if imgui.tree_node(L.tr("通道")) then draw_channels(st, live); imgui.tree_pop() end

    if imgui.tree_node(L.tr("视线")) then
        changed, v = imgui.slider_float(L.tr("满权重水平角"), eyes.full_deg.yaw, 5, 60)
        if changed then call("set_eye_cfg", { patch = { full_deg = { yaw = v } } }) end
        changed, v = imgui.slider_float(L.tr("满权重垂直角"), eyes.full_deg.pitch, 5, 60)
        if changed then call("set_eye_cfg", { patch = { full_deg = { pitch = v } } }) end
        changed, v = imgui.checkbox(L.tr("反转水平"), eyes.invert.yaw)
        if changed then call("set_eye_cfg", { patch = { invert = { yaw = v } } }) end
        imgui.same_line()
        changed, v = imgui.checkbox(L.tr("反转垂直"), eyes.invert.pitch)
        if changed then call("set_eye_cfg", { patch = { invert = { pitch = v } } }) end
        changed, v = imgui.checkbox(L.tr("驱动 EyeLook*（眼睑跟随）"), eyes.sets.eye_look)
        if changed then call("set_eye_cfg", { patch = { sets = { eye_look = v } } }) end
        changed, v = imgui.checkbox(L.tr("驱动 Look*（虹膜平面移动）"), eyes.sets.look)
        if changed then call("set_eye_cfg", { patch = { sets = { look = v } } }) end
        for _, s in ipairs({ "L", "R" }) do
            local e = live.eye_angle[s]
            imgui.text(string.format("%s  yaw %.2f  pitch %.2f", s, e.yaw, e.pitch))
        end
        if imgui.button(L.tr("把当前朝向设为正前方")) then call("calibrate_eye_neutral") end
        imgui.tree_pop()
    end

    local map_open = imgui.tree_node(L.tr("映射编辑 / 信号"))
    want_signals = map_open
    if map_open then draw_mapping(st, live); imgui.tree_pop() end

    if imgui.tree_node(L.tr("捏脸")) then draw_sculpt(st); imgui.tree_pop() end
    if imgui.tree_node(L.tr("预设 / 父预设")) then draw_presets(st); imgui.tree_pop() end

    if imgui.tree_node(L.tr("场景")) then
        for _, r in ipairs(st.scene.rigs) do
            local t = {}
            for _, x in ipairs(r.targets) do t[#t + 1] = string.format("%s (%d ch, %d idx)", x.display or x.name, x.channels, x.writes) end
            imgui.text((r.primary and "★ " or "  ") .. L.tr(r.label) .. L.f(" (每帧读 %d 个关节): ", r.reads or 0) .. table.concat(t, ", "))
        end
        for _, p in ipairs(st.scene.parts) do
            imgui.text(L.f("部件 %s  %d 通道  %s", p.display or p.id, p.channels, p.fingerprint))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.tr("设置")) then
        local se = st.settings
        changed, v = imgui.slider_int(L.tr("定期重扫 (秒, 0=关)"), se.periodic_scan_sec, 0, 60)
        if changed then call("set_setting", { key = "periodic_scan_sec", value = v }) end
        changed, v = imgui.slider_float(L.tr("写入阈值"), se.write_epsilon, 0, 0.01, "%.4f")
        if changed then call("set_setting", { key = "write_epsilon", value = v }) end
        changed, v = imgui.checkbox(L.tr("截断到 0..1"), se.clamp)
        if changed then call("set_setting", { key = "clamp", value = v }) end
        if se.scene_search_available ~= false then
            changed, v = imgui.checkbox(L.tr("始终搜索整个场景（其他猎人；名片自动）"), se.scene_search_always)
            if changed then call("set_setting", { key = "scene_search_always", value = v }) end
        end
        changed, v = imgui.slider_float(L.tr("捏脸滑块上限"), se.sculpt_max or 1, 1, 5, "%.1f")
        if changed then call("set_setting", { key = "sculpt_max", value = v }) end
        changed, v = imgui.checkbox(L.tr("过场动画中驱动"), se.cutscene_drive)
        if changed then call("set_setting", { key = "cutscene_drive", value = v }) end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.tr("通道哈希探针")) then
        if imgui.button(L.tr("运行（结果也写入 data/ShapeKeySystem/hash_probe.txt）")) then SKS.request_probe() end
        for _, line in ipairs(dbg.probe or {}) do imgui.text(line) end
        imgui.tree_pop()
    end

    if imgui.tree_node(L.tr("日志")) then
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
