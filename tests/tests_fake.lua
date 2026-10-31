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
check(not st.playback.supported and st.playback.game == "fake", "no playback adapter: animation tests stay unavailable")
ticks(60)
check(tick_ok(), "ticks run (" .. tostring(st.debug.status) .. ")")
local ex = st.expression
-- the channels left are eye nodes (no eye joints here), channels without a source ("—") and the
-- blink and jawOpen channels, which the procedural layer drives
local live, n_none, n_proc = {}, 0, 0
for _, c in ipairs(ex.channels) do
    local src = tostring(c.source_text)
    if c.no_signal then n_none = n_none + 1
    elseif src:find("自动表情", 1, true) then n_proc = n_proc + 1
    elseif src ~= "—" and not src:find("^eye%.") then live[#live + 1] = c.name end
end
check(ex.profile and ex.profile.id == "arkit" and n_none > 0 and n_proc == 3 and #live == 0,
    "no dictionary: ARKit loads, every signal channel but the blinks and jawOpen no_signal " .. table.concat(live, ", "))

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

-- an engine without getBlendShapeChannelName: names come back from the mesh's name hashes
local W = require("ShapeKeySystem_Core.Writer")
local U = require("ShapeKeySystem_Core.Util")
local NameHash = require("ShapeKeySystem_Core.NameHash")
HASH = NameHash.murmur3
local keep_cname, keep_channels = W.M_CNAME, CHANNELS
W.M_CNAME = nil
CHANNELS = { "Eye_Blink_Left", "Jaw_Open", "Waist_thin", "Zz_mod_only_key", "Mystery_key" }
local function sculpt_names()
    SKS.call("sculpt_scan"); ticks(5)
    local by = {}
    for _, k in ipairs(st.sculpt.keys) do by[k.name] = k end
    return by
end
local by = sculpt_names()
local mystery = NameHash.label(NameHash.murmur3("Mystery_key"))
check(by.Eye_Blink_Left and by.Jaw_Open and by.Waist_thin and by[mystery] and not by.Zz_mod_only_key,
    "hashes: ARKit spelling, alias and preset keys resolve, the rest show as " .. mystery)
check(ex.channels and SKS.state.expression.coverage.arkit_hit >= 2, "hashes: the profile matches the resolved names ("
    .. tostring(SKS.state.expression.coverage.arkit_hit) .. ")")
U.save_json(U.path("mods", "names", "fake.json"), { schema = "sks.names/1", names = { "Zz_mod_only_key" } })
SKS.call("set_sculpt_key", { name = mystery, value = 0.4 }); ticks(5)
check(SKS.call("save_sculpt", { name = "Hash Test" }), "a preset saves an unknown key by its hash")
U.save_json(U.path("user", "names", "mine.json"), { names = { "Mystery_key" } })
by = sculpt_names()
check(by.Zz_mod_only_key and by.Mystery_key and not by[mystery], "hashes: mod and user name tables resolve the rest")
SKS.call("set_sculpt_key", { name = "Mystery_key", value = 0 }); ticks(5)
SKS.call("load_sculpt", { name = "Hash Test" }); ticks(5)
by = sculpt_names()
check(math.abs((by.Mystery_key and by.Mystery_key.value or 0) - 0.4) < 1e-6,
    "a preset key saved as " .. mystery .. " applies to Mystery_key once its name is known")
W.M_CNAME, CHANNELS = keep_cname, keep_channels
sculpt_names()

SKS.call("set_setting", { key = "advanced", value = true })
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
for _, page in ipairs({ "basic", "sculpt", "expr", "cond", "debug" }) do
    -- "expr": the 映射配置 tab of the 表情 page
    Panel.ui.page = page == "expr" and "basic" or page
    if page == "basic" or page == "expr" then Panel.ui.page_state.basic = { tab = page == "expr" and "mapping" or nil } end
    frame(); frame()
    check(not find("页面出错"), "page draws: " .. page)
    if page == "basic" or page == "expr" then
        check(st.expression.no_signals == true and find("本游戏目前暂不支持表情"), "no raw channels: " .. page .. " says expressions are unsupported")
    end
end
print("FAKE FAILS:", ff)
