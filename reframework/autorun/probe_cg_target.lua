local ran = false
re.on_frame(function()
    if ran then return end
    ran = true
    local sm = sdk.get_native_singleton("via.SceneManager")
    local st = sdk.find_type_definition("via.SceneManager")
    local scene = sm and st and sdk.call_native_func(sm, st, "get_CurrentScene")
    if not scene then return end

    local f = io.open("probe_cg_target.txt", "w")
    if not f then return end

    local function log(msg) f:write(tostring(msg) .. "\n") end

    local p_go = scene:call("findGameObject(System.String)", "cp_A000")
    log("cp_A000 found: " .. tostring(p_go ~= nil))
    if p_go then
        log("  Valid: " .. tostring(p_go:call("get_Valid")))
        log("  DrawSelf: " .. tostring(p_go:call("get_DrawSelf")))
        local tr = p_go:call("get_Transform")
        log("  Transform: " .. tostring(tr ~= nil))
        if tr then
            local rhand = tr:call("getJointByName", "R_Arm_Hand")
            log("  R_Arm_Hand on root tr: " .. tostring(rhand ~= nil))
        end
        local motion = p_go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        log("  Motion on cp_A000: " .. tostring(motion ~= nil))
        if motion then
            local layer0 = motion:call("getLayer", 0)
            if layer0 then
                log("  layer0 bank: " .. tostring(layer0:call("get_MotionBankID")) .. " mot: " .. tostring(layer0:call("get_MotionID")))
            end
        end
    end

    f:close()
end)
