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

-- 页面内输入：搜索立即更新，不打开弹窗；控件 ID 和位置跨帧保持稳定。
click_text("捏脸", true)
check(Panel.ui.page == "sculpt", "rail: 捏脸")
click_text("扫描装备", true); frame()
check(st.sculpt.scan ~= nil, "扫描装备 -> sculpt_scan")
local X = require("ShapeKeySystem_UI.TextInput")
local D = require("ShapeKeySystem_UI.Draw")
local W = require("ShapeKeySystem_UI.Widgets")
local search = find("搜索形态键…", true)
frame()
local rect = INPUT_RECTS.sculpt_filter
check(rect and search and math.abs(rect.x - search.x) < 1 and math.abs(rect.y - (search.y - 2)) < 8,
    "inline: ImGui overlays the original search field")
check(INPUT_WINDOWS.sculpt_filter == "##sks_inline_sculpt_filter" and find("完成", true) == nil
    and find("中文", true) == nil, "inline: stable window ID, no input dialog or game-form button")
INPUT_ACTIVE = "sculpt_filter"
INPUT_EDITS.sculpt_filter = "zzz_no_such_key"; frame(); frame()
check(find("没有匹配的形态键", false) ~= nil, "inline: live search filters the list")
KEYS[0x0D] = true; frame(); KEYS[0x0D] = false; frame()
check(Panel.ui.page_state.sculpt.filter == "zzz_no_such_key", "inline: IME Enter does not submit or clear search")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
check(Panel.open, "inline: Delete edits text without closing the focused panel")
INPUT_EDITS.sculpt_filter = ""; frame(); frame()
check(not find("没有匹配的形态键", false), "inline: clearing the search shows keys again")
INPUT_ACTIVE = nil; frame()
check(IMGUI_STACK.var == 0 and IMGUI_STACK.color == 0 and IMGUI_STACK.width == 0
    and IMGUI_STACK.window == 0 and IMGUI_STACK.font == 0, "inline: ImGui stacks balanced")

-- 移除桥接依赖：即使 AVM 桥接存在也不得注册或读写它；换游戏名仍走相同控件。
local saved_game_name = reframework.get_game_name
avm_bridge = { register_runtime = function() error("SKS must not use AVM IME") end }
for _, game in ipairs({ "mhws", "mhrise", "re2", "re4" }) do
    reframework.get_game_name = function() return game end
    INPUT_EDITS.sculpt_filter = "中文测试"; frame(); frame()
    check(Panel.ui.page_state.sculpt.filter == "中文测试" and INPUT_WINDOWS.sculpt_filter == "##sks_inline_sculpt_filter",
        "inline: generic input path for " .. game)
end
avm_bridge, reframework.get_game_name = nil, saved_game_name
INPUT_EDITS.sculpt_filter = ""; frames(2)

-- 命名表单在保存操作栏下展开；通用选项、确定和取消保留原有语义。
click_text("另存为…", true); frames(2)
local form = Panel.ui.page_state.sculpt.name_form
check(form and find("另存为", true) ~= nil and INPUT_RECTS.sculpt_name,
    "inline: save-as expands an embedded naming row")
INPUT_EDITS.sculpt_name = "内联捏脸"; frames(2)
click_text("存为通用配置", false, -25)
check(form and form.extra.value == true, "inline: general preset option remains editable")
click_text("确定", true); frames(2)
check(not Panel.ui.page_state.sculpt.name_form and st.sculpt.preset and st.sculpt.preset.name == "内联捏脸"
    and st.sculpt.preset.folder == nil, "inline: confirm saves the named general preset")
click_text("另存为…", true); frames(2)
INPUT_EDITS.sculpt_name = "取消的配置"; frames(2)
click_text("取消", true); frames(2)
check(not Panel.ui.page_state.sculpt.name_form and st.sculpt.preset.name == "内联捏脸",
    "inline: cancel discards naming without saving")

-- 输入框不遮挡导航；切页后旧控件不能继续收到输入。
click_text("另存为…", true); frames(2)
INPUT_ACTIVE = "sculpt_filter"; frame()
click_text("表情", true); frame()
check(Panel.ui.page == "basic" and #X.fields == 0 and X.active == nil and not Panel.ui.page_state.sculpt.name_form,
    "inline: rail stays interactive, page switch discards the previous page's naming draft")
INPUT_ACTIVE = nil
click_text("捏脸", true); frame()

-- 在两个绘制回调之间登记布局；缩放、裁剪和异常清理不访问 d2d。
local saved_fields, saved_scale = X.fields, D.S
X.begin_layout(); D.S = 2
local changed
X.register("probe", 10, 20, 100, 28, "", function(t) changed = t end)
INPUT_EDITS.probe = "测试"; X.draw()
check(INPUT_RECTS.probe.x == 36 and INPUT_RECTS.probe.y == 40 and INPUT_RECTS.probe.w == 168
    and changed == "测试", "inline: logical geometry converted to physical pixels")
D.push_clip(0, 0, 60, 60); X.begin_layout()
check(not X.register("clipped", 10, 20, 100, 28, "") and #X.fields == 0,
    "inline: partly clipped controls create no input window")
D.pop_clip(); X.begin_layout()
X.register("probe", 10, 20, 100, 28, "")
local saved_input = imgui.input_text
imgui.input_text = function() error("input reset") end
local ok = pcall(X.draw)
imgui.input_text = saved_input
check(not ok and IMGUI_STACK.var == 0 and IMGUI_STACK.color == 0 and IMGUI_STACK.width == 0
    and IMGUI_STACK.window == 0 and IMGUI_STACK.font == 0, "inline: input errors release every ImGui resource")
X.fields, D.S = saved_fields, saved_scale
frame()

-- searchable select: while closed the ImGui buffer stays empty (the d2d layout runs a frame after
-- ImGui, so the click that opens it activates whatever was registered before)
local Wd = require("ShapeKeySystem_UI.Widgets")
X.begin_layout(); DRAWS = {}
Wd.search_select({}, "probe_search", 10, 20, 240, { { value = "a", label = "alpha" } }, "blink.L · fcParam_001", {})
check(X.fields[1] and X.fields[1].text == "" and find("blink.L · fcParam_001", true) ~= nil,
    "search select: closed field registers an empty buffer, the selection is drawn")
X.fields = saved_fields
frame()

-- an open dropdown removes the ImGui fields: their text is still drawn under the popup
INPUT_ACTIVE = "sculpt_filter"; INPUT_EDITS.sculpt_filter = "Bang"; frame(); frame(); INPUT_ACTIVE = nil; frame()
Wd.open_select = "sculpt_preset"; frame()
check(find("Bang", true) ~= nil and #X.fields == 0, "dropdown open: field text kept, ImGui windows removed")
Wd.open_select = nil; INPUT_EDITS.sculpt_filter = ""; frame(); frame()

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
