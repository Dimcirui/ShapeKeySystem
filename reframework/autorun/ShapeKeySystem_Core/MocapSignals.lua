-- ShapeKeySystem: face mocap through the game's facial signals, for every profile.
--
-- The builtin profiles are written against signal names every game's dictionary shares
-- (smile.L, blink.L, ...), so writing the phone's ARKit values into those signals drives any
-- profile, not only one whose channels carry ARKit names. Mocap.lua still holds the ARKit-named
-- keys as leases; this fills P and the eye angles of the primary rig for everything the profile
-- computes from signals. The mapping is arkit.json read backwards.
--
-- Rules:
-- - One ARKit value per signal. A value ARKit gives once for both sides (browInnerUp, cheekPuff,
--   mouthFunnel, mouthPucker, mouthClose) goes to both signals.
-- - browBring, smileMinor, mouthMove.down, cheekShrink and every other game signal have no ARKit
--   counterpart and fade to 0 while the stream fades in: the face follows the phone only.
-- - A signal the game lacks (no_signal) is written under Profile.no_signal_key, which its node reads.
-- - eyeLook* become eye angles in the SKS convention (yaw + = the character's own left, pitch + =
--   up) at the configured full-weight angles; ARKit In is toward the nose.

local Names = require("ShapeKeySystem_Core.Names")
local Profile = require("ShapeKeySystem_Core.Profile")

local S = {}

-- signal name -> ARKit name
S.MAP = {
    ["blink.L"] = "eyeBlinkLeft", ["blink.R"] = "eyeBlinkRight",
    ["eyeWide.L"] = "eyeWideLeft", ["eyeWide.R"] = "eyeWideRight",
    ["eyeSquint.L"] = "eyeSquintLeft", ["eyeSquint.R"] = "eyeSquintRight",
    ["browDown.L"] = "browDownLeft", ["browDown.R"] = "browDownRight",
    ["browInnerUp.L"] = "browInnerUp", ["browInnerUp.R"] = "browInnerUp",
    ["browOuterUp.L"] = "browOuterUpLeft", ["browOuterUp.R"] = "browOuterUpRight",
    ["sneer.L"] = "noseSneerLeft", ["sneer.R"] = "noseSneerRight",
    ["cheekSquint.L"] = "cheekSquintLeft", ["cheekSquint.R"] = "cheekSquintRight",
    ["puff.L"] = "cheekPuff", ["puff.R"] = "cheekPuff",
    ["smile.L"] = "mouthSmileLeft", ["smile.R"] = "mouthSmileRight",
    ["frown.L"] = "mouthFrownLeft", ["frown.R"] = "mouthFrownRight",
    ["dimple.L"] = "mouthDimpleLeft", ["dimple.R"] = "mouthDimpleRight",
    ["stretch.L"] = "mouthStretchLeft", ["stretch.R"] = "mouthStretchRight",
    ["press.L"] = "mouthPressLeft", ["press.R"] = "mouthPressRight",
    ["upperLipUp.L"] = "mouthUpperUpLeft", ["upperLipUp.R"] = "mouthUpperUpRight",
    ["lowerLipDown.L"] = "mouthLowerDownLeft", ["lowerLipDown.R"] = "mouthLowerDownRight",
    ["funnel.L"] = "mouthFunnel", ["funnel.R"] = "mouthFunnel",
    ["funnelTogether.L"] = "mouthPucker", ["funnelTogether.R"] = "mouthPucker",
    ["lipsTogether.L"] = "mouthClose", ["lipsTogether.R"] = "mouthClose",
    ["mouthMove.left"] = "mouthLeft", ["mouthMove.right"] = "mouthRight",
    ["mouthMove.up"] = "mouthShrugUpper", ["chinRaise"] = "mouthShrugLower",
    ["upperLipRoll"] = "mouthRollUpper", ["lowerLipRoll"] = "mouthRollLower",
    ["jawOpen"] = "jawOpen",
}

local slot_of = {}
for i, n in ipairs(Names.ARKIT52) do slot_of[n] = i end
local LOOK = {}
for _, n in ipairs({ "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeLookDownLeft",
                     "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeLookDownRight" }) do
    LOOK[n] = slot_of[n]
end

-- per signal dictionary: { key, i (ARKit slot), a, b } with P[key] * a + b = the signal value
local st = { for_sig = nil, plan = {}, nosig = {} }

local function plan_for(sigs)
    if st.for_sig == sigs then return st.plan end
    local plan, nosig, seen = {}, {}, {}
    for name, ark in pairs(S.MAP) do
        local sig = sigs.by_name[name]
        local key, a, b
        if sig and not sig.no_signal then key, a, b = sig.key, sig.a, sig.b
        elseif sig or sigs.none then key, a, b = Profile.no_signal_key(name), 1, 0; nosig[#nosig + 1] = key end
        if key ~= nil and not seen[key] and a ~= 0 then
            seen[key] = true
            plan[#plan + 1] = { key = key, i = slot_of[ark], a = a, b = b }
        end
    end
    st.for_sig, st.plan, st.nosig = sigs, plan, nosig
    return plan
end

-- mapped signals a compiled profile reads (prog.sig_names: signal name -> true)
function S.count(prog)
    local n = 0
    if prog and prog.sig_names then
        for name in pairs(S.MAP) do if prog.sig_names[name] then n = n + 1 end end
    end
    return n
end

-- After Expression.read on the primary rig: out = the mocap values by ARKit slot (gains, mirror and
-- smoothing applied), f = stream fade 0..1, fy / fp = eye full-weight angles.
function S.apply(rig, P, out, f, fy, fp)
    local plan = plan_for(Profile.signals)
    local g = 1 - f
    for k, v in pairs(P) do P[k] = v * g end
    for _, e in ipairs(plan) do
        P[e.key] = (P[e.key] or 0) + ((out[e.i] or 0) - e.b) / e.a * f
    end
    local A = rig.angles
    if not A then return end
    local L, R = A.L, A.R
    L[1] = L[1] * g + (out[LOOK.eyeLookOutLeft] - out[LOOK.eyeLookInLeft]) * fy * f
    L[2] = L[2] * g + (out[LOOK.eyeLookUpLeft] - out[LOOK.eyeLookDownLeft]) * fp * f
    R[1] = R[1] * g + (out[LOOK.eyeLookInRight] - out[LOOK.eyeLookOutRight]) * fy * f
    R[2] = R[2] * g + (out[LOOK.eyeLookUpRight] - out[LOOK.eyeLookDownRight]) * fp * f
end

-- the stream is gone: drop the values no game read will overwrite (signals the game lacks, the
-- angles of an eye Expression.read did not refresh this frame)
function S.release(rig, P)
    for _, key in ipairs(st.nosig) do P[key] = nil end
    local A = rig.angles
    if not A then return end
    for _, side in ipairs({ "L", "R" }) do
        local a = A[side]
        if not a.fresh then a[1], a[2] = 0, 0 end
    end
end

return S
