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
check(type(api) == "table" and api.version == "1.0" and api == SKS.public, "global ShapeKeySystemAPI published")
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
print("API FAILS:", afails)
