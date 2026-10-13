-- ShapeKeySystem panel: native text input (Windows IME) through ArmorVariantManager's UI DLL.
--
-- Adapted from ArmorVariantManager (ArmorVariantManager_UI/Service/NativeTextInput.lua and
-- BridgeRuntime.lua, https://github.com/Monkeysama/ArmorVariantManager):
--   MIT License, Copyright (c) 2026 MK
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
--   and associated documentation files (the "Software"), to deal in the Software without
--   restriction, including without limitation the rights to use, copy, modify, merge, publish,
--   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions: The above copyright
--   notice and this permission notice shall be included in all copies or substantial portions of
--   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
--   PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
--   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
--   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.
--
-- The DLL (reframework/plugins/ArmorVariantManager_UI.dll, shipped by AVM and, with the author's
-- consent, by SKS at the same path so only one copy exists) serves several clients: each registers
-- its own runtime folder (avm_bridge.register_runtime), writes D2DTextInputRequest.json there
-- (active, field rect in screen px, text) and reads D2DTextInputResult.json back (text, IME
-- composition, caret, focused). The field that was activated last owns the IME: activations bump
-- AVM's shared counter _G.__AVM_UI_TEXT_FOCUS_SEQUENCE. Without the DLL, N.available() is false.
-- MH Wilds only (the author's condition for reusing the DLL; it also crashes Rise at load).

local N = {}

local CLIENT_ID = "ShapeKeySystem"
local DIR = "ShapeKeySystem/Runtime"           -- under reframework/data (player data, not deployed)
local REQUEST = DIR .. "/D2DTextInputRequest.json"
local RESULT = DIR .. "/D2DTextInputResult.json"

local registered = false

-- static binding: reframework.get_game_name(), not reframework:get_game_name()
local GAME = nil
pcall(function() GAME = reframework.get_game_name() end)
N.WILDS = GAME == "mhwilds"
local st = {
    id = nil, session = 0, token = nil, text = "", composition = "", caret_start = nil, caret_end = nil,
    focused = false, last_sequence = 0, last_signature = nil, focus_sequence = 0,
    prefix = string.format("%d_%d", os.time(), math.floor(os.clock() * 1000000)),
}

local function bridge()
    local b = rawget(_G, "avm_bridge")
    if type(b) ~= "table" and type(b) ~= "userdata" then
        local d = rawget(_G, "d2d")
        b = d and d.bridge
    end
    return b
end

function N.available()
    if not N.WILDS then return false end
    local ok, b = pcall(bridge)
    if not ok or not b then return false end
    if registered then return true end
    local ok2, r = pcall(function() return b.register_runtime and b.register_runtime(CLIENT_ID, DIR) end)
    registered = ok2 and r == true
    return registered
end

local function write_request(active, rect)
    local req = { active = active == true }
    if req.active then
        req.session = st.session
        req.focus_sequence = st.focus_sequence
        req.id = st.id
        req.token = st.token
        req.text = st.text or ""
        req.x = math.floor((rect and rect.x or 0) + 0.5)
        req.y = math.floor((rect and rect.y or 0) + 0.5)
        req.width = math.max(1, math.floor((rect and rect.w or 1) + 0.5))
        req.height = math.max(1, math.floor((rect and rect.h or 28) + 0.5))
    end
    pcall(json.dump_file, REQUEST, req)
end

-- rect: screen px { x, y, w, h }. A new id, or reset, starts a new session and takes the IME focus.
function N.activate(id, text, rect, reset)
    if reset or st.id ~= id then
        st.session = st.session + 1
        local seq = (rawget(_G, "__AVM_UI_TEXT_FOCUS_SEQUENCE") or 0) + 1
        rawset(_G, "__AVM_UI_TEXT_FOCUS_SEQUENCE", seq)
        st.focus_sequence = seq
        st.id = id
        st.token = st.prefix .. ":" .. tostring(st.session)
        st.text = text or ""
        st.composition, st.caret_start, st.caret_end = "", nil, nil
        st.focused = true
        st.last_sequence = 0
        st.last_signature = nil
    end
    N.sync_rect(id, rect)
end

-- the field moved / resized: tell the DLL (only when something changed)
function N.sync_rect(id, rect)
    if st.id ~= id or not rect then return end
    local x, y = math.floor(rect.x + 0.5), math.floor(rect.y + 0.5)
    local w, h = math.max(1, math.floor(rect.w + 0.5)), math.max(1, math.floor(rect.h + 0.5))
    local sig = string.format("%s:%d:%d:%d:%d:%d", id, st.session, x, y, w, h)
    if sig == st.last_signature then return end
    st.last_signature = sig
    write_request(true, { x = x, y = y, w = w, h = h })
end

function N.deactivate(id)
    if st.id == nil or (id ~= nil and st.id ~= id) then return end
    st.id, st.token, st.text, st.composition = nil, nil, "", ""
    st.caret_start, st.caret_end, st.focused, st.last_signature = nil, nil, false, nil
    write_request(false)
end

function N.is_active(id) return st.id ~= nil and st.id == id end
function N.focused(id) return N.is_active(id) and st.focused end
function N.composition(id) return N.is_active(id) and st.composition or "" end
function N.caret(id) if N.is_active(id) then return st.caret_start, st.caret_end end end

-- every frame: newest result of our session -> id, text, composition, focused (nil when nothing new)
function N.update()
    if st.id == nil then return nil end
    local ok, r = pcall(json.load_file, RESULT)
    if not ok or type(r) ~= "table" then return nil end
    local seq = tonumber(r.sequence)
    if not seq or seq <= st.last_sequence then return nil end
    if r.id ~= st.id or tonumber(r.session) ~= st.session or r.token ~= st.token then return nil end
    st.last_sequence = seq
    st.text = type(r.text) == "string" and r.text or ""
    st.composition = type(r.composition) == "string" and r.composition or ""
    st.caret_start, st.caret_end = tonumber(r.caret_start), tonumber(r.caret_end)
    st.focused = r.focused ~= false
    return st.id, st.text, st.composition, st.focused
end

return N
