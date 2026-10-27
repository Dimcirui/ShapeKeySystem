-- RE9 native A/I/U/E/O pose basis, projected from the current facial bones or native facial driver.
local R=require('ShapeKeySystem_Games.RE9.Runtime')
local Hash=require('ShapeKeySystem_Core.NameHash')
local Motion=require('ShapeKeySystem_Games.RE9.Motion')
local Bones=require('ShapeKeySystem_Games.RE9.Bones')
local M={}
local config
local finite=require('ShapeKeySystem_Core.BoneSignals').finite
function M.validate(data)
    if data==nil then return true end
    if type(data)~='table'or type(data.features)~='table'or #data.features<1 or #data.features>16
        or type(data.matrix)~='table'or #data.matrix~=#data.features
        or type(data.scales)~='table'or #data.scales~=#data.features
        or type(data.solvers)~='table'or #data.solvers~=31 then return false,'RE9 口型基形无效'end
    for i,feature in ipairs(data.features)do
        if not Bones.validate({jawOpen={lo=0,hi=1,terms=feature}})or not finite(data.scales[i])or data.scales[i]<=0
            or type(data.matrix[i])~='table'or #data.matrix[i]~=5 then return false,'RE9 口型基形来源无效'end
        for _,v in ipairs(data.matrix[i])do if not finite(v)then return false,'RE9 口型基形数值无效'end end
    end
    for j=1,5 do
        local norm=0;for _,row in ipairs(data.matrix)do norm=norm+row[j]^2 end
        if norm<1e-6 then return false,'RE9 口型基形退化'end
    end
    local seen={}
    for _,solver in ipairs(data.solvers)do
        if type(solver)~='table'or type(solver.ids)~='table'or #solver.ids<1 or #solver.ids>5
            or type(solver.inverse)~='table'or #solver.inverse~=#solver.ids then return false,'RE9 口型求解器无效'end
        local mask,previous=0,0
        for i,id in ipairs(solver.ids)do
            if not finite(id)or id%1~=0 or id<=previous or id>5 then return false,'RE9 口型求解器索引无效'end
            previous=id;mask=mask+2^(id-1)
            if type(solver.inverse[i])~='table'or #solver.inverse[i]~=#data.features then return false,'RE9 口型求解器尺寸无效'end
            for _,v in ipairs(solver.inverse[i])do if not finite(v)then return false,'RE9 口型求解器数值无效'end end
        end
        if seen[mask]then return false,'RE9 口型求解器重复'end;seen[mask]=true
    end
    return true
end
function M.configure(data)
    local ok,why=M.validate(data)
    if not ok then return false,why end
    config=data;return true
end
function M.configured()return config~=nil end

-- Pre-hashed RE9 facial deformation tracks
local H_CRN_LWR_L = Hash.hash('HeadSkinned_blendShape.CrnPl_LwrLpDprs_L')
local H_CRN_LWR_R = Hash.hash('HeadSkinned_blendShape.CrnPl_LwrLpDprs_R')
local H_STR_CRN_L = Hash.hash('HeadSkinned_blendShape.Strtch_CrnPl_L')
local H_STR_CRN_R = Hash.hash('HeadSkinned_blendShape.Strtch_CrnPl_R')
local H_CRN04_L   = Hash.hash('HeadSkinned_blendShape.CrnPl_04_L')
local H_CRN04_R   = Hash.hash('HeadSkinned_blendShape.CrnPl_04_R')
local H_CRN05_L   = Hash.hash('HeadSkinned_blendShape.CrnPl_05_L')
local H_CRN05_R   = Hash.hash('HeadSkinned_blendShape.CrnPl_05_R')

local H_PKR_FNL_TL = Hash.hash('HeadSkinned_blendShape.Pkr_Fnl_TL')
local H_PKR_FNL_TR = Hash.hash('HeadSkinned_blendShape.Pkr_Fnl_TR')
local H_PKR_FNL_BL = Hash.hash('HeadSkinned_blendShape.Pkr_Fnl_BL')
local H_PKR_FNL_BR = Hash.hash('HeadSkinned_blendShape.Pkr_Fnl_BR')
local H_PKR03_L    = Hash.hash('HeadSkinned_blendShape.Pkr_03_L')
local H_PKR03_R    = Hash.hash('HeadSkinned_blendShape.Pkr_03_R')
local H_PKR01_L    = Hash.hash('HeadSkinned_blendShape.Pkr_01_L')
local H_PKR01_R    = Hash.hash('HeadSkinned_blendShape.Pkr_01_R')

local H_FNL04_L    = Hash.hash('HeadSkinned_blendShape.Fnl_04_L')
local H_FNL04_R    = Hash.hash('HeadSkinned_blendShape.Fnl_04_R')

local H_UPR05_L    = Hash.hash('HeadSkinned_blendShape.UprLpRs_05_L')
local H_UPR05_R    = Hash.hash('HeadSkinned_blendShape.UprLpRs_05_R')
local H_UPR01_L    = Hash.hash('HeadSkinned_blendShape.UprLpRs_01_L')
local H_UPR01_R    = Hash.hash('HeadSkinned_blendShape.UprLpRs_01_R')

local H_JW_SP_CRN_L = Hash.hash('HeadSkinned_blendShape.CrnPl_JwOpn_L')
local H_JW_SP_CRN_R = Hash.hash('HeadSkinned_blendShape.CrnPl_JwOpn_R')
local H_JW_SP_STR_L = Hash.hash('HeadSkinned_blendShape.Strtch_JwOpn_L')
local H_JW_SP_STR_R = Hash.hash('HeadSkinned_blendShape.Strtch_JwOpn_R')

-- Native PlayerFacialAnimationDriver + FACS mouth deforms reader
local cached_driver = nil
local last_driver_check = 0

local function get_facial_driver(head)
    local now = os.clock()
    if cached_driver and (now - last_driver_check) < 0.5 then
        return cached_driver
    end
    last_driver_check = now

    -- 1. Try resolving via CharacterManager -> PlayerContext -> PlayerUpdaterBase -> ManagedDrivers
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and cm:call("getPlayerContextRefFast")
        local updater = pc and pc:get_field("<Updater>k__BackingField")
        if updater then
            local board = updater:call("get_ManagedDrivers")
            if board then
                local drivers = board:get_field("Drivers")
                local count = drivers and drivers:call("get_Count") or 0
                for i = 0, count - 1 do
                    local d = drivers:call("get_Item", i)
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
    if cached_driver then return cached_driver end

    -- 2. Fallback: check root_go / face_go components
    if head then
        for _, obj in ipairs({head.root, head.face}) do
            if obj then
                local go = R.call(obj, 'get_GameObject')
                local drv_t = sdk.typeof('app.PlayerFacialAnimationDriver') or sdk.typeof('app.CharacterFacialAnimationDriver')
                local comp = drv_t and go and R.component(go, drv_t)
                if comp then
                    cached_driver = comp
                    return cached_driver
                end
            end
        end
    end
    cached_driver = nil
    return nil
end

function M.read_driver(head, motion_context)
    if not head then return nil end
    local driver = get_facial_driver(head)

    local cur_vowel = driver and driver:get_field('_CurrentVowel')
    local cur_vol = driver and (driver:get_field('_CurrentVolume') or 0.0) or 0.0

    local get_df = function(h)
        return motion_context and Motion.deform_value(motion_context, h) or 0.0
    end

    -- 1. I vowel: Corner pull + Lower lip depress / Stretch
    local crn_lwr = math.max(get_df(H_CRN_LWR_L), get_df(H_CRN_LWR_R))
    local str_crn = math.max(get_df(H_STR_CRN_L), get_df(H_STR_CRN_R))
    local crn04   = math.max(get_df(H_CRN04_L), get_df(H_CRN04_R))
    local crn05   = math.max(get_df(H_CRN05_L), get_df(H_CRN05_R))
    local v_i = math.max(crn_lwr, str_crn, crn04, crn05)

    -- 2. U vowel: Pucker + Funnel combination / Pucker 03 / Pucker 01
    local pkr_fnl = math.max(get_df(H_PKR_FNL_TL), get_df(H_PKR_FNL_TR), get_df(H_PKR_FNL_BL), get_df(H_PKR_FNL_BR))
    local pkr03   = math.max(get_df(H_PKR03_L), get_df(H_PKR03_R))
    local pkr01   = math.max(get_df(H_PKR01_L), get_df(H_PKR01_R))
    local v_u = math.max(pkr_fnl, pkr03, pkr01)

    -- 3. O vowel: Funnel 04
    local fnl04 = math.max(get_df(H_FNL04_L), get_df(H_FNL04_R))
    local v_o = fnl04

    -- 4. E vowel: Upper lip raise 05 / 01
    local upr05 = math.max(get_df(H_UPR05_L), get_df(H_UPR05_R))
    local upr01 = math.max(get_df(H_UPR01_L), get_df(H_UPR01_R))
    local v_e = math.max(upr05, upr01)

    -- 5. A vowel: Speech-coupled open mouth (CrnPl_JwOpn / Strtch_JwOpn)
    local jw_sp_crn = math.max(get_df(H_JW_SP_CRN_L), get_df(H_JW_SP_CRN_R))
    local jw_sp_str = math.max(get_df(H_JW_SP_STR_L), get_df(H_JW_SP_STR_R))
    local speech_a = math.max(jw_sp_crn, jw_sp_str)

    local weights = {0, 0, 0, 0, 0}
    local vstr = tostring(cur_vowel or '')
    local vnum = tonumber(cur_vowel) or 0
    local has_driver_vowel = false
    local vol = (cur_vol and cur_vol > 0.05) and cur_vol or 0.35

    if vstr:find('A') or vnum == 1 then
        weights[1] = math.max(vol, speech_a); has_driver_vowel = true
    elseif vstr:find('I') or vnum == 2 then
        weights[2] = math.max(vol, v_i); has_driver_vowel = true
    elseif vstr:find('U') or vnum == 3 then
        weights[3] = math.max(vol, v_u); has_driver_vowel = true
    elseif vstr:find('E') or vnum == 4 then
        weights[4] = math.max(vol, v_e); has_driver_vowel = true
    elseif vstr:find('O') or vnum == 5 then
        weights[5] = math.max(vol, v_o); has_driver_vowel = true
    end

    if not has_driver_vowel then
        local any_deform = false
        if v_i > 0.05 then weights[2] = v_i; any_deform = true end
        if v_u > 0.05 then weights[3] = v_u; any_deform = true end
        if v_e > 0.05 then weights[4] = v_e; any_deform = true end
        if v_o > 0.05 then weights[5] = v_o; any_deform = true end

        local other_vowels = math.max(weights[2], weights[3], weights[4], weights[5])
        local a_val = math.max(0, speech_a - other_vowels * 0.8)
        if a_val > 0.05 then
            weights[1] = a_val
            any_deform = true
        end

        -- If neither voice driver nor deform curves are active, return nil to allow bone solver to run!
        if not any_deform then
            return nil
        end
    end
    return weights, 'ok', {}, has_driver_vowel and 'driver' or 'deform'
end

function M.read(head,diagnostic,fallback,omitted,frame,motion_context)
    frame=frame or{}
    if frame.__vowels then return table.unpack(frame.__vowels,1,4)end
    
    -- Try native driver first
    local dweights, dstate, djoints, dsource = M.read_driver(head, motion_context)
    if dweights then
        frame.__vowels = {dweights, dstate, djoints, dsource}
        return dweights, dstate, djoints, dsource
    end
    
    if not config then return nil,'not_configured'end
    local y,joints,source={},{},'bones'
    for i,terms in ipairs(config.features)do
        local _,v,state,poses,used=Bones.evaluate(head,{lo=0,hi=1,terms=terms},diagnostic,fallback,omitted,frame)
        if not finite(v)then return nil,state end
        y[i]=v/config.scales[i]
        if used=='motion'then source='motion'end
        for name,pose in pairs(poses or{})do joints[name]=pose end
    end
    local weights,best={0,0,0,0,0},0
    for _,v in ipairs(y)do best=best+v*v end
    -- Enumerate the 31 active sets of five basis shapes. Unlike a short iterative fit,
    -- this recovers the authored O pose without confusing it with a blend of A and U.
    for _,solver in ipairs(config.solvers)do
        local w,valid={0,0,0,0,0},true
        for i,id in ipairs(solver.ids)do
            local value=0
            for f,c in ipairs(solver.inverse[i])do value=value+c*y[f]end
            if value< -1e-6 then valid=false;break end
            w[id]=math.max(0,value)
        end
        if valid then
            local error=0
            for i,value in ipairs(y)do
                local p=0;for j=1,5 do p=p+config.matrix[i][j]*w[j]end
                error=error+(value-p)^2
            end
            if error<best then best,weights=error,w end
        end
    end
    local total=0;for _,v in ipairs(weights)do total=total+v end
    if total>1 then for i=1,5 do weights[i]=weights[i]/total end end
    frame.__vowels={weights,'ok',joints,source}
    return weights,'ok',joints,source
end
return M
