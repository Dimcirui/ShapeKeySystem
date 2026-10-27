-- RecordShapeKeys.lua
-- RE9 原生96 FACS形态键与285骨骼实时同步监测与轨迹录制系统
-- (RE9 Native 96 FACS & 285 Face Bones Synchronized Trajectory Recorder)

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

local record_bones_trajectory = true -- 同时高精度采样全量 285 根骨骼与 96 形态键的每帧时序关联

local sort_by_baseline = false   -- 默认按序号 00 ~ 95 自然顺序排列，绝不打乱或把 0.000 挤到底部
local hide_zero_baseline = false

local ALL_285_BONES = {
    "root",
    "Hip",
    "Spine_0",
    "Spine_1",
    "Spine_2",
    "R_Arm_Clavicle",
    "R_Scapula_0Offset",
    "R_Scapula_0",
    "R_Scapula_1Offset",
    "R_Scapula_1",
    "R_Scapula_2Offset",
    "R_Scapula_2",
    "R_Arm_Upper",
    "R_Arm_Upper_Twist_0",
    "R_Arm_Upper_Twist_1",
    "R_Delt_Front_AOffset",
    "R_Delt_Front_A",
    "R_Delt_Rear_AOffset",
    "R_Delt_Rear_A",
    "R_Delt_Side_AOffset",
    "R_Delt_Side_A",
    "R_Pec_AOffset",
    "R_Pec_A",
    "L_Arm_Clavicle",
    "L_Scapula_0Offset",
    "L_Scapula_0",
    "L_Scapula_1Offset",
    "L_Scapula_1",
    "L_Scapula_2Offset",
    "L_Scapula_2",
    "L_Pec_AOffset",
    "L_Pec_A",
    "L_Arm_Upper",
    "L_Arm_Upper_Twist_0",
    "L_Arm_Upper_Twist_1",
    "L_Delt_Front_AOffset",
    "L_Delt_Front_A",
    "L_Delt_Rear_AOffset",
    "L_Delt_Rear_A",
    "L_Delt_Side_AOffset",
    "L_Delt_Side_A",
    "R_Trap_AOffset",
    "R_Trap_A",
    "L_Trap_AOffset",
    "L_Trap_A",
    "L_Pec_BOffset",
    "L_Pec_B",
    "R_Pec_BOffset",
    "R_Pec_B",
    "Neck_0",
    "FacialJnt_Neck_0",
    "C_NeckB",
    "L_NeckB_01",
    "L_NeckB_02",
    "L_NeckB_03",
    "R_NeckB_01",
    "R_NeckB_02",
    "R_NeckB_03",
    "Neck_1",
    "FacialJnt_Neck_1",
    "R_NeckA_01",
    "R_NeckA_02",
    "R_NeckA_03",
    "C_NeckA",
    "L_NeckA_01",
    "L_NeckA_02",
    "L_NeckA_03",
    "Head_0",
    "FacialJnt_Face",
    "L_Eye",
    "R_Eye",
    "C_Jaw",
    "C_tongue_00",
    "C_tongue_01",
    "C_tongue_02",
    "C_tongue_03",
    "C_tongue_04",
    "C_tongue_05",
    "C_Skull",
    "C_Forehead",
    "L_Forehead_01",
    "L_Forehead_02",
    "L_Forehead_03",
    "L_Temple_P",
    "C_NoseBridge",
    "L_Brow_01",
    "L_Brow_02",
    "L_Brow_03",
    "L_Brow_04",
    "L_NoseBridgeSide",
    "L_BrowSack_01",
    "L_BrowSack_02",
    "L_BrowSack_03",
    "L_UprLdCornerIn_02",
    "L_EyeFold_01",
    "L_EyeFold_02",
    "L_EyeFold_03",
    "L_EyeFold_04",
    "L_UprLd_01",
    "L_UprLd_02",
    "L_UprLd_03",
    "L_UprLdCornerIn_01",
    "L_UprLdEdge_01",
    "L_UprLdEdge_02",
    "L_UprLdEdge_03",
    "L_UprLdCornerOut",
    "L_LwrLdCornerIn_01",
    "L_LwrLdEdge_01",
    "L_LwrLdEdge_02",
    "L_LwrLdEdge_03",
    "L_LwrLdCornerOut",
    "L_LwrLdCornerIn_02",
    "L_LwrLd_01",
    "L_LwrLd_02",
    "L_LwrLd_03",
    "L_LwrLd_04",
    "L_EyeBag_01",
    "L_EyeBag_02",
    "L_EyeBag_03",
    "L_CrowFeet_02",
    "L_CrowFeet_01",
    "L_CheekBone_P",
    "L_CheekBone_03",
    "L_CheekBoneOut",
    "L_Ear_P",
    "L_Masseter",
    "L_JawBulge",
    "L_CheekIn_01",
    "L_CheekIn_02",
    "L_CheekIn_03",
    "L_CheekIn_04",
    "L_Cheek_01",
    "L_Cheek_02",
    "L_Cheek_03",
    "L_Cheek_04",
    "L_NasoBulge_01",
    "L_NasoBulge_02",
    "L_NasoBulge_03",
    "L_NasoFold",
    "C_NoseBone",
    "C_NoseTip",
    "L_NoseSide",
    "L_Nostril_P",
    "C_NoseBase",
    "C_UprLpOut",
    "L_UprLpOut_01",
    "L_UprLpOut_02",
    "L_MouthCornerOut",
    "C_UprLp_01",
    "C_UprLp_02",
    "C_UprLp_03",
    "L_UprLp_01",
    "L_UprLp_02",
    "L_UprLp_03",
    "L_UprLpSide_01",
    "L_UprLpSide_02",
    "L_UprLpSide_03",
    "L_UprLpCorner_01",
    "L_UprLpCorner_02",
    "L_UprLpCorner_03",
    "L_LipCorner_01",
    "L_LipCorner_02",
    "L_LipCorner_03",
    "C_LwrLp_01",
    "C_LwrLp_02",
    "C_LwrLp_03",
    "L_LwrLp_01",
    "L_LwrLp_02",
    "L_LwrLp_03",
    "L_LwrLpSide_01",
    "L_LwrLpSide_02",
    "L_LwrLpSide_03",
    "L_LwrLpCorner_01",
    "L_LwrLpCorner_02",
    "L_LwrLpCorner_03",
    "C_LwrLpOut",
    "L_LwrLpOut_01",
    "L_LwrLpOut_02",
    "C_MouthBag",
    "C_Chin_01",
    "C_Chin_02",
    "L_Chin_01",
    "L_Chin_02",
    "L_ChinSide",
    "C_UnderChin",
    "L_UnderChin",
    "C_NeckLine",
    "L_NeckLine",
    "L_JawLine_01",
    "L_JawLine_02",
    "L_JawLine_03",
    "R_Forehead_01",
    "R_Forehead_02",
    "R_Forehead_03",
    "R_Temple_P",
    "R_Brow_01",
    "R_Brow_02",
    "R_Brow_03",
    "R_Brow_04",
    "R_NoseBridgeSide",
    "R_BrowSack_01",
    "R_BrowSack_02",
    "R_BrowSack_03",
    "R_UprLdCornerIn_02",
    "R_EyeFold_01",
    "R_EyeFold_02",
    "R_EyeFold_03",
    "R_EyeFold_04",
    "R_UprLd_01",
    "R_UprLd_02",
    "R_UprLd_03",
    "R_UprLdCornerIn_01",
    "R_UprLdEdge_01",
    "R_UprLdEdge_02",
    "R_UprLdEdge_03",
    "R_UprLdCornerOut",
    "R_LwrLdCornerIn_01",
    "R_LwrLdEdge_01",
    "R_LwrLdEdge_02",
    "R_LwrLdEdge_03",
    "R_LwrLdCornerOut",
    "R_LwrLdCornerIn_02",
    "R_LwrLd_01",
    "R_LwrLd_02",
    "R_LwrLd_03",
    "R_LwrLd_04",
    "R_EyeBag_01",
    "R_EyeBag_02",
    "R_EyeBag_03",
    "R_CrowFeet_02",
    "R_CrowFeet_01",
    "R_CheekBone_P",
    "R_CheekBone_03",
    "R_CheekBoneOut",
    "R_Ear_P",
    "R_Masseter",
    "R_JawBulge",
    "R_CheekIn_01",
    "R_CheekIn_02",
    "R_CheekIn_03",
    "R_CheekIn_04",
    "R_Cheek_01",
    "R_Cheek_02",
    "R_Cheek_03",
    "R_Cheek_04",
    "R_NasoBulge_01",
    "R_NasoBulge_02",
    "R_NasoBulge_03",
    "R_NasoFold",
    "R_NoseSide",
    "R_Nostril_P",
    "R_UprLpOut_01",
    "R_UprLpOut_02",
    "R_MouthCornerOut",
    "R_UprLp_01",
    "R_UprLp_02",
    "R_UprLp_03",
    "R_UprLpSide_01",
    "R_UprLpSide_02",
    "R_UprLpSide_03",
    "R_UprLpCorner_01",
    "R_UprLpCorner_02",
    "R_UprLpCorner_03",
    "R_LipCorner_01",
    "R_LipCorner_02",
    "R_LipCorner_03",
    "R_LwrLp_01",
    "R_LwrLp_02",
    "R_LwrLp_03",
    "R_LwrLpSide_01",
    "R_LwrLpSide_02",
    "R_LwrLpSide_03",
    "R_LwrLpCorner_01",
    "R_LwrLpCorner_02",
    "R_LwrLpCorner_03",
    "R_LwrLpOut_01",
    "R_LwrLpOut_02",
    "R_Chin_01",
    "R_Chin_02",
    "R_ChinSide",
    "R_UnderChin",
    "R_NeckLine",
    "R_JawLine_01",
    "R_JawLine_02",
    "R_JawLine_03"
}


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

-- 轨迹时序采样存储
local trajectory_samples = {
    shapekeys = {}, -- [t] = { [0] = v0, ..., [95] = v95 }
    bones = {},     -- [bone_name] = { base_pos = {}, base_rot = {}, deltas = {} }
    times = {}
}

local bound_joints = nil

local function bind_all_joints(head)
    bound_joints = {}
    if not head or not head.face then return end
    for _, bone_name in ipairs(ALL_285_BONES) do
        local j = R.call(head.face, "getJointByName(System.String)", bone_name)
        if not j and head.root then
            j = R.call(head.root, "getJointByName(System.String)", bone_name)
        end
        if j then
            local bp = R.call(j, "get_BaseLocalPosition")
            local br = R.call(j, "get_BaseLocalRotation")
            table.insert(bound_joints, {
                name = bone_name,
                joint = j,
                bpos = bp and { bp.x, bp.y, bp.z } or {0, 0, 0},
                brot = br and { br.x, br.y, br.z, br.w } or {0, 0, 0, 1}
            })
        end
    end
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
    
    trajectory_samples = {
        shapekeys = {},
        bones = {},
        times = {}
    }
    bound_joints = nil
end

local function save_stats_to_file()
    -- 1. 保存 96 FACS 统计数据
    local export = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
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
            average = math.floor(avg * 1000 + 0.5) / 1000,
            has_high_baseline = (s.min >= 0.10)
        })
    end
    json.dump_file("ShapeKeySystem/native_facs_baselines.json", export, 2)
    
    -- 2. 保存 285 骨骼与 96 形态键的毫秒级高精度时序轨迹
    if record_bones_trajectory and #trajectory_samples.times > 0 then
        local traj_export = {
            timestamp = export.timestamp,
            frame_count = #trajectory_samples.times,
            duration_sec = export.duration_sec,
            channels_count = 96,
            bones_count = 0,
            shapekey_names = {},
            trajectory = trajectory_samples
        }
        for i = 0, 95 do traj_export.shapekey_names[i] = FACS_CHANNEL_INFO[i].name end
        local bc = 0
        for _ in pairs(trajectory_samples.bones) do bc = bc + 1 end
        traj_export.bones_count = bc
        
        json.dump_file("ShapeKeySystem/native_bone_shapekey_trajectory.json", traj_export)
    end
    
    return true
end

-- Sampling logic every frame
re.on_frame(function()
    if not is_recording and not ui_is_open then
        return
    end
    pcall(function()
        local head = R.find()
        if not head or not head.face then return end
        local mesh = head.mesh or R.mesh(head.face)
        local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0

        local face_go = R.call(head.face, 'get_GameObject')
        local root_go = head.root and R.call(head.root, 'get_GameObject')
        local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
        local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))
        local dm = fm or rm
        local dvals = dm and R.call(dm, "get_DeformValues")
        local dlen = dvals and (R.call(dvals, "get_Length") or R.call(dvals, "get_Count")) or 0

        if is_recording then
            record_frame_count = record_frame_count + 1
            if not bound_joints then
                bind_all_joints(head)
            end
            if use_timer and auto_stop_seconds > 0 then
                if (os.clock() - record_start_time) >= auto_stop_seconds then
                    is_recording = false
                    save_stats_to_file()
                end
            end
        end

        local cur_sk_frame = is_recording and {} or nil

        -- Sample 96 FACS Channels
        for i = 0, 95 do
            local val = nil
            if mesh and i < cn then
                val = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
                if val == nil then val = R.call(mesh, "getBlendShapeChannelWeightParam", i) end
                if val == nil then val = R.call(mesh, "getBlendShapeChannelWeight", i) end
            end
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
                if val < s.min then s.min = val end
                if val > s.max then s.max = val end
            else
                if val < s.min then s.min = val end
                if val > s.max then s.max = val end
                s.sum = s.sum + val
                s.count = s.count + 1
            end
            if cur_sk_frame then
                cur_sk_frame[i] = math.floor(val * 1000 + 0.5) / 1000
            end
        end

        -- Sample 285 Bones in Recording mode
        if is_recording and record_bones_trajectory and bound_joints then
            table.insert(trajectory_samples.times, os.clock() - record_start_time)
            table.insert(trajectory_samples.shapekeys, cur_sk_frame)
            
            for _, bj in ipairs(bound_joints) do
                local jname = bj.name
                local j = bj.joint
                local p = R.call(j, "get_LocalPosition")
                local r = R.call(j, "get_LocalRotation")
                
                local bdata = trajectory_samples.bones[jname]
                if not bdata then
                    bdata = {
                        base_pos = bj.bpos,
                        base_rot = bj.brot,
                        pos = {},
                        rot = {}
                    }
                    trajectory_samples.bones[jname] = bdata
                end
                
                if p and r then
                    -- Store relative delta or absolute
                    table.insert(bdata.pos, {
                        math.floor((p.x - bj.bpos[1]) * 10000) / 10, -- mm with 0.1 precision
                        math.floor((p.y - bj.bpos[2]) * 10000) / 10,
                        math.floor((p.z - bj.bpos[3]) * 10000) / 10
                    })
                    table.insert(bdata.rot, {
                        math.floor(r.x * 10000) / 10000,
                        math.floor(r.y * 10000) / 10000,
                        math.floor(r.z * 10000) / 10000,
                        math.floor(r.w * 10000) / 10000
                    })
                end
            end
        end
    end)
end)

-- UI Drawing logic

-- =========================================================================
-- 主动骨骼驱动形态键探测系统 (Active Bone Driver Probe System)
-- 测试原理: 强行逐一拖拽/旋转目标骨骼，实测 96 个形态键是否有任何一个发生数值响应
-- =========================================================================

local probe_active = false
local probe_bone_index = 1
local probe_phase = 0 -- 0: idle, 1: baseline, 2: manipulate, 3: verify/restore
local probe_frame_in_phase = 0

local PROBE_FOCUSED_BONES = {
    { name = "C_Jaw", desc = "下颌骨 (张嘴/下沉 -40mm)", trans = {0, -0.040, 0}, rot = {0.259, 0, 0, 0.966} },
    { name = "C_Jaw", desc = "下颌骨 (下沉微调 -20mm)", trans = {0, -0.020, 0}, rot = {0.130, 0, 0, 0.991} },
    { name = "MouthW_00_L", desc = "左嘴宽辅助驱动骨", trans = {0.025, 0, 0}, rot = nil },
    { name = "MouthW_00_R", desc = "右嘴宽辅助驱动骨", trans = {-0.025, 0, 0}, rot = nil },
    { name = "MouthW_01_L", desc = "左嘴宽第二节", trans = {0.025, 0, 0}, rot = nil },
    { name = "MouthR_05_L", desc = "左嘴角辅助骨", trans = {0.020, -0.015, 0}, rot = nil },
    { name = "MouthR_05_R", desc = "右嘴角辅助骨", trans = {-0.020, -0.015, 0}, rot = nil },
    { name = "MouthL_05_L", desc = "左唇辅助骨", trans = {0.015, 0.015, 0}, rot = nil },
    { name = "C_Chin_01", desc = "下巴第一节", trans = {0, -0.025, 0}, rot = nil },
    { name = "C_Chin_02", desc = "下巴第二节", trans = {0, -0.025, 0}, rot = nil },
    { name = "C_UnderChin", desc = "下巴底部", trans = {0, -0.025, 0}, rot = nil },
    { name = "L_LipCorner_01", desc = "左嘴角主骨", trans = {0.020, 0.010, 0}, rot = nil },
    { name = "R_LipCorner_01", desc = "右嘴角主骨", trans = {-0.020, 0.010, 0}, rot = nil },
    { name = "L_Brow_01", desc = "左眉峰主骨 (上抬 +25mm)", trans = {0, 0.025, 0}, rot = nil },
    { name = "L_Brow_01", desc = "左眉峰主骨 (下压 -25mm)", trans = {0, -0.025, 0}, rot = nil },
    { name = "L_Brow_02", desc = "左眉间主骨", trans = {0, -0.020, 0}, rot = nil },
    { name = "L_Brow_03", desc = "左眉头主骨", trans = {0, -0.020, 0}, rot = nil },
    { name = "L_BrowSack_01", desc = "左眉囊压迫骨", trans = {0, -0.020, 0}, rot = nil },
    { name = "L_EyeFold_01", desc = "左上眼睑折痕骨 (闭眼测试)", trans = {0, -0.015, 0}, rot = nil },
    { name = "L_EyeFold_02", desc = "左上眼睑外折骨", trans = {0, -0.015, 0}, rot = nil },
    { name = "L_EyeBag_01", desc = "左下眼睑眼袋骨 (眯眼测试)", trans = {0, 0.015, 0}, rot = nil },
    { name = "L_Eye", desc = "左眼球主骨 (下转测试)", trans = nil, rot = {0.174, 0, 0, 0.985} },
    { name = "FacialJnt_Face", desc = "面部根骨骼", trans = {0, -0.020, 0}, rot = nil }
}

local probe_target_bones = PROBE_FOCUSED_BONES
local probe_results = {}
local probe_baseline_weights = {}
local probe_status_msg = "待命 (点击下方按钮立即开始主动测试)"
local probe_last_test_summary = nil

local function start_probe_test(custom_bone_list)
    if custom_bone_list then
        probe_target_bones = custom_bone_list
    else
        probe_target_bones = PROBE_FOCUSED_BONES
    end
    probe_active = true
    probe_bone_index = 1
    probe_phase = 1
    probe_frame_in_phase = 0
    probe_results = {}
    probe_baseline_weights = {}
    probe_status_msg = "测试初始化中..."
    probe_last_test_summary = nil
end

local function finish_probe_test()
    probe_active = false
    probe_phase = 0
    local responsive_count = 0
    for _, res in ipairs(probe_results) do
        if #res.affected_shapekeys > 0 then
            responsive_count = responsive_count + 1
        end
    end
    
    probe_status_msg = string.format("探测完成! 测试 %d 组，响应驱动 %d 组。", #probe_results, responsive_count)
    
    probe_last_test_summary = {
        total_tested = #probe_results,
        responsive_bones_count = responsive_count,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        details = probe_results
    }
    
    json.dump_file("ShapeKeySystem/active_bone_probe_results.json", probe_last_test_summary, 2)
end

-- Hook into UpdateMotion: apply manual forced bone manipulation
re.on_application_entry("UpdateMotion", function()
    if not probe_active or probe_phase ~= 2 then return end
    local head = R.find()
    if not head or not head.face then return end
    
    local item = probe_target_bones[probe_bone_index]
    if not item then return end
    
    local j = R.call(head.face, "getJointByName(System.String)", item.name)
    if not j then return end
    
    local bpos = R.call(j, "get_BaseLocalPosition")
    local brot = R.call(j, "get_BaseLocalRotation")
    
    if item.trans and bpos then
        local np = Vector3f.new(bpos.x + item.trans[1], bpos.y + item.trans[2], bpos.z + item.trans[3])
        pcall(j.call, j, "set_LocalPosition", np)
    end
    if item.rot and brot then
        local q = Quaternion.new(item.rot[1], item.rot[2], item.rot[3], item.rot[4])
        pcall(j.call, j, "set_LocalRotation", q)
    end
end)

-- Hook into LateUpdateBehavior: check if any shapekey changed on Mesh
re.on_application_entry("LateUpdateBehavior", function()
    if not probe_active then return end
    local head = R.find()
    if not head or not head.face then return end
    local mesh = head.mesh or R.mesh(head.face)
    local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
    
    local item = probe_target_bones[probe_bone_index]
    if not item then
        finish_probe_test()
        return
    end
    
    probe_frame_in_phase = probe_frame_in_phase + 1
    
    -- Phase 1: Baseline sampling (5 frames)
    if probe_phase == 1 then
        probe_status_msg = string.format("[%d/%d] 采样底噪中: %s (%s)", probe_bone_index, #probe_target_bones, item.name, item.desc)
        if probe_frame_in_phase >= 5 then
            for i = 0, 95 do
                local w = nil
                if i < cn then
                    w = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
                    if w == nil then w = R.call(mesh, "getBlendShapeChannelWeight", i) end
                end
                probe_baseline_weights[i] = w or 0.0
            end
            probe_phase = 2
            probe_frame_in_phase = 0
        end
    -- Phase 2: Manipulation and Verification (8 frames)
    elseif probe_phase == 2 then
        probe_status_msg = string.format("[%d/%d] 强行位移操控中: %s -> 监测 96 形态键响应", probe_bone_index, #probe_target_bones, item.name)
        if probe_frame_in_phase >= 8 then
            local affected = {}
            for i = 0, 95 do
                local cur_w = nil
                if i < cn then
                    cur_w = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
                    if cur_w == nil then cur_w = R.call(mesh, "getBlendShapeChannelWeight", i) end
                end
                cur_w = cur_w or 0.0
                local base_w = probe_baseline_weights[i] or 0.0
                local delta = math.abs(cur_w - base_w)
                if delta >= 0.001 then
                    table.insert(affected, {
                        index = i,
                        name = FACS_CHANNEL_INFO[i].name,
                        desc = FACS_CHANNEL_INFO[i].desc,
                        base_weight = math.floor(base_w * 1000) / 1000,
                        current_weight = math.floor(cur_w * 1000) / 1000,
                        delta = math.floor(delta * 1000) / 1000
                    })
                end
            end
            
            table.insert(probe_results, {
                bone_name = item.name,
                bone_desc = item.desc,
                manipulation = item.trans and string.format("位移: (%.1f, %.1f, %.1f)mm", item.trans[1]*1000, item.trans[2]*1000, item.trans[3]*1000) or "旋转测试",
                affected_shapekeys = affected,
                response_status = (#affected > 0) and "RESPONSIVE" or "NO_REACTION"
            })
            
            -- Phase 3: Restore bone
            probe_phase = 3
            probe_frame_in_phase = 0
            local j = R.call(head.face, "getJointByName(System.String)", item.name)
            if j then
                local bpos = R.call(j, "get_BaseLocalPosition")
                local brot = R.call(j, "get_BaseLocalRotation")
                if bpos then pcall(j.call, j, "set_LocalPosition", bpos) end
                if brot then pcall(j.call, j, "set_LocalRotation", brot) end
            end
        end
    -- Phase 3: Cooldown/Restore (3 frames)
    elseif probe_phase == 3 then
        if probe_frame_in_phase >= 3 then
            probe_bone_index = probe_bone_index + 1
            if probe_bone_index > #probe_target_bones then
                finish_probe_test()
            else
                probe_phase = 1
                probe_frame_in_phase = 0
            end
        end
    end
end)
re.on_draw_ui(function()
    local opened = imgui.tree_node("RE9 原生96 FACS形态键与285骨骼实时联动录制与解析")
    ui_is_open = (opened == true)
    if opened then

        -- =========================================================================
        -- 主动骨骼驱动形态键探测控制区
        -- =========================================================================
        imgui.spacing()
        imgui.separator()
        imgui.text_colored("【实验】骨骼主动强制操控 / 形态键响应探测器", 0xFF00FFFF)
        imgui.text_colored("说明: 强行将骨骼拖拽 2~4cm 或旋转，监测网格形态键是否发生数值变动，验证驱动骨机制。", 0xFFAAAAAA)
        imgui.spacing()

        if not probe_active then
            if imgui.button("开始重点驱动骨主动探测 (22组下颌/嘴唇/眉骨测试)", 380, 32) then
                start_probe_test(PROBE_FOCUSED_BONES)
            end
            imgui.same_line()
            if imgui.button("探测全量面部骨骼 (117根)", 200, 32) then
                local full_list = {}
                local keywords = {"jaw", "chin", "lip", "eye", "mouth", "cheek", "nose", "brow", "tongue", "face"}
                for _, b in ipairs(ALL_285_BONES) do
                    local bl = string.lower(b)
                    local matched = false
                    for _, kw in ipairs(keywords) do
                        if string.find(bl, kw) then matched = true; break end
                    end
                    if matched then
                        table.insert(full_list, { name = b, desc = "面部骨骼全量测试", trans = {0, -0.020, 0}, rot = nil })
                    end
                end
                start_probe_test(full_list)
            end
        else
            imgui.text_colored(">>> 正在进行主动测试: " .. probe_status_msg, 0xFF00FF00)
            if imgui.button("中断测试 (Cancel)", 150, 28) then
                probe_active = false
                probe_phase = 0
                probe_status_msg = "测试已由用户手动中断"
            end
        end

        imgui.text_colored("当前状态: " .. probe_status_msg, 0xFFCCCCCC)

        if probe_last_test_summary then
            imgui.spacing()
            local sum = probe_last_test_summary
            if sum.responsive_bones_count > 0 then
                imgui.text_colored(string.format(">>> 探测发现! 共有 %d 根骨骼的主动位移成功驱动了形态键！", sum.responsive_bones_count), 0xFF00FF00)
            else
                imgui.text_colored(">>> 实验结论: 测试的全部 " .. sum.total_tested .. " 组骨骼强制位移后，网格形态键均无任何变动 (变动量全为 0.000)。", 0xFF8888FF)
            end

            if imgui.tree_node("查看详细测试结果列表 (" .. #sum.details .. " 条记录)") then
                for _, d in ipairs(sum.details) do
                    if #d.affected_shapekeys > 0 then
                        imgui.text_colored(string.format("[成功驱动] %-16s (%s) | %s", d.bone_name, d.bone_desc, d.manipulation), 0xFF00FF00)
                        for _, aff in ipairs(d.affected_shapekeys) do
                            imgui.text_colored(string.format("    -> [%02d] %-16s (底噪: %.3f, 当前: %.3f, 变动: +%.3f)", aff.index, aff.name, aff.base_weight, aff.current_weight, aff.delta), 0xFF00FF00)
                        end
                    else
                        imgui.text_colored(string.format("[无响应]   %-16s (%s) | %s -> 96个形态键变动量均为 0.000", d.bone_name, d.bone_desc, d.manipulation), 0xFF888888)
                    end
                end
                imgui.tree_pop()
            end
        end
        imgui.separator()
        imgui.spacing()
        imgui.spacing()
        local head = R.find()
        if head then
            local mesh = head.mesh or R.mesh(head.face)
            local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
            imgui.text_colored(string.format("网格状态: [已连接] 头部网格 (通道数: %d | 骨骼就绪: %d 根)", cn, #ALL_285_BONES), 0xFF00FF00)
        else
            imgui.text_colored("网格状态: [未连接] 正在寻找头部网格 (cp_A000)...", 0xFF5555FF)
        end
        imgui.spacing()
        if not is_recording then
            if imgui.button("开始录制 96形态键与285骨骼全量联动数据", 320, 36) then
                reset_stats()
                is_recording = true
            end
        else
            if imgui.button("停止录制并保存时序轨迹 (Stop & Save)", 320, 36) then
                is_recording = false
                save_stats_to_file()
            end
        end
        imgui.same_line()
        if imgui.button("重置统计 (Reset)", 100, 36) then
            reset_stats()
        end
        imgui.same_line()
        if imgui.button("导出为 JSON 文件", 150, 36) then
            save_stats_to_file()
        end

        -- Status Display
        local elapsed = is_recording and (os.clock() - record_start_time) or 0
        if is_recording then
            imgui.text_colored(string.format("正在录制中... 时间: %.1f 绉?/ 已录制: %d 帧全骨骼轨迹", elapsed, record_frame_count), 0xFF00FF00)
        else
            imgui.text(string.format("录制就绪 / 已统计: %d 帧 (文件保存至: ShapeKeySystem/native_bone_shapekey_trajectory.json)", record_frame_count))
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
        imgui.text_colored("提示：点击开始录制后，在游戏里让人物待机、说话或转动面部，录制完成后将自动计算 285 根骨骼与 96 形态键的数学对应关系！", 0xFF55FFFF)
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
