-- RecordShapeKeys.lua
-- RE9 原生 96 条 FACS Deform 实时监视器 & 录制系统 (High-Performance Monitor & Recorder)
-- 专用于实时监视 RE9 引擎本身的 96 个原生面部 FACS 形态键（00 ~ 95）
-- 无论当前角色是原版网格还是 Mod 装备，均直通底层 via.motion.Motion 与网格通道提取真实数值

local R = require('ShapeKeySystem_Games.RE9.Runtime')
local Hash = require('ShapeKeySystem_Core.NameHash')
local Signals = require('ShapeKeySystem_Games.RE9.Signals')
pcall(R.init)

local is_recording = false
local record_start_time = 0
local record_frame_count = 0
local filter_text = ''
local auto_stop_seconds = 15
local use_timer = true
local show_floating_window = false
local sort_by_value = false
local hide_zero = false

-- 96 个原生 FACS 通道定义与中文功能说明 (00 ~ 95)
local FACS_CHANNEL_INFO = {
    [0]  = { name = 'CrnPl_01_L',        desc = '嘴角平拉01左' },
    [1]  = { name = 'CrnPl_01_R',        desc = '嘴角平拉01右' },
    [2]  = { name = 'CrnPl_04_L',        desc = '微笑嘴角上提04左' },
    [3]  = { name = 'CrnPl_04_R',        desc = '微笑嘴角上提04右' },
    [4]  = { name = 'CrnPl_05_L',        desc = '嘴角上提05左(酒窝)' },
    [5]  = { name = 'CrnPl_05_R',        desc = '嘴角上提05右(酒窝)' },
    [6]  = { name = 'CrnPl_09_L',        desc = '嘴角平提09左' },
    [7]  = { name = 'CrnPl_09_R',        desc = '嘴角平提09右' },
    [8]  = { name = 'JwOpn_00_L',        desc = '下颚张开左(张嘴/发音A)' },
    [9]  = { name = 'JwOpn_00_R',        desc = '下颚张开右(张嘴/发音A)' },
    [10] = { name = 'NekTns_L',          desc = '颈部紧绷左' },
    [11] = { name = 'NekTns_R',          desc = '颈部紧绷右' },
    [12] = { name = 'ChnRs_04_L',        desc = '下巴抬起左' },
    [13] = { name = 'ChnRs_04_R',        desc = '下巴抬起右' },
    [14] = { name = 'Strtch_03_L',       desc = '嘴唇拉伸03左' },
    [15] = { name = 'Strtch_03_R',       desc = '嘴唇拉伸03右' },
    [16] = { name = 'Strtch_04_L',       desc = '嘴唇拉伸04左' },
    [17] = { name = 'Strtch_04_R',       desc = '嘴唇拉伸04右' },
    [18] = { name = 'Strtch_08_L',       desc = '嘴唇拉伸08左' },
    [19] = { name = 'Strtch_08_R',       desc = '嘴唇拉伸08右' },
    [20] = { name = 'Pkr_01_L',          desc = '嘟嘴01左' },
    [21] = { name = 'Pkr_01_R',          desc = '嘟嘴01右' },
    [22] = { name = 'Pkr_02_L',          desc = '嘟嘴02左' },
    [23] = { name = 'Pkr_02_R',          desc = '嘟嘴02右' },
    [24] = { name = 'Pkr_03_L',          desc = '嘟嘴03左(发音U)' },
    [25] = { name = 'Pkr_03_R',          desc = '嘟嘴03右(发音U)' },
    [26] = { name = 'NosWrnkl_03_L',     desc = '皱鼻03左' },
    [27] = { name = 'NosWrnkl_03_R',     desc = '皱鼻03右' },
    [28] = { name = 'NosWrnkl_04_L',     desc = '皱鼻04左' },
    [29] = { name = 'NosWrnkl_04_R',     desc = '皱鼻04右' },
    [30] = { name = 'NosWrnkl_05_L',     desc = '皱鼻05左' },
    [31] = { name = 'NosWrnkl_05_R',     desc = '皱鼻05右' },
    [32] = { name = 'BrInDn_00_L',       desc = '眉头下压/皱眉左' },
    [33] = { name = 'BrInDn_00_R',       desc = '眉头下压/皱眉右' },
    [34] = { name = 'BrInRs_00_L',       desc = '眉头挑起左(困惑)' },
    [35] = { name = 'BrInRs_00_R',       desc = '眉头挑起右(困惑)' },
    [36] = { name = 'BrOutRs_00_L',      desc = '眉梢上提左(惊讶)' },
    [37] = { name = 'BrOutRs_00_R',      desc = '眉梢上提右(惊讶)' },
    [38] = { name = 'BrLr_00_L',         desc = '整眉压低左' },
    [39] = { name = 'BrLr_00_R',         desc = '整眉压低右' },
    [40] = { name = 'LdTight_05_L',      desc = '下眼睑绷紧05左' },
    [41] = { name = 'LdTight_05_R',      desc = '下眼睑绷紧05右' },
    [42] = { name = 'Sqnt_03_L',         desc = '眯眼03左' },
    [43] = { name = 'Sqnt_03_R',         desc = '眯眼03右' },
    [44] = { name = 'Sqnt_06_L',         desc = '闭眼06左(眨眼/闭眼)' },
    [45] = { name = 'Sqnt_06_R',         desc = '闭眼06右(眨眼/闭眼)' },
    [46] = { name = 'LpRolIn_04_L',      desc = '上唇内卷04左' },
    [47] = { name = 'LpRolIn_04_R',      desc = '上唇内卷04右' },
    [48] = { name = 'LpRolIn_05_L',      desc = '下唇内卷05左' },
    [49] = { name = 'LpRolIn_05_R',      desc = '下唇内卷05右' },
    [50] = { name = 'UprLdDn_00_L',      desc = '上眼睑下垂00左' },
    [51] = { name = 'UprLdDn_00_R',      desc = '上眼睑下垂00右' },
    [52] = { name = 'UprLdDn_01_L',      desc = '上眼睑下垂01左' },
    [53] = { name = 'UprLdDn_01_R',      desc = '上眼睑下垂01右' },
    [54] = { name = 'UprLdDn_03_L',      desc = '上眼睑下垂03左' },
    [55] = { name = 'UprLdDn_03_R',      desc = '上眼睑下垂03右' },
    [56] = { name = 'UprLdDn_05_L',      desc = '上眼睑闭合05左' },
    [57] = { name = 'UprLdDn_05_R',      desc = '上眼睑闭合05右' },
    [58] = { name = 'MouthR_05_L',       desc = '嘴角右偏05左侧' },
    [59] = { name = 'MouthR_05_R',       desc = '嘴角右偏05右侧' },
    [60] = { name = 'MouthL_05_L',       desc = '嘴角左偏05左侧' },
    [61] = { name = 'MouthL_05_R',       desc = '嘴角左偏05右侧' },
    [62] = { name = 'UprLpRs_01_L',      desc = '上唇抬起01左' },
    [63] = { name = 'UprLpRs_01_R',      desc = '上唇抬起01右' },
    [64] = { name = 'UprLpRs_04_L',      desc = '上唇抬起04左' },
    [65] = { name = 'UprLpRs_04_R',      desc = '上唇抬起04右' },
    [66] = { name = 'UprLpRs_05_L',      desc = '上唇鼻侧抬高05左' },
    [67] = { name = 'UprLpRs_05_R',      desc = '上唇鼻侧抬高05右' },
    [68] = { name = 'Fnl_04_L',          desc = '漏斗状张嘴04左' },
    [69] = { name = 'Fnl_04_R',          desc = '漏斗状张嘴04右' },
    [70] = { name = 'CrnDprs_00_L',      desc = '嘴角下压00左(悲伤)' },
    [71] = { name = 'CrnDprs_00_R',      desc = '嘴角下压00右(悲伤)' },
    [72] = { name = 'CrnDprs_01_L',      desc = '嘴角下压01左' },
    [73] = { name = 'CrnDprs_01_R',      desc = '嘴角下压01右' },
    [74] = { name = 'CrnDprs_02_L',      desc = '嘴角下压02左' },
    [75] = { name = 'CrnDprs_02_R',      desc = '嘴角下压02右' },
    [76] = { name = 'LwrLpDprs_00_L',    desc = '下唇下拉00左', alias = 'CrnPl_JwOpn_L' },
    [77] = { name = 'LwrLpDprs_00_R',    desc = '下唇下拉00右', alias = 'CrnPl_JwOpn_R' },
    [78] = { name = 'LwrLpDprs_03_L',    desc = '下唇下拉03左', alias = 'Strtch_JwOpn_L' },
    [79] = { name = 'LwrLpDprs_03_R',    desc = '下唇下拉03右', alias = 'Strtch_JwOpn_R' },
    [80] = { name = 'LpPush_00_L',       desc = '嘴唇前突00左', alias = 'Sqnt_UprLdDn_L' },
    [81] = { name = 'LpPush_00_R',       desc = '嘴唇前突00右', alias = 'Sqnt_UprLdDn_R' },
    [82] = { name = 'LpPush_01_L',       desc = '嘴唇前突01左', alias = 'LdT_UprLdDn_L' },
    [83] = { name = 'LpPush_01_R',       desc = '嘴唇前突01右', alias = 'LdT_UprLdDn_R' },
    [84] = { name = 'MouthW_00_L',       desc = '嘴角向外展宽00左', alias = 'CrnPl_LwrLpDprs_L' },
    [85] = { name = 'MouthW_00_R',       desc = '嘴角向外展宽00右', alias = 'CrnPl_LwrLpDprs_R' },
    [86] = { name = 'MouthW_01_L',       desc = '嘴角向外展宽01左', alias = 'Strtch_CrnPl_L' },
    [87] = { name = 'MouthW_01_R',       desc = '嘴角向外展宽01右', alias = 'Strtch_CrnPl_R' },
    [88] = { name = 'LpBit_TL',          desc = '咬左上唇' },
    [89] = { name = 'LpBit_TR',          desc = '咬右上唇' },
    [90] = { name = 'LpBit_BL',          desc = '咬左下唇' },
    [91] = { name = 'LpBit_BR',          desc = '咬右下唇' },
    [92] = { name = 'Pkr_Fnl_TL',        desc = '嘟嘴漏斗左上' },
    [93] = { name = 'Pkr_Fnl_TR',        desc = '嘟嘴漏斗右上' },
    [94] = { name = 'Pkr_Fnl_BL',        desc = '嘟嘴漏斗左下' },
    [95] = { name = 'Pkr_Fnl_BR',        desc = '嘟嘴漏斗右下' },
}

-- Pre-calculate hashes
for i = 0, 95 do
    local info = FACS_CHANNEL_INFO[i]
    info.hash = Hash.hash('HeadSkinned_blendShape.' .. info.name)
    info.raw_hash = Hash.hash(info.name)
    if info.alias then
        info.alias_hash = Hash.hash('HeadSkinned_blendShape.' .. info.alias)
    end
end

local stats = {}
for i = 0, 95 do
    local info = FACS_CHANNEL_INFO[i]
    stats[i] = {
        index = i,
        name = info.name,
        desc = info.desc,
        min = 0.0,
        max = 0.0,
        current = 0.0,
        sum = 0.0,
        count = 0
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
        timestamp = os.date('%Y-%m-%d %H:%M:%S'),
        duration_sec = record_frame_count > 0 and (os.clock() - record_start_time) or 0,
        frame_count = record_frame_count,
        total_channels = 96,
        facs_channels = {}
    }
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
            average = math.floor(avg * 1000 + 0.5) / 1000
        })
    end
    json.dump_file('ShapeKeySystem/native_facs_baselines.json', export, 2)
end

-- Deform hash to index resolution on via.motion.Motion
local cached_motion_id = nil
local deform_indices = {}

local function get_deform_index(dm, h1, h2, h3)
    if not dm then return nil end
    local addr = R.address(dm)
    if addr ~= cached_motion_id then
        cached_motion_id = addr
        deform_indices = {}
        local dhashes = R.call(dm, 'get_DeformNameHashes')
        local len = dhashes and (R.call(dhashes, 'get_Length') or R.call(dhashes, 'get_Count')) or 0
        for i = 0, len - 1 do
            local h = Hash.hash_at(dhashes, i, true)
            if h then deform_indices[h] = i end
        end
    end
    return deform_indices[h1] or (h2 and deform_indices[h2]) or (h3 and deform_indices[h3])
end

local menu_tree_open = false

-- Real-time sampling per frame (idles when not recording and UI is closed)
re.on_frame(function()
    if not is_recording and not show_floating_window and not menu_tree_open then
        return
    end
    pcall(function()
        local head = R.find()
        if not head or not head.face then return end
        local mesh = head.mesh or R.mesh(head.face)
        local cn = mesh and R.call(mesh, 'get_BlendShapeChannelNum') or 0
        local is_native_mesh = (cn == 96)

        local face_go = head.face and R.call(head.face, 'get_GameObject')
        local root_go = head.root and R.call(head.root, 'get_GameObject')
        local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
        local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))

        -- Check facial animation driver
        local drv = root_go and (R.component(root_go, sdk.typeof('app.PlayerFacialAnimationDriver'))
            or R.component(root_go, sdk.typeof('app.CharacterFacialAnimationDriver')))
        local fmotion = drv and drv:get_field('_FacialMotion')
        local dm = fmotion or fm or rm

        local dvals = dm and R.call(dm, 'get_DeformValues')
        local dlen = dvals and (R.call(dvals, 'get_Length') or R.call(dvals, 'get_Count')) or 0

        if is_recording then
            record_frame_count = record_frame_count + 1
            if use_timer and auto_stop_seconds > 0 then
                if (os.clock() - record_start_time) >= auto_stop_seconds then
                    is_recording = false
                    save_stats_to_file()
                end
            end
        end

        local snap_outputs = nil
        if not is_native_mesh then
            local ok_s, s_obj = pcall(Signals.snapshot, { include_native_outputs = true })
            if ok_s and s_obj then snap_outputs = s_obj.outputs or s_obj end
        end

        for i = 0, 95 do
            local val = nil
            local info = FACS_CHANNEL_INFO[i]

            -- 1. If native mesh, read blendshape channel directly
            if is_native_mesh and mesh and i < cn then
                val = R.call(mesh, 'getBlendShapeChannelWeightParam(System.UInt64)', i)
                if val == nil then val = R.call(mesh, 'getBlendShapeChannelWeightParam', i) end
                if val == nil then val = R.call(mesh, 'getBlendShapeChannelWeight', i) end
            end

            -- 2. Read from Motion Deform buffer via hash lookup
            if (val == nil or not is_native_mesh) and dm and dvals then
                local didx = get_deform_index(dm, info.hash, info.alias_hash, info.raw_hash)
                if didx and didx < dlen then
                    val = R.call(dvals, 'get_Item', didx)
                end
            end

            -- 3. Read from SKS Bone Projection / Facial Driver snapshot if on Mod Mesh
            if (val == nil or val <= 0.0001) and snap_outputs then
                val = snap_outputs["re9.native." .. info.name] or snap_outputs[info.name]
                if val == nil or val <= 0.0001 then
                    if info.name == "JwOpn_00_L" or info.name == "JwOpn_00_R" then
                        val = snap_outputs["jawOpen"] or snap_outputs["re9VowelA"]
                    elseif info.name == "Strtch_04_L" or info.name == "Strtch_03_L" then
                        val = snap_outputs["mouthStretchLeft"]
                    elseif info.name == "Strtch_04_R" or info.name == "Strtch_03_R" then
                        val = snap_outputs["mouthStretchRight"]
                    elseif info.name == "Pkr_01_L" or info.name == "Pkr_02_L" or info.name == "Pkr_03_L" then
                        val = snap_outputs["mouthPucker"] or snap_outputs["re9VowelU"]
                    elseif info.name == "Pkr_01_R" or info.name == "Pkr_02_R" or info.name == "Pkr_03_R" then
                        val = snap_outputs["mouthPucker"] or snap_outputs["re9VowelU"]
                    elseif info.name:find("^CrnPl_0") then
                        val = info.name:find("_L") and snap_outputs["mouthSmileLeft"] or snap_outputs["mouthSmileRight"]
                    elseif info.name:find("Sqnt_06") or info.name:find("UprLdDn_05") then
                        val = info.name:find("_L") and snap_outputs["eyeBlinkLeft"] or snap_outputs["eyeBlinkRight"]
                    elseif info.name:find("BrInDn") or info.name:find("BrLr") then
                        val = info.name:find("_L") and snap_outputs["browDownLeft"] or snap_outputs["browDownRight"]
                    end
                end
            end

            if type(val) ~= 'number' or val ~= val then
                val = 0.0
            end

            val = math.max(0.0, math.min(1.0, val))
            local s = stats[i]
            s.current = val
            if s.count == 0 then
                s.min = val
                s.max = val
                s.sum = val
                s.count = 1
            else
                if val < s.min then s.min = val end
                if val > s.max then s.max = val end
                if is_recording then
                    s.sum = s.sum + val
                    s.count = s.count + 1
                end
            end
        end
    end)
end)

-- Main UI draw content
local function draw_deform_content()
    local head = R.find()
    if head then
        local mesh = head.mesh or R.mesh(head.face)
        local cn = mesh and R.call(mesh, 'get_BlendShapeChannelNum') or 0
        local is_mod = (cn ~= 96)
        if is_mod then
            imgui.text_colored(string.format('[Mod网格已连接] 当前装备: %s (通道数: %d)', head.identity or 'Mod', cn), 0xFF00FFFF)
            imgui.text_colored('数据源: [via.motion.Motion 原生Deform轨道 实时提取]', 0xFF00FF00)
        else
            imgui.text_colored(string.format('[原版里昂已连接] 网格: %s (96原生FACS通道)', head.identity or 'Leon'), 0xFF00FF00)
        end
    else
        imgui.text_colored('正在搜寻头部实体 (cp_A000 / ch0100)...', 0xFF8888FF)
    end

    imgui.spacing()

    -- Action Buttons
    if not is_recording then
        if imgui.button('开始录制 (Record)', 140, 28) then
            reset_stats()
            is_recording = true
        end
    else
        if imgui.button('停止并保存 (Stop & Save)', 160, 28) then
            is_recording = false
            save_stats_to_file()
        end
    end
    imgui.same_line()
    if imgui.button('重置统计峰值 (Reset)', 150, 28) then
        reset_stats()
    end
    imgui.same_line()
    if imgui.button('导出当前快照为 JSON', 160, 28) then
        save_stats_to_file()
    end

    imgui.spacing()

    -- Filters and Sorting
    local c_flt, v_flt = imgui.checkbox('开启独立悬浮监视窗 (Pin Overlay)', show_floating_window)
    if c_flt then show_floating_window = v_flt end
    imgui.same_line()
    local c_hz, v_hz = imgui.checkbox('仅显示活动通道 (>0.001)', hide_zero)
    if c_hz then hide_zero = v_hz end
    imgui.same_line()
    local c_sb, v_sb = imgui.checkbox('按实时数值降序排列', sort_by_value)
    if c_sb then sort_by_value = v_sb end

    local c_txt, v_txt = imgui.input_text('搜索过滤 (序号/名称/中文说明)', filter_text)
    if c_txt then filter_text = v_txt end

    imgui.separator()

    -- Prepare list
    local list = {}
    local f_low = filter_text:lower()
    for i = 0, 95 do
        local s = stats[i]
        local ok = true
        if filter_text ~= '' then
            local str = string.format('[%02d] %s %s', i, s.name, s.desc):lower()
            if not str:find(f_low, 1, true) then ok = false end
        end
        if hide_zero and s.current < 0.001 and s.max < 0.001 then
            ok = false
        end
        if ok then table.insert(list, s) end
    end

    if sort_by_value then
        table.sort(list, function(a, b) return a.current > b.current end)
    else
        table.sort(list, function(a, b) return a.index < b.index end)
    end

    imgui.text_colored(string.format('%-6s | %-16s | %-22s | %-8s | %-8s | %-8s | %s',
        '序号', 'FACS通道名', '中文功能说明', '实时当前', '常态Min', '峰值Max', '实时动态条'), 0xFFAAAAAA)
    imgui.separator()

    for _, s in ipairs(list) do
        local c = s.current
        local color = 0xFFAAAAAA -- dim gray for 0.000
        if c >= 0.70 then
            color = 0xFF5555FF -- Red/Pink
        elseif c >= 0.30 then
            color = 0xFF00AAFF -- Orange
        elseif c >= 0.001 then
            color = 0xFF00FFFF -- Bright Cyan/Yellow
        end

        local text = string.format('[%02d] | %-16s | %-20s | %6.3f | %6.3f | %6.3f',
            s.index, s.name, s.desc, c, s.min, s.max)
        imgui.text_colored(text, color)
        imgui.same_line()
        -- Visual bar
        local bar_len = math.floor(c * 20 + 0.5)
        local bar_str = string.rep('■', bar_len) .. string.rep(' ', 20 - bar_len)
        imgui.text_colored('[' .. bar_str .. ']', color)
    end
end

-- Draw in REFramework Menu and optional Floating Window
re.on_draw_ui(function()
    if imgui.tree_node('RE9 原生96条Deform实时监视器') then
        menu_tree_open = true
        draw_deform_content()
        imgui.tree_pop()
    else
        menu_tree_open = false
    end

    if show_floating_window then
        imgui.set_next_window_size({ 800, 500 }, 2) -- 2 = ImGuiCond_FirstUseEver
        local is_open = imgui.begin_window('【RE9】原生 96 条 FACS Deform 实时监视窗', true, 0)
        if is_open then
            draw_deform_content()
            imgui.end_window()
        else
            show_floating_window = false
        end
    end
end)
