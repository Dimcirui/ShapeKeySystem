-- ShapeKeySystem panel: MH Wilds' own text input form, for typing Chinese with the Windows IME.
-- REFramework's ImGui gets IME text garbled ("??": the game window is ANSI) and only REFramework's
-- ImGui keeps the IME attached, so the ImGui field can only take ASCII; the game's form gets the IME
-- right. G.open(text, on_done) starts the form flow; the typed text is caught by a hook on the text
-- module's textInputDecided while our request is pending, and G.frame calls on_done(text), or
-- on_done(nil) on cancel (hook, or the flow ending without a result).
-- Measured 2026-10-13: startFormFlow(NAME_EQUIP_SET) only shows the form, it renames nothing.
-- openImeDialog was tried too: it left the game's IME unusable (the chat as well) until a restart.
-- MH Wilds only (G.WILDS); other games keep the plain ImGui field. Lookups run under pcall.

local G = { pending = nil }

-- static binding: reframework.get_game_name(), not reframework:get_game_name()
pcall(function() G.WILDS = reframework.get_game_name() == "mhwilds" end)

local FORM_ID = nil
local hooked = false
local result = nil          -- set by the hooks (game thread), applied by G.frame

local function str_arg(p)
    local ok, s = pcall(function() return sdk.to_managed_object(p):call("ToString()") end)
    return ok and type(s) == "string" and s or nil
end

if G.WILDS then pcall(function()
    FORM_ID = sdk.find_type_definition("app.GUITextInputFormDef.ID"):get_field("NAME_EQUIP_SET"):get_data(nil)
    local t = sdk.find_type_definition("app.cGUISystemModuleTextInput")
    for _, m in ipairs(t:get_methods()) do
        local name = m:get_name()
        -- both textInputDecided overloads run for one decision: the first one wins
        if name == "textInputDecided" then
            sdk.hook(m, function(args)
                if G.pending and result == nil then result = { text = str_arg(args[3]) or "" } end
            end, nil)
            hooked = true
        elseif name == "textInputCanceled" then
            sdk.hook(m, function()
                if G.pending and result == nil then result = { cancel = true } end
            end, nil)
        end
    end
end) end

function G.available() return G.WILDS == true and FORM_ID ~= nil and hooked end
function G.active() return G.pending ~= nil end

local function text_module()
    return sdk.get_managed_singleton("app.GUIManager"):get_field("<TextInput>k__BackingField")
end

-- true when the form opened
function G.open(text, on_done)
    if G.pending or not G.available() then return false end
    local ok, h = pcall(function() return text_module():call("startFormFlow", FORM_ID, text or "", nil) end)
    if not ok or not h then return false end
    pcall(function() h = h:add_ref() end)
    result = nil
    G.pending = { on_done = on_done, handle = h }
    return true
end

-- close the form without a result (panel closed, script reset)
function G.cancel()
    local p = G.pending
    if not p then return end
    G.pending, result = nil, nil
    pcall(function() p.handle:call("terminate") end)
end

-- re.on_frame
function G.frame()
    local p = G.pending
    if not p then return end
    local r = result
    if not r then
        local ok, ended = pcall(function() return p.handle:call("get_IsEnd") end)
        if ok and ended then r = { cancel = true } else return end
    end
    G.pending, result = nil, nil
    pcall(p.on_done, (not r.cancel) and r.text or nil)
end

return G
