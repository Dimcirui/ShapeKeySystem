-- ShapeKeySystem: procedural expression signals (automatic blinking) and their merge with the
-- game's dictionary signals.
--
-- The generator writes `Pr.out[name]` under the dictionary's signal names (`blink.L`, `blink.R`),
-- so profiles need no procedural nodes; `Profile` wraps the `s` nodes of these names in `Pr.merge`.
-- `Pr.out` holds no values while the layer is off or the mode is "game", which leaves the compiled
-- signal value untouched.
--
-- Merge modes (cfg.procedural.mode):
--   game      the game's value only
--   fallback  only the signals the game lacks: max(game, procedural). A signal is lacking when the
--             dictionary has no raw channel for it or the adapter lists its group in `procedural`
--             (its raw channel exists but never carries the idle animation, e.g. Rise's eyelids)
--   add       every procedural signal: game + procedural, capped at 1 while the game value is <= 1
--
-- Constraints:
-- - The clock advances only through `Pr.tick` on consecutive frames: a frame skipped by the game
--   gate (paused, loading, cutscene not driven) makes the next step 0, so a blink never jumps.
-- - The random source is a private LCG (`Pr.seed`), not math.random, so a fixed seed gives the
--   same blink times in the offline tests.

local Pr = {}

Pr.MODES = { "game", "fallback", "add" }
Pr.MODE_NAMES = { game = "仅游戏", fallback = "游戏缺失时用自动表情", add = "叠加" }
-- signal name -> group; an adapter's `procedural = { blink = true }` marks a group as lacking
Pr.SIGNALS = { ["blink.L"] = "blink", ["blink.R"] = "blink" }

-- interval and durations from the Rise Kurumi mod's timer blink (7-12 s, 75 / 35 / 120 ms);
-- the default frequency 2 halves the interval
Pr.DEFAULTS = {
    enabled = true, mode = "fallback",
    -- frequency multiplies the blink rate (intervals are divided by it), speed divides the
    -- close / hold / open durations
    frequency = 2.0, speed = 1.0,
    blink = { interval_min = 7.0, interval_max = 12.0, close = 0.075, hold = 0.035, open = 0.12,
              double_chance = 0.15, double_gap = 0.1, asym = 0.0 },
}
Pr.LIMITS = {
    frequency = { 0.2, 4 }, speed = { 0.25, 3 },
    interval_min = { 0.5, 60 }, interval_max = { 0.5, 60 }, close = { 0.01, 1 }, hold = { 0, 1 },
    open = { 0.01, 1 }, double_chance = { 0, 1 }, double_gap = { 0, 1 }, asym = { 0, 0.1 },
}

Pr.adapter = {}   -- set by SKS.init
Pr.out = {}
Pr.time = 0       -- seconds the generator has advanced since load

local cfg = Pr.DEFAULTS
local rng = 1
local last_frame = nil
-- t = time since the current blink started; second = this blink is the repeat of a double blink
local b = { wait = 0, t = nil, double = false, second = false }

function Pr.seed(n)
    rng = math.floor(tonumber(n) or 1) % 2147483648
    if rng == 0 then rng = 1 end
end

local function rand()
    rng = (rng * 1103515245 + 12345) % 2147483648
    return rng / 2147483648
end

local function next_interval()
    local bc = cfg.blink
    local lo, hi = bc.interval_min, bc.interval_max
    if hi < lo then lo, hi = hi, lo end
    return (lo + (hi - lo) * rand()) / cfg.frequency
end

-- Resets the blink schedule: the first blink comes one random interval after this call.
function Pr.reset()
    b.wait, b.t, b.double, b.second = next_interval(), nil, false, false
    last_frame = nil
    for k in pairs(Pr.out) do Pr.out[k] = nil end
end

-- After an interval or frequency change: a pending wait longer than the new longest interval is
-- drawn again, so a faster setting shows at once; a blink in progress is kept.
function Pr.retime()
    if b.t then return end
    local bc = cfg.blink
    if b.wait > math.max(bc.interval_min, bc.interval_max) / cfg.frequency then b.wait = next_interval() end
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

-- true when the game supplies no usable value for this signal, see the header
function Pr.lacking(name, no_signal)
    local g = Pr.SIGNALS[name]
    if not g then return false end
    if no_signal then return true end
    local p = Pr.adapter.procedural
    return p ~= nil and p[g] == true
end

-- game value g, procedural value q (not nil)
function Pr.merge(g, q, lacking)
    local mode = cfg.mode
    if mode == "add" then
        local v = g + q
        if v > 1 and g <= 1 then v = 1 end
        return v
    elseif mode == "fallback" and lacking then
        return (q > g) and q or g
    end
    return g
end

local function smooth(x)
    if x <= 0 then return 0 elseif x >= 1 then return 1 end
    return x * x * (3 - 2 * x)
end

-- closedness of one eye t seconds into a blink; nil once the blink is over
local function curve(t, c, h, o)
    if t < 0 then return 0 end
    if t < c then return smooth(t / c) end
    t = t - c
    if t < h then return 1 end
    t = t - h
    if t < o then return 1 - smooth(t / o) end
    return nil
end

-- Advances the generator to frame f (os.clock seconds `now`) and fills Pr.out.
-- Returns the left eye's value (0 while off).
function Pr.tick(now, f)
    local out = Pr.out
    if not Pr.active() then
        if out["blink.L"] ~= nil then out["blink.L"], out["blink.R"] = nil, nil end
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

-- Advances the generator by dt seconds (the tests drive it directly).
function Pr.step(dt)
    Pr.time = Pr.time + dt
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
                b.wait = next_interval()
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
            b.double = not b.second and rand() < bc.double_chance
            vl = curve(b.t, c, h, o) or 0
            vr = curve(b.t - asym, c, h, o) or 0
        end
    end
    Pr.out["blink.L"], Pr.out["blink.R"] = vl, vr
    return vl
end

return Pr
