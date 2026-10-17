-- mocap + combination correctives (MocapDerived.lua): ref-only profile channels follow the phone
local Mocap = require("ShapeKeySystem_Core.Mocap")
local Derived = require("ShapeKeySystem_Core.MocapDerived")
local Profile = require("ShapeKeySystem_Core.Profile")
local Names = require("ShapeKeySystem_Core.Names")
local Ext = require("ShapeKeySystem_Core.External")
local U = require("ShapeKeySystem_Core.Util")
local dfails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[mocap_derived] " .. what)
    if not cond then dfails = dfails + 1 end
end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-4 end

-- an ARKit profile with the JSSPSI correctives (jsspsi_arkit), a corrective of a corrective, and
-- one channel that also reads the game: that one is left to the game signal path
local chans = {}
for _, n in ipairs(Names.ARKIT52) do chans[#chans + 1] = { name = n, group = "eye" } end
local function fix(main, side)
    chans[#chans + 1] = { name = main .. "_BlinkFix", group = "eye",
                          mul = { { ref = main }, { ref = "eyeBlink" .. side } } }
end
for _, side in ipairs({ "Left", "Right" }) do
    for _, k in ipairs({ "eyeLookUp", "eyeLookDown", "eyeSquint", "eyeWide" }) do fix(k .. side, side) end
end
chans[#chans + 1] = { name = "halfFix", group = "extra", ref = "eyeWideLeft_BlinkFix", k = 0.5 }
chans[#chans + 1] = { name = "constOnly", group = "extra", const = 0.3 }
local prog, perr = Profile.compile({ id = "t_jsspsi", name = "t", channels = chans })
check(prog ~= nil, "test profile compiles " .. tostring(perr))

-- plan: which channels are re-evaluated from mocap
do
    local held = {}
    for _, n in ipairs(Names.ARKIT52) do held[prog.slot_of[n]] = true end
    local planned = {}
    for _, s in ipairs(Derived.plan(prog, held)) do planned[prog.names[s]] = true end
    check(planned.eyeWideLeft_BlinkFix and planned.eyeLookDownRight_BlinkFix, "BlinkFix channels planned")
    check(planned.halfFix, "a corrective of a corrective is planned after its ref")
    check(not planned.constOnly, "a channel with no ref to a mocap key is left alone")
    -- a node that also reads a game signal cannot come from mocap values alone
    local fake = { order = { 1, 2 }, slot_of = { a = 1, b = 2 }, names = { "a", "b" },
                   channels = { { node = nil }, { fn = function() return 0 end,
                       node = { mul = { { ref = "a" }, { s = "blink.L" } } } } } }
    check(#Derived.plan(fake, { [1] = true }) == 0, "a node with a game signal is not planned")
    check(Derived.pure_refs({ sub = { { ref = "a" }, { const = 1 } } }, {})[1] == "a", "sub of ref and const is pure")
end

-- full path through Mocap.tick with live.json frames
local LIVE = U.path("mocap", "live.json")
local seq = 1000
local function frame_in(vals)
    seq = seq + 1
    local w = {}
    for i, n in ipairs(Names.ARKIT52) do w[i] = vals[n] or 0 end
    json.dump_file(LIVE, { seq = seq, w = w, head = { 0, 0, 0 } })
end
local expr = {}
local ctx = { prog = prog, gen = "t", expr = expr,
              resolve = function(n) return prog.slot_of[n] end, reaches = function() return true end }
local function step(vals) frame_in(vals); Mocap.tick(0.05, ctx) end
local function val(n) return (Ext.get(n)) end

Mocap.patch({ enabled = true, smoothing = 0, fade_sec = 0, timeout = 5, gain = 1 })
step({})   -- the first file seen is treated as stale
step({ eyeWideLeft = 1, eyeBlinkLeft = 1 })
check(near(val("eyeWideLeft_BlinkFix"), 1), "eyeWide 1 x eyeBlink 1 -> eyeWideLeft_BlinkFix 1")
check(near(val("halfFix"), 0.5), "ref to a derived channel uses its mocap value")
check(near(val("eyeWideRight_BlinkFix"), 0), "other side stays at 0")
check(val("constOnly") == nil, "non-ref channel not held by mocap")
check(Mocap.view.derived == 9, "view.derived counts the re-evaluated channels")
step({ eyeWideLeft = 1, eyeBlinkLeft = 0 })
check(near(val("eyeWideLeft_BlinkFix"), 0), "eyeBlink 0 -> 0")
step({ eyeWideLeft = 1, eyeBlinkLeft = 0.5 })
check(near(val("eyeWideLeft_BlinkFix"), 0.5), "eyeBlink 0.5 -> 0.5")
step({ eyeLookDownRight = 0.8, eyeBlinkRight = 0.5 })
check(near(val("eyeLookDownRight_BlinkFix"), 0.4), "right side lookDown x blink")

-- ref reads before the gains (neutral removed); the result takes the mocap master gain
Mocap.patch({ gain = 2 })
step({ eyeWideLeft = 0.5, eyeBlinkLeft = 0.5 })
check(near(val("eyeWideLeft"), 1) and near(val("eyeWideLeft_BlinkFix"), 0.5), "ref before gain, master gain applied after")
Mocap.patch({ gain = 1 })
Mocap.cfg.neutral = { eyeBlinkLeft = 0.5 }
step({ eyeWideLeft = 1, eyeBlinkLeft = 0.75 })
check(near(val("eyeWideLeft_BlinkFix"), 0.5), "neutral removed before ref")
Mocap.cfg.neutral = {}
step({ eyeWideLeft = 1, eyeBlinkLeft = 0.5 })

-- fade mixes with the expression weight like the ARKit keys
Mocap.patch({ fade_sec = 1 })
expr[prog.slot_of.eyeWideLeft_BlinkFix] = 0.2
Mocap.patch({ timeout = 0.1 })
local t = os.clock() + 0.15; while os.clock() < t do end
Mocap.tick(0.5, ctx)   -- stale: fade 1 -> 0.5
check(near(val("eyeWideLeft_BlinkFix"), 0.5 * 0.5 + 0.2 * 0.5), "fading out mixes with the expression weight")
Mocap.tick(0.6, ctx)   -- fade reaches 0: everything handed back
check(val("eyeWideLeft_BlinkFix") == nil and val("eyeWideLeft") == nil, "fade-out releases the derived leases")

Mocap.patch({ enabled = false, timeout = 0.5, fade_sec = 0.25, smoothing = 0.3 })
Mocap.tick(0.05, ctx)
Ext.release_all(Mocap.OWNER)
print("MOCAP_DERIVED FAILS:", dfails)
