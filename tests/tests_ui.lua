-- d2d panel (M3) tests: drive the panel through the mocked mouse / keyboard and read back what it
-- drew (DRAWS) and what it changed in SKS.state.
local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local ufails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[ui] " .. what)
    if not cond then ufails = ufails + 1 end
end

local function frame()
    CB.tick()
    CB.frame()
    DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}
    CB.d2d_draw()
end
local function frames(n) for _ = 1, n do frame() end end
local function find(s, exact)
    for _, d in ipairs(DRAWS) do
        if (exact and d.s == s) or (not exact and d.s:find(s, 1, true)) then return d end
    end
end
local function click_at(x, y)
    MOUSE.x, MOUSE.y = x, y
    MOUSE.down = true; frame()
    MOUSE.down = false; frame()
end
local function click_text(s, exact, dx)
    local d = find(s, exact)
    if not d then print("  (text not found: " .. s .. ")"); return false end
    click_at(d.x + (dx or 4), d.y + 6)
    return true
end
local VK_END = 0x2E   -- Delete (default since 2026-10-10)
local function hotkey()
    KEYS[VK_END] = true; frame(); KEYS[VK_END] = false; frame()
end
local function has_image(p) for _, x in ipairs(DRAWN_IMAGES) do if x == p or x:sub(-#p - 1) == "/" .. p then return true end end end

check(CB.d2d_draw ~= nil, "panel registered with d2d")
frame()
check(#DRAWS == 0, "closed: nothing drawn")
hotkey()
check(Panel.open, "Delete opens the panel")
check(st.settings.hotkey == "Delete", "default hotkey Delete (Home = AVM, End = game pause)")
check(find("SHAPEKEYSYSTEM", true) ~= nil, "title drawn")
check(find("表情", true) and find("捏脸", true), "basic rail entries")
check(not find("表情详情", true), "advanced entries hidden")
-- face styles come from Faces.lua (other session's work): only checked when a style is installed
check(#DRAWN_IMAGES == 0 or has_image("face_lines.png"), "basic page: face line art drawn (when a face style exists)")
check(st.runtime.ui_open == true, "backend told the panel is open")

-- pinned OS cursor (game owns the mouse): the panel follows the virtual cursor instead
local Blocker = require("ShapeKeySystem_UI.InputBlocker")
local I = require("ShapeKeySystem_UI.Input")
check(Blocker.enabled, "input blocker on while open")
MOUSE.x, MOUSE.y = 960, 540; frames(3)
Blocker.cursor = { x = 300, y = 310 }; frame()
check(Blocker.pinned and I.mx == 300 and I.my == 310, "cursor pinned at the centre -> virtual cursor used")
MOUSE.x, MOUSE.y = 500, 520; frame()
check(Blocker.pinned, "pinned is sticky: one off-centre sample between the game's pulls is not free")
frames(35)
check(not Blocker.pinned and I.mx == 500 and Blocker.cursor.x == 500, "free OS cursor (after the sticky window) -> used and synced")

-- advanced toggle
click_text("进阶", true, -30)
check(st.runtime.advanced == true, "进阶 toggle -> settings.advanced")
frame()
check(find("表情详情", true) ~= nil, "advanced rail entries shown")

-- master gain slider: drag from the left end to the right end
local lbl = find("表情强度", true)
check(lbl ~= nil, "basic page: master gain row")
if lbl then
    local sx, sy = lbl.x + 100, lbl.y + 4
    MOUSE.x, MOUSE.y, MOUSE.down = sx + 2, sy, true; frame()
    MOUSE.x = sx + 2000; frame()
    MOUSE.down = false; frame()
    check(math.abs((st.expression.master_gain or 0) - 2.0) < 1e-6, "slider drag sets master gain to 2.0")
    SKS.call("set_master_gain", { value = 1.0 })
end

-- face zone click selects the region shown in the card
click_text("在表情详情中查看", false)
check(Panel.ui.page == "expr", "region card button jumps to 表情详情")
frame()
check(find("ARKit 覆盖", false) ~= nil or find("表情配置", true) ~= nil, "表情详情 page drawn")

-- debug page
click_text("设置与调试", true)
check(Panel.ui.page == "debug", "rail: 设置与调试")
check(find("设置", true) and find("性能", true), "debug page cards drawn")

-- sculpt page: scan + search prompt
click_text("捏脸", true)
check(Panel.ui.page == "sculpt", "rail: 捏脸")
click_text("扫描装备", true)
frame()
check(st.sculpt.scan ~= nil, "扫描装备 -> sculpt_scan")
click_text("搜索形态键…", true)
check(PROMPT_OPEN ~= nil, "search box opens the text prompt")
PROMPT_TEXT = "zzz_no_such_key"; frame(); frame()
check(find("没有匹配的形态键", false) ~= nil, "live search filters the list")
PROMPT_TEXT = ""; frame(); KEYS[0x0D] = true; frame(); KEYS[0x0D] = false; frame()
check(not find("没有匹配的形态键", false), "clearing the search shows keys again")

-- the prompt dialog is drawn by the panel; only the text field is an ImGui window laid over it
local P = require("ShapeKeySystem_UI.Prompt")
click_text("搜索形态键…", true); frame()
local ptitle = find("搜索形态键", true)
check(P.is_open() and ptitle ~= nil and find("完成", true) ~= nil and find("取消", true) ~= nil, "prompt: dialog drawn by the panel")
check(PROMPT_RECT and ptitle and PROMPT_RECT.y > ptitle.y and PROMPT_RECT.w > 100 and PROMPT_RECT.h > 20, "prompt: ImGui field placed under the title")
check(IMGUI_STACK.var == 0 and IMGUI_STACK.color == 0 and IMGUI_STACK.width == 0, "prompt: ImGui style stacks balanced")
local page_before = Panel.ui.page
click_text("表情", true)
check(Panel.ui.page == page_before and P.is_open(), "prompt: modal, the rail under it takes no click")
PROMPT_TEXT = "zzz_no_such_key"; frame(); frame()
KEYS[0x1B] = true; frame(); KEYS[0x1B] = false; frame()
check(not P.is_open() and not find("没有匹配的形态键", false), "prompt: Esc cancels and restores the live search")
click_text("搜索形态键…", true); frame()
PROMPT_TEXT = "zzz"; frame()
CLIPBOARD = "_no_such\r\n"; click_text("粘贴", true)
check(P.req and P.req.text == "zzz_no_such ", "prompt: 粘贴 appends the clipboard, line breaks flattened")
PROMPT_TEXT = "zzz_no_such_key"; frame()
click_text("完成", true)
check(not P.is_open() and find("没有匹配的形态键", false) ~= nil, "prompt: 完成 button keeps the text")
-- 中文: the game's own text form (GameText, Wilds only) types for the field; the panel hides meanwhile
local G = require("ShapeKeySystem_UI.GameText")
check(not G.available() and find("中文", true) == nil, "prompt: no 中文 button without the game's text form")
local g_avail, g_open, g_text = G.available, G.open, nil
G.available = function() return true end
G.open = function(text, cb) g_text = text; G.pending = { on_done = cb, handle = { call = function() return false end } }; return true end
click_text("zzz_no_such_key", true); frame()
check(find("中文", true) ~= nil, "prompt: 中文 button when the game's form exists")
click_text("中文", true)
check(G.active() and g_text == "zzz_no_such_key", "prompt: 中文 opens the game's form with the current text")
frame()
check(#DRAWS == 0 and not Blocker.enabled, "prompt: panel hidden and game input released while the form is up")
local done = G.pending.on_done
G.pending = nil; done("测试\r\n")
frame(); frame()
check(P.req and P.req.text == "测试 " and Blocker.enabled and find("搜索形态键", true) ~= nil, "prompt: form text lands in the field, panel back")
G.available, G.open = g_avail, g_open
PROMPT_TEXT = "zzz_no_such_key"; frame(); click_text("完成", true)

-- native IME through ArmorVariantManager's UI DLL (NativeText): Wilds only, our own runtime folder
local N = require("ShapeKeySystem_UI.NativeText")
local REQ, RES = "ShapeKeySystem/Runtime/D2DTextInputRequest.json", "ShapeKeySystem/Runtime/D2DTextInputResult.json"
local reg_args
avm_bridge = { register_runtime = function(id, dir) reg_args = { id, dir }; return true end }
check(not N.available(), "native: off outside MH Wilds even with the DLL")
N.WILDS = true
click_text("zzz_no_such_key", true); frame()
check(P.req and P.req.native and reg_args and reg_args[1] == "ShapeKeySystem" and reg_args[2] == "ShapeKeySystem/Runtime",
    "native: registered as its own client")
local req = json.load_file(REQ)
check(req and req.active == true and req.text == "zzz_no_such_key" and req.width > 100 and req.focus_sequence >= 1,
    "native: request written (active, text, field rect, focus sequence)")
check(find("中文", true) == nil, "native: no 中文 button")
json.dump_file(RES, { sequence = 1, id = req.id, session = req.session, token = req.token, text = "测试",
                      composition = "ce", caret_start = 2, caret_end = 2, focused = true })
frame(); frame()
check(P.req.text == "测试" and find("测试", true) ~= nil and find("ce", true) ~= nil, "native: DLL text and composition drawn")
click_text("完成", true)
req = json.load_file(REQ)
check(not P.is_open() and req and req.active == false, "native: closing the dialog releases the IME")
N.WILDS, avm_bridge = false, nil
click_text("测试", true); frame(); PROMPT_TEXT = "zzz_no_such_key"; frame(); click_text("完成", true)

click_text("zzz_no_such_key", true); frame()   -- the box now shows the filter
PROMPT_TEXT = ""; frame(); click_text("完成", true)
check(not P.is_open() and not find("没有匹配的形态键", false), "prompt: reopened with the filter, cleared")

-- undo with nothing to undo is not shown as an error
local errs = 0
for _, t in ipairs(Panel.ui.toasts) do if t.level == "error" then errs = errs + 1 end end
check(errs == 0, "no error toasts so far")

-- window drag by the title bar
local w0 = st.settings.window.x
local t = find("SHAPEKEYSYSTEM", true)
MOUSE.x, MOUSE.y, MOUSE.down = t.x + 200, t.y + 4, true; frame()
MOUSE.x = MOUSE.x + 50; frame()
MOUSE.down = false; frame(); CB.tick()
check(st.settings.window.x == w0 + 50, "title drag moves the window and saves it")

-- every page draws without a page error
for _, name in ipairs({ "表情", "捏脸", "表情详情", "条件表情", "设置与调试" }) do
    click_text(name, true); MOUSE.x, MOUSE.y = 1500, 900; frame()
    SNAPS[#SNAPS + 1] = { name = name, cmds = CMDS }
    local e = find("页面出错", false)
    check(e == nil, "page " .. name .. " draws" .. (e and (": " .. e.s) or ""))
end
local logged = 0
for _, l in ipairs(st.debug.log) do if l.text:find("panel", 1, true) then logged = logged + 1; print("  log:", l.text) end end
check(logged == 0, "no panel errors logged")

-- sculpt: slider on a key writes it; the narrow-window layout also draws
click_text("捏脸", true); frame()
local before = #DRAWS
Panel.ui.win.w = 640; frame()
check(find("页面出错", false) == nil and #DRAWS > 0, "narrow window draws")
Panel.ui.win.w = 920; frame()

hotkey()
check(not Panel.open, "Delete closes the panel")
frame()
check(#DRAWS == 0, "closed again: nothing drawn")
-- coexistence with ArmorVariantManager (shared blocker table)
local reg = __AVM_UI_INPUT_BLOCKER_STATES
check(type(reg) == "table" and reg.ShapeKeySystem == false, "registered in AVM's blocker table (off while closed)")
KEYS[0x24] = true; frame(); KEYS[0x24] = false; frame()
check(not Panel.open, "Home (AVM's key) does not open our panel")
hotkey()
check(Panel.open and reg.ShapeKeySystem == true and __AVM_REFD2D_INPUT_BLOCKED == true, "open: published as blocking")
reg.ArmorVariantManager = true; frame()
check(not Panel.open, "AVM opening its panel closes ours")
check(reg.ShapeKeySystem == false and __AVM_REFD2D_INPUT_BLOCKED == true, "closed: AVM still blocking")
hotkey()
check(Panel.open, "ours can open while AVM is open")
local warned = false
for _, t in ipairs(Panel.ui.toasts) do if t.text:find("ArmorVariantManager", 1, true) then warned = true end end
check(warned, "warning that both panels are open")
local function quads() local n = 0; for _, c in ipairs(CMDS) do if c[1] == "quad" then n = n + 1 end end; return n end
frame(); local q_avm = quads()
reg.ArmorVariantManager = false; frame(); local q_alone = quads()
check(q_alone == q_avm + 2, "no second cursor while AVM draws its own (cursor = 2 quads)")
hotkey()
check(not Panel.open and not __AVM_REFD2D_INPUT_BLOCKED, "both closed: nobody blocking")

-- a d2d without rounded shapes / ovals (other builds): drawing falls back, no errors
local saved_rr, saved_oval = d2d.fill_rounded_rect, d2d.oval
d2d = setmetatable({ fill_rounded_rect = false, rounded_rect = false, oval = false }, { __index = d2d })
d2d.fill_rounded_rect, d2d.rounded_rect, d2d.oval = nil, nil, nil
hotkey(); frame()
check(Panel.open and #DRAWS > 0 and not find("页面出错", false), "d2d without rounded rects still draws")
hotkey()

-- ImGui backend (players without d2d): settings.ui_backend = "imgui" draws from re.on_frame
local D = require("ShapeKeySystem_UI.Draw")
local function iframe()
    CB.tick()
    DRAWS, DRAWN_IMAGES, IMGUI_ERR = {}, {}, {}
    CB.frame()
    local n = #DRAWS
    CB.d2d_draw()
    return n
end
local function ihotkey() KEYS[VK_END] = true; iframe(); KEYS[VK_END] = false; iframe() end
local function iclick(s)
    local d = find(s, true)
    if not d then print("  (text not found: " .. s .. ")"); return false end
    MOUSE.x, MOUSE.y = d.x + 4, d.y + 6
    MOUSE.down = true; iframe(); MOUSE.down = false; iframe()
    return true
end
check(D.pick("auto") == "d2d" and D.pick("d2d") == "d2d" and D.pick("imgui") == "imgui", "backend pick: auto prefers d2d, imgui on request")
check(not SKS.call("set_setting", { key = "ui_backend", value = "vulkan" }), "unknown ui_backend rejected")
check(SKS.call("set_setting", { key = "ui_backend", value = "imgui" }) and st.settings.ui_backend == "imgui", "ui_backend setting stored")
ihotkey()
local n_frame = iframe()
check(D.backend == "imgui" and Panel.open, "imgui: panel opens")
local title = find("SHAPEKEYSYSTEM", true)
check(title ~= nil, "imgui: title drawn from re.on_frame")
check(title and title.c == 0xFF4AA2D6, "imgui: colours converted ARGB -> ABGR")
check(n_frame == #DRAWS, "imgui: the d2d callback draws nothing")
check(#DRAWN_IMAGES == 0 and #IMGUI_ERR == 0, "imgui: no images; points are {x, y}, colours integers" .. (IMGUI_ERR[1] and (": " .. IMGUI_ERR[1]) or ""))
for _, name in ipairs({ "表情", "捏脸", "表情详情", "条件表情", "设置与调试" }) do
    iclick(name); MOUSE.x, MOUSE.y = 1500, 900; iframe()
    local e = find("页面出错", false)
    check(e == nil and #IMGUI_ERR == 0, "imgui: page " .. name .. " draws" .. (e and (": " .. e.s) or "") .. (IMGUI_ERR[1] and (": " .. IMGUI_ERR[1]) or ""))
    if name == "表情" then
        check(find("表情配置", true) ~= nil and #DRAWN_IMAGES == 0, "imgui: basic page draws its controls without the face art")
    end
end
check(find("绘制方式", true) ~= nil and find("ImGui（REFramework", false) ~= nil, "imgui: settings show the backend")
-- d2d not installed: auto draws with imgui; neither backend: the panel stays closed
local saved_d2d = d2d
d2d = nil
SKS.call("set_setting", { key = "ui_backend", value = "auto" })
iframe()
check(D.backend == "imgui" and Panel.open and find("SHAPEKEYSYSTEM", true) ~= nil, "no d2d: auto uses imgui")
local saved_dl = imgui.get_background_draw_list
imgui.get_background_draw_list = nil
iframe()
check(D.backend == nil and not Panel.open, "no backend: panel closes")
ihotkey()
check(not Panel.open, "no backend: hotkey does not open it")
imgui.get_background_draw_list, d2d = saved_dl, saved_d2d
iframe()
check(D.backend == "d2d" and not Panel.open, "d2d back: auto uses it again")

-- Surface queries belong to the active draw callback; frame/input/layout read only the cache.
local saved_surface, saved_display = d2d.surface_size, imgui.get_display_size
local surface_calls, in_draw = 0, false
local surface_result, surface_error = { 2560, 1440 }, false
d2d.surface_size = function()
    surface_calls = surface_calls + 1
    assert(in_draw, "d2d surface queried outside its draw callback")
    if surface_error then error("device resetting") end
    return surface_result[1], surface_result[2]
end
-- Bind the mock renderer once; its results change across resets without replacing the API.
D.set_backend(nil); D.set_backend("d2d")
Panel.set_open(true)
CB.frame()
Blocker.surface(); D.surface_size()
check(surface_calls == 0, "surface: frame, input and layout never query d2d")
in_draw = true; CB.d2d_draw(); in_draw = false
local sw, sh = D.surface_pixels()
check(surface_calls == 1 and sw == 2560 and sh == 1440, "surface: d2d draw refreshes physical dimensions")
CB.frame(); Blocker.surface(); D.surface_size()
check(surface_calls == 1, "surface: cached dimensions remain safe between draw callbacks")

local invalid_sizes = { { 0, 1440 }, { -1, 1440 }, { math.huge, 1440 }, { 0/0, 1440 },
                        { "2560", 1440 }, { 2560, 0 }, {} }
for _, size in ipairs(invalid_sizes) do
    surface_result = size
    DRAWS, CMDS = {}, {}
    in_draw = true; CB.d2d_draw(); in_draw = false
    sw, sh = D.surface_pixels()
    check(#DRAWS == 0 and #CMDS == 0 and sw == 2560 and sh == 1440,
        "surface: invalid dimensions skip drawing and retain the cache")
end
surface_error = true
DRAWS, CMDS = {}, {}
in_draw = true; CB.d2d_draw(); in_draw = false
sw, sh = D.surface_pixels()
check(#DRAWS == 0 and #CMDS == 0 and sw == 2560 and sh == 1440,
    "surface: renderer reset skips drawing and retains the cache")
surface_error, surface_result = false, { 1920, 1080 }
DRAWS = {}; in_draw = true; CB.d2d_draw(); in_draw = false
sw, sh = D.surface_pixels()
check(#DRAWS > 0 and sw == 1920 and sh == 1080, "surface: rendering resumes after reset")

-- Installed d2d must not be queried when ImGui is the selected backend.
surface_calls = 0
d2d.surface_size = function() surface_calls = surface_calls + 1; error("inactive d2d") end
imgui.get_display_size = function() return { x = 2560, y = 1440 } end
SKS.call("set_setting", { key = "ui_backend", value = "imgui" })
SKS.call("set_setting", { key = "ui_scale", value = 2 })
iframe()
sw, sh = D.surface_pixels()
local lw, lh = D.surface_size()
check(surface_calls == 0 and sw == 2560 and sh == 1440 and lw == 1280 and lh == 720
    and find("SHAPEKEYSYSTEM", true) ~= nil, "surface: ImGui uses its own dimensions and UI scale")
Panel.set_open(false)
d2d.surface_size, imgui.get_display_size = saved_surface, saved_display
SKS.call("set_setting", { key = "ui_backend", value = "auto" })
SKS.call("set_setting", { key = "ui_scale", value = 1 })
iframe()
print("UI FAILS:", ufails)
