-- ShapeKeySystem: Virtual 96 RE9 FACS Evaluation Engine (Bulletproof)
-- Safely extracts official PlayerFacialAnimationDriver + _FacialMotion deforms
-- into a normalized 96-channel Virtual FACS table (00..95).

local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Defs = require("ShapeKeySystem_Games.RE9.Native96Def")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")

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

-- Driver tracking
local cached_driver = nil
local last_driver_check = 0

local function resolve_driver(head)
    local now = os.clock()
    if cached_driver and (now - last_driver_check) < 0.5 then
        return cached_driver
    end
    last_driver_check = now

    pcall(function()
        if head and head.root then
            local root_go = R.call(head.root, "get_GameObject")
            if root_go then
                local drv = R.component(root_go, sdk.typeof("app.PlayerFacialAnimationDriver"))
                    or R.component(root_go, sdk.typeof("app.CharacterFacialAnimationDriver"))
                if drv then
                    cached_driver = drv
                    return
                end
            end
        end

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

-- Safely evaluate all 96 virtual channels per frame
function VF.evaluate(head, motion_context)
    for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

    pcall(function()
        -- 1. Resolve Deform Values buffer (dvals)
        local dvals = nil
        if motion_context and motion_context.deform_values then
            dvals = motion_context.deform_values
        elseif motion_context and (motion_context.deform_motion or motion_context.motion) then
            local dm = motion_context.deform_motion or motion_context.motion
            dvals = R.call(dm, "get_DeformValues")
        elseif head then
            local face_go = head.face and R.call(head.face, 'get_GameObject')
            local root_go = head.root and R.call(head.root, 'get_GameObject')
            local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
            local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))
            local dm = fm or rm
            if dm then dvals = R.call(dm, "get_DeformValues") end
        end

        local dlen = dvals and (R.call(dvals, "get_Length") or R.call(dvals, "get_Count")) or 0

        -- 2. Read all 96 motion deform tracks
        for i = 0, #DEF_LIST do
            local item = DEF_LIST[i]
            local val = nil
            if dvals and i < dlen then
                val = R.call(dvals, "get_Item", i)
            elseif motion_context then
                val = Motion.deform_by_index(motion_context, i)
                if val == nil then
                    val = Motion.deform_value(motion_context, Hash.hash(item.name))
                end
            end

            if type(val) == "number" and val == val then
                local net = val - (item.baseline or 0.0)
                if net > 0.001 then
                    LIVE_VALUES[i] = math.max(0.0, math.min(1.0, net))
                end
            end
        end

        -- 2. Inject Vowel Phonemes from PlayerFacialAnimationDriver
        local driver = resolve_driver(head)
        local cur_vowel = driver and driver:get_field("_CurrentVowel") or 0
        local cur_vol = driver and (driver:get_field("_CurrentVolume") or 0.0) or 0.0

        if cur_vowel ~= 0 and cur_vol > 0.001 then
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
    end)

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
