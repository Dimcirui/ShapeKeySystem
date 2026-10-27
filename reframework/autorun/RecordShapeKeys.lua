-- RecordShapeKeys.lua
-- RE9 原生96 FACS形态键监测与底噪录制工具 (RE9 Native 96 FACS Baseline Monitor & Recorder)
-- 专用于监测并录制 RE9 引擎本身的 96 个原生面部 FACS 形态键（00 ~ 95）
-- 严格按 00 ~ 95 自然序号排列，保留所有 0.000 静止键与实时动态

local R = require('ShapeKeySystem_Games.RE9.Runtime')
local Hash = require('ShapeKeySystem_Core.NameHash')
pcall(R.init)

local is_recording = false
local record_start_time = 0
local record_frame_count = 0
local filter_text = ""
local auto_stop_seconds = 15
local use_timer = true
local ui_is_open = false

local sort_by_baseline = false   -- 默认按序号 00 ~ 95 自然顺序排列，绝不打乱或把 0.000 挤到底部
local hide_zero_baseline = false

-- RE9 原生 96 个 FACS 面部形态键定义 (Index 00 ~ 95)
local FACS_CHANNEL_INFO = {
    [0]  = { name = "CrnPl_01_L",        desc = "嘴角平拉01左" },
    [1]  = { name = "CrnPl_01_R",        desc = "嘴角平拉01右" },
    [2]  = { name = "CrnPl_04_L",        desc = "微笑嘴角上提04左" },
    [3]  = { name = "CrnPl_04_R",        desc = "微笑嘴角上提04右" },
    [4]  = { name = "CrnPl_05_L",        desc = "嘴角上提05左(酒窝)" },
    [5]  = { name = "CrnPl_05_R",        desc = "嘴角上提05右(酒窝)" },
    [6]  = { name = "CrnPl_09_L",        desc = "嘴角平提09左" },
    [7]  = { name = "CrnPl_09_R",        desc = "嘴角平提09右" },
    [8]  = { name = "JwOpn_00_L",        desc = "下颚张开左(张嘴/发音A)" },
    [9]  = { name = "JwOpn_00_R",        desc = "下颚张开右(张嘴/发音A)" },
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
    [20] = { name = "Pkr_01_L",          desc = "嘟嘴01左" },
    [21] = { name = "Pkr_01_R",          desc = "嘟嘴01右" },
    [22] = { name = "Pkr_02_L",          desc = "嘟嘴02左" },
    [23] = { name = "Pkr_02_R",          desc = "嘟嘴02右" },
    [24] = { name = "Pkr_03_L",          desc = "嘟嘴03左(发音U)" },
    [25] = { name = "Pkr_03_R",          desc = "嘟嘴03右(发音U)" },
    [26] = { name = "NosWrnkl_03_L",     desc = "皱鼻03左" },
    [27] = { name = "NosWrnkl_03_R",     desc = "皱鼻03右" },
    [28] = { name = "NosWrnkl_04_L",     desc = "皱鼻04左" },
    [29] = { name = "NosWrnkl_04_R",     desc = "皱鼻04右" },
    [30] = { name = "NosWrnkl_05_L",     desc = "皱鼻05左" },
    [31] = { name = "NosWrnkl_05_R",     desc = "皱鼻05右" },
    [32] = { name = "BrInDn_00_L",       desc = "眉头下压/皱眉左" },
    [33] = { name = "BrInDn_00_R",       desc = "眉头下压/皱眉右" },
    [34] = { name = "BrInRs_00_L",       desc = "眉头挑起左(困惑)" },
    [35] = { name = "BrInRs_00_R",       desc = "眉头挑起右(困惑)" },
    [36] = { name = "BrOutRs_00_L",      desc = "眉梢上提左(惊讶)" },
    [37] = { name = "BrOutRs_00_R",      desc = "眉梢上提右(惊讶)" },
    [38] = { name = "BrLr_00_L",         desc = "整眉压低左" },
    [39] = { name = "BrLr_00_R",         desc = "整眉压低右" },
    [40] = { name = "LdTight_05_L",      desc = "下眼睑绷紧05左" },
    [41] = { name = "LdTight_05_R",      desc = "下眼睑绷紧05右" },
    [42] = { name = "Sqnt_03_L",         desc = "眯眼03左" },
    [43] = { name = "Sqnt_03_R",         desc = "眯眼03右" },
    [44] = { name = "Sqnt_06_L",         desc = "闭眼06左(眨眼/闭眼)" },
    [45] = { name = "Sqnt_06_R",         desc = "闭眼06右(眨眼/闭眼)" },
    [46] = { name = "LpRolIn_04_L",      desc = "上唇内卷04左" },
    [47] = { name = "LpRolIn_04_R",      desc = "上唇内卷04右" },
    [48] = { name = "LpRolIn_05_L",      desc = "下唇内卷05左" },
    [49] = { name = "LpRolIn_05_R",      desc = "下唇内卷05右" },
    [50] = { name = "UprLdDn_00_L",      desc = "上眼睑下垂00左" },
    [51] = { name = "UprLdDn_00_R",      desc = "上眼睑下垂00右" },
    [52] = { name = "UprLdDn_01_L",      desc = "上眼睑下垂01左" },
    [53] = { name = "UprLdDn_01_R",      desc = "上眼睑下垂01右" },
    [54] = { name = "UprLdDn_03_L",      desc = "上眼睑下垂03左" },
    [55] = { name = "UprLdDn_03_R",      desc = "上眼睑下垂03右" },
    [56] = { name = "UprLdDn_05_L",      desc = "上眼睑闭合05左" },
    [57] = { name = "UprLdDn_05_R",      desc = "上眼睑闭合05右" },
    [58] = { name = "MouthR_05_L",       desc = "嘴角右偏05左侧" },
    [59] = { name = "MouthR_05_R",       desc = "嘴角右偏05右侧" },
    [60] = { name = "MouthL_05_L",       desc = "嘴角左偏05左侧" },
    [61] = { name = "MouthL_05_R",       desc = "嘴角左偏05右侧" },
    [62] = { name = "UprLpRs_01_L",      desc = "上唇抬起01左" },
    [63] = { name = "UprLpRs_01_R",      desc = "上唇抬起01右" },
    [64] = { name = "UprLpRs_04_L",      desc = "上唇抬起04左" },
    [65] = { name = "UprLpRs_04_R",      desc = "上唇抬起04右" },
    [66] = { name = "UprLpRs_05_L",      desc = "上唇鼻侧抬高05左" },
    [67] = { name = "UprLpRs_05_R",      desc = "上唇鼻侧抬高05右" },
    [68] = { name = "Fnl_04_L",          desc = "漏斗状张嘴04左" },
    [69] = { name = "Fnl_04_R",          desc = "漏斗状张嘴04右" },
    [70] = { name = "CrnDprs_00_L",      desc = "嘴角下压00左(悲伤)" },
    [71] = { name = "CrnDprs_00_R",      desc = "嘴角下压00右(悲伤)" },
    [72] = { name = "CrnDprs_01_L",      desc = "嘴角下压01左" },
    [73] = { name = "CrnDprs_01_R",      desc = "嘴角下压01右" },
    [74] = { name = "CrnDprs_02_L",      desc = "嘴角下压02左" },
    [75] = { name = "CrnDprs_02_R",      desc = "嘴角下压02右" },
    [76] = { name = "LwrLpDprs_00_L",    desc = "下唇下拉00左" },
    [77] = { name = "LwrLpDprs_00_R",    desc = "下唇下拉00右" },
    [78] = { name = "LwrLpDprs_03_L",    desc = "下唇下拉03左" },
    [79] = { name = "LwrLpDprs_03_R",    desc = "下唇下拉03右" },
    [80] = { name = "LpPush_00_L",       desc = "嘴唇前突00左" },
    [81] = { name = "LpPush_00_R",       desc = "嘴唇前突00右" },
    [82] = { name = "LpPush_01_L",       desc = "嘴唇前突01左" },
    [83] = { name = "LpPush_01_R",       desc = "嘴唇前突01右" },
    [84] = { name = "MouthW_00_L",       desc = "嘴角向外展宽00左" },
    [85] = { name = "MouthW_00_R",       desc = "嘴角向外展宽00右" },
    [86] = { name = "MouthW_01_L",       desc = "嘴角向外展宽01左" },
    [87] = { name = "MouthW_01_R",       desc = "嘴角向外展宽01右" },
    [88] = { name = "LpBit_TL",          desc = "咬左上唇" },
    [89] = { name = "LpBit_TR",          desc = "咬右上唇" },
    [90] = { name = "LpBit_BL",          desc = "咬左下唇" },
    [91] = { name = "LpBit_BR",          desc = "咬右下唇" },
    [92] = { name = "Pkr_Fnl_TL",        desc = "嘟嘴漏斗左上" },
    [93] = { name = "Pkr_Fnl_TR",        desc = "嘟嘴漏斗右上" },
    [94] = { name = "Pkr_Fnl_BL",        desc = "嘟嘴漏斗左下" },
    [95] = { name = "Pkr_Fnl_BR",        desc = "嘟嘴漏斗右下" },
}

local stats = {}
for i = 0, 95 do
    local info = FACS_CHANNEL_INFO[i]
    stats[i] = {
        index = i,
        name = info.name,
        desc = info.desc,
        min = 0.0,
        max = 0.0,
        sum = 0.0,
        count = 0,
        current = 0.0
    }
end

local function reset_stats()
    for i = 0, 95 do
        local cur = stats[i].current or 0.0
        stats[i].min = cur
        stats[i].max = cur
        stats[i].sum = cur
        stats[i].count = 1
    end
    record_frame_count = 0
    record_start_time = os.clock()
end

local function save_stats_to_file()
    local export = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        duration_sec = record_frame_count > 0 and (os.clock() - record_start_time) or 0,
        frame_count = record_frame_count,
        total_channels = 96,
        facs_channels = {}
    }
    -- 严格按序号 00 ~ 95 自然顺序输出，保留所有 0.000 通道与其实际位置
    for i = 0, 95 do
        local s = stats[i]
        local avg = s.count > 0 and (s.sum / s.count) or 0
        local span = s.max - s.min
        table.insert(export.facs_channels, {
            index = s.index,
            name = s.name,
            description = s.desc,
            baseline_min = math.floor(s.min * 1000 + 0.5) / 1000,
            peak_max = math.floor(s.max * 1000 + 0.5) / 1000,
            span = math.floor(span * 1000 + 0.5) / 1000,
            average = math.floor(avg * 1000 + 0.5) / 1000,
            has_high_baseline = (s.min >= 0.10)
        })
    end
    
    local ok = json.dump_file("ShapeKeySystem/native_facs_baselines.json", export, 2)
    return ok
end

-- Sampling logic every frame (Exclusively for 96 Native FACS Channels)
re.on_frame(function()
    if not is_recording and not ui_is_open then
        return
    end
    pcall(function()
        local head = R.find()
        if not head or not head.face then return end
        local mesh = head.mesh or R.mesh(head.face)

        local face_go = R.call(head.face, 'get_GameObject')
        local root_go = head.root and R.call(head.root, 'get_GameObject')
        local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
        local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))
        local dm = fm or rm
        local dvals = dm and R.call(dm, "get_DeformValues")
        local dlen = dvals and (R.call(dvals, "get_Length") or R.call(dvals, "get_Count")) or 0

        local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0

        if is_recording then
            record_frame_count = record_frame_count + 1
            if use_timer and auto_stop_seconds > 0 then
                if (os.clock() - record_start_time) >= auto_stop_seconds then
                    is_recording = false
                    save_stats_to_file()
                end
            end
        end

        for i = 0, 95 do
            local val = nil

            -- 1. 优先读取网格当前通道权重（原版网格直接读取原生权重；Mod网格读取当前实时驱动权重）
            if mesh and i < cn then
                val = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
                if val == nil then val = R.call(mesh, "getBlendShapeChannelWeightParam", i) end
                if val == nil then val = R.call(mesh, "getBlendShapeChannelWeight", i) end
            end

            -- 2. 若网格未读出但动作组件有对应轨道，尝试从动作组件Deform轨道补充
            if (val == nil or val ~= val) and dvals and i < dlen then
                val = R.call(dvals, "get_Item", i)
            end

            if type(val) ~= "number" or val ~= val then
                val = 0.0
            end

            local s = stats[i]
            s.current = val
            if s.count == 0 then
                s.min = val
                s.max = val
                s.sum = val
                s.count = 1
            elseif not is_recording then
                -- 实时预览模式：动态更新最小/最大值以展现动态波形
                if val < s.min then s.min = val end
                if val > s.max then s.max = val end
            else
                -- 正式录制模式：累加帧数以计算均值底噪
                if val < s.min then s.min = val end
                if val > s.max then s.max = val end
                s.sum = s.sum + val
                s.count = s.count + 1
            end
        end
    end)
end)

-- UI Drawing logic
re.on_draw_ui(function()
    local opened = imgui.tree_node("RE9 原生96 FACS形态键监测与底噪录制")
    ui_is_open = (opened == true)
    if opened then
        imgui.spacing()
        local head = R.find()
        if head then
            local mesh = head.mesh or R.mesh(head.face)
            local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
            imgui.text_colored(string.format("网格状态: [已连接] 头部网格 (通道数: %d)", cn), 0xFF00FF00)
        else
            imgui.text_colored("网格状态: [未连接] 正在寻找头部网格 (cp_A000)...", 0xFF5555FF)
        end
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
        if imgui.button("导出为 JSON 文件", 150, 32) then
            save_stats_to_file()
        end

        -- Status Display
        local elapsed = is_recording and (os.clock() - record_start_time) or 0
        if is_recording then
            imgui.text_colored(string.format("正在录制中... 时间: %.1f 秒 / 已统计: %d 帧", elapsed, record_frame_count), 0xFF00FF00)
        else
            imgui.text(string.format("录制就绪 / 已统计: %d 帧 (文件保存至: ShapeKeySystem/native_facs_baselines.json)", record_frame_count))
        end

        local c_timer, v_timer = imgui.checkbox("自动录制固定秒数停止", use_timer)
        if c_timer then use_timer = v_timer end
        if use_timer then
            imgui.same_line()
            local c_sec, v_sec = imgui.slider_int("录制时长(秒)", auto_stop_seconds, 3, 60)
            if c_sec then auto_stop_seconds = v_sec end
        end

        imgui.separator()
        
        -- Sorting & View Options
        local c_sort, v_sort = imgui.checkbox("按常态底噪从大到小排序 (高底噪置顶排错)", sort_by_baseline)
        if c_sort then sort_by_baseline = v_sort end
        imgui.same_line()
        local c_hide, v_hide = imgui.checkbox("隐藏静止为 0 的形态键 (仅看活动/底噪键)", hide_zero_baseline)
        if c_hide then hide_zero_baseline = v_hide end

        -- Filter Input
        local c_filter, v_filter = imgui.input_text("搜索筛选 (序号 / 中文说明 / 英文原名)", filter_text)
        if c_filter then filter_text = v_filter end

        imgui.spacing()
        imgui.text_colored("提示：默认按【00 ~ 95 原生通道序号】完整展示全量形态键，白字=完全静止 0.000，黄/橙/红=活动及底噪。", 0xFF55FFFF)
        imgui.separator()

        -- Prepare sorted and filtered display list
        local display_list = {}
        local f_lower = filter_text:lower()
        for i = 0, 95 do
            local s = stats[i]
            local match_filter = true
            if filter_text ~= "" then
                local full = string.format("[%02d] %s %s", i, s.name, s.desc):lower()
                if not full:find(f_lower, 1, true) then match_filter = false end
            end
            if hide_zero_baseline and s.min < 0.0005 and s.max < 0.0005 and s.current < 0.0005 then
                match_filter = false
            end
            if match_filter then
                table.insert(display_list, s)
            end
        end

        if sort_by_baseline then
            table.sort(display_list, function(a, b)
                if (a.min >= 0.10) ~= (b.min >= 0.10) then
                    return a.min >= 0.10
                end
                return a.min > b.min
            end)
        else
            table.sort(display_list, function(a, b)
                return a.index < b.index
            end)
        end

        -- Header
        imgui.text_colored(string.format("%-6s | %-18s | %-28s | %-8s | %-8s | %-8s | %-8s", 
            "序号", "原生通道名 (Name)", "中文功能说明 (Description)", "实时当前", "常态底噪", "峰值Max", "波动跨度"), 0xFFAAAAAA)
        imgui.separator()

        for _, s in ipairs(display_list) do
            local span = s.max - s.min
            local is_high = (s.min >= 0.10)
            
            -- Color coding: Red for >= 0.40, Orange for >= 0.10, Yellow for > 0.001, White for 0.000
            local color = 0xFFFFFFFF
            if s.min >= 0.40 then
                color = 0xFF5555FF -- Reddish (bipolar or high tension)
            elseif is_high then
                color = 0xFF00AAFF -- Orange
            elseif s.min >= 0.001 or s.max >= 0.001 or s.current >= 0.001 then
                color = 0xFF00FFFF -- Yellow (active)
            end

            local line = string.format("[%02d] | %-16s | %-22s | %6.3f | %6.3f | %6.3f | %6.3f", 
                s.index,
                s.name, 
                s.desc, 
                s.current, 
                s.min, 
                s.max, 
                span)
            imgui.text_colored(line, color)
        end

        imgui.tree_pop()
    end
end)
