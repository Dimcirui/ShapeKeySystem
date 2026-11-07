-- shape key drivers (Drivers.lua): the formula parser, waveforms, driver groups (variables, rows
-- reading earlier rows, schema 1 files), leases owned by "drivers" and how they give way to mocap,
-- the 驱动 page
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
local function vrow(g, r) return st.drivers.groups[g].rows[r or 1] end
local function crow(g, r) return st.drivers.cfg.groups[g].rows[r or 1] end
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

-- comparisons and rand
check(near(ev("1 < 2"), 1) and near(ev("2 <= 1"), 0) and near(ev("3 >= 3"), 1) and near(ev("2 > 3"), 0),
    "comparisons give 1 or 0")
check(near(ev("1 == 1"), 1) and near(ev("1 != 2"), 1) and near(ev("1 ~= 1"), 0), "== and != (~= too)")
check(near(ev("1 + 1 > 1"), 1) and near(ev("2 * (1 < 2)"), 2) and near(ev("max(0, 1 >= 1)"), 1),
    "comparisons below arithmetic, inside brackets and arguments")
check(err_of("1 < 2 < 3") == "比较不能连写，请加括号" and near(ev("(1 < 2) < 3"), 1), "comparisons do not chain")
check(err_of("x = 1") == "无法识别的字符 %s", "a formula holds no assignment")
local seed0 = Dr.seed
Dr.seed = 7
local r1, r2, r3 = ev("rand(3.2)"), ev("rand(3.9)"), ev("rand(4)")
check(r1 and r1 >= 0 and r1 < 1 and near(r1, r2) and not near(r1, r3), "rand: same value within one whole number")
Dr.seed = 8
check(not near(ev("rand(3.2)"), r1), "rand: another seed gives another sequence")
Dr.seed = seed0

-- clip(name): a condition clip's weight along its fades
check(Dr.clip_progress == require("ShapeKeySystem_Core.CondExpr").alpha, "clip() reads the condition clips' weights")
local progress0 = Dr.clip_progress
Dr.clip_progress = function(id) return id == "aim" and 0.25 or 0 end
check(near(ev("clip(aim) * 2"), 0.5) and near(ev("clip(other)"), 0), "clip(name) gives that clip's weight, 0 for another")
check(err_of("clip(1)") and err_of("clip(1)"):find("clip", 1, true) and err_of("clip(a, b)") ~= nil and err_of("clip()") ~= nil,
    "clip takes exactly one bare name")
check(not Dr.valid_name("clip"), "clip is not a variable name")
Dr.clip_progress = progress0

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
check(ok and #st.drivers.cfg.groups == 1 and #st.drivers.cfg.groups[1].rows == 1 and crow(1).key == "Other"
    and crow(1).kind == "out", "add creates a group with one output row for the key")
ok, err = SKS.call("drivers", { op = "patch", index = 1, patch = { wave = "zigzag" } })
check(not ok and err == "E_BAD_ARGS" and crow(1).wave == "osc", "unknown wave rejected")
SKS.call("drivers", { op = "patch", index = 1, patch = { period = 999, lo = -1 } })
check(crow(1).period == 120 and crow(1).lo == 0, "numbers clamped to their limits (a group patch with row fields goes to row 1)")
SKS.call("drivers", { op = "patch", index = 1, patch = { wave = "expr", expr = "0.7" } })
check(vrow(1).err == nil and vrow(1).formula == "0.7", "formula driver compiled")
ticks(3)
local oi
for i, n in ipairs(CHANNELS) do if n:match("([^%.]+)$") == "Other" then oi = i - 1 end end
local _, owner = Ext.get("Other")
check(owner == "drivers" and near(vrow(1).value, 0.7), "the key is held by owner drivers")
check(oi and math.abs((WEIGHTS[oi] or -1) - 0.7) < 1e-3, "the driven value reaches the mesh")
local default_path = U.path("user", "drivers", "default.json")
check(U.load_json(default_path) == nil, "the file is written only after the edits settle")
Dr.flush()
local saved = U.load_json(default_path)
check(saved and saved.schema == "sks.drivers/2" and saved.name == "默认" and saved.groups[1].rows[1].expr == "0.7",
    "the first edit without a set creates and saves user/drivers/default.json")
check(st.drivers.current and st.drivers.current.id == "default" and #st.drivers.sets == 1, "默认 listed and selected")

-- driver sets: new, save as, select, a mods set saved as a user copy, delete, the old single file
local function settings_drivers() ticks(61); local s = U.load_json(U.path("settings.json")); return s and s.drivers end
ok, err = SKS.call("drivers", { op = "new", name = "默认" })
check(not ok and err == "E_EXISTS", "a set name already taken is rejected")
ok = SKS.call("drivers", { op = "save_as", name = "halo" })
check(ok and Dr.current.id == "halo" and #st.drivers.cfg.groups == 1 and U.load_json(U.path("user", "drivers", "halo.json")),
    "save_as copies the groups into a new set, written at once")
SKS.call("drivers", { op = "patch", index = 1, patch = { expr = "0.3" } })
SKS.call("drivers", { op = "new", name = "empty" })
check(#st.drivers.cfg.groups == 0 and U.load_json(U.path("user", "drivers", "halo.json")).groups[1].rows[1].expr == "0.3",
    "new starts empty; the previous set's pending edit is written first")
ticks(3)
check(Ext.get("Other") == nil, "switching sets lets the old set's keys go")
check(settings_drivers() == "empty", "the selected set goes to settings.json")
SKS.call("drivers", { op = "select", name = "halo" })
ticks(3)
check(near(Ext.get("Other"), 0.3), "select runs that set's groups")
U.save_json(U.path("mods", "drivers", "mod_halo.json"), { schema = "sks.drivers/2", name = "光环",
    groups = { { rows = { { kind = "out", key = "Other", wave = "expr", expr = "0.6" } } } } })
Dr.load_all()
ok = SKS.call("drivers", { op = "select", name = "光环" })
check(ok and Dr.current.source == "mods" and crow(1).expr == "0.6", "a mods set is found by its name")
ok, err = SKS.call("request_delete", { kind = "drivers", name = "mod_halo" })
check(not ok and err == "E_READONLY", "a mods set cannot be deleted")
SKS.call("drivers", { op = "patch", index = 1, patch = { expr = "0.65" } })
Dr.flush()
check(U.load_json(U.path("mods", "drivers", "mod_halo.json")).groups[1].rows[1].expr == "0.6"
    and U.load_json(U.path("user", "drivers", "mod_halo.json")).groups[1].rows[1].expr == "0.65"
    and Dr.current.source == "user", "editing a mods set saves a user copy of the same id; the mods file stays")
SKS.call("request_delete", { kind = "drivers", name = "empty" })
SKS.call("confirm_delete")
check(Dr.find("empty") == nil and Dr.current.id == "mod_halo", "deleting another set keeps the selected one")
SKS.call("request_delete", { kind = "drivers", name = "mod_halo" })
SKS.call("confirm_delete")
check(Dr.current.id == "mod_halo" and Dr.current.source == "mods" and crow(1).expr == "0.6",
    "deleting the user copy brings the mods set back")
SKS.call("drivers", { op = "select", name = "halo" })
SKS.call("request_delete", { kind = "drivers", name = "halo" })
SKS.call("confirm_delete")
check(Dr.current and Dr.current.id ~= "halo" and settings_drivers() == Dr.current.id,
    "deleting the selected set falls back to another one")
U.save_json(U.path("mods", "drivers", "mod_halo.json"), { deleted = true })
-- the single file of older versions becomes 默认 once, its master switch going to settings.json
U.save_json(default_path, nil)
U.save_json(U.path("user", "drivers.json"), { schema = "sks.drivers/2", enabled = false,
    groups = { { rows = { { kind = "out", key = "Other", wave = "expr", expr = "0.5" } } } } })
local id, on = Dr.start("")
check(id == "default" and on == false and crow(1).expr == "0.5" and U.load_json(default_path).name == "默认",
    "the old user/drivers.json is migrated to user/drivers/default.json")
U.save_json(default_path, { deleted = true })
Dr.load_all()
id = Dr.start("")
check(id ~= "default" and U.load_json(default_path).deleted == true, "a deleted 默认 is not migrated again")
U.save_json(U.path("user", "drivers.json"), nil)
Dr.load({ groups = { { rows = { { kind = "out", key = "Other", wave = "expr", expr = "0.7" } } } } })

-- a second driver on the same key is not applied; values above the cap are clamped
SKS.call("drivers", { op = "add", key = "other" })
SKS.call("drivers", { op = "patch", index = 2, patch = { wave = "expr", expr = "9" } })
ticks(1)
check(vrow(2).dup and vrow(2).dup[1] == 1 and vrow(2).dup[2] == 1 and near(Ext.get("Other"), 0.7),
    "a second driver on the same key is flagged, the first keeps it")
SKS.call("drivers", { op = "remove", index = 1 }); ticks(1)
check(#st.drivers.cfg.groups == 1 and near(Ext.get("Other"), st.settings.sculpt_max),
    "after removing the first, the second drives (clamped to sculpt_max)")

-- another owner holds the key: the driver waits
Ext.set("mocap", "Other", 0.3, 5)
ticks(1)
local v, o = Ext.get("Other")
check(o == "mocap" and near(v, 0.3) and vrow(1).owner == "mocap", "a key held by mocap is left to it")
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
check(vrow(1).err ~= nil and Ext.get("Waist_thin") == nil, "a formula with an error drives nothing")

-- the clock: dt adds up, a wave moves with it
Dr.load({ items = { { key = "Other", wave = "saw", period = 4, lo = 0, hi = 1 } } })
Dr.tick(1, 1); Dr.tick(1, 1)
check(near(Dr.view.groups[1].rows[1].value, 0.5) and near(Ext.get("Other"), 0.5), "saw at 2 s of a 4 s period is half way")
Dr.load({ enabled = "yes", items = { { key = 3, wave = "?", period = "x" }, "bad" } })
local c = Dr.config()
check(c.enabled == true and #c.groups == 2 and c.groups[1].rows[1].key == "" and c.groups[1].rows[1].wave == "osc"
    and c.groups[1].rows[1].period == 2, "a damaged file loads with defaults")
Dr.tick(0.1, 1)
check(Ext.get("Other") == nil, "loading a new list releases keys no driver names")

-- groups: variables, rows reading the rows above, one tick for all outputs
local function g1(r) return Dr.view.groups[1].rows[r] end
Dr.seed = 3
Dr.load({ schema = "sks.drivers/2", groups = { { rows = {
    { kind = "var", var = "u", wave = "expr", expr = "t % 10" },
    { kind = "var", var = "b", wave = "expr", expr = "1.5 + rand(floor(t / 10))" },
    { kind = "var", var = "blow", wave = "expr", expr = "u < b" },
    { kind = "out", key = "Other", wave = "expr", expr = "clamp(u, 0, 1) * blow" },
    { kind = "out", key = "Waist_thin", wave = "expr", expr = "0.5 * Other" },
} } } })
check(Dr.view.groups[1].rows[4].err == nil and Dr.view.groups[1].rows[5].err == nil, "a group compiles with names of earlier rows")
Dr.tick(0.6, 1)
check(near(g1(1).value, 0.6) and near(g1(3).value, 1) and near(Ext.get("Other"), 0.6) and near(Ext.get("Waist_thin"), 0.3),
    "variables feed the outputs; an output name is read by a later row")
for _ = 1, 30 do Dr.tick(0.1, 1) end
check(near(g1(3).value, 0) and near(Ext.get("Other"), 0) and near(Ext.get("Waist_thin"), 0),
    "a comparison switches the outputs off in the same tick")
check(Ext.get("u") == nil and Ext.get("blow") == nil, "variables hold no shape key")
-- names: forward references, bad names, the same name twice; any error stops the whole group
Dr.load({ groups = { { rows = {
    { kind = "out", key = "Other", wave = "expr", expr = "later" },
    { kind = "var", var = "later", wave = "expr", expr = "1" } } } } })
Dr.tick(0.1, 1)
check(g1(1).err and g1(1).err[1] == "未知名称 %s" and Ext.get("Other") == nil, "a row reads only names defined above it")
Dr.load({ groups = { { rows = {
    { kind = "var", var = "x", wave = "expr", expr = "1" }, { kind = "var", var = "x", wave = "expr", expr = "2" },
    { kind = "out", key = "Other", wave = "expr", expr = "0.4" } } } } })
Dr.tick(0.1, 1)
check(g1(2).err and g1(2).err[1] == "名称 %s 已在上面定义" and g1(3).err == nil and Ext.get("Other") == nil,
    "a name defined twice is an error, and the group's other outputs wait for it")
for _, bad in ipairs({ "t", "a", "pi", "sin", "2x", "x-y", "" }) do
    Dr.load({ groups = { { rows = { { kind = "var", var = bad, wave = "expr", expr = "1" } } } } })
    check(g1(1).err ~= nil, "variable name rejected: '" .. bad .. "'")
end
Dr.load({ groups = { { enabled = false, rows = { { kind = "out", key = "Other", wave = "expr", expr = "0.4" } } } } })
Dr.tick(0.1, 1)
check(Ext.get("Other") == nil and near(g1(1).value, 0), "a switched-off group writes nothing")

-- a group run by a condition clip: the halo hides at A, then spins in at B and slows to rest.
-- Four keys 90 degrees apart, weighted s * max(0, cos(phi - k * 90)), give one halo of size s at angle phi.
local P = 0
local progress1 = Dr.clip_progress
Dr.clip_progress = function(id) return id == "FY" and P or 0 end
local function hrow(kind, name, expr) return { kind = kind, var = kind == "var" and name or "", key = kind == "out" and name or "", wave = "expr", expr = expr } end
Dr.load({ groups = { { name = "halo", rows = {
    hrow("var", "p", "clip(FY)"),
    hrow("out", "Halo_Hide", "smoothstep(clamp(p / 0.35, 0, 1))"),
    hrow("var", "u", "clamp((p - 0.35) / 0.65, 0, 1)"),
    hrow("var", "s", "1 - (1 - u) ^ 2"),
    hrow("var", "phi", "-720 * (1 - u) ^ 3 * pi / 180"),
    hrow("out", "Spin000", "s * max(0, cos(phi))"),
    hrow("out", "Spin090", "s * max(0, cos(phi - pi / 2))"),
    hrow("out", "Spin180", "s * max(0, cos(phi - pi))"),
    hrow("out", "Spin270", "s * max(0, cos(phi - 1.5 * pi))") } } } })
local function halo(p)
    P = p; Dr.tick(0.016, 1)
    local r = Dr.view.groups[1].rows
    local w0, w1, w2, w3 = r[6].value, r[7].value, r[8].value, r[9].value
    return r[2].value, r[4].value, math.sqrt((w0 - w2) ^ 2 + (w1 - w3) ^ 2), math.atan(w1 - w3, w0 - w2)
end
local hide, size, radius = halo(0)
check(near(hide, 0) and near(radius, 0), "halo at rest: A shown, B hidden")
hide, size, radius = halo(0.35)
check(near(hide, 1) and near(radius, 0), "halo: A gone before B appears")
local ok_mid = true
for _, p in ipairs({ 0.45, 0.6, 0.8, 0.95 }) do
    hide, size, radius = halo(p)
    if not near(radius, size) then ok_mid = false end
end
check(ok_mid, "halo: B's size is exactly s at every angle while it spins")
hide, size, radius = halo(1)
local _, _, _, angle = halo(1)
check(near(radius, 1) and near(angle, 0) and near(Dr.view.groups[1].rows[6].value, 1), "halo: B ends full size at rest on Spin000")
Dr.clip_progress = progress1

-- ramp(target, in, out): a switch becomes a fade of its own length, each way
Dr.clip_progress = function(id) return id == "FY" and P or 0 end
Dr.load({ groups = { { rows = { hrow("var", "r", "ramp(clip(FY) > 0.5, 1.2, 0.4)") } } } })
local function ramp_after(p, sec)
    P = p
    for _ = 1, math.floor(sec / 0.05 + 0.5) do Dr.tick(0.05, 1) end
    return Dr.view.groups[1].rows[1].value
end
check(near(ramp_after(0, 1), 0), "ramp rests at 0")
check(near(ramp_after(1, 0.6), 0.5) and near(ramp_after(1, 0.6), 1) and near(ramp_after(1, 1), 1),
    "ramp rises over its fade-in and stays at the target")
check(near(ramp_after(0, 0.2), 0.5) and near(ramp_after(0, 0.2), 0), "ramp falls over its fade-out")
check(err_of("ramp(1, 2)") == "%s 需要 %s 个参数" and not Dr.valid_name("ramp"), "ramp takes three arguments and is not a variable name")
Dr.clip_progress = progress1

-- cond(id): a game condition read straight, past the states' priority; live = 0 lets the outputs go
local cond0, known0 = Dr.cond_value, Dr.cond_known
local CV = {}
Dr.cond_value = function(id) return CV[id] or 0 end
Dr.cond_known = function(id) return id ~= "nope" end
check(near(ev("cond(oni) * 2"), 0) and err_of("cond(nope)") == "没有 id 为 %s 的条件" and err_of("cond(1)") ~= nil
    and not Dr.valid_name("cond"), "cond(id) reads a condition; an unknown id is an error; cond is not a variable name")
Dr.load({ groups = { { name = "boost", rows = {
    hrow("var", "p", "ramp(cond(oni), 5, 1.5)"),
    hrow("var", "live", "p > 0"),
    hrow("out", "ChestPower", "1 - clamp((5 * p - 1) / 0.75, 0, 1)"),
    hrow("out", "HornAttack", "clamp((5 * p - 3) / 0.167, 0, 1)") } } } })
local function boost(on, sec)
    CV.oni = on
    for _ = 1, math.floor(sec / 0.05 + 0.5) do Dr.tick(0.05, 1) end
end
boost(0, 0.5)
local off_free = Ext.get("ChestPower") == nil and Ext.get("HornAttack") == nil
boost(1, 1.5)
local _, owner = Ext.get("ChestPower")
local chest_mid, horn_mid = Ext.get("ChestPower"), Ext.get("HornAttack")
boost(1, 4)
local chest_on, horn_on = Ext.get("ChestPower"), Ext.get("HornAttack")
boost(0, 1.6)
check(off_free and owner == "drivers" and near(chest_mid, 0.333333) and near(horn_mid, 0)
    and near(chest_on, 0) and near(horn_on, 1) and Ext.get("ChestPower") == nil and Ext.get("HornAttack") == nil,
    "live: keys free while off, driven through the timeline, free again once the fade-out ends")
local read_ids = Dr.cond_ids({})
check(read_ids.oni == true and next(read_ids, next(read_ids)) == nil, "cond_ids lists the conditions the drivers read")
Dr.cond_value, Dr.cond_known = cond0, known0

-- schema 1: each driver becomes a group of one output row
Dr.load({ schema = "sks.drivers/1", items = { { enabled = false, key = "Other", wave = "expr", expr = "0.2", actor = "ada" } } })
local mg = Dr.config().groups[1]
check(#Dr.config().groups == 1 and mg.enabled == false and mg.actor == "ada" and #mg.rows == 1 and mg.rows[1].kind == "out"
    and mg.rows[1].key == "Other" and mg.rows[1].expr == "0.2", "a schema 1 driver loads as a one-row group")

-- row commands
Dr.load({})
SKS.call("drivers", { op = "add", key = "Other" })
ok = SKS.call("drivers", { op = "add_row", index = 1, kind = "var" })
check(ok and crow(1, 2).kind == "var" and crow(1, 2).var == "x1", "add_row: a variable gets a free name")
SKS.call("drivers", { op = "add_row", index = 1, kind = "var" })
check(crow(1, 3).var == "x2", "the next variable takes the next free name")
SKS.call("drivers", { op = "patch", index = 1, row = 2, patch = { wave = "expr", expr = "0.25" } })
SKS.call("drivers", { op = "patch", index = 1, row = 1, patch = { wave = "expr", expr = "x1 * 2" } })
check(vrow(1, 1).err and vrow(1, 1).err[1] == "未知名称 %s", "the output above the variable cannot read it")
ok = SKS.call("drivers", { op = "move_row", index = 1, row = 2, to = 1 })
check(ok and crow(1, 1).var == "x1" and crow(1, 2).key == "Other" and vrow(1, 2).err == nil, "move_row: the variable moves above")
ticks(1)
check(near(Ext.get("Other"), 0.5), "the moved rows drive the key")
ok, err = SKS.call("drivers", { op = "patch", index = 1, row = 2, patch = { kind = "box" } })
check(not ok and err == "E_BAD_ARGS", "unknown row kind rejected")
ok, err = SKS.call("drivers", { op = "patch", index = 1, row = 9, patch = { expr = "1" } })
check(not ok and err == "E_NOT_FOUND", "patching a missing row is rejected")
ok, err = SKS.call("drivers", { op = "patch", index = 1, row = 2, patch = { expr = "1", period = "x" } })
check(not ok and err == "E_BAD_ARGS" and crow(1, 2).expr == "x1 * 2", "a rejected patch changes nothing")
SKS.call("drivers", { op = "patch", index = 1, patch = { name = "gum" } })
check(st.drivers.cfg.groups[1].name == "gum", "a group takes a name")
SKS.call("drivers", { op = "remove_row", index = 1, row = 1 })
check(#st.drivers.cfg.groups[1].rows == 2 and vrow(1, 1).err and vrow(1, 1).err[1] == "未知名称 %s",
    "remove_row: rows reading the removed name fail")
ticks(1)
check(Ext.get("Other") == nil, "and the group lets its key go")
SKS.call("drivers", { op = "remove", index = 1 })

-- page
Dr.load({ groups = {
    { name = "gum", rows = { { kind = "var", var = "u", wave = "tri", period = 3 },
                             { kind = "out", key = "Other", wave = "expr", expr = "u * (u < 0.8)" } } },
    { rows = { { key = "Other", wave = "expr", expr = "0.5" } } },
    { rows = { { key = "Waist_thin", wave = "expr", expr = "sin(" } } } } })
SKS.call("set_setting", { key = "advanced", value = true })
Panel.set_open(true)
Panel.ui.page = "drivers"
ticks(1)
-- a tall window: every card of the list is on screen
local h_page = Panel.ui.win.h
Panel.ui.win.h = 1400
DRAWS = {}; CB.d2d_draw()
local function drawn(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return true end end end
check(drawn("2 行，写入 Other") and drawn("1 行，有错误") and not drawn("相位") and not drawn("添加变量"),
    "groups start collapsed: one summary line each")
for _, grp in ipairs(Dr.config().groups) do Panel.ui.page_state.drivers.closed[grp] = false end
DRAWS = {}; CB.d2d_draw()
check(drawn("启用驱动") and drawn("添加驱动") and drawn("周期") and drawn("lerp(0, 1, tri(t / 3))") and drawn("改为公式"),
    "wave row drawn with its formula")
check(drawn("变量") and drawn("添加变量") and drawn("删除组") and drawn("上移"), "group card: kind picker, row buttons")
check(drawn("公式不完整") and drawn("第 1 组第 2 行") and not drawn("页面出错"), "formula error and duplicate shown")
-- key picker: a pick after typing a search holds, though ImGui reports the typed text once more
local function pframe() CB.tick(); CB.frame(); DRAWS, CMDS = {}, {}; CB.d2d_draw() end
local function drawn_at(text) for _, d in ipairs(DRAWS) do if d.s == text then return d end end end
local field = drawn_at("Other")
local function pclick(d) MOUSE.x, MOUSE.y = d.x + 4, d.y + 6; MOUSE.down = true; pframe(); MOUSE.down = false; pframe() end
if field then pclick(field) end
INPUT_EDITS["drv_key:1:2"] = "Wai"; pframe(); pframe()
local item = drawn_at("Waist_thin")
check(field ~= nil and item ~= nil and crow(1, 2).key == "Wai", "typing in the key picker searches and keeps the typed name")
if item then pclick(item) end
INPUT_EDITS["drv_key:1:2"] = "Wai"; pframe(); pframe()
check(crow(1, 2).key == "Waist_thin" and require("ShapeKeySystem_UI.Widgets").open_search == nil,
    "the first click on a search result picks it")
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
-- a non-ASCII name gets an ASCII file id; the name stays in the file and finds the set
ok = SKS.call("drivers", { op = "new", name = "光环" })
local cid = Dr.current and Dr.current.id or ""
local cfile = U.load_json(U.path("user", "drivers", cid .. ".json"))
check(ok and cid:match("^[%w_]+$") and cfile and cfile.name == "光环" and Dr.find("光环") and Dr.find("光环").id == cid,
    "a Chinese set name is saved under an ASCII file id")

-- a binding naming a driver set selects it; a set picked by hand lasts until the binding changes
SKS.call("drivers", { op = "new", name = "bind_a" })
SKS.call("drivers", { op = "new", name = "bind_b" })
local okb = SKS.call("bind_config", { kind = "drivers", name = "光环" })
SKS.call("rescan"); ticks(5)
check(okb and Dr.current and Dr.current.name == "光环" and st.drivers.binding_name == Dr.current.id,
    "bind_config drivers: the binding selects its set")
SKS.call("drivers", { op = "select", name = "bind_a" }); SKS.call("rescan"); ticks(5)
check(Dr.current.id == "bind_a" and settings_drivers() == "bind_b", "a pick by hand stays through scans and is not the global set")
local bpart = st.scene.parts[1] and st.scene.parts[1].id
SKS.call("restore_mod_binding", { part = bpart }); SKS.call("rescan"); ticks(5)
check(Dr.current.id == "bind_b" and st.drivers.binding_name == nil, "without the binding the global set comes back")
print("DRIVERS FAILS:", dfails)
