-- ShapeKeySystem: procedural expression signals (automatic blinking, gaze micro-saccades, a slight
-- idle mouth opening) and their merge with the game's signals.
--
-- Blink and mouth write `Pr.out[name]` under the dictionary's signal names (`blink.L`, `blink.R`,
-- `jawOpen`), so profiles need no procedural nodes; `Profile` wraps the `s` nodes of these names in
-- `Pr.merge`. A name holds no value while its generator is off, the layer is off or the mode is
-- "game", which leaves the compiled signal value untouched. Gaze is an offset in degrees (SKS gaze
-- convention) that `Pr.apply_gaze` adds to a rig's eye angles.
--
-- Merge modes (cfg.procedural.mode):
--   game      the game's value only
--   fallback  only what the game lacks: max(game, procedural) for a signal, the offset for gaze. A
--             signal is lacking when the dictionary has no raw channel for it, gaze when the rig has
--             no eye joints; both also when the adapter lists the group in `procedural` (the game
--             channel exists but never carries the idle animation, e.g. Rise's eyelids)
--   add       everything: game + procedural (signals capped at 1 while the game value is <= 1)
--
-- Constraints:
-- - The clock advances only through `Pr.tick` on consecutive frames: a frame skipped by the game
--   gate (paused, loading, cutscene not driven) makes the next step 0, so nothing jumps.
-- - Each generator draws from its own private LCG stream (`Pr.seed`), not math.random, so a fixed
--   seed gives the same timings in the offline tests and one generator's settings do not move
--   another's schedule.

local Pr = {}

Pr.MODES = { "game", "fallback", "add" }
Pr.MODE_NAMES = { game = "仅游戏", fallback = "游戏缺失时用自动表情", add = "叠加" }
Pr.GROUPS = { "blink", "gaze", "breath" }
-- signal name -> group; an adapter's `procedural = { blink = true }` marks a group as lacking
Pr.SIGNALS = { ["blink.L"] = "blink", ["blink.R"] = "blink", jawOpen = "breath" }

-- blink interval and durations from the Rise Kurumi mod's timer blink (7-12 s, 75 / 35 / 120 ms);
-- the default frequency 2 halves the interval
Pr.DEFAULTS = {
    enabled = true, mode = "fallback",
    -- blink only: frequency multiplies the blink rate (intervals are divided by it), speed divides
    -- the close / hold / open durations
    frequency = 2.0, speed = 1.0,
    blink = { enabled = true, interval_min = 7.0, interval_max = 12.0, close = 0.075, hold = 0.035, open = 0.12,
              double_chance = 0.15, double_gap = 0.1, asym = 0.0 },
    -- amplitude = largest yaw offset in degrees (pitch uses 0.6 of it); each jump takes `move` seconds
    gaze = { enabled = true, amplitude = 3.0, interval_min = 0.8, interval_max = 2.5, move = 0.05,
             center_chance = 0.3 },
    -- jawOpen rises to `amplitude` over `open` seconds, holds, and closes again
    breath = { enabled = true, amplitude = 0.1, interval_min = 7.0, interval_max = 12.0, open = 1.2,
               hold = 0.4, close = 1.6 },
}
-- group (or "top" for the fields of cfg.procedural itself) -> key -> { lo, hi }
Pr.LIMITS = {
    top = { frequency = { 0.2, 4 }, speed = { 0.25, 3 } },
    blink = { interval_min = { 0.5, 60 }, interval_max = { 0.5, 60 }, close = { 0.01, 1 }, hold = { 0, 1 },
              open = { 0.01, 1 }, double_chance = { 0, 1 }, double_gap = { 0, 1 }, asym = { 0, 0.1 } },
    gaze = { amplitude = { 0, 15 }, interval_min = { 0.1, 30 }, interval_max = { 0.1, 30 }, move = { 0.01, 0.5 },
             center_chance = { 0, 1 } },
    breath = { amplitude = { 0, 1 }, interval_min = { 0.5, 60 }, interval_max = { 0.5, 60 }, open = { 0.05, 5 },
               hold = { 0, 5 }, close = { 0.05, 5 } },
}

Pr.adapter = {}   -- set by SKS.init
Pr.out = {}
Pr.gaze = { 0, 0 }   -- yaw, pitch offset in degrees; meaningful while Pr.gaze_on()
Pr.time = 0          -- seconds the generator has advanced since load

local cfg = Pr.DEFAULTS
local streams = { blink = 1, gaze = 2, breath = 3 }
local last_frame = nil
-- t = time since the current blink started; second = this blink is the repeat of a double blink
local b = { wait = 0, t = nil, double = false, second = false }
-- t = time since the current jump started (nil = holding at `to`)
local g = { wait = 0, t = nil, from = { 0, 0 }, to = { 0, 0 } }
local m = { wait = 0, t = nil }

function Pr.seed(n)
    n = math.floor(tonumber(n) or 1)
    for i, k in ipairs(Pr.GROUPS) do
        local s = (n + (i - 1) * 7919) % 2147483648
        streams[k] = (s == 0) and 1 or s
    end
end

local function rand(k)
    local s = (streams[k] * 1103515245 + 12345) % 2147483648
    streams[k] = s
    return s / 2147483648
end

local function between(k, lo, hi)
    if hi < lo then lo, hi = hi, lo end
    return lo + (hi - lo) * rand(k)
end

local function blink_interval()
    local bc = cfg.blink
    return between("blink", bc.interval_min, bc.interval_max) / cfg.frequency
end

local function gaze_interval() return between("gaze", cfg.gaze.interval_min, cfg.gaze.interval_max) end
local function breath_interval() return between("breath", cfg.breath.interval_min, cfg.breath.interval_max) end

-- Resets every schedule: each generator starts one random interval after this call, at rest.
function Pr.reset()
    b.wait, b.t, b.double, b.second = blink_interval(), nil, false, false
    g.wait, g.t = gaze_interval(), nil
    g.from[1], g.from[2], g.to[1], g.to[2] = 0, 0, 0, 0
    m.wait, m.t = breath_interval(), nil
    Pr.gaze[1], Pr.gaze[2] = 0, 0
    last_frame = nil
    for k in pairs(Pr.out) do Pr.out[k] = nil end
end

-- After an interval or frequency change: a pending wait longer than the new longest interval is
-- drawn again, so a faster setting shows at once; a motion in progress is kept.
function Pr.retime()
    local bc, gc, mc = cfg.blink, cfg.gaze, cfg.breath
    if not b.t and b.wait > math.max(bc.interval_min, bc.interval_max) / cfg.frequency then b.wait = blink_interval() end
    if not g.t and g.wait > math.max(gc.interval_min, gc.interval_max) then g.wait = gaze_interval() end
    if not m.t and m.wait > math.max(mc.interval_min, mc.interval_max) then m.wait = breath_interval() end
end

-- c: the cfg.procedural table (shared, edits through set_procedural take effect at once)
function Pr.configure(c)
    cfg = c or Pr.DEFAULTS
    Pr.reset()
end

function Pr.config() return cfg end

function Pr.active()
    return cfg.enabled == true and cfg.mode ~= "game"
end

function Pr.mode() return cfg.mode end

local function group_on(k)
    local c = cfg[k]
    return Pr.active() and type(c) == "table" and c.enabled ~= false
end

function Pr.gaze_on() return group_on("gaze") end

local function adapter_lacks(group)
    local p = Pr.adapter.procedural
    return p ~= nil and p[group] == true
end

-- true when the game supplies no usable value for this signal, see the header
function Pr.lacking(name, no_signal)
    local grp = Pr.SIGNALS[name]
    if not grp then return false end
    if no_signal then return true end
    return adapter_lacks(grp)
end

function Pr.lacking_group(group) return adapter_lacks(group) end

function Pr.gaze_lacking(rig)
    return adapter_lacks("gaze") or not (rig and rig.eyes and (rig.eyes.L or rig.eyes.R))
end

-- game value gv, procedural value q (not nil)
function Pr.merge(gv, q, lacking)
    local mode = cfg.mode
    if mode == "add" then
        local v = gv + q
        if v > 1 and gv <= 1 then v = 1 end
        return v
    elseif mode == "fallback" and lacking then
        return (q > gv) and q or gv
    end
    return gv
end

-- Adds the gaze offset to rig.angles. A side whose angle `Expression.read` refreshed this frame
-- (`fresh`) is offset from that reading; any other side from its last reading, or from 0 without
-- an eye joint, so offsets never accumulate. The frame after the offset stops applying puts the
-- angles back on their base.
function Pr.apply_gaze(rig)
    if not rig.use_eyes then return end
    local on = Pr.gaze_on() and not (cfg.mode == "fallback" and not Pr.gaze_lacking(rig))
    if not on and not rig.gaze_applied then return end
    local oy, op = 0, 0
    if on then oy, op = Pr.gaze[1], Pr.gaze[2] end
    for _, side in ipairs({ "L", "R" }) do
        local a = rig.angles[side]
        if a.fresh then a.fresh, a.base_y, a.base_p = false, a[1], a[2] end
        a[1], a[2] = (a.base_y or 0) + oy, (a.base_p or 0) + op
    end
    rig.gaze_applied = on or nil
end

local function smooth(x)
    if x <= 0 then return 0 elseif x >= 1 then return 1 end
    return x * x * (3 - 2 * x)
end

-- rise / hold / fall envelope t seconds in; nil once it is over
local function curve(t, c, h, o)
    if t < 0 then return 0 end
    if t < c then return smooth(t / c) end
    t = t - c
    if t < h then return 1 end
    t = t - h
    if t < o then return 1 - smooth(t / o) end
    return nil
end

-- Advances the generators to frame f (os.clock seconds `now`) and fills Pr.out / Pr.gaze.
-- Returns the left eye's blink value (0 while off).
function Pr.tick(now, f)
    if not Pr.active() then
        if next(Pr.out) ~= nil then for k in pairs(Pr.out) do Pr.out[k] = nil end end
        Pr.gaze[1], Pr.gaze[2] = 0, 0
        last_frame = nil
        return 0
    end
    local dt = 0
    if last_frame and f == last_frame.f + 1 then
        dt = now - last_frame.now
        if dt < 0 then dt = 0 elseif dt > 0.1 then dt = 0.1 end
    end
    last_frame = last_frame or {}
    last_frame.f, last_frame.now = f, now
    return Pr.step(dt)
end

local function step_blink(dt)
    local bc, sp = cfg.blink, cfg.speed
    local c, h, o = bc.close / sp, bc.hold / sp, bc.open / sp
    local asym = bc.asym / sp
    local vl, vr = 0, 0
    if b.t then
        b.t = b.t + dt
        local l = curve(b.t, c, h, o)
        local r = curve(b.t - asym, c, h, o)
        if l == nil and r == nil then
            b.t = nil
            if b.double then
                b.double, b.second = false, true
                b.wait = bc.double_gap / sp
            else
                b.second = false
                b.wait = blink_interval()
            end
        else
            vl, vr = l or 0, r or 0
        end
    else
        b.wait = b.wait - dt
        if b.wait <= 0 then
            -- the overshoot carries into the blink so the curve does not depend on the frame rate
            b.t = -b.wait
            b.wait = 0
            b.double = not b.second and rand("blink") < bc.double_chance
            vl = curve(b.t, c, h, o) or 0
            vr = curve(b.t - asym, c, h, o) or 0
        end
    end
    return vl, vr
end

local function step_gaze(dt)
    local gc = cfg.gaze
    if g.t then
        g.t = g.t + dt
    else
        g.wait = g.wait - dt
        if g.wait > 0 then return end
        g.from[1], g.from[2] = Pr.gaze[1], Pr.gaze[2]
        if rand("gaze") < gc.center_chance then
            g.to[1], g.to[2] = 0, 0
        else
            local amp = gc.amplitude
            g.to[1] = amp * (2 * rand("gaze") - 1)
            g.to[2] = 0.6 * amp * (2 * rand("gaze") - 1)
        end
        g.t = -g.wait
        g.wait = 0
    end
    local k = smooth(g.t / gc.move)
    Pr.gaze[1] = g.from[1] + (g.to[1] - g.from[1]) * k
    Pr.gaze[2] = g.from[2] + (g.to[2] - g.from[2]) * k
    if g.t >= gc.move then g.t, g.wait = nil, gaze_interval() end
end

local function step_breath(dt)
    local mc = cfg.breath
    if m.t then
        m.t = m.t + dt
        local v = curve(m.t, mc.open, mc.hold, mc.close)
        if v == nil then m.t, m.wait = nil, breath_interval(); return 0 end
        return v * mc.amplitude
    end
    m.wait = m.wait - dt
    if m.wait > 0 then return 0 end
    m.t = -m.wait
    m.wait = 0
    return (curve(m.t, mc.open, mc.hold, mc.close) or 0) * mc.amplitude
end

-- Advances every generator by dt seconds (the tests drive it directly). A generator that is
-- switched off keeps its schedule still and leaves its names empty.
function Pr.step(dt)
    Pr.time = Pr.time + dt
    local out = Pr.out
    local vl = 0
    if cfg.blink.enabled ~= false then
        local vr
        vl, vr = step_blink(dt)
        out["blink.L"], out["blink.R"] = vl, vr
    else
        out["blink.L"], out["blink.R"] = nil, nil
    end
    if cfg.gaze.enabled ~= false then step_gaze(dt) else Pr.gaze[1], Pr.gaze[2] = 0, 0 end
    if cfg.breath.enabled ~= false then out.jawOpen = step_breath(dt) else out.jawOpen = nil end
    return vl
end

return Pr
