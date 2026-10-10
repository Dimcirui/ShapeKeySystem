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
print("UI FAILS:", ufails)
