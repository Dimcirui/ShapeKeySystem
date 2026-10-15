-- ShapeKeySystem: release the Onimusha menu cursor and hold camera rotation while SKS is open.
-- The native cursor controller borrows menu priority only for its synchronous update;
-- its post hook restores the original value, including when the panel closes during the call.
local I = {}
local MENU_PRIORITY, FIELD_PRIORITY = 15, 11 -- PRIO_14 and PRIO_10

function I.install(is_enabled, failed, forced)
    local live, reported = true, {}
    local function report(text)
        if not reported[text] then reported[text] = true; failed(text) end
    end
    local function hook(type_name, signature, pre, post)
        local ok, err = pcall(function()
            local td = sdk.find_type_definition(type_name)
            local method = td and td:get_method(signature)
            if not method then error("method unavailable") end
            sdk.hook(method, pre, post)
        end)
        if not ok then report(type_name .. "." .. signature .. " " .. tostring(err)) end
    end
    hook("app.GUI090000", "guiLateUpdate()", function()
        if not live or not is_enabled() then return end
        local storage = thread.get_hook_storage()
        local ok, err = pcall(function()
            local gui = sdk.get_managed_singleton("app.GUIManager")
            if not gui then return end
            local priority = gui:get_field("_CurInput")
            local value = tonumber(tostring(priority))
            if not value or value > FIELD_PRIORITY then return end
            local borrow = { gui = gui, priority = priority }
            storage.sks_onimusha_cursor = borrow
            gui:set_field("_CurInput", MENU_PRIORITY)
            borrow.changed = true
            forced()
        end)
        if not ok then report("native cursor: " .. tostring(err)) end
    end, function(retval)
        local borrow = thread.get_hook_storage().sks_onimusha_cursor
        if borrow and borrow.changed then
            local ok, err = pcall(function() borrow.gui:set_field("_CurInput", borrow.priority) end)
            if not ok then report("restore cursor priority: " .. tostring(err)) end
        end
        return retval
    end)
    hook("app.mcCam_GameCameraInputRotate", "checkInputRotationFixed()", nil, function(retval)
        if live and is_enabled() then return sdk.to_ptr(true) end
        return retval
    end)
    re.on_script_reset(function() live = false end)
end

return I
