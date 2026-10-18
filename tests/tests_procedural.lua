-- procedural expression layer (Procedural.lua): blink generator under a fixed seed, merge modes,
-- the clock pausing on skipped frames, and the Wilds mock whose game blink must stay untouched
local SKS = require("ShapeKeySystem_Core.API")
local Pr = require("ShapeKeySystem_Core.Procedural")
local U = require("ShapeKeySystem_Core.Util")
local st, live = SKS.state, SKS.live
local pf = 0
local api_cfg = Pr.config()   -- cfg.procedural of the API, put back before the command checks
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[procedural] " .. what)
    if not cond then pf = pf + 1 end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function cfg_with(patch)
    local c = U.copy(Pr.DEFAULTS)
    c.frequency = 1   -- the checks below are written against the base interval
    for k, v in pairs(patch or {}) do
        if type(v) == "table" then for bk, bv in pairs(v) do c[k][bk] = bv end else c[k] = v end
    end
    return c
end

-- one blink: smoothstep close, hold, smoothstep open (75 / 35 / 120 ms)
Pr.configure(cfg_with({ blink = { interval_min = 1, interval_max = 1, double_chance = 0 } }))
Pr.step(1.0)
check(near(Pr.out["blink.L"], 0) and near(Pr.out["blink.R"], 0), "the blink starts after the interval")
Pr.step(0.0375)
check(near(Pr.out["blink.L"], 0.5), "half way through closing: smoothstep 0.5 (" .. Pr.out["blink.L"] .. ")")
Pr.step(0.0375 + 0.02)
check(near(Pr.out["blink.L"], 1), "hold: fully closed")
Pr.step(0.015 + 0.06)
check(near(Pr.out["blink.L"], 0.5), "half way through opening: 0.5 (" .. Pr.out["blink.L"] .. ")")
Pr.step(0.0601)
check(near(Pr.out["blink.L"], 0) and near(Pr.out["blink.R"], 0), "open again after 230 ms")

-- speed halves every duration, frequency halves the interval
Pr.configure(cfg_with({ frequency = 2, speed = 2, blink = { interval_min = 1, interval_max = 1, double_chance = 0 } }))
Pr.step(0.5); Pr.step(0.0375 / 2)
check(near(Pr.out["blink.L"], 0.5), "frequency 2, speed 2: blink at 0.5 s, half closed 19 ms later")

-- asymmetry: the right eye lags
Pr.configure(cfg_with({ blink = { interval_min = 1, interval_max = 1, double_chance = 0, asym = 0.02 } }))
Pr.step(1.0); Pr.step(0.0375)
check(near(Pr.out["blink.L"], 0.5) and Pr.out["blink.R"] < 0.5 and Pr.out["blink.R"] > 0, "asym 20 ms: right eye behind")

-- fixed seed: blink start times over 120 s at 60 fps
local function run(seed, c)
    Pr.configure(c or cfg_with({}))
    Pr.seed(seed); Pr.reset()
    local starts, prev, t = {}, 0, 0
    for _ = 1, 120 * 60 do
        Pr.step(1 / 60); t = t + 1 / 60
        local v = Pr.out["blink.L"]
        if v > 0 and prev == 0 then starts[#starts + 1] = t end
        prev = v
    end
    return starts
end
local a, b, other = run(42), run(42), run(7)
local same, differ = #a == #b, #a ~= #other
for i = 1, #a do
    if a[i] ~= b[i] then same = false end
    if other[i] ~= a[i] then differ = true end
end
check(#a > 0 and same and differ, string.format("seed 42 repeats exactly (%d blinks), seed 7 differs", #a))
local singles, doubles, bad = 0, 0, {}
for i = 2, #a do
    local gap = a[i] - a[i - 1]
    -- a double blink restarts 230 ms (blink) + 100 ms (gap) after the first one
    if gap < 0.5 then
        doubles = doubles + 1
        if gap < 0.3 or gap > 0.37 then bad[#bad + 1] = string.format("double %.3f", gap) end
    else
        singles = singles + 1
        if gap < 7 + 0.2 or gap > 12 + 0.27 then bad[#bad + 1] = string.format("interval %.3f", gap) end
    end
end
check(#bad == 0 and singles > 0, "intervals 7-12 s after the blink, double blinks 330 ms apart " .. table.concat(bad, ", "))
local many = run(42, cfg_with({ blink = { interval_min = 1, interval_max = 1, double_chance = 1 } }))
local triple = false
for i = 3, #many do if many[i] - many[i - 2] < 1 then triple = true end end
check(#many > 20 and not triple, "double_chance 1: every blink doubles, never a triple")
check(string.format("%.4f %.4f %.4f", a[1], a[2], a[3]) == "9.9167 19.4833 28.8333",
    "seed 42 golden start times " .. string.format("%.4f %.4f %.4f", a[1], a[2], a[3]))

-- merge modes
local function merge_cfg(mode) Pr.configure(cfg_with({ mode = mode })) end
merge_cfg("fallback")
check(near(Pr.merge(0.2, 0.7, true), 0.7) and near(Pr.merge(0.9, 0.7, true), 0.9) and near(Pr.merge(0.2, 0.7, false), 0.2),
    "fallback: max(game, procedural) for a lacking signal, the game value otherwise")
merge_cfg("add")
check(near(Pr.merge(0.2, 0.7, false), 0.9) and near(Pr.merge(0.6, 0.7, false), 1) and near(Pr.merge(1.2, 0.7, false), 1.9),
    "add: game + procedural, capped at 1 unless the game is already above it")
merge_cfg("game")
check(not Pr.active() and Pr.tick(0, 1) == 0 and Pr.out["blink.L"] == nil, "game: no procedural values at all")
Pr.configure(cfg_with({ enabled = false }))
check(not Pr.active() and Pr.tick(0, 1) == 0 and Pr.out["blink.L"] == nil, "switched off: no procedural values")
check(Pr.lacking("blink.L", true) and not Pr.lacking("blink.L", false) and not Pr.lacking("smile.L", true),
    "lacking: no raw channel for a procedural signal (the Wilds adapter claims nothing)")

-- gaze: jumps within the amplitude, each `move` long, holding in between
local function gaze_run(seed)
    Pr.configure(cfg_with({ blink = { enabled = false }, breath = { enabled = false },
                            gaze = { amplitude = 4, interval_min = 0.5, interval_max = 1, move = 0.05, center_chance = 0.3 } }))
    Pr.seed(seed); Pr.reset()
    local jumps, moving, max_y, max_p, frames, prev = 0, 0, 0, 0, 0, { 0, 0 }
    for _ = 1, 30 * 100 do
        Pr.step(0.01)
        local y, p = Pr.gaze[1], Pr.gaze[2]
        if y ~= prev[1] or p ~= prev[2] then moving = moving + 1 end
        max_y, max_p = math.max(max_y, math.abs(y)), math.max(max_p, math.abs(p))
        prev[1], prev[2] = y, p
        frames = frames + 1
    end
    return moving, max_y, max_p, Pr.out["blink.L"], Pr.out.jawOpen
end
local mv, my, mp, bl, jo = gaze_run(42)
check(my <= 4 + 1e-9 and mp <= 2.4 + 1e-9 and my > 1, string.format("gaze within ±4° yaw, ±2.4° pitch (%.2f, %.2f)", my, mp))
-- about 40 jumps in 30 s, each 5 frames of motion: the eyes hold still most of the time
check(mv > 60 and mv < 400, "gaze moves in short jumps and holds in between (" .. mv .. " moving frames of 3000)")
check(bl == nil and jo == nil, "blink and mouth switched off: their names stay empty")
local mv2, my2 = gaze_run(42)
check(mv2 == mv and my2 == my, "gaze repeats under the same seed")

-- breath: jawOpen rises to the amplitude over `open`, holds, closes; 7-12 s apart
Pr.configure(cfg_with({ blink = { enabled = false }, gaze = { enabled = false } }))
Pr.seed(42); Pr.reset()
local peak, starts, prevj, t = 0, {}, 0, 0
for _ = 1, 60 * 100 do
    Pr.step(0.01); t = t + 0.01
    local v = Pr.out.jawOpen
    if v > peak then peak = v end
    if v > 0 and prevj == 0 then starts[#starts + 1] = t end
    prevj = v
end
local gaps_ok = #starts >= 4
for i = 2, #starts do
    local gap = starts[i] - starts[i - 1]
    if gap < 7 + 3.2 - 0.02 or gap > 12 + 3.2 + 0.02 then gaps_ok = false end
end
check(near(peak, 0.1) and gaps_ok, string.format("breath: jawOpen peaks at 0.1, %d openings 7-12 s apart after each", #starts))
check(Pr.gaze[1] == 0 and Pr.gaze[2] == 0 and Pr.out["blink.L"] == nil, "gaze switched off: offset 0")

-- apply_gaze: a rig without eye joints gets the offset itself, never an accumulating one, and goes
-- back to 0 once gaze stops applying; a rig with joints only in add mode
Pr.configure(cfg_with({ gaze = { amplitude = 4, interval_min = 0.1, interval_max = 0.1, center_chance = 0 } }))
local norig = { use_eyes = true, eyes = {}, angles = { L = { 0, 0 }, R = { 0, 0 } } }
Pr.step(0.3)
local oy = Pr.gaze[1]
Pr.apply_gaze(norig); Pr.apply_gaze(norig)
check(oy ~= 0 and near(norig.angles.L[1], oy) and near(norig.angles.R[1], oy), "no eye joints, fallback: angles = offset, applied twice still once")
local jrig = { use_eyes = true, eyes = { L = {}, R = {} }, angles = { L = { 5, 1, fresh = true }, R = { 5, 1, fresh = true } } }
Pr.apply_gaze(jrig)
check(jrig.angles.L[1] == 5 and not jrig.gaze_applied, "eye joints, fallback: game angles untouched")
Pr.config().mode = "add"
Pr.apply_gaze(jrig)
check(near(jrig.angles.L[1], 5 + oy), "eye joints, add: game angle + offset")
Pr.apply_gaze(jrig)
check(near(jrig.angles.L[1], 5 + oy), "add again without a new reading: still one offset")
Pr.config().mode = "game"
Pr.apply_gaze(jrig); Pr.apply_gaze(norig)
check(jrig.angles.L[1] == 5 and norig.angles.L[1] == 0 and not norig.gaze_applied, "game only: angles back on their base")

-- the clock runs on consecutive frames only
Pr.configure(cfg_with({}))
local t0 = Pr.time
Pr.tick(10.0, 100); Pr.tick(10.016, 101); Pr.tick(10.032, 102)
check(near(Pr.time - t0, 0.032), "consecutive frames advance the clock")
Pr.tick(25.0, 160)
check(near(Pr.time - t0, 0.032), "a frame gap (gate closed) adds nothing")
Pr.tick(25.5, 161)
check(near(Pr.time - t0, 0.132), "one long frame advances at most 0.1 s")

-- the Wilds mock: blink.L has a game signal, so fallback leaves it alone and add blinks on top
Pr.configure(api_cfg)
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
-- scans never switch profiles: drive the mesh the earlier groups left with the best match
SKS.call("auto_match_profile", {}); ticks(3)
local function run_for(sec)
    local m, stop = 0, os.clock() + sec
    while os.clock() < stop do
        local w = os.clock() + 0.01
        while os.clock() < w do end
        ticks(1)
        local s
        -- the profile in effect here is not always ARKit: take the first channel blink.L drives
        for _, c in ipairs(st.expression.channels) do
            if not s and tostring(c.source_text):find("blink.L", 1, true) then s = c.slot end
        end
        local v = s and live.weight[s] or 0
        if v > m then m = v end
    end
    return m
end
local fast = { interval_min = 0.5, interval_max = 0.5, double_chance = 0 }
check(SKS.call("set_procedural", { patch = { enabled = true, mode = "fallback", frequency = 4, blink = fast } }),
    "set_procedural accepts a patch")
check(st.procedural.mode == "fallback" and st.procedural.frequency == 4 and st.procedural.blink.interval_min == 0.5
    and st.procedural.lacking["blink.L"] == false, "state.procedural mirrors the settings; Wilds has a blink signal")
local ok_bad = SKS.call("set_procedural", { patch = { mode = "sometimes" } })
check(not ok_bad, "an unknown mode is rejected")
FC[1] = 0
check(run_for(0.6) == 0, "Wilds, fallback: no procedural blink on top of the game's")
SKS.call("set_procedural", { patch = { mode = "add" } })
local m_add = run_for(0.6)
check(m_add > 0.5, string.format("Wilds, add: procedural blinks on top (max %.2f)", m_add))
SKS.call("set_procedural", { patch = { mode = "game" } })
check(run_for(0.3) == 0, "Wilds, game only: no procedural blink")
ticks(70)
local saved = json.load_file("ShapeKeySystem/settings.json")
check(saved and saved.procedural and saved.procedural.mode == "game" and saved.procedural.blink.interval_min == 0.5,
    "settings.json keeps the procedural settings")
local d = Pr.DEFAULTS
SKS.call("set_procedural", { patch = { enabled = d.enabled, mode = d.mode, frequency = d.frequency, speed = d.speed,
                                       blink = U.copy(d.blink) } })
check(st.procedural.mode == "fallback" and st.procedural.blink.interval_min == 7, "defaults restored")

print("PROCEDURAL FAILS:", pf)
