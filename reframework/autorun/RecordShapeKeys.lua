-- RecordShapeKeys.lua
-- RE9 Native FACS Deform & Signal Baseline Recorder
-- Monitors and records real-time facial blendshapes to identify rest baselines (e.g. 0.17, 0.5)

local R = require('ShapeKeySystem_Games.RE9.Runtime')
local Hash = require('ShapeKeySystem_Core.NameHash')
local Signals = require('ShapeKeySystem_Games.RE9.Signals')

local is_recording = false
local record_start_time = 0
local record_frame_count = 0
local filter_text = ""
local auto_stop_seconds = 15
local use_timer = true

local show_facs_mesh = true
local show_sks_signals = true
local show_motion_deforms = false

-- 96 Native FACS blendshapes definitions on Leon's head mesh (Index 00 ~ 95)
local FACS_CHANNEL_INFO = {
    [0]  = { name = "CrnPl_01_L",        desc = "嘴角平拉01左" },
    [1]  = { name = "CrnPl_01_R",        desc = "嘴角平拉01右" },
    [2]  = { name = "CrnPl_04_L",        desc = "微笑嘴角上提04左" },
    [3]  = { name = "CrnPl_04_R",        desc = "微笑嘴角上提04右" },
    [4]  = { name = "CrnPl_05_L",        desc = "嘴角上提05左" },
    [5]  = { name = "CrnPl_05_R",        desc = "嘴角上提05右" },
    [6]  = { name = "CrnPl_09_L",        desc = "嘴角平提09左" },
    [7]  = { name = "CrnPl_09_R",        desc = "嘴角平提09右" },
    [8]  = { name = "JwOpn_00_L",        desc = "物理下颌骨张开左" },
    [9]  = { name = "JwOpn_00_R",        desc = "物理下颌骨张开右" },
    [10] = { name = "NekTns_L",          desc = "颈部紧绷左" },
    [11] = { name = "NekTns_R",          desc = "颈部紧绷右" },
    [12] = { name = "ChnRs_04_L",        desc = "下巴抬起左" },
    [13] = { name = "ChnRs_04_R",        desc = "下巴抬起右" },
    [14] = { name = "Strtch_03_L",       desc = "嘴唇拉伸03左" },
    [15] = { name = "Strtch_03_R",       desc = "嘴唇拉伸03右" },
    [16] = { name = "Strtch_04_L",       desc = "嘴唇拉伸04左" },
    [17] = { name = "Strtch_04_R",       desc = "嘴唇拉伸04右" },
    [18] = { name = "Strtch_08_L",       desc = "嘴唇拉伸08左" },
    [19] = { name = "Strtch_08_R",       desc = "嘴唇拉伸08右" },
    [20] = { name = "Pkr_01_L",          desc = "噘嘴01左" },
    [21] = { name = "Pkr_01_R",          desc = "噘嘴01右" },
    [22] = { name = "Pkr_02_L",          desc = "噘嘴02左" },
    [23] = { name = "Pkr_02_R",          desc = "噘嘴02右" },
    [24] = { name = "Pkr_03_L",          desc = "噘嘴03左(发音U)" },
    [25] = { name = "Pkr_03_R",          desc = "噘嘴03右(发音U)" },
    [26] = { name = "NosWrnkl_03_L",     desc = "皱鼻03左" },
    [27] = { name = "NosWrnkl_03_R",     desc = "皱鼻03右" },
    [28] = { name = "NosWrnkl_04_L",     desc = "皱鼻04左" },
    [29] = { name = "NosWrnkl_04_R",     desc = "皱鼻04右" },
    [30] = { name = "NosWrnkl_05_L",     desc = "皱鼻05左" },
    [31] = { name = "NosWrnkl_05_R",     desc = "皱鼻05右" },
    [32] = { name = "BrInDn_00_L",       desc = "眉头下压/皱眉左" },
    [33] = { name = "BrInDn_00_R",       desc = "眉头下压/皱眉右" },
    [34] = { name = "BrInRs_00_L",       desc = "眉头上提/挑眉左" },
    [35] = { name = "BrInRs_00_R",       desc = "眉头上提/挑眉右" },
    [36] = { name = "BrOutRs_00_L",      desc = "眉梢上提左" },
    [37] = { name = "BrOutRs_00_R",      desc = "眉梢上提右" },
    [38] = { name = "BrLr_00_L",         desc = "整眉压低左" },
    [39] = { name = "BrLr_00_R",         desc = "整眉压低右" },
    [40] = { name = "LdTight_05_L",      desc = "眼睑收紧左" },
    [41] = { name = "LdTight_05_R",      desc = "眼睑收紧右" },
    [42] = { name = "Sqnt_03_L",         desc = "眯眼03左" },
    [43] = { name = "Sqnt_03_R",         desc = "眯眼03右" },
    [44] = { name = "Sqnt_06_L",         desc = "眯眼06左" },
    [45] = { name = "Sqnt_06_R",         desc = "眯眼06右" },
    [46] = { name = "LpRolIn_04_L",      desc = "抿唇卷唇04左" },
    [47] = { name = "LpRolIn_04_R",      desc = "抿唇卷唇04右" },
    [48] = { name = "LpRolIn_05_L",      desc = "抿唇卷唇05左" },
    [49] = { name = "LpRolIn_05_R",      desc = "抿唇卷唇05右" },
    [50] = { name = "UprLdDn_00_L",      desc = "上眼睑下落/眨眼闭眼左" },
    [51] = { name = "UprLdDn_00_R",      desc = "上眼睑下落/眨眼闭眼右" },
    [52] = { name = "UprLdDn_01_L",      desc = "眼睑下落01左" },
    [53] = { name = "UprLdDn_01_R",      desc = "眼睑下落01右" },
    [54] = { name = "UprLdDn_03_L",      desc = "眼睑下落03左" },
    [55] = { name = "UprLdDn_03_R",      desc = "眼睑下落03右" },
    [56] = { name = "UprLdDn_05_L",      desc = "眼睑下落05左" },
    [57] = { name = "UprLdDn_05_R",      desc = "眼睑下落05右" },
    [58] = { name = "MouthR_05_L",       desc = "嘴偏向右05左" },
    [59] = { name = "MouthR_05_R",       desc = "嘴偏向右05右" },
    [60] = { name = "MouthL_05_L",       desc = "嘴偏向左05左" },
    [61] = { name = "MouthL_05_R",       desc = "嘴偏向左05右" },
    [62] = { name = "UprLpRs_01_L",      desc = "上唇抬起01左" },
    [63] = { name = "UprLpRs_01_R",      desc = "上唇抬起01右" },
    [64] = { name = "UprLpRs_04_L",      desc = "上唇抬起04左" },
    [65] = { name = "UprLpRs_04_R",      desc = "上唇抬起04右" },
    [66] = { name = "UprLpRs_05_L",      desc = "上唇抬起05左(发音E)" },
    [67] = { name = "UprLpRs_05_R",      desc = "上唇抬起05右(发音E)" },
    [68] = { name = "Fnl_04_L",          desc = "漏斗口型04左(发音O)" },
    [69] = { name = "Fnl_04_R",          desc = "漏斗口型04右(发音O)" },
    [70] = { name = "CrnDprs_00_L",      desc = "嘴角下压00左" },
    [71] = { name = "CrnDprs_00_R",      desc = "嘴角下压00右" },
    [72] = { name = "CrnDprs_01_L",      desc = "嘴角下压01左" },
    [73] = { name = "CrnDprs_01_R",      desc = "嘴角下压01右" },
    [74] = { name = "CrnDprs_02_L",      desc = "嘴角下压02左" },
    [75] = { name = "CrnDprs_02_R",      desc = "嘴角下压02右" },
    [76] = { name = "CrnPl_JwOpn_L",     desc = "嘴角张开(发音A)左" },
    [77] = { name = "CrnPl_JwOpn_R",     desc = "嘴角张开(发音A)右" },
    [78] = { name = "Strtch_JwOpn_L",    desc = "嘴周张开拉伸(发音A)左" },
    [79] = { name = "Strtch_JwOpn_R",    desc = "嘴周张开拉伸(发音A)右" },
    [80] = { name = "Sqnt_UprLdDn_L",    desc = "眯眼闭眼组合左" },
    [81] = { name = "Sqnt_UprLdDn_R",    desc = "眯眼闭眼组合右" },
    [82] = { name = "LdT_UprLdDn_L",     desc = "眼睑紧绷闭眼组合左" },
    [83] = { name = "LdT_UprLdDn_R",     desc = "眼睑紧绷闭眼组合右" },
    [84] = { name = "CrnPl_LwrLpDprs_L", desc = "下唇下压平拉(发音I)左" },
    [85] = { name = "CrnPl_LwrLpDprs_R", desc = "下唇下压平拉(发音I)右" },
    [86] = { name = "Strtch_CrnPl_L",    desc = "嘴角强力拉伸(发音I)左" },
    [87] = { name = "Strtch_CrnPl_R",    desc = "嘴角强力拉伸(发音I)右" },
    [88] = { name = "LpBit_TL",          desc = "咬唇上左" },
    [89] = { name = "LpBit_TR",          desc = "咬唇上右" },
    [90] = { name = "LpBit_BL",          desc = "咬唇下左" },
    [91] = { name = "LpBit_BR",          desc = "咬唇下右" },
    [92] = { name = "Pkr_Fnl_TL",        desc = "嘟嘴漏斗(发音U)上左" },
    [93] = { name = "Pkr_Fnl_TR",        desc = "嘟嘴漏斗(发音U)上右" },
    [94] = { name = "Pkr_Fnl_BL",        desc = "嘟嘴漏斗(发音U)下左" },
    [95] = { name = "Pkr_Fnl_BR",        desc = "嘟嘴漏斗(发音U)下右" }
}

-- SKS Output Signals
local SKS_SIGNAL_INFO = {
    re9VowelA = "SKS元音 A 输出 (あ)",
    re9VowelI = "SKS元音 I 输出 (い)",
    re9VowelU = "SKS元音 U 输出 (う)",
    re9VowelE = "SKS元音 E 输出 (え)",
    re9VowelO = "SKS元音 O 输出 (お)",
    jawOpen   = "SKS物理下颌骨开合输出",
    eyeBlinkLeft  = "SKS眨眼闭眼左输出",
    eyeBlinkRight = "SKS眨眼闭眼右输出",
    re9BrowInLeft = "SKS眉头表情左输出",
    re9BrowInRight= "SKS眉头表情右输出"
}

local stats = {} -- key -> { min = x, max = x, sum = x, count = n, current = x, category = cat, desc = desc }

local function reset_stats()
    stats = {}
    record_frame_count = 0
    record_start_time = os.clock()
end

local function record_value(key, val, category, desc)
    if type(val) ~= "number" or val ~= val then return end
    local entry = stats[key]
    if not entry then
        entry = { min = val, max = val, sum = val, count = 1, current = val, category = category, desc = desc }
        stats[key] = entry
    else
        entry.current = val
        if is_recording then
            if val < entry.min then entry.min = val end
            if val > entry.max then entry.max = val end
            entry.sum = entry.sum + val
            entry.count = entry.count + 1
        end
    end
end

local function save_stats_to_file()
    local export = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        duration_sec = record_frame_count > 0 and (os.clock() - record_start_time) or 0,
        frame_count = record_frame_count,
        channels = {}
    }
    for key, s in pairs(stats) do
        local avg = s.count > 0 and (s.sum / s.count) or 0
        local span = s.max - s.min
        table.insert(export.channels, {
            name = key,
            category = s.category,
            description = s.desc,
            baseline_min = math.floor(s.min * 1000 + 0.5) / 1000,
            peak_max = math.floor(s.max * 1000 + 0.5) / 1000,
            span = math.floor(span * 1000 + 0.5) / 1000,
            average = math.floor(avg * 1000 + 0.5) / 1000,
            has_high_baseline = (s.min >= 0.10)
        })
    end
    table.sort(export.channels, function(a, b)
        if a.has_high_baseline ~= b.has_high_baseline then
            return a.has_high_baseline
        end
        return a.baseline_min > b.baseline_min
    end)
    
    local ok = json.dump_file("ShapeKeySystem/baseline_stats.json", export, 2)
    return ok
end

-- Sampling logic every frame
re.on_frame(function()
    local head = R.find()
    if not head or not head.face then return end

    if is_recording then
        record_frame_count = record_frame_count + 1
        if use_timer and auto_stop_seconds > 0 then
            if (os.clock() - record_start_time) >= auto_stop_seconds then
                is_recording = false
                save_stats_to_file()
            end
        end
    end

    -- 1. Sample 96 FACS Channels directly from head mesh or fallback
    local mesh = R.mesh(head.face)
    if mesh then
        local cn = R.call(mesh, "get_BlendShapeChannelNum") or 0
        for i = 0, math.min(cn - 1, 95) do
            local val = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
            local info = FACS_CHANNEL_INFO[i]
            local name = info and info.name or string.format("Channel_%d", i)
            local desc = info and info.desc or "未命名形态键"
            local display_key = string.format("[FACS %02d] %s", i, name)
            record_value(display_key, val, "facs", desc)
        end
    end

    -- 2. Sample SKS Evaluated Output Signals
    pcall(function()
        local snap = Signals.snapshot()
        if snap and snap.outputs then
            for sig_name, sig_val in pairs(snap.outputs) do
                local desc = SKS_SIGNAL_INFO[sig_name] or sig_name
                local display_key = string.format("[SKS信号] %s", sig_name)
                record_value(display_key, sig_val, "sks", desc)
            end
        end
    end)

    -- 3. Sample Motion Component Deforms (if available on root or face)
    local face_go = R.call(head.face, 'get_GameObject')
    local root_go = head.root and R.call(head.root, 'get_GameObject')
    local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
    local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))
    local dm = fm or rm
    if dm then
        local dhashes = R.call(dm, "get_DeformNameHashes")
        local dvals = R.call(dm, "get_DeformValues")
        local len = dhashes and (R.call(dhashes, "get_Length") or R.call(dhashes, "get_Count")) or 0
        if len > 0 and dvals then
            for i = 0, len - 1 do
                local h = Hash.hash_at(dhashes, i, true)
                local val = R.call(dvals, "get_Item", i)
                if h and type(val) == "number" and val == val then
                    local hex_str = string.format("0x%08X", h)
                    local display_key = string.format("[Motion %02d] %s", i, hex_str)
                    record_value(display_key, val, "motion", "骨骼运动变形通道")
                end
            end
        end
    end
end)

-- UI Drawing logic
re.on_draw_ui(function()
    if imgui.tree_node("RE9 原生形态键常态底噪监测与录制 (Baseline Recorder)") then
        -- Controls
        imgui.spacing()
        if not is_recording then
            if imgui.button("开始录制 (Start Recording)", 200, 32) then
                reset_stats()
                is_recording = true
            end
        else
            if imgui.button("停止并保存 (Stop & Save JSON)", 200, 32) then
                is_recording = false
                save_stats_to_file()
            end
        end
        imgui.same_line()
        if imgui.button("重置统计 (Reset)", 100, 32) then
            reset_stats()
        end
        imgui.same_line()
        if imgui.button("导出当前数据为 JSON", 160, 32) then
            save_stats_to_file()
        end

        -- Status Display
        local elapsed = is_recording and (os.clock() - record_start_time) or 0
        if is_recording then
            imgui.text_colored(string.format("正在录制中... 时间: %.1f 秒 / %d 帧", elapsed, record_frame_count), 0xFF00FF00)
        else
            imgui.text(string.format("录制就绪 / 已统计: %d 帧", record_frame_count))
        end

        local c_timer, v_timer = imgui.checkbox("自动录制固定秒数停止", use_timer)
        if c_timer then use_timer = v_timer end
        if use_timer then
            imgui.same_line()
            local c_sec, v_sec = imgui.slider_int("录制时长(秒)", auto_stop_seconds, 3, 60)
            if c_sec then auto_stop_seconds = v_sec end
        end

        imgui.separator()
        
        -- Category Checkboxes
        local c1, v1 = imgui.checkbox("显示面部96 FACS原生形态键", show_facs_mesh)
        if c1 then show_facs_mesh = v1 end
        imgui.same_line()
        local c2, v2 = imgui.checkbox("显示SKS实时信号", show_sks_signals)
        if c2 then show_sks_signals = v2 end
        imgui.same_line()
        local c3, v3 = imgui.checkbox("显示Motion骨骼变形", show_motion_deforms)
        if c3 then show_motion_deforms = v3 end

        -- Filter Input
        local c_filter, v_filter = imgui.input_text("筛选 (Filter: 名称/中文功能)", filter_text)
        if c_filter then filter_text = v_filter end

        imgui.spacing()
        imgui.text("提示：红色/橙色表示【常态底噪 >= 0.10】的形态键，这类键静止时非零，需要在 signals.json 中切除底噪。")
        imgui.separator()

        -- Filter and sort list
        local sorted_list = {}
        local f_lower = filter_text:lower()
        for key, s in pairs(stats) do
            local visible = true
            if s.category == "facs" and not show_facs_mesh then visible = false end
            if s.category == "sks" and not show_sks_signals then visible = false end
            if s.category == "motion" and not show_motion_deforms then visible = false end

            if visible then
                local full_search = (key .. " " .. s.desc):lower()
                if filter_text == "" or full_search:find(f_lower, 1, true) then
                    table.insert(sorted_list, { key = key, s = s })
                end
            end
        end

        table.sort(sorted_list, function(a, b)
            if (a.s.min >= 0.10) ~= (b.s.min >= 0.10) then
                return a.s.min >= 0.10
            end
            return a.s.min > b.s.min
        end)

        -- Header
        imgui.text_colored(string.format("%-34s | %-24s | %-8s | %-8s | %-8s | %-8s", "形态键标识 (Name)", "中文含义/说明 (Description)", "当前值", "常态底噪", "峰值Max", "跨度Span"), 0xFFAAAAAA)
        imgui.separator()

        for _, item in ipairs(sorted_list) do
            local s = item.s
            local span = s.max - s.min
            local is_high = (s.min >= 0.10)
            
            -- Color coding: Red for >= 0.40, Orange for >= 0.10, Green for SKS signals, White otherwise
            local color = 0xFFFFFFFF
            if s.category == "sks" then
                color = 0xFFFFFF55 -- Cyan-ish for SKS signals
            elseif s.min >= 0.40 then
                color = 0xFF5555FF -- Reddish for near 0.5
            elseif is_high then
                color = 0xFF00AAFF -- Orange
            end

            local line = string.format("%-34s | %-24s | %8.3f | %8.3f | %8.3f | %8.3f", 
                item.key:sub(1, 34), 
                s.desc:sub(1, 24), 
                s.current, 
                s.min, 
                s.max, 
                span)
            imgui.text_colored(line, color)
        end

        imgui.tree_pop()
    end
end)
