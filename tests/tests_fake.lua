-- its own runtime: a made-up adapter that only finds the character, the face and the parts (no
-- dictionary, raw channels, gate, hooks, conditions or input). Sculpt and presets still work,
-- every expression channel reads "no signal", nothing errors.
local Fake = {
    id = "fake", name = "Fake",
    primary_root = function() return ROOT end,
    is_face = function(tr) return tr._name == "Player_Face" end,
    face_rank = function() return 1 end,
    is_part = function(name) return name:find("^ch03") ~= nil end,
    eye_joints = function() return {} end,
}
package.loaded["ShapeKeySystem_Games.Registry"] = {
    list = { Fake },
    game_name = function() return "fake" end,
    pick = function(g) return g == "fake" and Fake or nil end,
}
dofile(ENTRY)
package.searchers[2] = function(name) return "autorun module after load: " .. name end

local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local ff = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[fake] " .. what)
    if not cond then ff = ff + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function frame() CB.tick(); CB.frame(); DRAWS = {}; CB.d2d_draw() end
local function find(t) for _, d in ipairs(DRAWS) do if d.s:find(t, 1, true) then return d end end end
local function tick_ok() return not tostring(st.debug.status):find("tick error", 1, true) end

check(SKS.adapter == Fake and next(HOOKS) == nil, "the fake adapter is in use, no hooks")
ticks(60)
check(tick_ok(), "ticks run (" .. tostring(st.debug.status) .. ")")
local ex = st.expression
-- the channels left are eye nodes (no eye joints here) and channels without a source ("—")
local live, n_none = {}, 0
for _, c in ipairs(ex.channels) do
    local src = tostring(c.source_text)
    if c.no_signal then n_none = n_none + 1
    elseif src ~= "—" and not src:find("^eye%.") then live[#live + 1] = c.name end
end
check(ex.profile and ex.profile.id == "arkit" and n_none > 0 and #live == 0,
    "no dictionary: ARKit loads, every signal channel no_signal " .. table.concat(live, ", "))

SKS.call("sculpt_scan"); ticks(5)
local waist
for _, k in ipairs(st.sculpt.keys) do if k.name == "Waist_thin" then waist = k end end
check(waist ~= nil, "sculpt scan finds the part's keys")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.7 }); ticks(10)
check(math.abs((WEIGHTS[10] or 0) - 0.7) < 1e-6, "a sculpt value is written (" .. tostring(WEIGHTS[10]) .. ")")
check(SKS.call("save_sculpt", { name = "Fake Test" }), "save_sculpt")
local saved = false
for _, e in ipairs(st.presets.sculpt) do if e.name == "Fake Test" then saved = true end end
check(saved and tick_ok(), "the saved preset is listed")

SKS.call("set_setting", { key = "advanced", value = true })
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
for _, page in ipairs({ "basic", "sculpt", "expr", "cond", "debug" }) do
    Panel.ui.page = page; frame(); frame()
    check(not find("页面出错"), "page draws: " .. page)
end
print("FAKE FAILS:", ff)
