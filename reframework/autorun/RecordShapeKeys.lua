-- RecordShapeKeys.lua
-- RE9 Native FACS Deform & Signal Baseline Recorder
-- Monitors and records real-time facial blendshapes to identify rest baselines (e.g. 0.17, 0.5)

local R = require('ShapeKeySystem_Games.RE9.Runtime')
local Hash = require('ShapeKeySystem_Core.NameHash')

local is_recording = false
local record_start_time = 0
local record_frame_count = 0
local filter_text = ""
local auto_stop_seconds = 15
local use_timer = true

-- Pre-load known names from leon.json to map hash -> human-readable name
local hash_to_name = {}
pcall(function()
    local data = json.load_file("ShapeKeySystem/builtin/re9/leon.json")
    if data and data.native_names then
        for _, name in ipairs(data.native_names) do
            hash_to_name[Hash.hash(name)] = name
        end
    end
end)

local stats = {} -- name -> { min = x, max = x, sum = x, count = n, current = x, hash = h }

local function reset_stats()
    stats = {}
    record_frame_count = 0
    record_start_time = os.clock()
end

local function save_stats_to_file()
    local export = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        duration_sec = record_frame_count > 0 and (os.clock() - record_start_time) or 0,
        frame_count = record_frame_count,
        channels = {}
    }
    for name, s in pairs(stats) do
        local avg = s.count > 0 and (s.sum / s.count) or 0
        local span = s.max - s.min
        table.insert(export.channels, {
            name = name,
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
    local face_go = R.call(head.face, 'get_GameObject')
    local root_go = head.root and R.call(head.root, 'get_GameObject')
    local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
    local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))
    local dm = fm or rm
    if not dm then return end

    local dhashes = R.call(dm, "get_DeformNameHashes")
    local dvals = R.call(dm, "get_DeformValues")
    local len = dhashes and (R.call(dhashes, "get_Length") or R.call(dhashes, "get_Count")) or 0
    if len <= 0 or not dvals then return end

    if is_recording then
        record_frame_count = record_frame_count + 1
        if use_timer and auto_stop_seconds > 0 then
            if (os.clock() - record_start_time) >= auto_stop_seconds then
                is_recording = false
                save_stats_to_file()
            end
        end
    end

    for i = 0, len - 1 do
        local h = Hash.hash_at(dhashes, i, true)
        local val = R.call(dvals, "get_Item", i)
        if h and type(val) == "number" and val == val then
            local raw_name = hash_to_name[h] or string.format("0x%08X", h)
            local clean_name = raw_name:gsub("^HeadSkinned_blendShape%.", "")
            
            local entry = stats[clean_name]
            if not entry then
                entry = { min = val, max = val, sum = val, count = 1, current = val, raw_name = raw_name }
                stats[clean_name] = entry
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
        
        -- Filter Input
        local c_filter, v_filter = imgui.input_text("筛选名称 (Filter)", filter_text)
        if c_filter then filter_text = v_filter end

        imgui.spacing()
        imgui.text("提示：黄色/橙色表示【常态底噪 >= 0.10】的形态键，这类键静止时非零，需要做底噪死区切除。")
        imgui.separator()

        -- Sorted keys list
        local sorted_list = {}
        local f_lower = filter_text:lower()
        for name, s in pairs(stats) do
            if filter_text == "" or name:lower():find(f_lower, 1, true) then
                table.insert(sorted_list, { name = name, s = s })
            end
        end
        table.sort(sorted_list, function(a, b)
            if (a.s.min >= 0.10) ~= (b.s.min >= 0.10) then
                return a.s.min >= 0.10
            end
            return a.s.min > b.s.min
        end)

        -- Columns
        imgui.columns(5, "RecorderColumns", true)
        imgui.text("形态键名称 (Name)")
        imgui.next_column()
        imgui.text("实时值 (Current)")
        imgui.next_column()
        imgui.text("常态底噪 (Min)")
        imgui.next_column()
        imgui.text("峰值 (Max)")
        imgui.next_column()
        imgui.text("跨度 (Span)")
        imgui.next_column()
        imgui.separator()

        for _, item in ipairs(sorted_list) do
            local s = item.s
            local span = s.max - s.min
            local is_high = (s.min >= 0.10)
            
            -- Color coding: orange for high baseline (>= 0.10), white otherwise
            local color = is_high and 0xFF00AAFF or 0xFFFFFFFF
            if s.min >= 0.40 then
                color = 0xFF5555FF -- Reddish for near 0.5
            end

            imgui.text_colored(item.name, color)
            imgui.next_column()
            imgui.text_colored(string.format("%.3f", s.current), color)
            imgui.next_column()
            imgui.text_colored(string.format("%.3f", s.min), color)
            imgui.next_column()
            imgui.text_colored(string.format("%.3f", s.max), color)
            imgui.next_column()
            imgui.text_colored(string.format("%.3f", span), color)
            imgui.next_column()
        end
        imgui.columns(1)

        imgui.tree_pop()
    end
end)
