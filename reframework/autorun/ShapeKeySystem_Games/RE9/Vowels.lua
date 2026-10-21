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

-- Native PlayerFacialAnimationDriver + FACS mouth deforms reader
function M.read_driver(head, motion_context)
    if not head or not head.root then return nil end
    local root_go = R.call(head.root, 'get_GameObject')
    if not root_go then return nil end
    local driver = R.component(root_go, sdk.typeof('app.PlayerFacialAnimationDriver'))
    if not driver then return nil end
    
    local cur_vowel = driver:get_field('_CurrentVowel')
    local cur_vol = driver:get_field('_CurrentVolume') or 0.0
    
    local jw = motion_context and Motion.deform_value(motion_context, Hash.hash('HeadSkinned_blendShape.JwOpn_00_L')) or 0.0
    local crn = motion_context and Motion.deform_value(motion_context, Hash.hash('HeadSkinned_blendShape.CrnPl_01_L')) or 0.0
    local pkr = motion_context and Motion.deform_value(motion_context, Hash.hash('HeadSkinned_blendShape.Pkr_01_L')) or 0.0
    local fnl = motion_context and Motion.deform_value(motion_context, Hash.hash('HeadSkinned_blendShape.Fnl_04_L')) or 0.0
    local upr = motion_context and Motion.deform_value(motion_context, Hash.hash('HeadSkinned_blendShape.UprLpRs_01_L')) or 0.0
    
    local weights = {0, 0, 0, 0, 0}
    local vstr = tostring(cur_vowel or '')
    local vnum = tonumber(cur_vowel) or 0
    
    local vol = math.max(cur_vol or 0, jw or 0)
    if vstr:find('A') or vnum == 1 then
        weights[1] = math.max(0.15, vol)
    elseif vstr:find('I') or vnum == 2 then
        weights[2] = math.max(0.15, math.max(vol, crn or 0))
    elseif vstr:find('U') or vnum == 3 then
        weights[3] = math.max(0.15, math.max(vol, pkr or 0))
    elseif vstr:find('E') or vnum == 4 then
        weights[4] = math.max(0.15, math.max(vol, upr or 0))
    elseif vstr:find('O') or vnum == 5 then
        weights[5] = math.max(0.15, math.max(vol, fnl or 0))
    else
        if jw and jw > 0.05 then
            weights[1] = jw
        end
    end
    return weights, 'ok', {}, 'driver'
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
