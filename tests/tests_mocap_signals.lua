-- face mocap through the game signals (MocapSignals.lua): ARKit values -> P and eye angles
local S = require("ShapeKeySystem_Core.MocapSignals")
local Profile = require("ShapeKeySystem_Core.Profile")
local Names = require("ShapeKeySystem_Core.Names")
local sfails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[mocap_signals] " .. what)
    if not cond then sfails = sfails + 1 end
end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-4 end

local ark = {}
for _, n in ipairs(Names.ARKIT52) do ark[n] = true end
local bad = {}
for sig, n in pairs(S.MAP) do if not ark[n] then bad[#bad + 1] = sig end end
check(#bad == 0, "every mapped signal takes an ARKit name " .. table.concat(bad, ","))

-- a small dictionary: eyeWide.L has no raw channel, smile.L a raw range of its own
local saved = Profile.signals
Profile.load_signals({ full = 0.01, signals = {
    { name = "blink.L", raw = 1 }, { name = "smile.L", raw = 2, lo = 0.002, hi = 0.006 },
    { name = "browInnerUp.R", raw = 3 }, { name = "eyeWide.L" }, { name = "browBring.L", raw = 4 } } })
local prog = Profile.compile({ id = "t_sig", name = "t", channels = {
    { name = "close", s = "blink.L" }, { name = "smile", s = "smile.L" },
    { name = "inner", s = "browInnerUp.R" }, { name = "wide", s = "eyeWide.L" },
    { name = "bring", s = "browBring.L" },
    { name = "left", eye = "L", axis = "yaw", sign = 1 }, { name = "up", eye = "R", axis = "pitch", sign = 1 } } })
check(prog ~= nil, "test profile compiles")
check(S.count(prog) == 4, "count: four of the profile's signals are mapped, browBring is not")

local out = {}
for i, n in ipairs(Names.ARKIT52) do out[i] = 0 end
local function set(n, v) for i, m in ipairs(Names.ARKIT52) do if m == n then out[i] = v end end end
set("eyeBlinkLeft", 0.8); set("mouthSmileLeft", 0.5); set("browInnerUp", 0.4); set("eyeWideLeft", 0.7)
set("eyeLookOutLeft", 0.5); set("eyeLookInLeft", 0.1); set("eyeLookUpRight", 1)
local function eval(P, rig)
    local ctx = { P = P, A = rig.angles, V = {}, fy = 25, fp = 20 }
    local r = {}
    for _, s in ipairs(prog.order) do
        local c = prog.channels[s]
        ctx.V[s] = c.fn(ctx); r[c.name] = ctx.V[s]
    end
    return r
end

local rig = { angles = { L = { 0, 0 }, R = { 0, 0 } } }
local P = { [1] = 0.3, [4] = 0.9, [99] = 0.5 }
S.apply(rig, P, out, 1, 25, 20)
local v = eval(P, rig)
check(near(v.close, 0.8), "blink.L follows eyeBlinkLeft")
check(near(v.smile, 0.5), "smile.L follows mouthSmileLeft through its own raw range")
check(near(v.inner, 0.4), "browInnerUp feeds the right-side signal too")
check(near(v.wide, 0.7), "a signal the game lacks reads the mocap value")
check(near(v.bring, 0) and near(P[99], 0), "unmapped signals drop to 0 at full fade")
check(near(rig.angles.L[1], 10) and near(v.left, 0.4), "eyeLookOut - eyeLookIn of the left eye = yaw to the character's left")
check(near(rig.angles.R[2], 20) and near(v.up, 1), "eyeLookUp = pitch up at the full-weight angle")

-- half faded in: half the game's reading, half the phone
rig = { angles = { L = { 4, 0 }, R = { 0, 0 } } }
P = { [1] = 0.2 }
S.apply(rig, P, out, 0.5, 25, 20)
check(near(eval(P, rig).close, 0.5), "fade 0.5 mixes the game value and the phone")
check(near(rig.angles.L[1], 2 + 5), "fade 0.5 mixes the eye angles too")

-- stream gone: the value no game read overwrites is dropped, unread eye angles go back to 0
rig.angles.R.fresh = true; rig.angles.R[1] = 3
S.release(rig, P)
v = eval(P, rig)
check(near(v.wide, 0), "release drops the lacking signal's value")
check(near(rig.angles.L[1], 0) and near(rig.angles.R[1], 3), "release zeroes only the eye Expression.read did not refresh")

Profile.signals = saved
print("MOCAP_SIGNALS FAILS:", sfails)
