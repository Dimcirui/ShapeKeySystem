-- public API for other plugins (_G.ShapeKeySystemAPI)
local SKS = require("ShapeKeySystem_Core.API")
local st = SKS.state
local afails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[api] " .. what)
    if not cond then afails = afails + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function mesh_idx(key)
    for i, n in ipairs(CHANNELS) do
        local short = n:match("([^%.]+)$")
        if short == key then return i - 1 end
    end
end
local function wait(sec) local t = os.clock() + sec; while os.clock() < t do end end

local api = ShapeKeySystemAPI
check(type(api) == "table" and api.version == "1.1" and api == SKS.public, "global ShapeKeySystemAPI published")
SKS.call("rescan"); ticks(80)
local list = api.channels()
check(#list > 0 and api.is_ready(), "channels() lists the worn keys")
local self_key, expr_key
for _, c in ipairs(list) do
    if c.expression and not expr_key then expr_key = c.name end
    if not c.expression and not self_key then self_key = c.name end
end
print("  keys:", self_key, expr_key)
check(self_key and expr_key, "one sculpt key and one expression key available")

-- sculpt key override
local si = mesh_idx(self_key)
local ok = api.set("TestMod", self_key, 0.7)
ticks(2)
check(ok and math.abs((WEIGHTS[si] or -1) - 0.7) < 1e-6, "set() overrides a sculpt key on the mesh")
local v, ctl = api.get(self_key)
check(v == 0.7 and ctl == "external:TestMod", "get() reports value and controller")
check(#st.external.held == 1 and st.external.held[1].owner == "TestMod", "state.external lists the held key")
check(st.external.by_norm[self_key:gsub("[%s_%-%.]", ""):lower()] == "TestMod", "state.external.by_norm")

-- the panel can't move it: the sculpt value changes underneath, the mesh keeps the external value
SKS.call("set_sculpt_key", { name = self_key, value = 0.2 }); ticks(2)
check(math.abs(WEIGHTS[si] - 0.7) < 1e-6, "external beats the sculpt value")

-- last owner wins; a non-owner cannot release
api.set("OtherMod", self_key, 0.4); ticks(2)
check(select(2, api.get(self_key)) == "external:OtherMod" and math.abs(WEIGHTS[si] - 0.4) < 1e-6, "last owner wins")
api.release("TestMod", self_key); ticks(2)
check(select(2, api.get(self_key)) == "external:OtherMod", "release by a non-owner is ignored")

-- lease expiry gives the key back (sculpt value 0.2)
api.set("OtherMod", self_key, 0.5, { ttl = 0.05 }); ticks(1)
wait(0.08); ticks(2)
check(api.get(self_key) == 0.2 and math.abs(WEIGHTS[si] - 0.2) < 1e-6, "expired lease returns the key to the sculpt layer")
check(#st.external.held == 0, "state.external empty after expiry")

-- ttl 0 holds until release
api.set("TestMod", self_key, 0.9, { ttl = 0 }); wait(0.6); ticks(2)
check(math.abs(WEIGHTS[si] - 0.9) < 1e-6, "ttl 0 does not expire")
api.release_all("TestMod"); ticks(2)
check(math.abs(WEIGHTS[si] - 0.2) < 1e-6, "release_all gives keys back")

-- expression key override, by canonical or mesh spelling
local ei = mesh_idx(expr_key)
api.set("TestMod", expr_key, 1.0, { ttl = 0 }); ticks(2)
check(math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "set() overrides an expression-driven key")
local before = WEIGHTS[ei]
api.release("TestMod", expr_key); FC[1] = 0.002; ticks(3)
check(WEIGHTS[ei] ~= before, "release returns the key to the expression layer")

-- clamp + bad args
api.set("TestMod", self_key, 9, { ttl = 0 }); ticks(1)
check(api.get(self_key) == require("ShapeKeySystem_Core.Sculpt").RANGE[2], "values clamp to the sculpt cap")
api.release_all("TestMod")
local r1, c1 = api.set("", self_key, 0.1)
local r2, c2 = api.set("TestMod", self_key, "x")
local r3, c3 = api.set("TestMod", self_key, 0.1, { ttl = -1 })
check(not r1 and not r2 and not r3 and c1 == "E_BAD_ARGS" and c2 == "E_BAD_ARGS" and c3 == "E_BAD_ARGS", "bad arguments rejected")

-- scan event
local fired = 0
local id = api.on("scan", function() fired = fired + 1 end)
SKS.call("rescan"); ticks(3)
check(fired == 1, "on('scan') fires after a scan")
api.off(id); SKS.call("rescan"); ticks(3)
check(fired == 1, "off() removes the listener")
local bad_id = api.on("scan", function() error("boom") end)
SKS.call("rescan"); ticks(3)
check(true, "a failing listener does not break the scan")
api.off(bad_id)
-- expression + sculpt on the same key: sculpt is the rest position, the expression remaps onto it
local Sculpt = require("ShapeKeySystem_Core.Sculpt")
check(Sculpt.mix(0.4, 0) == 0.4 and math.abs(Sculpt.mix(0.4, 0.5) - 0.7) < 1e-9 and Sculpt.mix(0.4, 1) == 1 and Sculpt.mix(0, 0.3) == 0.3,
    "mix(s, e) = s + (1 - s) e")
ok = SKS.call("set_sculpt_key", { name = expr_key, value = 0.4 })
check(ok, "an expression key accepts a sculpt value")
FC[1] = 0; ticks(3)
check(math.abs(WEIGHTS[ei] - 0.4) < 1e-6, "expression at rest -> the sculpt value (sleepy eyes)")
FC[1] = 0.005; ticks(3)
check(math.abs(WEIGHTS[ei] - 0.7) < 1e-6, "half blink -> 0.4 + 0.6 * 0.5 = 0.7")
FC[1] = 0.01; ticks(3)
check(math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "full blink still closes fully")
api.set("TestMod", expr_key, 0.25, { ttl = 0 }); ticks(2)
check(math.abs(WEIGHTS[ei] - 0.25) < 1e-6, "an external value is written as is (not mixed)")
api.release_all("TestMod")
SKS.call("set_sculpt_key", { name = expr_key, value = 0 }); FC[1] = 0.005; ticks(3)
check(math.abs(WEIGHTS[ei] - 0.5) < 1e-6, "sculpt 0 -> pure expression, as before")

-- panel: held keys are marked and can be taken back by the user
local Panel = require("ShapeKeySystem_UI.Panel")
api.set("TestMod", self_key, 0.6, { ttl = 0 }); ticks(2)
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return d end end end
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "sculpt"; frame()
Panel.ui.page_state.sculpt.filter = self_key; frame()   -- every key is listed: find it
check(find("由 TestMod 控制") ~= nil, "sculpt page marks the held key")
-- a key the selected key group option holds says so; set to 无 it is a normal row again
SKS.call("key_group_new", { name = "UI组" }); SKS.call("key_group_option_add", { group = "UI组", name = "开" })
SKS.call("key_group_assign", { group = "UI组", option = 1, names = { expr_key }, values = { [expr_key] = 0.4 } })
SKS.call("key_group_set", { group = "UI组", value = 1 })
Panel.ui.page_state.sculpt.filter = expr_key; frame()
check(find("键组「UI组」· 开") ~= nil, "sculpt page: a key held by a key group option names it")
SKS.call("key_group_set", { group = "UI组", value = 0 }); frame()
check(find("键组「UI组」· 开") == nil and find("键组「UI组」") ~= nil, "group at 无: the key is a normal row that names its group")
SKS.call("key_group_delete", { group = "UI组" })
Panel.ui.page_state.sculpt.filter = ""
-- 调试 tab: a tall window keeps the external control card in view
local win_h = Panel.ui.win.h
Panel.ui.page = "debug"; Panel.ui.page_state.debug = { tab = "debug" }; Panel.ui.win.h = 1060; frame()
local b = find("全部收回")
check(b ~= nil and find("TestMod") ~= nil, "debug page lists external control")
if b then MOUSE.x, MOUSE.y = b.x + 4, b.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(api.get(self_key) == 0.2 and #st.external.held == 0, "全部收回 takes the key back")
Panel.ui.win.h = win_h
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
-- v1.1: another plugin picks sculpt configs and key group options (sculpt layer, not leases)
do
    local Presets = require("ShapeKeySystem_Core.Presets")
    local before_values, before_overrides = Sculpt.export_values()
    local before_groups = Sculpt.export_groups()
    -- a second sculpt-only key for the group
    CHANNELS[#CHANNELS + 1] = "blendShape1.api_extra"
    SKS.call("rescan"); ticks(80)
    local key2 = "api_extra"
    local k2 = mesh_idx(key2)
    json.dump_file("ShapeKeySystem/user/sculpt/api_a.json", { schema = "sks.sculpt/1", name = "API_A",
        values = { [self_key] = 0.3, [key2] = 0 },
        key_groups = { { name = "G", value = 0, options = {
            { name = "on", values = { [key2] = 0.8 } }, { name = "half", values = { [key2] = 0.4 } } } } } })
    json.dump_file("ShapeKeySystem/user/sculpt/api_b.json", { schema = "sks.sculpt/1", name = "API_B",
        values = { [self_key] = 0.6 } })
    json.dump_file("ShapeKeySystem/user/sculpt/api_c.json", { schema = "sks.sculpt/1", name = "API_C",
        values = { [self_key] = 0.5, [key2] = 0 },
        key_groups = { { name = "G", value = 0, options = {
            { name = "half", values = { [key2] = 0.5 } }, { name = "on", values = { [key2] = 0.7 } } } } } })
    Presets.load_sculpt()
    local listed
    for _, e in ipairs(api.sculpt_presets()) do if e.name == "API_A" then listed = e end end
    check(listed and listed.folder == nil and listed.key_groups[1].name == "G" and listed.key_groups[1].options[2] == "half",
        "sculpt_presets() lists configs with their key groups and options")
    local gl = api.key_groups({ sculpt = "API_A" })
    check(gl and #gl == 1 and #gl[1].options == 2, "key_groups({sculpt}) lists a config's groups")
    local acts = api.actors()
    check(#acts == 1 and acts[1].id == "" and acts[1].edited and api.actor_of({}) == "",
        "one character: actors() has one entry with id \"\", actor_of() gives \"\"")
    local r0, c0 = api.select_sculpt("AVM", "API_A", { actor = "leon" })
    check(not r0 and c0 == "E_NOT_FOUND", "one character: opts.actor other than \"\" is refused")
    local r1, c1 = api.select_sculpt("AVM", "nope")
    local r2, c2 = api.select_sculpt("", "API_A")
    local r3, c3 = api.select_group_option("AVM", "G", -1)
    check(not r1 and c1 == "E_NOT_FOUND" and not r2 and c2 == "E_BAD_ARGS" and not r3 and c3 == "E_BAD_ARGS",
        "select_*: unknown config and bad arguments are refused")

    local events = {}
    local ev = api.on("selection", function(info) events[#events + 1] = info end)
    local ok1, _, _, res = api.select_sculpt("AVM", "API_A")
    ticks(3)
    check(ok1 and res.applied and math.abs(WEIGHTS[si] - 0.3) < 1e-6, "select_sculpt loads the config onto the mesh now")
    check(st.sculpt.preset and st.sculpt.preset.name == "API_A" and not st.sculpt.dirty,
        "the picked config shows as current and counts as saved")
    check(#events == 1 and events[1].sculpt == "API_A" and events[1].owner == "AVM" and #events[1].errors == 0,
        "on('selection') reports the applied pick")
    check(api.get(self_key) == 0.3 and select(2, api.get(self_key)) == "sculpt", "the value stays a sculpt value")
    check(SKS.call("set_sculpt_key", { name = self_key, value = 0.35 }), "the user can still edit a picked config's keys")

    local og, cg = api.select_group_option("AVM", "G", "nope")
    local og2, cg2 = api.select_group_option("AVM", "X", 1)
    check(not og and cg == "E_NOT_FOUND" and not og2 and cg2 == "E_NOT_FOUND", "unknown option / group of the edited character refused")
    check(api.select_group_option("AVM", "G", "half"), "select_group_option by option name"); ticks(3)
    check(math.abs(WEIGHTS[k2] - 0.4) < 1e-6 and api.key_groups()[1].value == 2, "the option's fixed value is written")
    api.select_group_option("AVM", 1, 1); ticks(3)
    check(math.abs(WEIGHTS[k2] - 0.8) < 1e-6, "group and option by index")
    local sel = api.selection()
    check(sel and sel.sculpt == "API_A" and sel.groups.G == 1 and sel.groups[1] == nil and not sel.pending,
        "selection() reports the pick, kept by group name")

    -- the same pick again keeps the user's edits; force loads it again
    local okc, _, _, rc = api.select_sculpt("AVM", "API_A")
    check(okc and rc.unchanged and api.get(self_key) == 0.35, "picking the config already picked keeps the user's edit")
    api.select_sculpt("AVM", "API_A", { force = true }); ticks(3)
    local last = st.runtime.notices[#st.runtime.notices]
    check(api.get(self_key) == 0.3 and last and last.text:find("AVM", 1, true) and last.text:find("API_A", 1, true),
        "force reloads it; replaced edits get a notice")
    check(SKS.call("sculpt_undo") and api.get(self_key) == 0.35, "one undo brings the replaced edit back")

    -- the user's own choice ends the pick
    api.select_sculpt("AVM", "API_A", { force = true }); api.select_group_option("AVM", "G", "on")
    SKS.call("key_group_set", { group = "G", value = 0 })
    sel = api.selection()
    check(sel and sel.sculpt == "API_A" and sel.groups.G == nil, "switching a key group by hand drops that group's pick")
    -- option picks follow the character into other configs by group name
    api.select_group_option("AVM", "G", "on")
    local ev2 = {}
    local id2 = api.on("selection", function(info) ev2[#ev2 + 1] = info end)
    SKS.call("load_sculpt", { name = "API_A" }); ticks(3)
    sel = api.selection()
    check(sel and sel.sculpt == "API_A" and sel.groups.G == "on" and math.abs(WEIGHTS[k2] - 0.8) < 1e-6,
        "loading the picked config by hand keeps the config and option picks")
    SKS.call("load_sculpt", { name = "API_C" }); ticks(3)
    sel = api.selection()
    check(sel and sel.sculpt == nil and sel.groups.G == "on", "loading another config by hand ends the config pick, keeps the option pick")
    check(math.abs(WEIGHTS[k2] - 0.7) < 1e-6 and api.key_groups()[1].value == 2, "the option pick is applied to the new config's group by name")
    check(ev2[#ev2] and ev2[#ev2].config == "API_C" and #ev2[#ev2].errors == 0, "on('selection') reports the apply in the new config")
    local n_ev = #ev2
    SKS.call("load_sculpt", { name = "API_B" }); ticks(3)
    sel = api.selection()
    check(sel and sel.groups.G == "on" and sel.skipped[1] == "G", "a config without the group: the pick is skipped and kept")
    check(#ev2 == n_ev + 1 and ev2[#ev2].errors[1] and ev2[#ev2].errors[1].group == "G", "the skipped group is reported in errors")
    SKS.call("load_sculpt", { name = "API_A" }); ticks(3)
    check(math.abs(WEIGHTS[k2] - 0.8) < 1e-6 and #api.selection().skipped == 0, "back to a config with the group: the pick applies again")
    n_ev = #ev2
    SKS.call("rescan"); ticks(4)
    check(#ev2 == n_ev, "a rescan does not report the same state again")
    SKS.call("save_sculpt", { name = "API_D", general = true })
    check(api.selection() and api.selection().groups.G == "on", "saving under another name keeps the option pick")
    SKS.call("load_sculpt", { name = "API_A" })
    api.clear_selection("AVM"); ticks(3)
    check(api.selection() == nil and api.key_groups()[1].value == 0 and math.abs(WEIGHTS[k2]) < 1e-6,
        "clear_selection of option picks: the groups go back to the config's saved option")
    -- the binding brings another config (groups no one edited): the pick follows by name
    api.select_group_option("AVM", "G", "on")
    Sculpt.K.groups_touched = false
    local okb, _, _, bres = SKS.call("bind_config", { kind = "sculpt", name = "API_C" }); ticks(4)
    check(okb and api.key_groups()[1].options[1] == "half" and api.key_groups()[1].value == 2 and math.abs(WEIGHTS[k2] - 0.7) < 1e-6,
        "a config the binding brings gets the option pick by name")
    Presets.tombstone_binding(bres.base or Presets.binding_base(st.scene.parts[1].id))
    api.clear_selection("AVM")
    SKS.call("rescan"); ticks(4)
    api.off(id2)

    -- before the scan: queued, applied once the keys are there
    local keys = Sculpt.K.keys
    Sculpt.K.keys = {}
    local okq, _, _, rq = api.select_sculpt("AVM", "API_A")
    local okg = api.select_group_option("AVM", "G", "half")
    Sculpt.K.keys = keys
    check(okq and not rq.applied and okg and api.selection().pending, "called before the scan: queued")
    events = {}
    SKS.call("rescan"); ticks(4)
    check(math.abs(WEIGHTS[si] - 0.3) < 1e-6 and math.abs(WEIGHTS[k2] - 0.4) < 1e-6 and not api.selection().pending,
        "the scan that brings the keys applies the queued config, then the option")
    check(#events == 1 and events[1].groups.G == 2, "on('selection') after the queued pick")
    SKS.call("rescan"); ticks(4)
    check(#events == 1 and not st.sculpt.dirty, "later scans do not apply it again")

    -- a pick no one edited goes back to the binding's config (none here: mod defaults) on clear
    api.clear_selection("Other")
    check(api.selection() ~= nil, "clear_selection leaves other owners' picks")
    api.clear_selection("AVM"); ticks(3)
    check(api.selection() == nil and api.get(self_key) == Sculpt.K.by_name[self_key].default,
        "clear_selection: an unedited pick returns to the defaults")
    api.select_sculpt("AVM", "API_A"); SKS.call("set_sculpt_key", { name = self_key, value = 0.45 })
    api.clear_selection("AVM")
    check(api.get(self_key) == 0.45, "clear_selection: an edited pick keeps the values on screen")
    api.off(ev)
    Sculpt.apply_preset({ values = before_values, overrides = before_overrides, key_groups = before_groups or {} })
    Sculpt.mark_saved()
    CHANNELS[#CHANNELS] = nil
    SKS.call("rescan"); ticks(80)
end
print("API FAILS:", afails)
