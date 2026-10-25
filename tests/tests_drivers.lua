-- shape key drivers (Drivers.lua): the formula parser, waveforms, leases owned by "drivers" and
-- how they give way to mocap, the 驱动 page
local SKS = require("ShapeKeySystem_Core.API")
local Dr = require("ShapeKeySystem_Core.Drivers")
local Ext = require("ShapeKeySystem_Core.External")
local U = require("ShapeKeySystem_Core.Util")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local dfails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[drivers] " .. what)
    if not cond then dfails = dfails + 1 end
end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6 end
local function ev(src, t)
    local fn, err = Dr.compile(src)
    if not fn then return nil, err end
    return fn(t or 0)
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
-- this file's face; the earlier groups' channel list comes back at the end
local saved_channels = {}
for i, n in ipairs(CHANNELS) do saved_channels[i] = n end
local function set_channels(list)
    for i = 1, #CHANNELS do CHANNELS[i] = nil end
    for i, n in ipairs(list) do CHANNELS[i] = n end
    SKS.call("rescan"); ticks(80)
end

-- formula parser
check(near(ev("1 + 2 * 3 ^ 2"), 19), "precedence: ^ before * before +")
check(near(ev("-2 ^ 2"), -4) and near(ev("2 ^ 3 ^ 2"), 512), "unary minus below ^, ^ right-associative")
check(near(ev("(1 + 2) * 3"), 9) and near(ev("7 % 3"), 1) and near(ev("1.5e1 / 3"), 5), "brackets, %, exponent numbers")
check(near(ev("t * 2", 1.5), 3) and near(ev("tau / pi"), 2), "t and the constants")
check(near(ev("clamp(5, 0, 1)"), 1) and near(ev("lerp(2, 4, 0.5)"), 3) and near(ev("max(1, min(3, 2))"), 2),
    "functions with several arguments")
check(near(ev("1 / 0"), 0) and near(ev("1 % 0"), 0) and near(ev("(-8) ^ 0.5"), 0), "division by zero and complex powers give 0")
check(near(ev("osc(0)"), 0) and near(ev("osc(0.5)"), 1) and near(ev("tri(0.25)"), 0.5) and near(ev("saw(1.25)"), 0.25),
    "cycle functions: 0 on a whole cycle, osc / tri peak at half")
check(near(ev("square(0.2)"), 1) and near(ev("square(0.7)"), 0) and near(ev("pulse(0.2, 0.1)"), 0), "square and pulse")
local n1, n2 = ev("noise(3)"), ev("noise(3.5)")
check(n1 and n1 >= 0 and n1 <= 1 and n2 >= 0 and n2 <= 1 and near(ev("noise(3)"), n1), "noise stays in 0..1 and repeats")
local function err_of(src) local _, e = Dr.compile(src); return e and e[1] end
check(err_of("") == "公式为空" and err_of("   ") == "公式为空", "empty formula")
check(err_of("foo(1)") == "未知函数 %s" and err_of("x + 1") == "未知名称 %s", "unknown function / name")
check(err_of("lerp(1, 2)") == "%s 需要 %s 个参数", "wrong argument count")
check(err_of("(1 + 2") == "缺少右括号" and err_of("1 +") == "公式不完整" and err_of("1 2") == "多余的内容：%s",
    "missing bracket, incomplete, trailing text")
check(err_of('("x"):rep(9)') == "无法识别的字符 %s" and err_of("os.exit()") ~= nil, "Lua code is not a formula")
check(err_of(string.rep("1+", 150) .. "1") == "公式太长（最多 %s 个字符）", "length limit")
check(err_of(string.rep("(", 40) .. "1" .. string.rep(")", 40)) == "括号嵌套太深", "nesting limit")

-- a waveform is compiled through its formula
local it = { wave = "osc", period = 2, lo = 0.2, hi = 0.8, phase = 0 }
local f = Dr.formula_of(it)
check(f == "lerp(0.2, 0.8, osc(t / 2))", "wave written as a formula (" .. f .. ")")
check(near(ev(f, 0), 0.2) and near(ev(f, 1), 0.8) and near(ev(f, 2), 0.2), "osc from low to high and back over one period")
it.phase = 0.25
check(Dr.formula_of(it) == "lerp(0.2, 0.8, osc(t / 2 + 0.25))", "phase in the formula")

-- commands
set_channels({ "blendShape1.jawOpen", "blendShape1.Other", "blendShape1.Waist_thin" })
local ok, err = SKS.call("drivers", { op = "patch", index = 1, patch = { period = 1 } })
check(not ok and err == "E_NOT_FOUND", "patching a missing driver is rejected")
ok = SKS.call("drivers", { op = "add", key = "Other" })
check(ok and #st.drivers.cfg.items == 1 and st.drivers.cfg.items[1].key == "Other", "add creates a driver for the key")
ok, err = SKS.call("drivers", { op = "patch", index = 1, patch = { wave = "zigzag" } })
check(not ok and err == "E_BAD_ARGS" and st.drivers.cfg.items[1].wave == "osc", "unknown wave rejected")
SKS.call("drivers", { op = "patch", index = 1, patch = { period = 999, lo = -1 } })
check(st.drivers.cfg.items[1].period == 120 and st.drivers.cfg.items[1].lo == 0, "numbers clamped to their limits")
SKS.call("drivers", { op = "patch", index = 1, patch = { wave = "expr", expr = "0.7" } })
check(st.drivers.items[1].err == nil and st.drivers.items[1].formula == "0.7", "formula driver compiled")
ticks(3)
local oi
for i, n in ipairs(CHANNELS) do if n:match("([^%.]+)$") == "Other" then oi = i - 1 end end
local _, owner = Ext.get("Other")
check(owner == "drivers" and near(st.drivers.items[1].value, 0.7), "the key is held by owner drivers")
check(oi and math.abs((WEIGHTS[oi] or -1) - 0.7) < 1e-3, "the driven value reaches the mesh")
check(U.load_json(U.path("user", "drivers.json")) == nil, "the file is written only after the edits settle")
Dr.flush()
local saved = U.load_json(U.path("user", "drivers.json"))
check(saved and saved.schema == "sks.drivers/1" and saved.items[1].expr == "0.7", "saved to user/drivers.json")

-- a second driver on the same key is not applied; values above the cap are clamped
SKS.call("drivers", { op = "add", key = "other" })
SKS.call("drivers", { op = "patch", index = 2, patch = { wave = "expr", expr = "9" } })
ticks(1)
check(st.drivers.items[2].dup == 1 and near(Ext.get("Other"), 0.7), "a second driver on the same key is flagged, the first keeps it")
SKS.call("drivers", { op = "remove", index = 1 }); ticks(1)
check(#st.drivers.cfg.items == 1 and near(Ext.get("Other"), st.settings.sculpt_max),
    "after removing the first, the second drives (clamped to sculpt_max)")

-- another owner holds the key: the driver waits
Ext.set("mocap", "Other", 0.3, 5)
ticks(1)
local v, o = Ext.get("Other")
check(o == "mocap" and near(v, 0.3) and st.drivers.items[1].owner == "mocap", "a key held by mocap is left to it")
Ext.release("mocap", "Other"); ticks(1)
_, o = Ext.get("Other")
check(o == "drivers", "the driver takes the key back once it is free")

-- switching off hands the key back at once
SKS.call("drivers", { op = "patch", index = 1, patch = { enabled = false } }); ticks(1)
check(Ext.get("Other") == nil, "a switched-off driver releases its key")
SKS.call("drivers", { op = "patch", index = 1, patch = { enabled = true } }); ticks(1)
SKS.call("drivers", { op = "patch", index = 1, patch = { key = "Waist_thin" } }); ticks(1)
check(Ext.get("Other") == nil and Ext.get("Waist_thin") ~= nil, "renaming the key releases the old one")
SKS.call("drivers", { op = "patch", patch = { enabled = false } }); ticks(1)
check(Ext.get("Waist_thin") == nil and st.drivers.cfg.enabled == false, "the master switch releases everything")
SKS.call("drivers", { op = "patch", patch = { enabled = true } })
SKS.call("drivers", { op = "patch", index = 1, patch = { expr = "lerp(0, 1" } }); ticks(1)
check(st.drivers.items[1].err ~= nil and Ext.get("Waist_thin") == nil, "a formula with an error drives nothing")

-- the clock: dt adds up, a wave moves with it
Dr.load({ items = { { key = "Other", wave = "saw", period = 4, lo = 0, hi = 1 } } })
Dr.tick(1, 1); Dr.tick(1, 1)
check(near(Dr.view.items[1].value, 0.5) and near(Ext.get("Other"), 0.5), "saw at 2 s of a 4 s period is half way")
Dr.load({ enabled = "yes", items = { { key = 3, wave = "?", period = "x" }, "bad" } })
local c = Dr.config()
check(c.enabled == true and #c.items == 2 and c.items[1].key == "" and c.items[1].wave == "osc" and c.items[1].period == 2,
    "a damaged file loads with defaults")
Dr.tick(0.1, 1)
check(Ext.get("Other") == nil, "loading a new list releases keys no driver names")

-- page
Dr.load({ items = { { key = "Other", wave = "tri", period = 3 }, { key = "Other", wave = "expr", expr = "0.5" },
                    { key = "Waist_thin", wave = "expr", expr = "sin(" } } })
SKS.call("set_setting", { key = "advanced", value = true })
Panel.set_open(true)
Panel.ui.page = "drivers"
ticks(1)
DRAWS = {}; CB.d2d_draw()
local function drawn(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return true end end end
check(drawn("启用驱动") and drawn("添加驱动") and drawn("周期") and drawn("lerp(0, 1, tri(t / 3))") and drawn("改为公式"),
    "wave driver card drawn with its formula")
check(drawn("公式不完整") and drawn("第 1 条驱动") and not drawn("页面出错"), "formula error and duplicate shown")
local h_page = Panel.ui.win.h
Panel.ui.win.h = 1000
DRAWS, CMDS = {}, {}; CB.d2d_draw()
SNAP("驱动", function() DRAWS, CMDS = {}, {}; CB.d2d_draw() end)
Panel.ui.win.h = h_page
Dr.load({})
DRAWS, CMDS = {}, {}; CB.d2d_draw()
check(drawn("还没有驱动") and not drawn("页面出错"), "empty list hint")
Panel.set_open(false)
Panel.ui.page = "basic"
SKS.call("set_setting", { key = "advanced", value = false })
ticks(1)
set_channels(saved_channels)
print("DRIVERS FAILS:", dfails)
