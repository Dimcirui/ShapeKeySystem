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
-- 全量 285 根骨骼全覆盖主动操控/形态键驱动探测系统 (Full 285 Bones Active Probe)
-- 严格从第 1 根到第 285 根逐一强行位移(30mm)与旋转(30度)，无任何漏项与跳过
-- =========================================================================

local probe_active = false
local probe_bone_index = 1
local probe_phase = 0 -- 0: idle, 1: baseline, 2: manipulate & verify, 3: restore
local probe_frame_in_phase = 0
local freeze_face_anim = true -- 测试期间自动断开/冻结面部表情动画，排除一切动作干扰

local probe_results = {}
local probe_baseline_weights = {}
local probe_status_msg = "待命 (点击下方按钮立即开始 285 根全量测试)"
local probe_last_test_summary = nil

local saved_motion_states = {}

local function freeze_facial_animation(head)
    saved_motion_states = {}
    if not head or not head.face then return end
    local face_go = R.call(head.face, 'get_GameObject')
    if not face_go then return end
    
    local fm = R.component(face_go, sdk.typeof('via.motion.Motion'))
    if fm then
        local orig_enabled = R.call(fm, "get_Enabled")
        saved_motion_states.fm = fm
        saved_motion_states.orig_enabled = (orig_enabled ~= false)
        
        -- Store layer speeds and zero them
        local layer_count = R.call(fm, "getLayerCount") or 0
        saved_motion_states.layers = {}
        for i = 0, layer_count - 1 do
            local layer = R.call(fm, "getLayer(System.UInt32)", i)
            if layer then
                local spd = R.call(layer, "get_Speed")
                table.insert(saved_motion_states.layers, { layer = layer, speed = spd })
                pcall(layer.call, layer, "set_Speed", 0.0)
            end
        end
        
        pcall(fm.call, fm, "set_Enabled", false)
    end
end

local function restore_facial_animation()
    if saved_motion_states.fm then
        pcall(saved_motion_states.fm.call, saved_motion_states.fm, "set_Enabled", saved_motion_states.orig_enabled)
        if saved_motion_states.layers then
            for _, linfo in ipairs(saved_motion_states.layers) do
                pcall(linfo.layer.call, linfo.layer, "set_Speed", linfo.speed or 1.0)
            end
        end
    end
    saved_motion_states = {}
end

local function start_full_285_probe()
    local head = R.find()
    if freeze_face_anim and head then
        freeze_facial_animation(head)
    end
    probe_active = true
    probe_bone_index = 1
    probe_phase = 1
    probe_frame_in_phase = 0
    probe_results = {}
    probe_baseline_weights = {}
    probe_status_msg = "全量 285 根骨骼探测已启动 (面部表情动画已断开)..."
    probe_last_test_summary = nil
end

local function finish_probe_test()
    probe_active = false
    probe_phase = 0
    restore_facial_animation()
    
    local responsive_count = 0
    for _, res in ipairs(probe_results) do
        if #res.affected_shapekeys > 0 then
            responsive_count = responsive_count + 1
        end
    end
    
    probe_status_msg = string.format("探测完成! 285 根骨骼全部实测完毕，响应驱动 %d 根 (表情动画已恢复)。", responsive_count)
    
    probe_last_test_summary = {
        total_bones_tested = #probe_results,
        responsive_bones_count = responsive_count,
        facial_animation_frozen = freeze_face_anim,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        details = probe_results
    }
    
    json.dump_file("ShapeKeySystem/active_bone_probe_results.json", probe_last_test_summary, 2)
end
re.on_application_entry("UpdateMotion", function()
    if not probe_active or probe_phase ~= 2 then return end
    local head = R.find()
    if not head or not head.face then return end
    
    local bname = ALL_285_BONES[probe_bone_index]
    if not bname then return end
    
    local j = R.call(head.face, "getJointByName(System.String)", bname)
    if not j and head.root then
        j = R.call(head.root, "getJointByName(System.String)", bname)
    end
    if not j then return end
    
    local bpos = R.call(j, "get_BaseLocalPosition")
    local brot = R.call(j, "get_BaseLocalRotation")
    
    if bpos then
        -- 30mm 多向复合位移 (X+20mm, Y-30mm, Z+20mm) 极大化激活潜在传感器
        local np = Vector3f.new(bpos.x + 0.020, bpos.y - 0.030, bpos.z + 0.020)
        pcall(j.call, j, "set_LocalPosition", np)
    end
    if brot then
        -- 30度复合俯仰/滚转旋转
        local q = Quaternion.new(0.259, 0.100, 0, 0.960)
        pcall(j.call, j, "set_LocalRotation", q)
    end
end)

-- Hook into LateUpdateBehavior: check all 96 shapekeys on Mesh
re.on_application_entry("LateUpdateBehavior", function()
    if not probe_active then return end
    local head = R.find()
    if not head or not head.face then return end
    local mesh = head.mesh or R.mesh(head.face)
    local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
    
    if probe_bone_index > #ALL_285_BONES then
        finish_probe_test()
        return
    end
    
    local bname = ALL_285_BONES[probe_bone_index]
    probe_frame_in_phase = probe_frame_in_phase + 1
    
    -- Phase 1: Baseline sampling (2 frames)
    if probe_phase == 1 then
        probe_status_msg = string.format("[%d/285] 采样基准: %s (进度: %.1f%%)",
            probe_bone_index, bname, (probe_bone_index / #ALL_285_BONES) * 100)
        if probe_frame_in_phase >= 2 then
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
    -- Phase 2: Manipulation & Verification (2 frames)
    elseif probe_phase == 2 then
        probe_status_msg = string.format("[%d/285] 强行位移旋转中: %s -> 监测 96 形态键响应",
            probe_bone_index, bname)
        if probe_frame_in_phase >= 2 then
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
                bone_index = probe_bone_index,
                bone_name = bname,
                manipulation = "复合位移(X+20mm, Y-30mm, Z+20mm) + 旋转30度",
                affected_shapekeys = affected,
                response_status = (#affected > 0) and "RESPONSIVE" or "NO_REACTION"
            })
            
            -- Phase 3: Restore bone
            probe_phase = 3
            probe_frame_in_phase = 0
            local j = R.call(head.face, "getJointByName(System.String)", bname)
            if not j and head.root then
                j = R.call(head.root, "getJointByName(System.String)", bname)
            end
            if j then
                local bpos = R.call(j, "get_BaseLocalPosition")
                local brot = R.call(j, "get_BaseLocalRotation")
                if bpos then pcall(j.call, j, "set_LocalPosition", bpos) end
                if brot then pcall(j.call, j, "set_LocalRotation", brot) end
            end
        end
    -- Phase 3: Cooldown/Next bone (1 frame)
    elseif probe_phase == 3 then
        if probe_frame_in_phase >= 1 then
            probe_bone_index = probe_bone_index + 1
            if probe_bone_index > #ALL_285_BONES then
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
        imgui.spacing()
        local head = R.find()
        if head then
            local mesh = head.mesh or R.mesh(head.face)
            local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
            imgui.text_colored(string.format("网格状态: [已连接] 头部网格 (通道数: %d | 骨骼总库: %d 根已全部挂载)", cn, #ALL_285_BONES), 0xFF00FF00)
        else
            imgui.text_colored("网格状态: [未连接] 正在寻找头部网格 (cp_A000)...", 0xFF5555FF)
        end
        imgui.spacing()

        -- =========================================================================
        -- 全量 285 根骨骼主动驱动探测控制区
        -- =========================================================================
        imgui.separator()
        imgui.text_colored("【实验】全量 285 根骨骼全覆盖主动操控 / 形态键响应探测器", 0xFF00FFFF)
        imgui.text_colored("规则: 严格从第 1 根到第 285 根逐一强行位移(-30mm)与旋转(30度)，实测96个形态键是否有任何反应。", 0xFFAAAAAA)
        local changed_freeze, new_freeze = imgui.checkbox("测试期间自动冻结/断开脸部表情动画 (消除眨眼/说话干扰)", freeze_face_anim)
        if changed_freeze then freeze_face_anim = new_freeze end
        imgui.spacing()

        if not probe_active then
            if imgui.button("开始全量 285 根骨骼全覆盖主动探测 (1 ~ 285 无遗漏)", 460, 36) then
                start_full_285_probe()
            end
        else
            imgui.text_colored(">>> 正在进行 285 根全量测试: " .. probe_status_msg, 0xFF00FF00)
            if imgui.button("中断测试 (Cancel)", 150, 30) then
                probe_active = false
                probe_phase = 0
                restore_facial_animation()
                probe_status_msg = "测试已中断 (面部表情动画已恢复)"
            end
        end

        imgui.text_colored("探测状态: " .. probe_status_msg, 0xFFCCCCCC)

        if probe_last_test_summary then
            imgui.spacing()
            local sum = probe_last_test_summary
            if sum.responsive_bones_count > 0 then
                imgui.text_colored(string.format(">>> 探测实测发现! 共有 %d 根骨骼的主动操控成功驱动了形态键！", sum.responsive_bones_count), 0xFF00FF00)
            else
                imgui.text_colored(">>> 实验确凿结论: 全量 285 根骨骼逐一强制位移与旋转后，网格全部 96 个形态键变动量均为 0.000 (无任何驱动骨响应)。", 0xFF8888FF)
            end

            if imgui.tree_node(string.format("查看全量 285 根骨骼实测明细表 (%d 条记录)", #sum.details)) then
                for _, d in ipairs(sum.details) do
                    if #d.affected_shapekeys > 0 then
                        imgui.text_colored(string.format("[驱动成功] #%03d %-20s | 驱动形态键数量: %d", d.bone_index, d.bone_name, #d.affected_shapekeys), 0xFF00FF00)
                        for _, aff in ipairs(d.affected_shapekeys) do
                            imgui.text_colored(string.format("    -> [%02d] %-16s (底噪: %.3f, 当前: %.3f, 变动: +%.3f)", aff.index, aff.name, aff.base_weight, aff.current_weight, aff.delta), 0xFF00FF00)
                        end
                    else
                        imgui.text_colored(string.format("[无响应]   #%03d %-20s -> 96个形态键全为 0.000", d.bone_index, d.bone_name), 0xFF777777)
                    end
                end
                imgui.tree_pop()
            end
        end
        imgui.separator()
        imgui.spacing()

        -- 录制数据控制区
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
        imgui.text(string.format("录制状态: %s | 耗时: %.1f 秒 / %d 秒 | 帧数: %d 帧",
            is_recording and "录制中 (RECORDING)" or "待命 (IDLE)",
            elapsed, auto_stop_seconds, record_frame_count))

        imgui.spacing()
        imgui.separator()

        -- Search / Filter
        local changed_f, new_f = imgui.input_text("过滤形态键 (名称 / 描述)", filter_text)
        if changed_f then filter_text = new_f end

        local changed_sort, new_sort = imgui.checkbox("按常态底噪排序 (高活跃优先)", sort_by_baseline)
        if changed_sort then sort_by_baseline = new_sort end
        imgui.same_line()
        local changed_hide, new_hide = imgui.checkbox("隐藏零底噪项 (0.000)", hide_zero_baseline)
        if changed_hide then hide_zero_baseline = new_hide end

        -- Build display list
        local display_list = {}
        for i = 0, 95 do
            local s = stats[i]
            local show = true
            if hide_zero_baseline and s.min < 0.001 and s.max < 0.001 then
                show = false
            end
            if filter_text ~= "" then
                local text_lower = string.lower(filter_text)
                local name_lower = string.lower(s.name)
                local desc_lower = string.lower(s.desc)
                if not string.find(name_lower, text_lower) and not string.find(desc_lower, text_lower) then
                    show = false
                end
            end
            if show then
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

            local color = 0xFFFFFFFF
            if s.min >= 0.40 then
                color = 0xFF5555FF
            elseif is_high then
                color = 0xFF00AAFF
            elseif s.min >= 0.001 or s.max >= 0.001 or s.current >= 0.001 then
                color = 0xFF00FFFF
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
