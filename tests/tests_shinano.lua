-- the shipped ShinanoOC condition set (user/conditions/ShinanoOC.json): loads, and the priority
-- order picks the intended clip
local SKS = require("ShapeKeySystem_Core.API")
local CE = require("ShapeKeySystem_Core.CondExpr")
local st = SKS.state
local sf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[shinano] " .. what)
    if not cond then sf = sf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function wait(sec) local t = os.clock() + sec; while os.clock() < t do end end
local function run_for(sec) local t = os.clock() + sec; while os.clock() < t do wait(0.02); ticks(1) end end

CE.load_all()
check(CE.find("ShinanoOC") ~= nil, "ShinanoOC set found")
check(SKS.call("cond_select", { name = "ShinanoOC", discard = true }), "cond_select ShinanoOC")
local d = CE.current and CE.current.data
check(d and #d.states == 17, "17 states")
local n = 0; for _ in pairs(d and d.clips or {}) do n = n + 1 end
check(n == 17, "17 clips")
local function reset()
    HSTATE.get_IsCombat, HSTATE.get_IsCombatBoss, HSTATE.get_IsInBaseCamp, HSTATE._IsWeaponOn = false, false, false, false
    HEALTH.hp, HEALTH.dead = HEALTH.max, false
end
local function playing() return CE.playing end
reset(); run_for(0.1)
check(playing() == nil, "idle -> no clip (pure game expression)")
HSTATE.get_IsInBaseCamp = true; run_for(0.1)
check(playing() == "日常", "base camp -> 日常 (" .. tostring(playing()) .. ")")
HSTATE.get_IsCombat = true; run_for(0.1)
check(playing() == "专注", "combat outranks 日常 -> 专注 (" .. tostring(playing()) .. ")")
HSTATE.get_IsCombatBoss = true; run_for(0.1)
check(playing() == "认真", "boss fight -> 认真 (" .. tostring(playing()) .. ")")
HEALTH.hp = math.floor(HEALTH.max * 0.25); run_for(0.1)
check(playing() == "吃痛", "the hit itself -> 吃痛 first (" .. tostring(playing()) .. ")")
run_for(0.9)
check(playing() == "濒危", "after the 0.7 s hold, low HP -> 濒危 (" .. tostring(playing()) .. ")")
HEALTH.dead = true; run_for(0.1)
check(playing() == "力尽", "down -> 力尽 outranks everything (" .. tostring(playing()) .. ")")
reset(); run_for(2.3)
check(playing() == nil, "all clear (after the combat holds) -> no clip (" .. tostring(playing()) .. ")")
SKS.call("cond_select", { name = "", discard = true })
print("SHINANO FAILS:", sf)
