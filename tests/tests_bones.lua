-- Bone signals: in gameplay emotes MH Wilds moves the face's BONES (jaw, lip corners, brows,
-- cheeks), not the fcParam joints (kevin's in-game probes, 2026-10-13). Bone signals read a face
-- bone's position in the head's frame against its rest pose and feed profiles like any signal.
local SKS = require("ShapeKeySystem_Core.API")
local Profile = require("ShapeKeySystem_Core.Profile")
local st = SKS.state
local bf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[bones] " .. what)
    if not cond then bf = bf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function idx(chname) for i, n in ipairs(CHANNELS) do if n == chname then return i - 1 end end end
local function w(name) return WEIGHTS[idx(name)] or 0 end
local function near(a, b) return math.abs(a - b) < 1e-4 end

local by = Profile.signals.by_name
local function expect(signal, metres)
    local s = by[signal]
    local v = metres / s.full
    if s.deadzone and s.deadzone > 0 then v = (v - s.deadzone) / (1 - s.deadzone) end
    return math.max(0, math.min(1, v))
end

check(by.jawDrop and by.jawDrop.bone == "C_Chin_LOD00", "jawDrop is a bone signal on C_Chin_LOD00")
check(by["mouthCornerUp.L"] and by["mouthCornerUp.L"].bone == "L_cornerLip_LOD02", "mouthCornerUp.L reads L_cornerLip_LOD02")

-- Maya's face: her own key names, the builtin maya profile
for k in pairs(FC) do FC[k] = nil end
for i = 1, #CHANNELS do CHANNELS[i] = nil end
for i, n in ipairs({ "あ", "口角上げL", "口角上げR", "口角下げ", "口_横幅1", "怒り", "眉_上", "眉_下",
                     "下まつ毛_上_L", "下まつ毛_上_R", "ウィンク２" }) do CHANNELS[i] = n end
for k in pairs(WEIGHTS) do WEIGHTS[k] = nil end
SKS.call("set_profile", { id = "maya" }); SKS.call("rescan"); ticks(75)
check(st.expression.profile.id == "maya", "maya profile in effect (" .. tostring(st.expression.profile.id) .. ")")

local all_zero = true
for _, n in ipairs(CHANNELS) do if w(n) > 1e-6 then all_zero = false end end
check(all_zero, "every bone at rest: nothing moves")

HEAD.pos = { x = 3, y = 1.2, z = -2 }
HEAD.rot = { x = 0.1, y = 0.7, z = 0.05, w = 0.7 }
local l = math.sqrt(0.1 ^ 2 + 0.7 ^ 2 + 0.05 ^ 2 + 0.7 ^ 2)
HEAD.rot = { x = 0.1 / l, y = 0.7 / l, z = 0.05 / l, w = 0.7 / l }
ticks(3)
all_zero = true
for _, n in ipairs(CHANNELS) do if w(n) > 1e-6 then all_zero = false end end
check(all_zero, "the head moves and turns, the face does not: still nothing (head frame)")

BONE_OFF.C_Chin_LOD00 = { 0, -0.0125, 0 }; ticks(3)
check(near(w("あ"), expect("jawDrop", 0.0125)), string.format("jaw 12.5 mm down -> あ %.3f (want %.3f)", w("あ"), expect("jawDrop", 0.0125)))
BONE_OFF.C_Chin_LOD00 = nil

BONE_OFF.L_cornerLip_LOD02 = { 0, 0.008, 0 }; ticks(3)
check(near(w("口角上げL"), expect("mouthCornerUp.L", 0.008)) and w("口角上げR") < 1e-6,
      string.format("left lip corner 8 mm up -> 口角上げL %.3f, 口角上げR %.3f", w("口角上げL"), w("口角上げR")))
BONE_OFF.L_cornerLip_LOD02 = { 0, -0.010, 0 }; BONE_OFF.R_cornerLip_LOD02 = { 0, -0.010, 0 }; ticks(3)
check(near(w("口角下げ"), expect("mouthCornerDown.L", 0.010)) and w("口角上げL") < 1e-6,
      string.format("both corners 10 mm down -> 口角下げ %.3f, no smile", w("口角下げ")))
BONE_OFF.L_cornerLip_LOD02 = { 0.007, 0, 0 }; BONE_OFF.R_cornerLip_LOD02 = { -0.007, 0, 0 }; ticks(3)
check(near(w("口_横幅1"), expect("mouthCornerOut.L", 0.007)),
      string.format("both corners 7 mm outward -> 口_横幅1 %.3f", w("口_横幅1")))
BONE_OFF.R_cornerLip_LOD02 = { 0.007, 0, 0 }; ticks(3)
check(near(w("口_横幅1"), 0.5 * expect("mouthCornerOut.L", 0.007)),
      "the right corner moving toward the face's left is not 'outward': only half the width")
BONE_OFF.L_cornerLip_LOD02, BONE_OFF.R_cornerLip_LOD02 = nil, nil

BONE_OFF.L_BetweenEyeBrow_LOD01 = { 0, -0.005, 0 }; BONE_OFF.R_BetweenEyeBrow_LOD01 = { 0, -0.005, 0 }; ticks(3)
check(near(w("怒り"), expect("browInnerDown.L", 0.005)), string.format("inner brows 5 mm down -> 怒り %.3f", w("怒り")))
BONE_OFF.L_BetweenEyeBrow_LOD01, BONE_OFF.R_BetweenEyeBrow_LOD01 = nil, nil
BONE_OFF.L_EyeBrow_A_LOD01 = { 0, 0.006, 0 }; BONE_OFF.R_EyeBrow_A_LOD01 = { 0, 0.006, 0 }; ticks(3)
check(near(w("眉_上"), expect("browRaise.L", 0.006)) and w("眉_下") < 1e-6, string.format("brows 6 mm up -> 眉_上 %.3f", w("眉_上")))
BONE_OFF.L_EyeBrow_A_LOD01 = { 0, -0.005, 0 }; BONE_OFF.R_EyeBrow_A_LOD01 = { 0, -0.005, 0 }; ticks(3)
check(near(w("眉_下"), expect("browLower.L", 0.005)) and w("眉_上") < 1e-6, string.format("brows 5 mm down -> 眉_下 %.3f", w("眉_下")))
BONE_OFF.L_EyeBrow_A_LOD01, BONE_OFF.R_EyeBrow_A_LOD01 = nil, nil
BONE_OFF.L_malarFat_B_LOD01 = { 0, 0.007, 0 }; ticks(3)
check(near(w("下まつ毛_上_L"), expect("cheekRaise.L", 0.007)) and w("下まつ毛_上_R") < 1e-6,
      string.format("left cheek 7 mm up -> 下まつ毛_上_L %.3f", w("下まつ毛_上_L")))
BONE_OFF.L_malarFat_B_LOD01 = nil

-- the game's own face signals still drive the same keys (cutscenes): the louder of the two wins
FC[52] = 0.006; BONE_OFF.C_Chin_LOD00 = { 0, -0.005, 0 }; ticks(3)
check(near(w("あ"), math.max(0.6, expect("jawDrop", 0.005))), string.format("fcParam jawOpen 0.6 with a small bone drop -> あ %.3f", w("あ")))
FC[52] = nil; BONE_OFF.C_Chin_LOD00 = nil; ticks(3)
check(w("あ") < 1e-6, "all back to rest -> あ 0")

HEAD.pos = { x = 0, y = 1.5, z = 0 }; HEAD.rot = { x = 0, y = 0, z = 0, w = 1 }

-- every profile tools/vrc_profiles/gen.py builds: a channel driven by one of these game signals
-- also reads the bone signal of the same motion, same side (the emote face)
local BONE_OF = { browOuterUp = "browRaise", browDown = "browLower", browBring = "browInnerDown",
                  cheekSquint = "cheekRaise", jawOpen = "jawDrop", smile = "mouthCornerUp",
                  frown = "mouthCornerDown", stretch = "mouthCornerOut" }
local GENERATED = { "airi", "chocolat", "kaguya", "karin", "kipfel", "mafuyu", "manuka", "maya", "moko",
                    "nitco", "sairou" }
local function reads(node, acc)
    if type(node) ~= "table" then return acc end
    if type(node.s) == "string" then acc[node.s] = true end
    for _, v in pairs(node) do if type(v) == "table" then reads(v, acc) end end
    return acc
end
Profile.load_all()
for _, id in ipairs(GENERATED) do
    local prof = Profile.resolve(id)
    local missing, paired = {}, 0
    for _, ch in ipairs(prof and prof.channels or {}) do
        local sig = reads(Profile.node_of(ch), {})
        for s in pairs(sig) do
            local base, side = s:match("^([^.]+)(.*)$")
            local bone = BONE_OF[base]
            if bone then
                if sig[bone .. side] then paired = paired + 1
                else missing[#missing + 1] = ch.name .. ":" .. s end
            end
        end
    end
    table.sort(missing)
    check(prof ~= nil and #missing == 0 and paired > 0, string.format("%s: game signals paired with bone signals (%d paired%s)",
          id, paired, #missing > 0 and ("; missing " .. table.concat(missing, ", ")) or ""))
end

print("BONES FAILS:", bf)
