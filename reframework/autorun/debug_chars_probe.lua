local executed = false
re.on_frame(function()
    if executed then return end
    executed = true
    local sm = sdk.get_native_singleton("via.SceneManager")
    local st = sdk.find_type_definition("via.SceneManager")
    local scene = sm and st and sdk.call_native_func(sm, st, "get_CurrentScene")
    if not scene then return end

    local f = io.open("F:/SteamLibrary/steamapps/common/RESIDENT EVIL requiem BIOHAZARD requiem/debug_chars_now.txt", "w")
    if not f then return end

    local function sc(o, m, ...) if not o then return nil end local ok, r = pcall(o.call, o, m, ...) return ok and r or nil end

    local function check_char(go, name)
        f:write(string.format("CHAR: %s\n", name))
        f:write(string.format("  Valid: %s, DrawSelf: %s\n", tostring(sc(go, "get_Valid")), tostring(sc(go, "get_DrawSelf"))))
        local tr = sc(go, "get_Transform")
        if tr then
            local pos = sc(tr, "get_Position")
            if pos then f:write(string.format("  Position: (%.2f, %.2f, %.2f)\n", pos.x, pos.y, pos.z)) end
        end
        local motion = sc(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        if motion then
            local layer0 = sc(motion, "getLayer", 0)
            if layer0 then
                f:write(string.format("  Layer0: bank=%s mot=%s frame=%.1f/%.1f speed=%.2f\n",
                    tostring(sc(layer0, "get_MotionBankID")),
                    tostring(sc(layer0, "get_MotionID")),
                    sc(layer0, "get_Frame") or 0,
                    sc(layer0, "get_EndFrame") or 0,
                    sc(layer0, "get_PlaySpeed") or 0))
            end
        end
    end

    local p_go = sc(scene, "findGameObject(System.String)", "cp_A000")
    if p_go then check_char(p_go, "cp_A000 (via findGameObject)") end

    local cur = sc(scene, "get_FirstTransform")
    local function walk(tr, d)
        if not tr or d > 100 then return end
        local go = sc(tr, "get_GameObject")
        if go then
            local name = tostring(sc(go, "get_Name") or "")
            local lower = name:lower()
            if lower:find("ch0100") or lower:find("cp_a000") then
                check_char(go, name)
            end
        end
        local c = sc(tr, "get_Child")
        if c then walk(c, d + 1) end
        local n = sc(tr, "get_Next")
        if n then walk(n, d) end
    end
    walk(cur, 0)
    f:close()
end)
