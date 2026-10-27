-- ShapeKeySystem: Virtual 96 RE9 FACS Evaluation Engine (Dual-Core: Deform + Bone Solver)
-- Solves the live facial state from:
--   1. Official PlayerFacialAnimationDriver (speech vowels A/I/U/E/O and volume)
--   2. _FacialMotion deform curves (active during cutscenes, speech, and major expressions)
--   3. Physical face bones solver (active 24/7 during normal gameplay / idle / running)
-- Both pipelines feed into this unified 96-channel Virtual FACS table (00..95),
-- which is then transparently mapped to the target mesh's actual shapekeys.

local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Defs = require("ShapeKeySystem_Games.RE9.Native96Def")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")

local VF = {}

local DEF_LIST = Defs.DEFINITIONS
local NAME_TO_IDX = {}
local SHORT_TO_IDX = {}

for idx = 0, #DEF_LIST do
    local item = DEF_LIST[idx]
    if item then
        NAME_TO_IDX[item.name] = idx
        SHORT_TO_IDX[item.short] = idx
    end
end

-- Live 96 channel values buffer
local LIVE_VALUES = {}
for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

-- Active state tracking
local cached_driver = nil
local last_driver_check = 0

local function resolve_driver(head)
    local now = os.clock()
    if cached_driver and (now - last_driver_check) < 0.5 then
        return cached_driver
    end
    last_driver_check = now

    if head and head.root then
        local root_go = R.call(head.root, "get_GameObject")
        if root_go then
            local drv = R.component(root_go, sdk.typeof("app.PlayerFacialAnimationDriver"))
                or R.component(root_go, sdk.typeof("app.CharacterFacialAnimationDriver"))
            if drv then
                cached_driver = drv
                return cached_driver
            end
        end
    end

    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and cm:call("getPlayerContextRefFast")
        local updater = pc and pc:get_field("<Updater>k__BackingField")
        if updater then
            local board = updater:call("get_ManagedDrivers")
            if board then
                local drivers = board:get_field("Drivers")
                local count = 0
                if drivers then
                    count = (drivers.get_Length and drivers:get_Length())
                        or (drivers.call and drivers:call("get_Count")) or 0
                end
                for i = 0, count - 1 do
                    local d = drivers[i] or (drivers.call and drivers:call("get_Item", i))
                    if d then
                        local t = d:get_type_definition()
                        local tname = t and t:get_full_name() or ""
                        if tname:find("FacialAnimationDriver") then
                            cached_driver = d
                            return
                        end
                    end
                end
            end
        end
    end)

    return cached_driver
end

-- Evaluate all 96 virtual channels per frame
function VF.evaluate(head, motion_context)
    for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

    local driver = resolve_driver(head)
    local cur_vowel = driver and driver:get_field("_CurrentVowel") or 0
    local cur_vol = driver and (driver:get_field("_CurrentVolume") or 0.0) or 0.0
    local is_speaking = (cur_vowel ~= 0 and cur_vol > 0.001)

    -- 1. Try reading motion deform tracks (if active in current motion clip)
    if motion_context then
        for i = 0, #DEF_LIST do
            local item = DEF_LIST[i]
            local val = Motion.deform_value(motion_context, Hash.hash(item.name))
            if type(val) == "number" and val == val then
                local net = val - (item.baseline or 0.0)
                if net > 0.001 then
                    LIVE_VALUES[i] = math.max(0.0, math.min(1.0, net))
                end
            end
        end
    end

    -- 2. Physical Bone Solvers (always active in gameplay!)
    if head then
        -- A. Jaw bone opening -> JwOpn_00_L/R
        local jaw_bone = Bones.read(head, "jawOpen")
        if type(jaw_bone) == "number" and jaw_bone > 0.005 then
            local idx_l = SHORT_TO_IDX["JwOpn_00_L"]
            local idx_r = SHORT_TO_IDX["JwOpn_00_R"]
            if idx_l then LIVE_VALUES[idx_l] = math.max(LIVE_VALUES[idx_l], jaw_bone) end
            if idx_r then LIVE_VALUES[idx_r] = math.max(LIVE_VALUES[idx_r], jaw_bone) end
        end

        -- B. Eye blink bones (eyelid joints) -> UprLdDn_05_L/R & UprLdDn_00_L/R
        local blink_l = Bones.read(head, "eyeBlinkLeft")
        if type(blink_l) == "number" and blink_l > 0.005 then
            local i5 = SHORT_TO_IDX["UprLdDn_05_L"]
            local i0 = SHORT_TO_IDX["UprLdDn_00_L"]
            if i5 then LIVE_VALUES[i5] = math.max(LIVE_VALUES[i5], blink_l) end
            if i0 then LIVE_VALUES[i0] = math.max(LIVE_VALUES[i0], blink_l) end
        end

        local blink_r = Bones.read(head, "eyeBlinkRight")
        if type(blink_r) == "number" and blink_r > 0.005 then
            local i5 = SHORT_TO_IDX["UprLdDn_05_R"]
            local i0 = SHORT_TO_IDX["UprLdDn_00_R"]
            if i5 then LIVE_VALUES[i5] = math.max(LIVE_VALUES[i5], blink_r) end
            if i0 then LIVE_VALUES[i0] = math.max(LIVE_VALUES[i0], blink_r) end
        end

        -- C. Brow Outer Up -> BrOutRs_00_L/R (上左/上右)
        local brow_up_l = Bones.read(head, "browOuterUpLeft")
        if type(brow_up_l) == "number" and brow_up_l > 0.005 then
            local idx = SHORT_TO_IDX["BrOutRs_00_L"]
            if idx then LIVE_VALUES[idx] = math.max(LIVE_VALUES[idx], brow_up_l) end
        end
        local brow_up_r = Bones.read(head, "browOuterUpRight")
        if type(brow_up_r) == "number" and brow_up_r > 0.005 then
            local idx = SHORT_TO_IDX["BrOutRs_00_R"]
            if idx then LIVE_VALUES[idx] = math.max(LIVE_VALUES[idx], brow_up_r) end
        end

        -- D. Brow Down -> BrLr_00_L/R (下左/下右)
        local brow_dn_l = Bones.read(head, "browDownLeft")
        if type(brow_dn_l) == "number" and brow_dn_l > 0.005 then
            local idx = SHORT_TO_IDX["BrLr_00_L"]
            if idx then LIVE_VALUES[idx] = math.max(LIVE_VALUES[idx], brow_dn_l) end
        end
        local brow_dn_r = Bones.read(head, "browDownRight")
        if type(brow_dn_r) == "number" and brow_dn_r > 0.005 then
            local idx = SHORT_TO_IDX["BrLr_00_R"]
            if idx then LIVE_VALUES[idx] = math.max(LIVE_VALUES[idx], brow_dn_r) end
        end

        -- E. Brow Inner Up / Down (困る / 眉心) -> BrInDn_00 / BrInRs_00
        local brow_in = Bones.read(head, "browInnerUp")
        if type(brow_in) == "number" and brow_in > 0.005 then
            local idx_l = SHORT_TO_IDX["BrInRs_00_L"]
            local idx_r = SHORT_TO_IDX["BrInRs_00_R"]
            if idx_l then LIVE_VALUES[idx_l] = math.max(LIVE_VALUES[idx_l], brow_in) end
            if idx_r then LIVE_VALUES[idx_r] = math.max(LIVE_VALUES[idx_r], brow_in) end
        end
    end

    -- 3. Vowel Injection from PlayerFacialAnimationDriver
    if is_speaking then
        local vowel_strength = math.min(1.0, math.max(0.3, cur_vol * 1.5))
        if cur_vowel == 1 then -- Vowel A: Jaw open
            local jw_l = SHORT_TO_IDX["JwOpn_00_L"]
            local jw_r = SHORT_TO_IDX["JwOpn_00_R"]
            if jw_l then LIVE_VALUES[jw_l] = math.max(LIVE_VALUES[jw_l], 0.85 * vowel_strength) end
            if jw_r then LIVE_VALUES[jw_r] = math.max(LIVE_VALUES[jw_r], 0.85 * vowel_strength) end
        elseif cur_vowel == 2 then -- Vowel I: Stretch
            local str_l = SHORT_TO_IDX["Strtch_04_L"]
            local str_r = SHORT_TO_IDX["Strtch_04_R"]
            if str_l then LIVE_VALUES[str_l] = math.max(LIVE_VALUES[str_l], 0.80 * vowel_strength) end
            if str_r then LIVE_VALUES[str_r] = math.max(LIVE_VALUES[str_r], 0.80 * vowel_strength) end
        elseif cur_vowel == 3 then -- Vowel U: Pucker
            local pkr_l = SHORT_TO_IDX["Pkr_01_L"]
            local pkr_r = SHORT_TO_IDX["Pkr_01_R"]
            if pkr_l then LIVE_VALUES[pkr_l] = math.max(LIVE_VALUES[pkr_l], 0.85 * vowel_strength) end
            if pkr_r then LIVE_VALUES[pkr_r] = math.max(LIVE_VALUES[pkr_r], 0.85 * vowel_strength) end
        elseif cur_vowel == 4 then -- Vowel E: Half jaw + Stretch
            local jw_l = SHORT_TO_IDX["JwOpn_00_L"]
            local str_l = SHORT_TO_IDX["Strtch_04_L"]
            if jw_l then LIVE_VALUES[jw_l] = math.max(LIVE_VALUES[jw_l], 0.50 * vowel_strength) end
            if str_l then LIVE_VALUES[str_l] = math.max(LIVE_VALUES[str_l], 0.65 * vowel_strength) end
        elseif cur_vowel == 5 then -- Vowel O: Funnel
            local fnl_l = SHORT_TO_IDX["Fnl_04_L"]
            local fnl_r = SHORT_TO_IDX["Fnl_04_R"]
            if fnl_l then LIVE_VALUES[fnl_l] = math.max(LIVE_VALUES[fnl_l], 0.90 * vowel_strength) end
            if fnl_r then LIVE_VALUES[fnl_r] = math.max(LIVE_VALUES[fnl_r], 0.90 * vowel_strength) end
        end
    end

    return LIVE_VALUES
end

function VF.get(name_or_idx)
    if type(name_or_idx) == "number" then
        return LIVE_VALUES[name_or_idx] or 0.0
    end
    if type(name_or_idx) == "string" then
        local idx = SHORT_TO_IDX[name_or_idx] or NAME_TO_IDX[name_or_idx]
        if idx then return LIVE_VALUES[idx] or 0.0 end
    end
    return 0.0
end

function VF.get_all()
    return LIVE_VALUES
end

return VF
