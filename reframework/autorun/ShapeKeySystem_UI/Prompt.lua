-- ShapeKeySystem panel: text input dialog. Every text field of the panel goes through P.open.
-- The dialog is drawn by the panel like any other widget (P.draw_dialog, from Panel.draw, on
-- either draw backend); only the text field itself is an ImGui input_text (P.draw, re.on_frame)
-- in a bare transparent window laid exactly over the drawn field, so REFramework's ImGui still
-- does the typing: IME, caret, selection, clipboard. The field rect comes from the previous draw.
-- The dialog is modal: a full-screen input overlay keeps the page under it from taking clicks.
--
-- Chinese cannot be typed into the ImGui field (the game's ANSI window garbles IME text into "??").
-- With ArmorVariantManager's UI DLL (NativeText.lua, Wilds only) the field is not ImGui at all: the
-- DLL owns the IME and we draw its text, composition and caret. Without it the ImGui field has two
-- helpers: 中文 opens the game's own text form (GameText.lua, Wilds only) and puts what was typed
-- there into the field; 粘贴 appends the clipboard. REFramework has no Lua binding for ImGui's
-- SetKeyboardFocusHere: the ImGui field takes typing once it is clicked.
--
-- P.open{ title, text, hint, live = bool, on_change(text), on_submit(text), extra = {label, value} }
--   live: on_change is called on every edit (search boxes)
--   extra: one optional checkbox shown under the field (e.g. "save as general preset")

local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local I = require("ShapeKeySystem_UI.Input")
local W = require("ShapeKeySystem_UI.Widgets")
local G = require("ShapeKeySystem_UI.GameText")
local N = require("ShapeKeySystem_UI.NativeText")

local P = { req = nil, field = nil }
local C = T.c
local floor, max, min = math.floor, math.max, math.min

local seq = 0
function P.open(req)
    if P.req then N.deactivate(P.req.nid) end
    req.text = req.text or ""
    req.original = req.text
    req.first_frame = true
    req.native = N.available()
    seq = seq + 1
    req.nid = "prompt" .. seq
    P.req = req
    P.field = nil          -- set by the first draw of the dialog
end

local function finish(r)
    N.deactivate(r.nid)
    if P.req == r then P.req = nil end
end

function P.close() if P.req then finish(P.req) end; G.cancel() end
function P.is_open() return P.req ~= nil end
-- the game's text form is up: the panel hides and lets the game have the input meanwhile
function P.external_active() return G.active() end

local function submit(r)
    finish(r)
    if r.on_submit then pcall(r.on_submit, r.text, r.extra and r.extra.value) end
end

local function set_text(r, text)
    if text == r.text then return end
    r.text = text
    if r.live and r.on_change then pcall(r.on_change, text) end
end

local function cancel(r)
    if r.live and r.on_change and r.original ~= nil then pcall(r.on_change, r.original) end
    finish(r)
end

-- ---------------------------------------------------------------- ImGui text field (re.on_frame)
-- ImGui enums by number (REFramework exposes no ImGuiCol table; these have not moved in years)
local WIN_FLAGS = 1 | 2 | 4 | 8 | 16 | 32 | 128 | 256   -- NoTitleBar NoResize NoMove NoScrollbar
                                                        -- NoScrollWithMouse NoCollapse NoBackground NoSavedSettings
local SV_WINDOW_PADDING, SV_WINDOW_BORDER, SV_WINDOW_MIN, SV_FRAME_PADDING, SV_FRAME_BORDER = 2, 4, 5, 11, 13
local COL_TEXT, COL_FRAME, COL_FRAME_HOVER, COL_FRAME_ACTIVE = 0, 7, 8, 9

local function v4(argb)
    return Vector4f.new(((argb >> 16) & 255) / 255, ((argb >> 8) & 255) / 255, (argb & 255) / 255,
                        ((argb >> 24) & 255) / 255)
end

local key_was = {}
local function key_edge(vk)
    local ok, down = pcall(function() return reframework:is_key_down(vk) end)
    down = ok and down == true
    local was = key_was[vk]
    key_was[vk] = down
    return down and not was
end

local function field(r, f)
    local nv, nc = 0, 0
    local function var(i, v) if pcall(imgui.push_style_var, i, v) then nv = nv + 1 end end
    local function color(i, c) if pcall(imgui.push_style_color, i, v4(c)) then nc = nc + 1 end end
    var(SV_WINDOW_PADDING, Vector2f.new(0, 0)); var(SV_WINDOW_BORDER, 0.0); var(SV_WINDOW_MIN, Vector2f.new(1, 1))
    var(SV_FRAME_BORDER, 0.0); var(SV_FRAME_PADDING, Vector2f.new(0, max(0, (f.h - f.px) / 2)))
    color(COL_TEXT, C.text); color(COL_FRAME, 0); color(COL_FRAME_HOVER, 0); color(COL_FRAME_ACTIVE, 0)
    pcall(imgui.set_next_window_pos, Vector2f.new(f.x, f.y), 1)       -- ImGuiCond_Always
    pcall(imgui.set_next_window_size, Vector2f.new(f.w, f.h), 1)
    imgui.begin_window("##sks_prompt", nil, WIN_FLAGS)
    -- begin / end must pair whatever happens in between (an unpaired window asserts in ImGui)
    local ok, text = pcall(function()
        local sized = imgui.push_font_size ~= nil and pcall(imgui.push_font_size, f.px + 0.0)
        local widened = pcall(imgui.push_item_width, f.w + 0.0)
        local _, t = imgui.input_text("##sks_prompt_text", r.text)
        if widened then imgui.pop_item_width() end
        if sized then imgui.pop_font_size() end
        return t
    end)
    imgui.end_window()
    if nc > 0 then imgui.pop_style_color(nc) end
    if nv > 0 then imgui.pop_style_var(nv) end
    if not ok then error(text, 0) end
    return text
end

function P.draw()
    G.frame()
    local r = P.req
    if not r then return end
    if G.active() then
        -- keys go to the game's form: track them, act on none (Enter there must not submit here)
        key_edge(0x0D); key_edge(0x1B)
        return
    end
    if r.native then
        local id, text = N.update()
        if id == r.nid and text then set_text(r, text) end
    elseif P.field then
        local text = field(r, P.field)
        if text ~= nil then set_text(r, text) end
    end
    -- REFramework's input_text returns true on every edit, not only on Enter: Enter / Esc are read
    -- from the keyboard instead (edges, so a key still held from an earlier dialog does nothing)
    local enter, esc = key_edge(0x0D), key_edge(0x1B)
    if r.first_frame then r.first_frame = false; return end
    if P.req ~= r then return end
    if enter then submit(r) elseif esc then cancel(r) end
end

-- ---------------------------------------------------------------- native field (Panel.draw)
local function drop(s, n)          -- s without its first n characters
    if n <= 0 then return s end
    local i = utf8.offset(s, n + 1)
    return i and s:sub(i) or ""
end
local function chars(s) return utf8.len(s) or #s end

-- text + IME composition (underlined) + caret, the end kept visible when it does not fit
local function native_field(r, x, y, w, h)
    local f = W.body()
    local comp = N.composition(r.nid)
    local committed = r.text or ""
    local focused = N.focused(r.nid)
    local tx, avail = x + 8, w - 16
    if committed == "" and comp == "" and not focused then
        D.text_mid("点击输入", tx, y, h, C.faint, f, avail)
        return
    end
    local cut, shown = 0, committed .. comp
    while shown ~= "" and D.measure(f, shown) > avail do shown = drop(shown, 1); cut = cut + 1 end
    local cc = chars(committed)
    local vis_committed = drop(committed, cut)
    local vis_comp = cut > cc and drop(comp, cut - cc) or comp
    D.text_mid(vis_committed, tx, y, h, C.text, f)
    local cx = tx + D.measure(f, vis_committed)
    if vis_comp ~= "" then
        local cw = D.text_mid(vis_comp, cx, y, h, C.brass, f)
        D.line(cx, y + h - 7, cx + cw, y + h - 7, 1, C.brass)
    end
    if focused then
        -- caret: end of the composition while composing, else the DLL's caret (characters)
        local kx
        if comp ~= "" then kx = cx + D.measure(f, vis_comp)
        else
            local _, ce = N.caret(r.nid)
            local k = math.max(0, math.min(cc, math.floor(tonumber(ce) or cc)))
            kx = k <= cut and tx or tx + D.measure(f, drop(committed:sub(1, (utf8.offset(committed, k + 1) or #committed + 1) - 1), cut))
        end
        local pulse = (math.sin(os.clock() * math.pi * 2) + 1) / 2
        local a = math.floor(72 + pulse * 183)
        D.line(kx + 1, y + 7, kx + 1, y + h - 7, 1, a * 0x1000000 + (C.brass % 0x1000000))
    end
end

-- ---------------------------------------------------------------- dialog (Panel.draw)
-- wx..wh: the panel window, shaded and centred on
function P.draw_dialog(wx, wy, ww, wh)
    local r = P.req
    if not r then return end
    I.add_overlay(-1e6, -1e6, 2e6, 2e6)
    I.in_overlay = true
    D.rrect(wx, wy, ww, wh, T.m.radius, 0x99000000)

    local w = min(440, ww - 40)
    local fh, hint_h, extra_h = 32, r.hint and 22 or 0, r.extra and 28 or 0
    local h = 14 + 34 + fh + (r.hint and 6 + hint_h or 0) + (r.extra and 8 + extra_h or 0) + 18 + 28 + 14
    local x, y = wx + (ww - w) / 2, wy + max(20, (wh - h) / 2 - 20)
    D.rect(x + 4, y + 6, w, h, 0x55000000)
    W.panel_box(x, y, w, h, true)
    local cy = y + 14
    W.h2(r.title or "输入", x + 16, cy, w - 32)
    cy = cy + 34

    local fx, fw = x + 16, w - 32
    D.rrect(fx, cy, fw, fh, 3, C.ink)
    D.outline(fx, cy, fw, fh, 3, 1, C.brass)
    -- 中文 / 粘贴 inside the field's right end; the ImGui field stops before them
    local pw = D.measure(W.small(), "粘贴") + 16
    local px = fx + fw - pw - 4
    local paste = W.button("粘贴", px, cy + 4, pw, fh - 8, { kind = "ghost", font = W.small() })
    local game = false
    if not r.native and G.available() then
        local gw = D.measure(W.small(), "中文") + 16
        px = px - gw - 4
        game = W.button("中文", px, cy + 4, gw, fh - 8, { kind = "ghost", font = W.small() })
    end
    local S = D.S
    P.field = { x = (fx + 8) * S, y = cy * S, w = (px - fx - 12) * S, h = fh * S, px = max(6, floor(T.font.body * S + 0.5)) }
    if r.native then
        local rect = { x = fx * S, y = cy * S, w = (px - fx - 4) * S, h = fh * S }
        -- the first draw takes the IME; a click on the field takes it back after it was lost
        if not N.is_active(r.nid) or (I.clicked and I.inside(fx, cy, px - fx - 4, fh) and not N.focused(r.nid)) then
            N.activate(r.nid, r.text, rect, true)
        else
            N.sync_rect(r.nid, rect)
        end
        native_field(r, fx, cy, px - fx - 4, fh)
    end
    if paste then
        -- ImGui: the click also took ImGui's focus, so the inactive field picks the new text up next
        -- frame. Native: the DLL gets the new text through a fresh session.
        local ok, clip = pcall(imgui.get_clipboard)
        if ok and type(clip) == "string" and clip ~= "" then
            set_text(r, r.text .. (clip:gsub("[\r\n]+", " ")))
            if r.native then N.activate(r.nid, r.text, { x = fx * S, y = cy * S, w = (px - fx - 4) * S, h = fh * S }, true) end
        end
    end
    if game then
        -- the form starts from the current text and replaces it when decided
        G.open(r.text, function(text)
            if text and P.req == r then set_text(r, (text:gsub("[\r\n]+", " "))) end
        end)
    end
    cy = cy + fh

    if r.hint then
        cy = cy + 6
        D.text_mid(r.hint, fx, cy, hint_h, C.muted, W.small(), fw)
        cy = cy + hint_h
    end
    if r.extra then
        cy = cy + 8
        local ch, v = W.toggle(r.extra.label, fx, cy, r.extra.value == true, { h = extra_h })
        if ch then r.extra.value = v end
        cy = cy + extra_h
    end
    cy = cy + 18
    local bw = 76
    local ok = W.button(r.live and "完成" or "确定", x + w - 16 - bw, cy, bw, 28, { kind = "primary" })
    local no = W.button("取消", x + w - 16 - 2 * bw - 8, cy, bw, 28)

    I.consume()            -- the rest of the click (shade, empty dialog space) goes nowhere
    I.in_overlay = false
    if P.req ~= r then return end
    if ok then submit(r) elseif no then cancel(r) end
end

return P
