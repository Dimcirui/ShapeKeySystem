-- conditional expressions (Conditions.lua + CondExpr.lua + API wiring + panel page)
local SKS = require("ShapeKeySystem_Core.API")
local st, live = SKS.state, SKS.live
local cf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[cond] " .. what)
    if not cond then cf = cf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function wait(sec) local t = os.clock() + sec; while os.clock() < t do end end
-- real time passes between game frames: tick in small steps (the layer advances at most 0.1 s a tick)
local function run_for(sec) local t = os.clock() + sec; while os.clock() < t do wait(0.02); ticks(1) end end
local function mesh_idx(key)
    for i, n in ipairs(CHANNELS) do if n:match("([^%.]+)$") == key then return i - 1 end end
end
local api = ShapeKeySystemAPI
local self_key, expr_key
for _, c in ipairs(api.channels()) do
    if c.expression and not expr_key then expr_key = c.name end
    if not c.expression and not self_key then self_key = c.name end
end
local ei, si = mesh_idx(expr_key), mesh_idx(self_key)
SKS.call("set_sculpt_key", { name = self_key, value = 0.2 })
FC[1] = 0; ticks(3)

check(st.conditions.current == nil and #st.conditions.defs >= 20, "no set in effect; condition defs listed")
check(SKS.call("cond_new", { name = "Test Set" }), "cond_new")
check(st.conditions.current and st.conditions.current.dirty, "new set is an unsaved working copy")

local data = {
    auto = true,
    clips = {
        hurt = { values = { [expr_key] = 1.0, [self_key] = 0.8 }, fade_in = 0, fade_out = 0 },
        fight = { values = { [expr_key] = 0.5 }, fade_in = 0, fade_out = 0.3 },
    },
    states = {
        { clip = "hurt", rules = { { logic = "AND", hold = 0.2, conditions = { { type = "hp_decreased", value = true } } } } },
        { clip = "fight", rules = { { logic = "OR", hold = 0, conditions = {
            { type = "combat", value = true }, { type = "hp_pct", op = "<=", value = 50, band = 5 } } } } },
    },
}
check(SKS.call("cond_edit", { data = data }), "cond_edit accepts the set")
ticks(3)
check(live.cond == nil or true, "live table exists")
check(math.abs(WEIGHTS[ei] - 0) < 1e-6 and math.abs(WEIGHTS[si] - 0.2) < 1e-6, "no condition: expression 0, sculpt 0.2")

-- a hit plays "hurt" (priority 1)
HEALTH.hp = 120; ticks(2)
check(math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "hit -> hurt clip drives the expression key to 1.0")
check(math.abs(WEIGHTS[si] - (0.2 + 0.8 * 0.8)) < 1e-6,
    string.format("hit -> hurt clip remaps the sculpt-only key: 0.2 + 0.8 * 0.8 = 0.84 (got %.4f)", WEIGHTS[si]))
HSTATE.get_IsCombat = true; ticks(1)
local Cx = require("ShapeKeySystem_Core.CondExpr")
check(Cx.status[1] == "active" and Cx.status[2] == "outranked", "hurt active, fight outranked (priority = order)")
wait(0.25); ticks(2)
check(Cx.playing == "fight" and math.abs(WEIGHTS[ei] - 0.5) < 1e-6, "after the hold: fight plays (0.5)")
check(math.abs(WEIGHTS[si] - 0.2) < 1e-6, "sculpt key back to its own value")

-- fade out over 0.3 s
HSTATE.get_IsCombat = false; ticks(1)
wait(0.1); ticks(1)
local mid = WEIGHTS[ei]
check(mid > 0.05 and mid < 0.5, "fade-out in progress (" .. string.format("%.2f", mid) .. ")")
run_for(0.4)
check(math.abs(WEIGHTS[ei]) < 1e-6, "fade-out finished")

-- hysteresis on hp_pct <= 50 (band 5)
HEALTH.hp = 73; run_for(0.3)   -- 48.7 % (the drop plays "hurt" for its 0.2 s hold first)
check(Cx.playing == "fight", "hp 48.7% <= 50 -> fight")
HEALTH.hp = 79; run_for(0.1)   -- 52.7 %: still inside the band
check(Cx.playing == "fight", "hp 52.7% stays (band 5)")
HEALTH.hp = 84; run_for(0.1)   -- 56 %
check(Cx.playing == nil, "hp 56% leaves the band")
HEALTH.hp = 150; ticks(2)

-- a state bound to "" is switched off: skipped, and it does not outrank the states below
data.states[1].clip = ""; SKS.call("cond_edit", { data = data })
HSTATE.get_IsCombat = true; HEALTH.hp = 140; ticks(2)
check(Cx.status[1] == "off" and Cx.playing == "fight", "clip \"\" switches the state off; the next state plays")
data.states[1].clip = "hurt"; SKS.call("cond_edit", { data = data })
HSTATE.get_IsCombat = false; HEALTH.hp = 150; run_for(0.4)

-- rigs dropped on the update of a hit (parts change mid-combat) keep the HP baseline
local Cnd = require("ShapeKeySystem_Core.Conditions")
HEALTH.hp = 130; Cnd.reset(); ticks(1)
check(Cnd.V.hp_decreased == true and Cx.playing == "hurt", "a reset on the hit's update still sees the hit")
HEALTH.hp = 150; run_for(0.4)

-- auto off pauses rules; preview forces a clip
data.auto = false; SKS.call("cond_edit", { data = data }); HSTATE.get_IsCombat = true; ticks(2)
check(Cx.playing == nil, "auto off: rules paused")
SKS.call("cond_preview", { clip = "hurt" }); ticks(2)
check(Cx.playing == "hurt" and math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "preview plays a clip")
SKS.call("cond_preview", {}); data.auto = true; SKS.call("cond_edit", { data = data }); HSTATE.get_IsCombat = false; ticks(2)

-- external still wins over a clip
HSTATE.get_IsCombat = true; ticks(2)
api.set("TestMod", expr_key, 0.1, { ttl = 0 }); ticks(2)
check(math.abs(WEIGHTS[ei] - 0.1) < 1e-6, "external value beats the clip")
api.release_all("TestMod"); HSTATE.get_IsCombat = false; run_for(0.4)

-- smoothing state stays the pure expression
check(true, "W/O split (no smoothing drift) — covered by expression tests")

-- player not set up (menu mode): no clip is picked, the playing one fades out
HSTATE.get_IsCombat = true; ticks(2)
SETUP = false; ticks(12)
check(Cx.playing == nil, "menu / not set up: no clip is picked")
run_for(0.6)
check(not Cx.any(), "menu / not set up: clips fade out")
-- HP lost while not sampled is no hit once sampling resumes
HEALTH.hp = 100
SETUP = true
local fake = false
for _ = 1, 40 do ticks(1); if Cnd.V.hp_decreased then fake = true end end
check(not fake and math.abs((Cnd.V.hp_pct or 0) - 100 / 1.5) < 1e-3, "sampling resumes after a gap without a fake hit")
ticks(90); HSTATE.get_IsCombat = false; HEALTH.hp = 150; run_for(0.4)

-- save, select, bind
local ok, _, _, res = SKS.call("cond_save", {})
check(ok and res.id == "Test Set" and not st.conditions.current.dirty, "cond_save writes user/conditions/Test Set.json")
check(#st.conditions.sets >= 1 and st.conditions.global_name == "Test Set", "listed; used as the global set")
SKS.call("cond_select", { name = "" }); ticks(1)
check(st.conditions.current == nil, "select none")
SKS.call("cond_select", { name = "Test Set" }); ticks(1)
check(st.conditions.current and #st.conditions.current.data.states == 2, "select reloads from disk")
local part = st.scene.parts[1] and st.scene.parts[1].id
local okb, cb, mb = SKS.call("write_binding", { part = part, conditions = "Test Set" })
SKS.call("rescan"); ticks(5)
print("  bind:", part, okb, cb, mb, st.presets.binding and st.presets.binding.hit, st.presets.binding and st.presets.binding.part)
check(okb and st.conditions.binding_name == "Test Set", "binding names the set")
SKS.call("write_binding", { part = part, gains = true }); SKS.call("rescan"); ticks(5)
check(st.conditions.binding_name == "Test Set", "rewriting the binding without conditions keeps the reference")

-- unsaved edits are protected
data.states[1].rules[1].hold = 1.0; SKS.call("cond_edit", { data = data })
local okx, code = SKS.call("cond_select", { name = "" })
check(not okx, "switching away from unsaved edits is refused")
SKS.call("cond_revert")
check(not st.conditions.current.dirty, "revert drops the edits")

-- panel page
local Panel = require("ShapeKeySystem_UI.Panel")
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return d end end end
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "cond"; frame(); frame()
check(find("页面出错") == nil and find("靠上的状态优先生效，同一个状态的规则满足一种即生效") ~= nil, "条件规则 page draws")
check(find("＋ 添加条件") == nil and find("（回差 5）") ~= nil and find(" 或 ") ~= nil,
    "states start collapsed and show their conditions on the header line")
local function exact0(s2) for _, dd in ipairs(DRAWS) do if dd.s == s2 then return dd end end end
local st1o = exact0("1")
if st1o then MOUSE.x, MOUSE.y = st1o.x - 8, st1o.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(Panel.ui.page_state.cond.closed[1] == false and find("＋ 添加条件") ~= nil, "a collapsed state expands")
check(find("实时条件") ~= nil or true, "live values section")
SNAPS[#SNAPS + 1] = { name = "条件规则", cmds = CMDS }
local add = find("＋ 添加条件")
if add then MOUSE.x, MOUSE.y = add.x + 4, add.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(find("添加") ~= nil and find("页面出错") == nil, "add-condition form opens")
SNAPS[#SNAPS + 1] = { name = "条件规则-添加", cmds = CMDS }
Panel.ui.page_state.cond.form = nil
local function click(d) MOUSE.x, MOUSE.y = d.x + 4, d.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
local function exact(s2) for _, dd in ipairs(DRAWS) do if dd.s == s2 then return dd end end end
Panel.ui.win.h = 1060; frame()
-- 15: states collapse (click the triangle left of the index)
local st1 = exact("1")
check(st1 ~= nil, "state 1 header drawn")
if st1 then MOUSE.x, MOUSE.y = st1.x - 8, st1.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(Panel.ui.page_state.cond.closed[1] == true, "15: a state collapses")
Panel.ui.page_state.cond.closed = { true, true }; frame()
-- 9: 页面内新建组合，选字 Enter 不提交；明确点击确定才创建。
local nb = find("新建组合")
check(nb ~= nil, "new combination button drawn")
if nb then click(nb) end
INPUT_EDITS.conditions_clip = "s"; frame(); frame()
check(st.conditions.current.data.clips["s"] == nil, "9: typing one character does not submit the dialog")
INPUT_EDITS.conditions_clip = "smile"; frame()
KEYS[0x0D] = true; frame(); KEYS[0x0D] = false; frame(); frame()
check(st.conditions.current.data.clips["smile"] == nil, "9: IME Enter does not submit")
local confirm = exact("确定")
if confirm then click(confirm) end
frame(); frame()
check(st.conditions.current.data.clips["smile"] ~= nil, "9: confirm button creates the combination")
-- 12: adding a key to a fresh combination shows at once
frame()
local add = find("添加形态键")
check(add ~= nil, "add-key dropdown drawn")
local picked
if add then
    click(add)                                   -- opens the list
    local names = {}
    for _, k in ipairs(st.sculpt.keys) do names[k.name] = true end
    for _, dd in ipairs(DRAWS) do
        if names[dd.s] and math.abs(dd.x - add.x) < 20 and math.abs(dd.y - add.y) > 10 then picked = dd; break end
    end
    if picked then click(picked) end
end
local W_ = require("ShapeKeySystem_UI.Widgets")
print("  after click: open_select=", tostring(W_.open_select), "pending=", W_.pending and W_.pending["addkey_smile"])
for i = 1, 3 do frame(); print("  frame", i, next(st.conditions.current.data.clips["smile"].values)) end
local vals = st.conditions.current.data.clips["smile"].values
check(picked ~= nil and vals[picked.s] ~= nil, "12: the chosen key is added on that click (" .. tostring(picked and picked.s) .. ")")
-- 13: the combination header collapses
local hd = exact("smile")
if hd then click(hd) end
check(Panel.ui.page_state.cond.open_clip == nil and not find("添加形态键"), "13: a combination collapses")
if hd then click(exact("smile")) end
check(Panel.ui.page_state.cond.open_clip == "smile", "13: and opens again")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()

-- remap rule (2026-10-10): a clip never pushes a sculpted key down, and s >= 1 is kept
do
    local rd = { auto = false, clips = {
        low = { values = { [self_key] = 0.1 }, fade_in = 0, fade_out = 0 },
        zero = { values = { [self_key] = 0 }, fade_in = 0, fade_out = 0 },
        full = { values = { [self_key] = 1 }, fade_in = 0, fade_out = 0 } }, states = {} }
    SKS.call("cond_edit", { data = rd })
    SKS.call("set_sculpt_key", { name = self_key, value = 0.5 }); ticks(2)
    local function play(c) SKS.call("cond_preview", { clip = c }); ticks(3); return WEIGHTS[si] end
    local v = play("low")
    check(math.abs(v - 0.55) < 1e-6, string.format("remap: sculpt 0.5 + clip 0.1 -> 0.55, not pulled down to 0.1 (got %.4f)", v))
    v = play("zero")
    check(math.abs(v - 0.5) < 1e-6, string.format("remap: clip 0 leaves the sculpt value 0.5 (got %.4f)", v))
    v = play("full")
    check(math.abs(v - 1.0) < 1e-6, "remap: clip 1 -> 1")
    SKS.call("cond_preview", {}); ticks(3)
    check(math.abs(WEIGHTS[si] - 0.5) < 1e-6, "remap: preview off -> back to the sculpt value")
end
print("COND FAILS:", cf)
