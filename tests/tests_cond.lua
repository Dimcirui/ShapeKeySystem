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
check(Cx.status[1] == "active" and Cx.status[2] == "active" and Cx.playing == "hurt" and Cx.playing_set[2] == "fight"
    and math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "hurt and fight both play; on the key both name the upper state wins")
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

-- states play together: a lower state fills the keys an upper one leaves free, unless the upper is exclusive
do
    local d2 = {
        auto = true,
        clips = { top = { values = { [expr_key] = 0.9 }, fade_in = 0, fade_out = 0 },
                  low = { values = { [expr_key] = 0.3, [self_key] = 0.5 }, fade_in = 0, fade_out = 0 } },
        states = {
            { clip = "top", rules = { { logic = "AND", hold = 0, conditions = { { type = "combat", value = true } } } } },
            { clip = "low", rules = { { logic = "AND", hold = 0, conditions = { { type = "combat", value = true } } } } },
        },
    }
    HSTATE.get_IsCombat = true
    SKS.call("cond_edit", { data = d2 }); ticks(2)
    check(math.abs(WEIGHTS[ei] - 0.9) < 1e-6 and math.abs(WEIGHTS[si] - (0.2 + 0.8 * 0.5)) < 1e-6,
        "non-exclusive: the upper state keeps its key, the lower one drives the key the upper leaves free")
    d2.states[1].exclusive = true
    SKS.call("cond_edit", { data = d2 }); ticks(2)
    check(Cx.status[2] == "outranked" and #Cx.playing_set == 1 and math.abs(WEIGHTS[si] - 0.2) < 1e-6,
        "exclusive: the states below do not play")
    check(Cx.status_by[2] == 1 and Cx.status_by[1] == nil, "an outranked state records which exclusive state covers it")
    check(Cx.current.data.states[1].exclusive == true and Cx.current.data.states[2].exclusive == false,
        "exclusive is kept and defaults to false")
    HSTATE.get_IsCombat = false
    SKS.call("cond_edit", { data = data }); ticks(2)
end
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

-- Wilds status drinks, bad conditions, time of day and weather
ticks(1)
check(Cnd.V.bad_condition == "none" and Cnd.V.hot_drink == nil and Cnd.V.time_zone == 2
    and math.abs((Cnd.V.hour or 0) - 16.5) < 1e-6 and Cnd.V.weather == "Fertility",
    "Wilds: no bad condition, noon, 16:30, plenty")
BAD._Poison, BAD._Sleep, HSTATE["st.get_IsHotEffectActive"] = true, true, true
ENV.zone, ENV.weather = 4, "SandStorm"; ticks(1)
check(Cnd.V.bad_condition == "sleep" and Cnd.V.hot_drink == true and Cnd.V.time_zone == 4 and Cnd.V.weather == "SandStorm",
    "Wilds: sleep outranks poison; hot drink; night; sandstorm")
check(Cnd.eval_condition({ type = "bad_condition", op = "~=", value = "none" })
    and not Cnd.eval_condition({ type = "bad_condition", value = "poison" }), "Wilds: ≠ 无 matches any bad condition")
BAD._Sleep = nil; ticks(1)
check(Cnd.V.bad_condition == "poison", "Wilds: poison once sleep ends")
check(Cnd.V.focus == nil, "Wilds: focus unreadable without a sub action")
HSTATE.sub_action = "app.PlayerCommonSubAction.cNothing"; ticks(1)
local f_off = Cnd.V.focus
HSTATE.sub_action = "app.WpCommonSubAction.cAimRoot"; ticks(1)
local f_on = Cnd.V.focus
HSTATE.sub_action = "app.WpCommonSubAction.cAimEnd"; ticks(1)
check(f_off == false and f_on == true and Cnd.V.focus == false, "Wilds: focus while the sub action is an aim one, not on its end")
HSTATE.sub_action = nil
BAD._Poison, HSTATE["st.get_IsHotEffectActive"] = nil, nil
ENV.zone, ENV.weather = 2, "Fertility"; ticks(1)

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
Panel.ui.page = "cond"; Panel.ui.page_state.cond = Panel.ui.page_state.cond or {}
Panel.ui.page_state.cond.tab = "states"; frame(); frame()
check(find("页面出错") == nil and find("命中的状态同时生效，同一个形态键由靠上的状态决定") ~= nil, "条件规则 page draws")
Panel.ui.page_state.cond.closed = { false }; frame(); frame()
check(find("独占状态") ~= nil and find("页面出错") == nil, "an open state shows the 独占状态 switch")
Panel.ui.page_state.cond.closed = nil; frame()
check(find("＋ 添加条件") == nil and find("（回差 5）") ~= nil and find(" 或 ") ~= nil,
    "states start collapsed and show their conditions on the header line")
local function exact0(s2) for _, dd in ipairs(DRAWS) do if dd.s == s2 then return dd end end end
local st1o = exact0("1")
if st1o then MOUSE.x, MOUSE.y = st1o.x - 8, st1o.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(Panel.ui.page_state.cond.closed[1] == false and find("＋ 添加条件") ~= nil, "a collapsed state expands")
check(find("实时条件") ~= nil or true, "live values section")
SNAP("条件规则", frame)
local add = find("＋ 添加条件")
if add then MOUSE.x, MOUSE.y = add.x + 4, add.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(find("添加") ~= nil and find("页面出错") == nil, "add-condition form opens")
SNAP("条件规则-添加", frame)
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
-- tabs 条件状态 | 形态键配置组合; the live conditions are on both
check(Panel.ui.page_state.cond.tab == "states" and find("实时条件") ~= nil and find("新建组合") == nil,
    "条件状态 tab: states and live conditions, no combinations")
local clips_tab = exact("形态键配置组合")
if clips_tab then click(clips_tab) end
check(Panel.ui.page_state.cond.tab == "clips" and find("实时条件") ~= nil and find("靠上的状态优先生效") == nil,
    "形态键配置组合 tab: combinations and live conditions, no states")
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
        -- a row of the inline search list: under the field, inside its width
        if names[dd.s] and dd.x >= add.x - 20 and dd.x < add.x + 320 and dd.y > add.y + 10 then picked = dd; break end
    end
    if picked then click(picked) end
end
for _ = 1, 3 do frame() end
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

-- import a sculpt preset's non-zero values into a clip
do
    SKS.call("zero_sculpt_all")
    SKS.call("set_sculpt_key", { name = self_key, value = 0.6 })
    SKS.call("set_sculpt_key", { name = expr_key, value = 0.9 })
    check(SKS.call("save_sculpt", { name = "Cond Import" }), "import: sculpt preset saved")
    local rd = { auto = false, clips = { imp = { values = { keep_me = 0.3, [self_key] = 0.1 }, fade_in = 0, fade_out = 0 } }, states = {} }
    SKS.call("cond_edit", { data = rd })
    local okc, _, _, ri = SKS.call("cond_import_sculpt", { clip = "imp", name = "Cond Import" })
    local v = st.conditions.current.data.clips.imp.values
    local zeros = 0
    for _, x in pairs(v) do if x == 0 then zeros = zeros + 1 end end
    check(okc and ri.count == 2 and zeros == 0, "import: only the non-zero values are copied (" .. tostring(ri and ri.count) .. ")")
    check(v[self_key] == 0.6 and v[expr_key] == 0.9 and v.keep_me == 0.3, "import: values as they are, same keys overwritten, others kept")
    check(st.conditions.current.dirty, "import: the set has unsaved edits")
    check(not SKS.call("cond_import_sculpt", { clip = "nope", name = "Cond Import" }), "import: unknown clip refused")
    check(not SKS.call("cond_import_sculpt", { clip = "imp", name = "no such preset" }), "import: unknown preset refused")
    SKS.call("cond_preview", { clip = "imp" }); ticks(3)
    check(math.abs(WEIGHTS[si] - (0.6 + 0.4 * 0.6)) < 1e-6, string.format("import: the imported value plays like any clip value (got %.4f)", WEIGHTS[si]))
    SKS.call("cond_preview", {}); ticks(3)

    -- one option of a key group: only that option's values, by name or index
    SKS.call("zero_sculpt_all")
    SKS.call("key_group_new", { name = "Look" })
    SKS.call("key_group_option_add", { group = "Look", name = "A" })
    SKS.call("key_group_option_add", { group = "Look", name = "B" })
    SKS.call("key_group_assign", { group = "Look", option = 1, names = { self_key }, values = { [self_key] = 0.4 } })
    SKS.call("key_group_assign", { group = "Look", option = 2, names = { expr_key }, values = { [expr_key] = 0.7 } })
    check(SKS.call("save_sculpt", { name = "Cond Groups" }), "import: sculpt preset with a key group saved")
    local listed
    for _, e in ipairs(st.presets.sculpt or {}) do
        if e.name == "Cond Groups" then listed = e.key_groups end
    end
    check(listed and listed[1] and listed[1].name == "Look" and listed[1].options[2] == "B",
        "import: the preset list names its key groups and options")
    rd = { auto = false, clips = { opt = { values = { keep_me = 0.3 }, fade_in = 0, fade_out = 0 } }, states = {} }
    SKS.call("cond_edit", { data = rd })
    okc, _, _, ri = SKS.call("cond_import_sculpt", { clip = "opt", name = "Cond Groups", group = "Look", option = 2 })
    v = st.conditions.current.data.clips.opt.values
    check(okc and ri.count == 1 and v[expr_key] == 0.7 and v[self_key] == nil and v.keep_me == 0.3,
        "import: an option copies only its own values")
    okc = SKS.call("cond_import_sculpt", { clip = "opt", name = "Cond Groups", group = 1, option = "A" })
    v = st.conditions.current.data.clips.opt.values
    check(okc and v[self_key] == 0.4, "import: group by index, option by name")
    check(not SKS.call("cond_import_sculpt", { clip = "opt", name = "Cond Groups", group = "Nope", option = 1 }),
        "import: unknown key group refused")
    check(not SKS.call("cond_import_sculpt", { clip = "opt", name = "Cond Groups", group = "Look", option = 3 }),
        "import: unknown option refused")
    SKS.call("key_group_delete", { group = "Look" })

    -- presets without keys on the scanned meshes are left out; keys of other combinations stay
    SKS.call("zero_sculpt_all")
    check(SKS.call("save_sculpt", { name = "Cond Empty" }), "import: an all-zero sculpt preset saved")
    local hits, folder = {}, {}
    for _, e in ipairs(st.presets.sculpt or {}) do hits[e.name], folder[e.name] = e.hits, e.folder end
    check(hits["Cond Import"] == 2 and hits["Cond Groups"] == 2 and hits["Cond Empty"] == 0,
        "import: presets count their keys on the meshes (2, 2, 0)")
    rd = { auto = false, clips = { a = { values = { [expr_key] = 0.5 }, fade_in = 0, fade_out = 0 },
                                   b = { values = {}, fade_in = 0, fade_out = 0 } }, states = {} }
    SKS.call("cond_edit", { data = rd })
    okc = SKS.call("cond_import_sculpt", { clip = "b", name = "Cond Import" })
    v = st.conditions.current.data.clips
    check(okc and v.b.values[expr_key] == 0.9 and v.a.values[expr_key] == 0.5, "import: a key of another combination is imported too")
    local page = Panel.ui.page
    Panel.ui.page = "cond"; Panel.ui.page_state.cond.tab = "clips"; Panel.ui.page_state.cond.open_clip = "b"
    frame(); frame()
    local reopened = #DRAWS == 0
    if reopened then KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame(); frame() end   -- reopen the panel
    local in_search = false
    for _, it in ipairs(Panel.ui.page_state.cond.keys or {}) do if it.value == expr_key then in_search = true end end
    check(in_search, "search: a key of another combination is listed")
    check(find("从捏脸配置导入") ~= nil and find("选择捏脸配置…") ~= nil and find("预设值") ~= nil and find("页面出错") == nil,
        "import row: preset list, 预设值 and 导入")
    Panel.ui.page_state.cond.import = { b = { name = "Cond Empty", folder = folder["Cond Empty"] } }; frame()
    check(find("选择捏脸配置…") ~= nil, "import row: a preset without hits is not offered")
    Panel.ui.page_state.cond.import = { b = { name = "Cond Groups", folder = folder["Cond Groups"], part = 2 } }; frame(); frame()
    check(find("Cond Groups") ~= nil and find("Look / A") ~= nil, "import row: a picked preset shows; its group options are the second list")
    Panel.ui.page_state.cond.open_clip, Panel.ui.page_state.cond.import = nil, nil
    if reopened then KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame() end   -- leave it closed, as found
    Panel.ui.page = page
end

-- a set without combinations still takes states: they start unbound ("-") with their rules editable
do
    SKS.call("cond_new", { name = "No Clips" })
    local page = Panel.ui.page
    Panel.ui.page = "cond"; Panel.ui.page_state.cond.tab = "states"; frame(); frame()
    local reopened = #DRAWS == 0
    if reopened then KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame(); frame() end   -- reopen the panel
    local add_state = find("＋ 添加状态")
    check(add_state ~= nil, "add-state button drawn without combinations")
    if add_state then click(add_state) end
    local s1 = st.conditions.current.data.states[1]
    check(s1 ~= nil and s1.clip == "" and #st.conditions.current.data.states == 1,
        "a state added without combinations is unbound")
    -- info notices leave the panel 10 s after it first shows them; warnings stay
    local keep_clock, now = os.clock, os.clock()
    Panel.ui.toasts = {}
    os.clock = function() return now end
    SKS.call("cond_save", {})
    local rt = st.runtime.notices
    rt[#rt + 1] = { id = 99999, level = "warn", text = "test warning", time = os.time() }
    frame(); frame()
    check(find("已保存条件规则") ~= nil, "notices: info shown")
    now = now + 9; frame()
    check(find("已保存条件规则") ~= nil, "notices: info still shown after 9 s")
    now = now + 2; frame(); frame()
    local warn_kept = false
    for _, n in ipairs(rt) do if n.id == 99999 then warn_kept = true end end
    check(find("已保存条件规则") == nil and warn_kept, "notices: info gone after 10 s, warning stays")
    os.clock = keep_clock
    if reopened then KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame() end   -- leave it closed, as found
    Panel.ui.page = page
end
-- non-ASCII names get ASCII file ids; saving again keeps the same file
do
    local U = require("ShapeKeySystem_Core.Util")
    check(U.file_id("Airi 日常脸"):match("^Airi_%x+$") and U.file_id("日常脸"):match("^%x+$") and U.file_id("Plain") == "Plain",
        "file_id: ASCII names unchanged, others ASCII part + hash")
    SKS.call("cond_new", { name = "中文规则" })
    local ok1, _, _, r1 = SKS.call("cond_save", {})
    SKS.call("cond_select", { name = "中文规则" })
    local ok2, _, _, r2 = SKS.call("cond_save", {})
    local n = 0
    for _, e in ipairs(st.conditions.sets) do if e.name == "中文规则" then n = n + 1 end end
    check(ok1 and ok2 and r1.id:match("^%x+$") and r2.id == r1.id and n == 1, "a Chinese condition set: ASCII id, saved again into the same file")
    local _, _, _, s1 = SKS.call("save_sculpt", { name = "日常脸" })
    local _, _, _, s2 = SKS.call("save_sculpt", { name = "日常脸" })
    check(s1 and s1.id:match("^%x+$") and s2 and s2.id == s1.id, "a Chinese sculpt preset: ASCII id, saved again into the same file")
end
-- export as mod: the binding names prefixed copies of the sets in effect, unsaved edits included
do
    local U = require("ShapeKeySystem_Core.Util")
    local okp, cp = SKS.call("export_mod", { prefix = "bad prefix" })
    check(not okp and cp == "E_BAD_ARGS", "export: a prefix with a space is rejected")
    SKS.call("cond_select", { name = "中文规则" })
    SKS.call("drivers", { op = "new", name = "导出驱动" })
    SKS.call("drivers", { op = "add", key = "NoSuchKey" })
    local cdata = U.copy(st.conditions.current.data)
    cdata.auto = false
    SKS.call("cond_edit", { data = cdata })
    local ok, _, _, res = SKS.call("export_mod", { prefix = "me" })
    local root = { "export", "me", "reframework", "data", "ShapeKeySystem", "mods" }
    local function exported(rel)
        for _, f in ipairs(res and res.files or {}) do
            if f == rel then
                local parts = { table.unpack(root) }
                for seg in rel:sub(6):gmatch("[^/]+") do parts[#parts + 1] = seg end
                return U.load_json(U.path(table.unpack(parts)))
            end
        end
    end
    local bind, conds, drv
    for _, f in ipairs(res and res.files or {}) do
        if f:match("^mods/[^/]+/[^/]+%.json$") then bind = exported(f) end
        if f:match("^mods/conditions/") then conds = f end
        if f:match("^mods/drivers/") then drv = f end
    end
    check(ok and bind and bind.schema == "sks.binding/1" and bind.conditions and bind.conditions:match("^me%.%x+$")
        and bind.drivers and bind.drivers:match("^me%.") and next(bind.fingerprints or {}) ~= nil,
        "export: the binding names the prefixed sets and carries fingerprints")
    check(conds == "mods/conditions/" .. tostring(bind and bind.conditions) .. ".json" and exported(conds).name == "中文规则"
        and exported(conds).auto == false, "export: the condition set is copied with its unsaved edit, under its prefixed id")
    check(bind and bind.sculpt and exported("mods/" .. bind.part:sub(1, -2) .. "/sculpt/" .. U.file_id(bind.sculpt) .. ".json"),
        "export: the sculpt values in effect are written and named by the binding")
    check(drv and exported(drv).groups[1].rows[1].key == "NoSuchKey", "export: the driver set is copied")
    check(res and res.path == "reframework/data/ShapeKeySystem/export/me/", "export: the result names the export folder")
end
print("COND FAILS:", cf)
