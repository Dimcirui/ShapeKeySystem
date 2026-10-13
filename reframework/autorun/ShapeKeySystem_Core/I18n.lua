-- ShapeKeySystem: interface language (settings.language = "zh" | "en"; zh is the default).
--
--   local L = require("ShapeKeySystem_Core.I18n")
--   L.t("sculpt.saved", name)     message id + string.format params, in the current language
--   L.field(obj, "name")          obj.name_en in English (when present), else obj.name
--   L.pick(v)                     v as it is, or {zh = .., en = ..} by language, or {k = id, args = {..}}
--   L.notice_text(n)              a backend notice {key, args, text} in the current language
--
-- Who translates what (docs/plans/shape-key-system-api.md section 15):
--   * panel / imgui strings and backend notices: this table, by message id. Notices carry
--     key + args, so a language switch re-renders them; their `text` is a rendering for readers
--     that do not translate.
--   * definitions that live with their data: name / label / note in Chinese plus name_en /
--     label_en / note_en next to it (Expression.lua regions and groups, Conditions.lua, Version.lua,
--     profile and signal JSON, face styles, armor_names.json). The UI picks with L.field.
--   * never translated: shape-key / channel names, signal names, ids, file names, commands.
-- A missing English text falls back to Chinese; an unknown id shows the id and is listed in L.missing.

local L = { lang = "zh", missing = {} }

L.LANGS = { "zh", "en" }
-- shown in the language picker in their own script, whatever the interface language is
L.LANG_NAMES = { zh = "中文", en = "English" }

local VALID = { zh = true, en = true }

function L.set(lang)
    if not VALID[lang] then return false end
    L.lang = lang
    return true
end

local S = {}
L.S = S

function L.pick(v)
    if type(v) ~= "table" then return v end
    if v.k then return L.t(v.k, table.unpack(v.args or {})) end
    local s = v[L.lang]
    if s == nil or s == "" then s = v.zh end
    return s
end

function L.field(obj, f)
    if type(obj) ~= "table" then return nil end
    if L.lang ~= "zh" then
        local v = obj[f .. "_" .. L.lang]
        if v ~= nil and v ~= "" then return v end
    end
    return obj[f]
end

function L.t(id, ...)
    local e = S[id]
    if not e then
        L.missing[id] = true
        return id
    end
    local s = e[L.lang]
    if s == nil or s == "" then s = e.zh end
    local n = select("#", ...)
    if n == 0 then return s end
    local args = table.pack(...)
    for i = 1, n do
        local a = args[i]
        if type(a) == "table" then a = L.pick(a) end
        if a == nil then a = "nil" end
        args[i] = a
    end
    local ok, out = pcall(string.format, s, table.unpack(args, 1, n))
    if ok then return out end
    local parts = {}
    for i = 1, n do parts[i] = tostring(args[i]) end
    return s .. " " .. table.concat(parts, " ")
end

function L.notice_text(n)
    if type(n) ~= "table" then return tostring(n) end
    if n.key then return L.t(n.key, table.unpack(n.args or {})) end
    return n.text or ""
end

-- --------------------------------------------------------------------------------------------
-- message table: id = { zh, en }. zh is the original wording; ids are grouped by where they show.
local function add(list) for id, e in pairs(list) do S[id] = { zh = e[1], en = e[2] } end end

-- shared
add({
    ["common.none"]          = { "（无）", "(none)" },
    ["common.save"]          = { "保存", "Save" },
    ["common.save_as"]       = { "另存为", "Save as" },
    ["common.delete"]        = { "删除", "Delete" },
    ["common.cancel"]        = { "取消", "Cancel" },
    ["common.apply"]         = { "应用", "Apply" },
    ["common.new"]           = { "新建", "New" },
    ["common.remove"]        = { "移除", "Remove" },
    ["common.yes"]           = { "是", "yes" },
    ["common.no"]            = { "否", "no" },
    ["common.empty"]         = { "（空）", "(empty)" },
    ["common.saved"]         = { "已保存：%s", "Saved: %s" },
    ["common.name_source"]   = { "%s（%s）", "%s (%s)" },
    ["common.held_by"]       = { "由 %s 控制", "held by %s" },
    ["common.take_back"]     = { "收回", "Take back" },
    ["common.dash"]          = { "—", "—" },
    ["src.builtin"]          = { "内置", "built-in" },
    ["src.mods"]             = { "mod 自带", "mod" },
    ["src.user"]             = { "用户", "user" },
})

-- panel chrome (Panel.lua)
add({
    ["page.basic"]           = { "表情", "Expression" },
    ["page.sculpt"]          = { "捏脸", "Sculpt" },
    ["page.facial"]          = { "整脸表情", "Face presets" },
    ["page.expr"]            = { "表情详情", "Channels" },
    ["page.cond"]            = { "条件表情", "Conditions" },
    ["page.debug"]           = { "设置与调试", "Settings" },
    ["panel.section_basic"]  = { "基础", "Basic" },
    ["panel.section_adv"]    = { "进阶", "Advanced" },
    ["panel.subtitle"]       = { "形态键系统", "Shape Key System" },
    ["panel.enabled"]        = { "启用", "On" },
    ["panel.advanced"]       = { "进阶", "Advanced" },
    ["panel.status"]         = { "%.2f ms/帧 · 写入 %.1f / 跳过 %.1f", "%.2f ms/frame · writes %.1f / skipped %.1f" },
    ["panel.cmd_failed"]     = { "%s：%s %s", "%s: %s %s" },
    ["panel.page_load_failed"] = { "页面加载失败：%s", "Page failed to load: %s" },
    ["panel.page_error"]     = { "页面出错：%s", "Page error: %s" },
    ["panel.avm_open"]       = { "ArmorVariantManager 的面板也开着：点击会同时传给两个面板",
                                 "ArmorVariantManager's panel is open too: clicks reach both panels" },
    ["panel.prompt_error"]   = { "输入框：%s", "Text input: %s" },
})

-- widgets (Widgets.lua): outfit defaults
add({
    ["bind.set_default_for"] = { "设为 %s 的默认", "Default for %s" },
    ["bind.set_default"]     = { "设为默认", "Set as default" },
    ["bind.default_tip"]     = { "穿上 %s 时自动使用左边选中的配置", "Used automatically while %s is worn" },
    ["bind.suffix_default"]  = { " · 默认", " · default" },
    ["bind.suffix_global"]   = { " · 全局默认", " · global default" },
})

-- text prompt (Prompt.lua)
add({
    ["prompt.title"]         = { "输入", "Input" },
    ["prompt.done"]          = { "完成", "Done" },
    ["prompt.ok"]            = { "确定", "OK" },
})

-- basic page (PageBasic.lua)
add({
    ["basic.no_faces"]       = { "缺少面部图：reframework/data/ShapeKeySystem/faces/*.json",
                                 "No face image: reframework/data/ShapeKeySystem/faces/*.json" },
    ["basic.missing_image"]  = { "缺少图片 reframework/images/%s", "Missing image reframework/images/%s" },
    ["basic.profile"]        = { "表情配置", "Profile" },
    ["basic.from_binding"]   = { "来自绑定", "from binding" },
    ["basic.live"]           = { "实时 %.2f", "live %.2f" },
    ["basic.show_channels"]  = { "在表情详情中查看 %d 个通道", "Show %d channels" },
    ["basic.strength"]       = { "强度", "Strength" },
    ["basic.no_region"]      = { "当前表情配置没有这个部位。", "The current profile has no channels here." },
    ["basic.overall"]        = { "整体", "Overall" },
    ["basic.master"]         = { "表情强度", "Expression" },
    ["basic.gaze"]           = { "视线强度", "Gaze" },
})

-- expression details (PageExpression.lua)
add({
    ["expr.profile"]         = { "表情配置", "Profile" },
    ["expr.save_tuning"]     = { "保存调整", "Save tuning" },
    ["expr.save_tuning_tip"] = { "把强度、增益和视线设置保存到当前绑定", "Save strengths, gains and gaze settings to the current binding" },
    ["expr.browsing"]        = { "正在浏览：%s（未应用）· 当前装备的网格匹配 %d / %d 个通道",
                                 "Browsing: %s (not applied) · the worn meshes match %d / %d channels" },
    ["expr.coverage"]        = { "ARKit 覆盖 %d/%d · 扩展 %d", "ARKit coverage %d/%d · extra %d" },
    ["expr.gains_other"]     = { "单通道增益属于 %s，切回它时生效", "Channel gains belong to %s and apply when you switch back to it" },
    ["expr.tuning_unsaved"]  = { "调整未保存", "Tuning not saved" },
    ["expr.filter"]          = { "筛选通道…", "Filter channels…" },
    ["expr.filter_title"]    = { "筛选通道", "Filter channels" },
    ["expr.only_present"]    = { "只看网格里有的", "On mesh only" },
    ["expr.only_active"]     = { "只看活跃", "Active only" },
    ["expr.smoothing"]       = { "平滑", "Smoothing" },
    ["expr.collapse_all"]    = { "全部收起", "Collapse all" },
    ["expr.expand_all"]      = { "全部展开", "Expand all" },
    ["expr.region_strength"] = { "%s 强度", "%s" },
    ["expr.guessed"]         = { "推测", "guess" },
    ["expr.extension"]       = { "扩展", "extra" },
    ["expr.not_on_mesh_tail"] = { "  · 网格里没有", "  · not on mesh" },
    ["expr.test"]            = { "测试", "Test" },
    ["expr.mesh_name"]       = { "网格：%s", "Mesh: %s" },
    ["expr.not_on_mesh"]     = { "网格里没有", "Not on mesh" },
    ["expr.count"]           = { "%d 个", "%d" },
    ["expr.gaze_settings"]   = { "视线设置", "Gaze settings" },
})

-- gaze settings (PageEyes.lua)
add({
    ["eyes.angles"]          = { "水平 %+.1f°   垂直 %+.1f°", "yaw %+.1f°   pitch %+.1f°" },
    ["eyes.right"]           = { "右眼", "Right eye" },
    ["eyes.left"]            = { "左眼", "Left eye" },
    ["eyes.mapping"]         = { "映射", "Mapping" },
    ["eyes.full_yaw"]        = { "满权重水平角", "Full-weight yaw" },
    ["eyes.full_pitch"]      = { "满权重垂直角", "Full-weight pitch" },
    ["eyes.invert_yaw"]      = { "水平反转", "Invert yaw" },
    ["eyes.invert_pitch"]    = { "垂直反转", "Invert pitch" },
    ["eyes.calibrate"]       = { "把当前朝向设为正前方", "Set current direction as straight ahead" },
    ["eyes.sets"]            = { "驱动的形态键组", "Driven key sets" },
    ["eyes.set_eye_look"]    = { "EyeLook*（眼睑跟随）", "EyeLook* (eyelids follow)" },
    ["eyes.set_look"]        = { "Look*（虹膜平面移动）", "Look* (iris slides)" },
    ["eyes.iris_note1"]      = { "虹膜仍绑着眼球骨骼权重时，", "If the iris is still weighted to the eye bones," },
    ["eyes.iris_note2"]      = { "会和 Look* 叠加，移动量翻倍。", "Look* adds to it and the movement doubles." },
    ["eyes.gain_hint"]       = { "视线强度在「表情」页调整。", "Gaze strength is set on the Expression page." },
})

-- sculpt (PageSculpt.lua)
add({
    ["sculpt.scan"]          = { "扫描装备", "Scan outfit" },
    ["sculpt.scan_info"]     = { "%d 个部件 · %d 项（已合并同名，%d 项由表情驱动）",
                                 "Parts %d · keys %d (merged by name, %d from expressions)" },
    ["sculpt.not_scanned"]   = { "还没有扫描", "Not scanned yet" },
    ["sculpt.force"]         = { "强制覆盖", "Force write" },
    ["sculpt.force_tip"]     = { "平时改动只在数值变化时写一次就生效；其他插件也在改同一个形态键、值被抢回去时再打开，打开后每帧都写入",
                                 "A change is normally written once, when the value changes. Turn this on when another plugin keeps taking the same key back: then it is written every frame" },
    ["sculpt.general_suffix"] = { "（通用）", " (general)" },
    ["sculpt.config"]        = { "捏脸配置", "Sculpt config" },
    ["sculpt.none_selected"] = { "（未选择）", "(none selected)" },
    ["sculpt.no_configs"]    = { "（还没有配置）", "(no configs yet)" },
    ["sculpt.save_general"]  = { "存为通用配置（不属于这套装备）", "Save as a general config (not tied to this outfit)" },
    ["sculpt.save_new_title"] = { "保存为新配置（mod 自带的配置不能覆盖）", "Save as a new config (a mod's config cannot be overwritten)" },
    ["sculpt.save_title"]    = { "保存捏脸配置", "Save sculpt config" },
    ["sculpt.save_as"]       = { "另存为…", "Save as…" },
    ["sculpt.delete_confirm"] = { "删除捏脸配置「%s」？", "Delete sculpt config \"%s\"?" },
    ["sculpt.ab_on"]         = { "正在看：初始", "Showing: initial" },
    ["sculpt.ab_off"]        = { "对比初始", "Compare initial" },
    ["sculpt.only_modified"] = { "只看已修改", "Modified only" },
    ["sculpt.show_locked"]   = { "显示表情通道", "Expression keys" },
    ["sculpt.hide_unpreset"] = { "隐藏非预设通道", "Preset keys only" },
    ["sculpt.hide_unpreset_tip"] = { "只显示 mod 自带或当前捏脸配置里用到的形态键（改过的键总会显示）",
                                     "Show only the keys a mod's config or the current sculpt config uses (changed keys always show)" },
    ["sculpt.zero"]          = { "归零", "Zero" },
    ["sculpt.reset"]         = { "重置", "Reset" },
    ["sculpt.redo"]          = { "重做", "Redo" },
    ["sculpt.undo"]          = { "撤销", "Undo" },
    ["sculpt.search"]        = { "搜索形态键…", "Search keys…" },
    ["sculpt.search_title"]  = { "搜索形态键", "Search shape keys" },
    ["sculpt.ab_tip"]        = { "临时显示初始值（mod 默认值），再点一次回到当前值",
                                 "Shows the initial values (mod defaults) for now; click again to go back" },
    ["sculpt.zero_tip"]      = { "所有形态键归零，可以撤销", "Set every key to 0 (can be undone)" },
    ["sculpt.reset_tip"]     = { "所有形态键恢复为 mod 默认值，可以撤销", "Reset every key to the mod default (can be undone)" },
    ["sculpt.unsaved"]       = { "有未保存的修改", "Unsaved changes" },
    ["sculpt.mixed"]         = { "表情叠加", "expression mix" },
    ["sculpt.has_overrides"] = { "有部件单独值", "per-part values" },
    ["sculpt.external_tip"]  = { "另一个插件正在控制这个形态键；收回后恢复捏脸的值",
                                 "Another plugin controls this key; take it back to restore the sculpt value" },
    ["sculpt.per_part"]      = { "按部件", "Per part" },
    ["sculpt.default"]       = { "默认", "Default" },
    ["sculpt.default_tip"]   = { "恢复为 mod 默认值 %.2f", "Back to the mod default %.2f" },
    ["sculpt.follow_merged"] = { "跟随合并值", "Follow merged" },
    ["sculpt.scan_hint"]     = { "点「扫描装备」读取身上部件的形态键。", "Click \"Scan outfit\" to read the shape keys of the worn parts." },
    ["sculpt.count"]         = { "%d 项", "%d" },
    ["sculpt.no_match"]      = { "没有匹配的形态键。", "No matching shape keys." },
})

-- facial presets (PageFacial.lua)
add({
    ["facial.hint"]          = { "形态键名为数字的整脸表情（如 Maya 的 1–10）。",
                                 "Whole-face expressions on numbered shape keys (like Maya's 1–10)." },
    ["facial.keep"]          = { "动作驱动的表情保留 %d%%，视线照常。", "Emote-driven face kept at %d%%; gaze unaffected." },
    ["facial.all_off"]       = { "全部归零", "All off" },
    ["facial.none"]          = { "身上部件没有数字命名的形态键（1、2、3…）。",
                                 "The worn parts have no numbered shape keys (1, 2, 3…)." },
})

-- bindings and config files (PagePresets.lua, shown under settings & debug)
add({
    ["files.delete_confirm"] = { "删除「%s」？此操作不能撤销。", "Delete \"%s\"? This cannot be undone." },
    ["files.binding_title"]  = { "绑定（查找过程）", "Binding (lookup)" },
    ["files.part"]           = { "部件 %s", "Part %s" },
    ["files.no_parts"]       = { "没有带形态键的部件", "No parts with shape keys" },
    ["files.error"]          = { "错误：%s", "Error: %s" },
    ["files.hit"]            = { "命中", "hit" },
    ["files.exists_unused"]  = { "存在 · 未采用", "exists · not used" },
    ["files.configs"]        = { "表情配置：%s    捏脸配置：%s", "Profile: %s    Sculpt config: %s" },
    ["files.fingerprint_bad"] = { "捏脸配置和当前网格的通道不一致（换过模型？）",
                                  "The sculpt config does not match the current mesh's channels (model changed?)" },
    ["files.no_binding"]     = { "没有绑定，正在使用全局设置。", "No binding: the global settings are in use." },
    ["files.write_binding"]  = { "把当前表情、捏脸配置和增益写入绑定", "Write profile, sculpt config and gains to the binding" },
    ["files.restore_mod"]    = { "恢复 mod 自带的绑定", "Restore the mod's binding" },
    ["files.tuning_from"]    = { "表情增益与视线设置来自：%s", "Expression gains and gaze settings from: %s" },
    ["files.global_settings"] = { "全局设置 settings.json", "global settings.json" },
    ["files.unsaved_tail"]   = { "  · 未保存", "  · not saved" },
    ["files.gains_other_tail"] = { "  · 通道增益是为 %s 调的，暂不生效", "  · channel gains were tuned for %s and are off" },
    ["files.save_to_binding"] = { "保存到绑定", "Save to binding" },
    ["files.sculpt_list"]    = { "捏脸配置", "Sculpt configs" },
    ["files.profile_list"]   = { "表情配置", "Expression profiles" },
    ["files.general"]        = { "通用", "general" },
    ["files.load"]           = { "加载", "Load" },
    ["files.extends"]        = { " · 继承 %s", " · extends %s" },
    ["files.use"]            = { "使用", "Use" },
})

-- conditional expressions (PageConditions.lua)
add({
    ["cond.status_active"]   = { "生效中", "active" },
    ["cond.status_outranked"] = { "命中，但被上面的压着", "matched, outranked" },
    ["cond.status_idle"]     = { "未命中", "not matched" },
    ["cond.unknown"]         = { "未知条件 %s", "Unknown condition %s" },
    ["cond.is_no"]           = { " ＝ 否", " = no" },
    ["cond.eq"]              = { "＝", "=" },
    ["cond.ne"]              = { "≠", "≠" },
    ["cond.band"]            = { "（回差 %s）", " (band %s)" },
    ["cond.none"]            = { "（不使用）", "(none)" },
    ["cond.unsaved_suffix"]  = { "（未保存）", " (unsaved)" },
    ["cond.set"]             = { "配置", "Set" },
    ["cond.unsaved_toast"]   = { "当前配置有未保存的修改：先保存或还原", "The current set has unsaved changes: save or revert first" },
    ["cond.new_title"]       = { "新建条件表情配置", "New condition set" },
    ["cond.save_as_title"]   = { "另存为（mod 自带的配置不能覆盖）", "Save as (a mod's set cannot be overwritten)" },
    ["cond.revert"]          = { "还原", "Revert" },
    ["cond.auto"]            = { "自动", "Auto" },
    ["cond.auto_tip"]        = { "关闭后规则暂停（拍照、试表情时用）", "Off pauses the rules (for photos or trying expressions)" },
    ["cond.delete_confirm"]  = { "删除条件表情配置「%s」？", "Delete condition set \"%s\"?" },
    ["cond.band_tip"]        = { "回差：命中后要越过阈值这么多才算结束，避免数值卡在阈值附近时来回闪",
                                 "Band: once matched, the value must cross the threshold by this much to end, so it does not flicker near the threshold" },
    ["cond.add"]             = { "添加", "Add" },
    ["cond.states"]          = { "状态（靠上的优先生效）", "States (higher ones win)" },
    ["cond.any_rule"]        = { "规则满足一种即生效", "Any one rule is enough" },
    ["cond.delete_state"]    = { "删除状态", "Delete state" },
    ["cond.down"]            = { "下移", "Down" },
    ["cond.up"]              = { "上移", "Up" },
    ["cond.or_rule"]         = { "或者", "or" },
    ["cond.rule"]            = { "规则 %d", "Rule %d" },
    ["cond.hold"]            = { "条件结束后保持", "Hold after end" },
    ["cond.delete_rule"]     = { "删除规则", "Delete rule" },
    ["cond.or"]              = { "或", "OR" },
    ["cond.and"]             = { "且", "AND" },
    ["cond.now"]             = { "当前：%s", "now: %s" },
    ["cond.add_condition"]   = { "＋ 添加条件", "+ Add condition" },
    ["cond.add_rule"]        = { "＋ 添加规则", "+ Add rule" },
    ["cond.need_clip"]       = { "先在下面新建一个表情组合，再添加状态。", "Create an expression clip below first, then add states." },
    ["cond.add_state"]       = { "＋ 添加状态", "+ Add state" },
    ["cond.clips"]           = { "表情组合", "Expression clips" },
    ["cond.new_clip"]        = { "＋ 新建组合", "+ New clip" },
    ["cond.new_clip_title"]  = { "新建表情组合", "New expression clip" },
    ["cond.n_keys"]          = { "%d 个形态键", "%d keys" },
    ["cond.stop_preview"]    = { "停止预览", "Stop preview" },
    ["cond.preview"]         = { "预览", "Preview" },
    ["cond.fade_in"]         = { "淡入", "Fade in" },
    ["cond.fade_out"]        = { "淡出", "Fade out" },
    ["cond.add_key"]         = { "＋ 添加形态键…", "+ Add shape key…" },
    ["cond.scan_first"]      = { "先在「捏脸」页扫描装备，才能选择形态键", "Scan the outfit on the Sculpt page first to pick shape keys" },
    ["cond.no_clips"]        = { "还没有表情组合。", "No expression clips yet." },
    ["cond.live"]            = { "实时条件", "Live conditions" },
    ["cond.live_hint"]       = { "（只在游戏中、主角色可操作时读取）", "(read only in game, while your hunter can act)" },
    ["cond.intro"]           = { "满足一定条件时应用指定表情。", "Plays the chosen expression while game conditions are met." },
})

-- settings & debug (PageDebug.lua)
add({
    ["debug.settings"]       = { "设置", "Settings" },
    ["debug.language"]       = { "语言 / Language", "Language" },
    ["debug.hotkey"]         = { "打开面板的按键", "Panel hotkey" },
    ["debug.ui_scale"]       = { "界面缩放", "UI scale" },
    ["debug.face_style"]     = { "面部图样式", "Face image style" },
    ["debug.sculpt_max"]     = { "捏脸滑块上限", "Sculpt slider max" },
    ["debug.periodic"]       = { "定期重扫（秒，0=关）", "Rescan every (s, 0 = off)" },
    ["debug.epsilon"]        = { "写入阈值", "Write threshold" },
    ["debug.clamp"]          = { "权重截断到 0..1", "Clamp weights to 0..1" },
    ["debug.cutscene"]       = { "过场动画中驱动", "Drive in cutscenes" },
    ["debug.scene_search"]   = { "始终搜索整个场景（其他猎人；名片和菜单自动）", "Always search the whole scene (other hunters)" },
    ["debug.perf"]           = { "性能", "Performance" },
    ["debug.perf_line"]      = { "写入 %.1f / 跳过 %.1f 每帧", "writes %.1f / skipped %.1f per frame" },
    ["debug.t_read"]         = { "读取", "read" },
    ["debug.t_compute"]      = { "计算", "compute" },
    ["debug.t_write"]        = { "写入", "write" },
    ["debug.t_scan"]         = { "扫描", "scan" },
    ["debug.t_total"]        = { "合计", "total" },
    ["debug.last_scan"]      = { "最近扫描 %s · %.1f ms · 脸 %d（缓存跳过 %d）%s", "Last scan %s · %.1f ms · faces %d (cached skip %d)%s" },
    ["debug.guild_card"]     = { " · 名片", " · guild card" },
    ["debug.target"]         = { "%s（%d 通道）", "%s (%d ch)" },
    ["debug.rig_line"]       = { "%s：%s", "%s: %s" },
    ["debug.list_sep"]       = { "，", ", " },
    ["debug.part_line"]      = { "部件 %s · %d 通道 · 指纹 %s%s", "Part %s · %d channels · fingerprint %s%s" },
    ["debug.part_binding"]   = { " · 绑定 %s", " · binding %s" },
    ["debug.scene"]          = { "场景", "Scene" },
    ["debug.rescan"]         = { "重新扫描", "Rescan" },
    ["debug.probe"]          = { "哈希探针", "Hash probe" },
    ["debug.no_scan"]        = { "还没有扫描结果", "No scan yet" },
    ["debug.external"]       = { "其他插件的控制", "Held by other plugins" },
    ["debug.api_hint"]       = { "（ShapeKeySystemAPI）", "(ShapeKeySystemAPI)" },
    ["debug.release_all"]    = { "全部收回", "Take all back" },
    ["debug.no_external"]    = { "没有插件在控制形态键", "No plugin holds any shape key" },
    ["debug.log"]            = { "日志", "Log" },
    ["debug.about"]          = { "关于", "About" },
    ["debug.about_line"]     = { "%s v%s · 作者 %s", "%s v%s · by %s" },
    ["debug.this_version"]   = { "本版", "Current" },
    ["debug.prev_version"]   = { "上一版", "Previous" },
    ["debug.files"]          = { "绑定与配置文件", "Bindings & config files" },
})

-- input blocker diagnostics (InputBlocker.lua)
add({
    ["blocker.forced"]       = { "放开光标 %d 次", "cursor freed %d times" },
    ["blocker.hook_failed"]  = { "hook 失败：%s", "hook failed: %s" },
    ["blocker.line"]         = { "鼠标 %s · %s · 最近移动 %.0f,%.0f", "mouse %s · %s · last move %.0f,%.0f" },
    ["blocker.pinned"]       = { "锁定(虚拟光标)", "pinned (virtual cursor)" },
    ["blocker.free"]         = { "自由", "free" },
})

-- backend notices (API.lua): notice(level, key, args)
add({
    ["notice.binding_error"] = { "%s：%s %s", "%s: %s %s" },
    ["notice.missing_profile"] = { "绑定 %s 指定的表情配置 %s 不存在", "Binding %s names expression profile %s, which does not exist" },
    ["notice.auto_switched"] = { "当前部件没有 %s 的通道，已切换到 %s", "The worn parts have no %s channels: switched to %s" },
    ["notice.profile_saved"] = { "已保存表情配置：%s", "Expression profile saved: %s" },
    ["notice.sculpt_loaded"] = { "已加载捏脸配置：%s", "Sculpt config loaded: %s" },
    ["notice.sculpt_saved"]  = { "已保存捏脸配置：%s", "Sculpt config saved: %s" },
    ["notice.binding_written"] = { "已写入绑定：%s", "Binding written: %s" },
    ["notice.bound_to"]      = { "已绑定到 %s", "Bound to %s" },
    ["notice.tuning_saved"]  = { "已保存到绑定：%s", "Saved to binding: %s" },
    ["notice.deleted"]       = { "已删除：%s", "Deleted: %s" },
    ["notice.hotkey_moved"]  = { "打开面板的按键改成了 Delete（End 是游戏的暂停键，Home 和 ArmorVariantManager 冲突），可在设置里修改",
                                 "The panel hotkey is now Delete (End pauses the game, Home is ArmorVariantManager's); change it in the settings" },
    ["notice.profile_fallback"] = { "表情配置加载失败，改用 ARKit：%s", "Expression profile failed to load, using ARKit: %s" },
    ["notice.no_profile"]    = { "没有可用的表情配置：%s %s", "No usable expression profile: %s %s" },
    ["notice.cond_missing"]  = { "条件表情配置不存在：%s", "Condition set not found: %s" },
    ["notice.cond_saved"]    = { "已保存条件表情：%s", "Condition set saved: %s" },
    ["binding.stale_fingerprint"] = { "通道指纹不符（可能是被覆盖的旧 mod 留下的），已跳过",
                                      "channel fingerprint mismatch (left behind by an overwritten older mod?), skipped" },
})

-- imgui debug window (DebugUI.lua)
add({
    ["dbg.tag_no_mesh"]      = { " [mesh 无]", " [not on mesh]" },
    ["dbg.tag_no_signal"]    = { " [无信号]", " [no signal]" },
    ["dbg.tag_guessed"]      = { " [推测]", " [guess]" },
    ["dbg.tag_edited"]       = { " [已改]", " [edited]" },
    ["dbg.test"]             = { "测试", "Test" },
    ["dbg.channel"]          = { "通道", "Channel" },
    ["dbg.source"]           = { "来源: %s", "Source: %s" },
    ["dbg.node_json"]        = { "节点 JSON", "Node JSON" },
    ["dbg.apply"]            = { "应用", "Apply" },
    ["dbg.json_error"]       = { "JSON 解析失败", "JSON parse failed" },
    ["dbg.revert"]           = { "恢复", "Revert" },
    ["dbg.save_as"]          = { "另存为", "Save as" },
    ["dbg.save"]             = { "保存", "Save" },
    ["dbg.active_signals"]   = { "活跃信号（归一化）：", "Active signals (normalised):" },
    ["dbg.scan"]             = { "扫描", "Scan" },
    ["dbg.force"]            = { "强制覆盖（每帧写入）", "Force write (every frame)" },
    ["dbg.ab"]               = { "A/B：显示 mod 默认值", "A/B: show mod defaults" },
    ["dbg.undo"]             = { "撤销", "Undo" },
    ["dbg.redo"]             = { "重做", "Redo" },
    ["dbg.unsaved"]          = { "[未保存]", "[unsaved]" },
    ["dbg.saved"]            = { "[已保存]", "[saved]" },
    ["dbg.current_config"]   = { "%s  当前配置：%s", "%s  current config: %s" },
    ["dbg.none"]             = { "无", "none" },
    ["dbg.scan_line"]        = { "部件 %s  形态键 %d  （其中 %d 个由表情驱动，锁定）", "parts %s  shape keys %d  (%d driven by expressions, locked)" },
    ["dbg.locked_key"]       = { "   %s  （表情驱动，锁定）", "   %s  (expression-driven, locked)" },
    ["dbg.default"]          = { "默认", "Default" },
    ["dbg.mod_default"]      = { "mod 默认值 %.2f", "mod default %.2f" },
    ["dbg.sculpt_name"]      = { "捏脸配置名", "Sculpt config name" },
    ["dbg.save_general"]     = { "存为通用预设（不属于某件装备）", "Save as general preset (not tied to an outfit)" },
    ["dbg.save_bind"]        = { "保存并绑定到 %s", "Save and bind to %s" },
    ["dbg.binding_line"]     = { "生效的父预设：%s（部件 %s）  表情：%s  捏脸：%s%s", "Binding in effect: %s (part %s)  profile: %s  sculpt: %s%s" },
    ["dbg.fingerprint_bad"]  = { "  [捏脸配置与网格通道不一致]", "  [sculpt config does not match the mesh channels]" },
    ["dbg.chain_error"]      = { "  错误：%s", "  error: %s" },
    ["dbg.no_binding"]       = { "没有命中的父预设（使用全局设置）", "No binding hit (global settings in use)" },
    ["dbg.write_binding"]    = { "把当前表情配置和增益写入 %s 的父预设", "Write the profile and gains to %s's binding" },
    ["dbg.restore_mod"]      = { "恢复 mod 自带的父预设", "Restore the mod's binding" },
    ["dbg.tuning_from"]      = { "表情增益与视线设置来自：%s%s%s", "Expression gains and gaze settings from: %s%s%s" },
    ["dbg.global_settings"]  = { "全局设置 settings.json", "global settings.json" },
    ["dbg.gains_other"]      = { "  [通道增益是为 %s 调的，暂不生效]", "  [channel gains were tuned for %s and are off]" },
    ["dbg.save_tuning"]      = { "保存到这个部件的父预设", "Save to this part's binding" },
    ["dbg.sculpt_list"]      = { "捏脸配置（点名字加载，不改父预设）：", "Sculpt configs (click a name to load; the binding is not changed):" },
    ["dbg.general"]          = { "通用", "general" },
    ["dbg.delete"]           = { "删除", "Delete" },
    ["dbg.confirm_delete"]   = { "确认删除 %s：%s？", "Delete %s: %s?" },
    ["dbg.confirm"]          = { "确认", "Confirm" },
    ["dbg.cancel"]           = { "取消", "Cancel" },
    ["dbg.last_error"]       = { "最近错误: %s", "Last error: %s" },
    ["dbg.enabled"]          = { "启用", "Enabled" },
    ["dbg.rescan"]           = { "重新扫描", "Rescan" },
    ["dbg.profile"]          = { "表情配置", "Expression profile" },
    ["dbg.coverage"]         = { "ARKit 覆盖 %d/%d  扩展 %d  推荐: %s", "ARKit coverage %d/%d  extra %d  recommended: %s" },
    ["dbg.master"]           = { "整体表情强度", "Overall expression strength" },
    ["dbg.gaze"]             = { "视线强度", "Gaze strength" },
    ["dbg.smoothing"]        = { "平滑", "Smoothing" },
    ["dbg.region"]           = { "%s  (活跃 %.2f)", "%s  (active %.2f)" },
    ["dbg.channels"]         = { "通道", "Channels" },
    ["dbg.gaze_tree"]        = { "视线", "Gaze" },
    ["dbg.full_yaw"]         = { "满权重水平角", "Full-weight yaw" },
    ["dbg.full_pitch"]       = { "满权重垂直角", "Full-weight pitch" },
    ["dbg.invert_yaw"]       = { "反转水平", "Invert yaw" },
    ["dbg.invert_pitch"]     = { "反转垂直", "Invert pitch" },
    ["dbg.set_eye_look"]     = { "驱动 EyeLook*（眼睑跟随）", "Drive EyeLook* (eyelids follow)" },
    ["dbg.set_look"]         = { "驱动 Look*（虹膜平面移动）", "Drive Look* (iris slides)" },
    ["dbg.calibrate"]        = { "把当前朝向设为正前方", "Set current direction as straight ahead" },
    ["dbg.mapping"]          = { "映射编辑 / 信号", "Mapping editor / signals" },
    ["dbg.sculpt"]           = { "捏脸", "Sculpt" },
    ["dbg.presets"]          = { "预设 / 父预设", "Presets / bindings" },
    ["dbg.scene"]            = { "场景", "Scene" },
    ["dbg.rig_reads"]        = { " (每帧读 %d 个关节): ", " (reads %d joints per frame): " },
    ["dbg.part_line"]        = { "部件 %s  %d 通道  %s", "part %s  %d channels  %s" },
    ["dbg.settings"]         = { "设置", "Settings" },
    ["dbg.language"]         = { "语言 / Language", "Language" },
    ["dbg.periodic"]         = { "定期重扫 (秒, 0=关)", "Rescan every (s, 0 = off)" },
    ["dbg.epsilon"]          = { "写入阈值", "Write threshold" },
    ["dbg.clamp"]            = { "截断到 0..1", "Clamp to 0..1" },
    ["dbg.scene_search"]     = { "始终搜索整个场景（其他猎人；名片自动）", "Always search the whole scene (other hunters; guild card is automatic)" },
    ["dbg.sculpt_max"]       = { "捏脸滑块上限", "Sculpt slider max" },
    ["dbg.cutscene"]         = { "过场动画中驱动", "Drive in cutscenes" },
    ["dbg.probe"]            = { "通道哈希探针", "Channel hash probe" },
    ["dbg.probe_run"]        = { "运行（结果也写入 data/ShapeKeySystem/hash_probe.txt）", "Run (also writes data/ShapeKeySystem/hash_probe.txt)" },
    ["dbg.log"]              = { "日志", "Log" },
})

-- conditions that have no definition-side English (value_text)
add({
    ["cond.value_yes"]       = { "是", "yes" },
    ["cond.value_no"]        = { "否", "no" },
})

return L
