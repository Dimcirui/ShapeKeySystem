-- Onimusha: Way of the Sword (run.py --game onimusha): the same plugin on an Onimusha world
-- (mock_oni.lua). The face is the player's "Head" child and carries the shape keys itself.
local SKS = require("ShapeKeySystem_Core.API")
local Game = require("ShapeKeySystem_Core.Game")
local Profile = require("ShapeKeySystem_Core.Profile")
local st = SKS.state
local of = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[oni] " .. what)
    if not cond then of = of + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function sum_gaze(m)
    local s = 0
    for _, n in ipairs({ "瞳上", "瞳下", "瞳左", "瞳右" }) do s = s + (ONI.weight(m, n) or 0) end
    return s
end
local function rig_labels()
    local out = {}
    for _, r in ipairs(st.scene.rigs or {}) do out[#out + 1] = r.label end
    table.sort(out)
    return table.concat(out, ",")
end

-- the game -------------------------------------------------------------------------------------
check(Game.id == "onimusha", "the game is detected from reframework:get_game_name()")

local function hooked()
    local out = {}
    for k in pairs(HOOKS) do out[#out + 1] = k end
    table.sort(out)
    return out
end
check(#hooked() == 0, "no MH Wilds hooks installed at load: " .. table.concat(hooked(), ","))

-- signals: Wilds' names stay declared (every builtin profile still compiles); nothing reads an
-- fcParam or a Wilds face bone, since Onimusha has neither
local by = Profile.signals.by_name
check(by["smile.L"] ~= nil and by["smile.L"].kind == "none", "fcParam signals are declared but unwired")
check(by.jawDrop ~= nil and by.jawDrop.bone ~= "C_Chin_LOD00", "no signal reads a Wilds face bone (jawDrop)")
local bad = {}
for _, s in ipairs(Profile.signals.list) do
    if s.bone and (s.bone:find("_LOD%d") or s.bone:find("fcParam")) then bad[#bad + 1] = s.name .. "->" .. s.bone end
end
check(#bad == 0, "no Wilds bone names in the Onimusha signals: " .. table.concat(bad, ","))
local broken = {}
for id in pairs(Profile.registry) do
    local r = Profile.resolve(id)
    local prog, _, msg = r and Profile.compile(r, {})
    if not prog then broken[#broken + 1] = id .. ": " .. tostring(msg) end
end
table.sort(broken)
check(#broken == 0, "every builtin profile compiles: " .. table.concat(broken, "; "))

-- channel names from name hashes ----------------------------------------------------------------
local U = require("ShapeKeySystem_Core.Util")
local Scene = require("ShapeKeySystem_Core.Scene")
local W = require("ShapeKeySystem_Core.Writer")
check(W.M_CNAME == nil, "the mock has no getBlendShapeChannelName, as in the game")
local bad_hash = {}
for _, n in ipairs({ "あ", "ｳｨﾝｸ２右", "ウィンク２", "口角上げL", "眉_斜め1", "eyeBlinkLeft", "1", "" }) do
    if U.murmur3(n) ~= py_mm3(n) then bad_hash[#bad_hash + 1] = n end
end
check(#bad_hash == 0, "murmur3 of UTF-16LE names matches the reference: " .. table.concat(bad_hash, ","))
local m = ONI.mesh({ "あ", "nobody_knows_me" })
local names = Scene.channel_names(m)
check(names[1] == "あ" and names[2] == string.format("#%08X", py_mm3("nobody_knows_me")),
      "channels are named through their hashes; an unknown one by its hash: " .. table.concat(names, ","))

-- the face drives itself --------------------------------------------------------------------------
SKS.call("set_profile", { id = "maya" })
ticks(90)
check(rig_labels() == "Head", "one rig, the player's Head: " .. rig_labels())
local r1 = (st.scene.rigs or {})[1]
check(r1 and r1.primary and r1.targets[1] and r1.targets[1].name == "Head",
      "the Head rig is primary and drives its own mesh")
check(sum_gaze(ONI.head_mesh) > 0, string.format("the eyes (eye_Lt / eye_Rt) drive Maya's gaze keys (%.3f)", sum_gaze(ONI.head_mesh)))
check(INT_WRITES == nil, "every weight is written as a float")

-- Oni form: OniHead is a second face with its own keys (not merged into Head's rig)
ONI.oni_form(true)
ticks(90)
check(rig_labels() == "Head,OniHead", "Oni form: Head and OniHead each drive themselves: " .. rig_labels())
check(sum_gaze(ONI.oni_mesh) > 0, "OniHead's gaze keys are driven")
ONI.oni_form(false)
ticks(90)
check(rig_labels() == "Head", "back from Oni form: only Head again: " .. rig_labels())

-- the game rebuilds Head (same name, new objects): the old mesh is let go at once
local old = ONI.head_mesh
ONI.rebuild_head()
local n_old = #old.writes
ticks(90)
check(#old.writes == n_old, "the replaced Head mesh is never written again")
check(sum_gaze(ONI.head_mesh) > 0, "the new Head mesh is driven")

-- no controlling player (title, loading): nothing is written, and it comes back by itself
ONI.player_on = false
local before = #ONI.head_mesh.writes
ticks(60)
check(#ONI.head_mesh.writes == before, "no player: nothing is written")
check(st.debug.status == "paused: no player", "no player: paused and let go (" .. tostring(st.debug.status) .. ")")
ONI.player_on = true
ONI.rebuild_head()
ticks(120)
check(rig_labels() == "Head" and sum_gaze(ONI.head_mesh) > 0, "the player comes back: Head is driven again")

-- a mesh whose weight buffer is not there yet is not written until it is (Guard)
ONI.rebuild_head()
ONI.head_mesh.ready = false
ticks(90)
check(#ONI.head_mesh.writes == 0, "a face mesh without its weight buffer is not written")
ONI.head_mesh.ready = true
ticks(90)
check(#ONI.head_mesh.writes > 0, "it is written once the buffer exists")

-- opening the panel installs no Wilds input hooks
local Panel = package.loaded["ShapeKeySystem_UI.Panel"]
if Panel then
    pcall(Panel.set_open, true); ticks(2); pcall(Panel.set_open, false); ticks(2)
end
check(#hooked() == 0, "no MH Wilds input hooks after the panel opens: " .. table.concat(hooked(), ","))

-- Onimusha face signals (signals_onimusha.json, measured on kevin's probe recordings) -------------
local wired = {}
for _, sg in ipairs(Profile.signals.list) do if sg.bone then wired[sg.name] = sg end end
local need = { "eyeClose.L", "eyeClose.R", "jawDrop", "lowerLipDrop", "mouthCornerUp.L", "mouthCornerUp.R",
               "mouthCornerDown.L", "mouthCornerOut.L", "browRaise.L", "browLower.R", "browInnerDown.L",
               "cheekRaise.L", "lowerLidRaise.R", "eyeWiden.L" }
local missing = {}
for _, n in ipairs(need) do
    if not (wired[n] and wired[n].bone:find("^face_joint")) then missing[#missing + 1] = n end
end
check(#missing == 0, "the maya profile's face signals read Onimusha face joints: missing " .. table.concat(missing, ","))

-- move a signal's bone to its full travel from the idle rest (head frame, mm)
local function pose(signame, amount)
    local sg = wired[signame]
    local d = { 0, 0, 0 }
    d[sg.axis] = sg.rest + sg.sign * sg.full * (amount or 1)   -- metres (Profile stores rest/full in metres)
    ONI.lpos["Head:" .. sg.bone] = d
end
local function relax() for k in pairs(ONI.lpos) do ONI.lpos[k] = nil end end
local function settle() ticks(40) end

relax(); settle()
local idle_blink = ONI.weight(ONI.head_mesh, "ウィンク２")
pose("eyeClose.L"); pose("eyeClose.R"); settle()
local wl, wr = ONI.weight(ONI.head_mesh, "ウィンク２"), ONI.weight(ONI.head_mesh, "ｳｨﾝｸ２右")
check(wl > 0.95 and wr > 0.95 and idle_blink < 0.05,
      string.format("a full game blink closes both eyes (L %.2f, R %.2f; open %.2f)", wl, wr, idle_blink))
relax(); pose("jawDrop"); settle()
check(ONI.weight(ONI.head_mesh, "あ") > 0.95, string.format("the jaw at full drop opens あ (%.2f)", ONI.weight(ONI.head_mesh, "あ")))
relax(); pose("jawDrop", 0.2); settle()
check(ONI.weight(ONI.head_mesh, "あ") < 0.05, "a jaw inside the deadzone leaves あ shut")
relax(); pose("browRaise.L"); pose("browRaise.R"); settle()
check(ONI.weight(ONI.head_mesh, "眉_上") > 0.95, string.format("both brows up raise 眉_上 (%.2f)", ONI.weight(ONI.head_mesh, "眉_上")))
relax(); settle()
check(ONI.weight(ONI.head_mesh, "あ") < 0.05 and ONI.weight(ONI.head_mesh, "ウィンク２") < 0.05,
      "back at the idle rest every key lets go")

print("ONI FAILS:", of)
