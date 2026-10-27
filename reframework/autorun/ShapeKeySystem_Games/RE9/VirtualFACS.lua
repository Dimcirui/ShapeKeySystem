-- ShapeKeySystem: Virtual 96 RE9 FACS Evaluation Engine
-- Evaluates official PlayerFacialAnimationDriver + _FacialMotion deforms + physical bone solver
-- into a clean, normalized 96-channel Virtual FACS bus (indices 00..95),
-- which is then mapped to arbitrary custom models (e.g. MMD shapekeys).

local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Defs = require("ShapeKeySystem_Games.RE9.Native96Def")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")
local Bones = require("ShapeKeySystem_Games.RE9.Bones")

local VF = {}

-- 96 Definitions and lookup maps
local DEF_LIST = Defs.DEFINITIONS
local NAME_TO_IDX = {}
local SHORT_TO_IDX = {}
local HASH_TO_IDX = {}

for idx = 0, #DEF_LIST do
    local item = DEF_LIST[idx]
    if item then
        NAME_TO_IDX[item.name] = idx
        SHORT_TO_IDX[item.short] = idx
        HASH_TO_IDX[Hash.hash(item.name)] = idx
    end
end

-- Live 96 channel values buffer
local LIVE_VALUES = {}
for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

-- Driver tracking
local cached_driver = nil
local last_driver_check = 0

local function resolve_driver(head)
    local now = os.clock()
    if cached_driver and (now - last_driver_check) < 0.5 then
        return cached_driver
    end
    last_driver_check = now

    -- 1. Direct check on root_go (as shown in EMV cp_A000 components list #79)
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

    -- 2. Traverse via CharacterManager -> PlayerContext -> PlayerUpdaterBase -> ManagedDrivers
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
    -- Reset buffer
    for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

    local driver = resolve_driver(head)
    local cur_vowel = driver and driver:get_field("_CurrentVowel") or 0
    local cur_vol = driver and (driver:get_field("_CurrentVolume") or 0.0) or 0.0
    local is_speaking = (cur_vowel ~= 0 and cur_vol > 0.001)

    -- 1. Read motion deform tracks (from _FacialMotion or motion_context)
    if motion_context then
        for i = 0, #DEF_LIST do
            local item = DEF_LIST[i]
            local val = Motion.deform_value(motion_context, Hash.hash(item.name))
            if type(val) == "number" and val == val then
                -- Subtract baseline offset
                local net = val - (item.baseline or 0.0)
                LIVE_VALUES[i] = math.max(0.0, math.min(1.0, net))
            end
        end
    end

    -- 2. Inject Vowel Phonemes from PlayerFacialAnimationDriver
    -- VowelType: 1=A, 2=I, 3=U, 4=E, 5=O
    local vowel_strength = math.min(1.0, math.max(0.2, cur_vol * 1.5))
    if cur_vowel == 1 then -- Vowel A: Jaw open + Corner pull
        local jw_l = SHORT_TO_IDX["JwOpn_00_L"]
        local jw_r = SHORT_TO_IDX["JwOpn_00_R"]
        if jw_l then LIVE_VALUES[jw_l] = math.max(LIVE_VALUES[jw_l], 0.85 * vowel_strength) end
        if jw_r then LIVE_VALUES[jw_r] = math.max(LIVE_VALUES[jw_r], 0.85 * vowel_strength) end
    elseif cur_vowel == 2 then -- Vowel I: Lip stretch + Lower lip depress
        local str_l = SHORT_TO_IDX["Strtch_04_L"]
        local str_r = SHORT_TO_IDX["Strtch_04_R"]
        if str_l then LIVE_VALUES[str_l] = math.max(LIVE_VALUES[str_l], 0.80 * vowel_strength) end
        if str_r then LIVE_VALUES[str_r] = math.max(LIVE_VALUES[str_r], 0.80 * vowel_strength) end
    elseif cur_vowel == 3 then -- Vowel U: Pucker + Funnel
        local pkr_l = SHORT_TO_IDX["Pkr_01_L"]
        local pkr_r = SHORT_TO_IDX["Pkr_01_R"]
        if pkr_l then LIVE_VALUES[pkr_l] = math.max(LIVE_VALUES[pkr_l], 0.85 * vowel_strength) end
        if pkr_r then LIVE_VALUES[pkr_r] = math.max(LIVE_VALUES[pkr_r], 0.85 * vowel_strength) end
    elseif cur_vowel == 4 then -- Vowel E: Half jaw open + Lip stretch
        local jw_l = SHORT_TO_IDX["JwOpn_00_L"]
        local str_l = SHORT_TO_IDX["Strtch_04_L"]
        if jw_l then LIVE_VALUES[jw_l] = math.max(LIVE_VALUES[jw_l], 0.50 * vowel_strength) end
        if str_l then LIVE_VALUES[str_l] = math.max(LIVE_VALUES[str_l], 0.65 * vowel_strength) end
    elseif cur_vowel == 5 then -- Vowel O: Funnel + Mouth round
        local fnl_l = SHORT_TO_IDX["Fnl_04_L"]
        local fnl_r = SHORT_TO_IDX["Fnl_04_R"]
        if fnl_l then LIVE_VALUES[fnl_l] = math.max(LIVE_VALUES[fnl_l], 0.90 * vowel_strength) end
        if fnl_r then LIVE_VALUES[fnl_r] = math.max(LIVE_VALUES[fnl_r], 0.90 * vowel_strength) end
    end

    -- 3. Bone Fallback & Compensation (when not speaking or deforms are idle)
    -- Jaw bone physical opening:
    if head and not is_speaking then
        local jaw_val = Bones.read(head, "jawOpen")
        if type(jaw_val) == "number" and jaw_val > 0.01 then
            local jw_l = SHORT_TO_IDX["JwOpn_00_L"]
            local jw_r = SHORT_TO_IDX["JwOpn_00_R"]
            if jw_l then LIVE_VALUES[jw_l] = math.max(LIVE_VALUES[jw_l], jaw_val) end
            if jw_r then LIVE_VALUES[jw_r] = math.max(LIVE_VALUES[jw_r], jaw_val) end
        end
    end

    return LIVE_VALUES
end

-- Query functions
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

function VF.get_definitions()
    return DEF_LIST
end

function VF.driver_status()
    local d = cached_driver
    return {
        connected = (d ~= nil),
        current_vowel = d and d:get_field("_CurrentVowel") or 0,
        current_volume = d and (d:get_field("_CurrentVolume") or 0.0) or 0.0
    }
end

return VF
