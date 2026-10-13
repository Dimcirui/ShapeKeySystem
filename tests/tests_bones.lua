-- Bone signals: in gameplay emotes MH Wilds moves the face's BONES (jaw, lip corners, brows,
-- cheeks, eyelids), not the fcParam joints (kevin's in-game probes, 2026-10-13). Bone signals read
-- a face bone's position in the head's frame, or an eyelid's turn about its own axis, against its
-- rest pose and the game's idle face, and feed profiles like any signal.
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
-- expected value of a signal for a move of `amount` (metres, or degrees for an eyelid) from the
-- game's idle face, along the signal's own direction
local function expect(signal, amount)
    local s = by[signal]
    local v = amount / s.full
    if s.deadzone and s.deadzone > 0 then v = (v - s.deadzone) / (1 - s.deadzone) end
    return math.max(0, math.min(1, v))
end

-- The game's idle face is not the bones' bind pose: measured in game (sks_lid_probe, 2026-10-13,
-- standing still), offsets from the bind pose in the head's frame (mm) and the upper lids' turn (deg).
local IDLE_MM = {
    C_Chin_LOD00 = { 0, 0.8, 0 },
    L_cornerLip_LOD02 = { -2.1, -1.4, 0 }, R_cornerLip_LOD02 = { 3.0, -1.1, 0 },
    L_BetweenEyeBrow_LOD01 = { 0, -4.2, 0 }, R_BetweenEyeBrow_LOD01 = { 0, -4.2, 0 },
    L_EyeBrow_A_LOD01 = { 0, -3.3, 0 }, R_EyeBrow_A_LOD01 = { 0, -3.5, 0 },
    L_malarFat_B_LOD01 = { 0, 1.3, 0 }, R_malarFat_B_LOD01 = { 0, 1.1, 0 },
}
local IDLE_LID, IDLE_LO = -0.8, -5.9
local function idle_face()
    for k in pairs(BONE_OFF) do BONE_OFF[k] = nil end
    for b, o in pairs(IDLE_MM) do BONE_OFF[b] = { o[1] / 1000, o[2] / 1000, o[3] / 1000 } end
    LID_DEG.L_UpEyeLidJ_LOD02, LID_DEG.R_UpEyeLidJ_LOD02 = IDLE_LID, IDLE_LID
    LID_DEG.L_LoEyeLidJ_LOD02, LID_DEG.R_LoEyeLidJ_LOD02 = IDLE_LO, IDLE_LO
end
-- move a bone by d = {x, y, z} metres from its idle position
local function pose(bone, d)
    local o = IDLE_MM[bone]
    BONE_OFF[bone] = { o[1] / 1000 + d[1], o[2] / 1000 + d[2], o[3] / 1000 + d[3] }
end

check(by.jawDrop and by.jawDrop.bone == "C_Chin_LOD00", "jawDrop is a bone signal on C_Chin_LOD00")
check(by["mouthCornerUp.L"] and by["mouthCornerUp.L"].bone == "L_cornerLip_LOD02", "mouthCornerUp.L reads L_cornerLip_LOD02")
check(by["eyeClose.L"] and by["eyeClose.L"].bone == "L_UpEyeLidJ_LOD02" and by["eyeClose.L"].kind == "rot",
      "eyeClose.L is a rotation signal on L_UpEyeLidJ_LOD02")

-- Maya's face: her own key names, the builtin maya profile
for k in pairs(FC) do FC[k] = nil end
for i = 1, #CHANNELS do CHANNELS[i] = nil end
for i, n in ipairs({ "あ", "口角上げL", "口角上げR", "口角下げ", "口_横幅1", "怒り", "眉_上", "眉_下",
                     "下まつ毛_上_L", "下まつ毛_上_R", "ウィンク２", "ｳｨﾝｸ２右", "びっくり_L", "びっくり_R",
                     "ウィンク", "ウィンク右", "い" }) do CHANNELS[i] = n end
for k in pairs(WEIGHTS) do WEIGHTS[k] = nil end
idle_face()
SKS.call("set_profile", { id = "maya" }); SKS.call("rescan"); ticks(75)
check(st.expression.profile.id == "maya", "maya profile in effect (" .. tostring(st.expression.profile.id) .. ")")

local function moving()
    local out = {}
    for _, n in ipairs(CHANNELS) do if w(n) > 1e-6 then out[#out + 1] = string.format("%s %.2f", n, w(n)) end end
    return out
end
local m = moving()
check(#m == 0, "the game's idle face (brows 3-4 mm below their bind pose): nothing moves" ..
      (#m > 0 and (" -- moving: " .. table.concat(m, ", ")) or ""))

HEAD.pos = { x = 3, y = 1.2, z = -2 }
local l = math.sqrt(0.1 ^ 2 + 0.7 ^ 2 + 0.05 ^ 2 + 0.7 ^ 2)
HEAD.rot = { x = 0.1 / l, y = 0.7 / l, z = 0.05 / l, w = 0.7 / l }
ticks(3)
check(#moving() == 0, "the head moves and turns, the face does not: still nothing (head frame)")

pose("C_Chin_LOD00", { 0, -0.0125, 0 }); ticks(3)
check(near(w("あ"), expect("jawDrop", 0.0125)), string.format("jaw 12.5 mm down -> あ %.3f (want %.3f)", w("あ"), expect("jawDrop", 0.0125)))
idle_face()

pose("L_cornerLip_LOD02", { 0, 0.008, 0 }); ticks(3)
check(near(w("口角上げL"), expect("mouthCornerUp.L", 0.008)) and w("口角上げR") < 1e-6,
      string.format("left lip corner 8 mm up -> 口角上げL %.3f, 口角上げR %.3f", w("口角上げL"), w("口角上げR")))
pose("L_cornerLip_LOD02", { 0, -0.010, 0 }); pose("R_cornerLip_LOD02", { 0, -0.010, 0 }); ticks(3)
check(near(w("口角下げ"), expect("mouthCornerDown.L", 0.010)) and w("口角上げL") < 1e-6,
      string.format("both corners 10 mm down -> 口角下げ %.3f, no smile", w("口角下げ")))
pose("L_cornerLip_LOD02", { 0.007, 0, 0 }); pose("R_cornerLip_LOD02", { -0.007, 0, 0 }); ticks(3)
check(near(w("口_横幅1"), expect("mouthCornerOut.L", 0.007)),
      string.format("both corners 7 mm outward -> 口_横幅1 %.3f", w("口_横幅1")))
pose("R_cornerLip_LOD02", { 0.007, 0, 0 }); ticks(3)
check(near(w("口_横幅1"), 0.5 * expect("mouthCornerOut.L", 0.007)),
      "the right corner moving toward the face's left is not 'outward': only half the width")
idle_face()

pose("L_BetweenEyeBrow_LOD01", { 0, -0.005, 0 }); pose("R_BetweenEyeBrow_LOD01", { 0, -0.005, 0 }); ticks(3)
check(near(w("怒り"), expect("browInnerDown.L", 0.005)), string.format("inner brows 5 mm down -> 怒り %.3f", w("怒り")))
idle_face()
pose("L_EyeBrow_A_LOD01", { 0, 0.006, 0 }); pose("R_EyeBrow_A_LOD01", { 0, 0.006, 0 }); ticks(3)
check(near(w("眉_上"), expect("browRaise.L", 0.006)) and w("眉_下") < 1e-6, string.format("brows 6 mm up -> 眉_上 %.3f", w("眉_上")))
pose("L_EyeBrow_A_LOD01", { 0, -0.005, 0 }); pose("R_EyeBrow_A_LOD01", { 0, -0.005, 0 }); ticks(3)
check(near(w("眉_下"), expect("browLower.L", 0.005)) and w("眉_上") < 1e-6, string.format("brows 5 mm down -> 眉_下 %.3f", w("眉_下")))
idle_face()
pose("L_malarFat_B_LOD01", { 0, 0.007, 0 }); ticks(3)
check(near(w("下まつ毛_上_L"), expect("cheekRaise.L", 0.007)) and w("下まつ毛_上_R") < 1e-6,
      string.format("left cheek 7 mm up -> 下まつ毛_上_L %.3f", w("下まつ毛_上_L")))
idle_face(); ticks(3)

-- eyelids: emotes close the lids with the lid bones while the blink fcParams stay 0. Maya's
-- blink key still shows a slit at 0.8, and the vanilla lids look shut by ~30 deg: full at 30.
LID_DEG.L_UpEyeLidJ_LOD02 = IDLE_LID + 30; ticks(3)
check(near(w("ウィンク２"), 1) and w("ｳｨﾝｸ２右") < 1e-6,
      string.format("left upper lid turned 30 deg past idle -> ウィンク２ %.3f, ｳｨﾝｸ２右 %.3f", w("ウィンク２"), w("ｳｨﾝｸ２右")))
LID_DEG.L_UpEyeLidJ_LOD02 = IDLE_LID + 15; ticks(3)
check(near(w("ウィンク２"), expect("eyeClose.L", 15)), string.format("half closed (15 deg) -> ウィンク２ %.3f (want %.3f)",
      w("ウィンク２"), expect("eyeClose.L", 15)))
LID_DEG.R_UpEyeLidJ_LOD02 = IDLE_LID + 25; ticks(3)
check(near(w("ｳｨﾝｸ２右"), expect("eyeClose.R", 25)), string.format("right lid 25 deg -> ｳｨﾝｸ２右 %.3f", w("ｳｨﾝｸ２右")))
idle_face()
-- wide eyes (cactus spin: -13.8 deg for ~4 s; battle cry: -6.5 deg) -> her びっくり keys
LID_DEG.L_UpEyeLidJ_LOD02 = -13.8; LID_DEG.R_UpEyeLidJ_LOD02 = -13.8; ticks(3)
check(near(w("びっくり_L"), 1) and near(w("びっくり_R"), 1) and w("ウィンク２") < 1e-6,
      string.format("lids opened wide (-13.8 deg, cactus) -> びっくり_L %.3f, _R %.3f, no close", w("びっくり_L"), w("びっくり_R")))
LID_DEG.L_UpEyeLidJ_LOD02 = -6.5; ticks(3)
check(near(w("びっくり_L"), expect("eyeWiden.L", 5.7)), string.format("battle cry glare (-6.5 deg) -> びっくり_L %.3f (want %.3f)",
      w("びっくり_L"), expect("eyeWiden.L", 5.7)))
idle_face(); ticks(3)
check(w("びっくり_L") < 1e-6 and w("ウィンク２") < 1e-6, "lids back at idle -> neither wide nor closed")
-- smiling eyes (happy 1): lower lids lift ~4.4 deg while the mouth smiles -> her ^^ keys
LID_DEG.L_LoEyeLidJ_LOD02 = IDLE_LO - 4.4; pose("L_cornerLip_LOD02", { 0, 0.008, 0 }); ticks(3)
local want = expect("lowerLidRaise.L", 4.4) * expect("mouthCornerUp.L", 0.008)
check(near(w("ウィンク"), want) and w("ウィンク") > 0.3 and w("ウィンク右") < 1e-6,
      string.format("left lower lid up + smile -> ウィンク %.3f (want %.3f), ウィンク右 %.3f", w("ウィンク"), want, w("ウィンク右")))
idle_face(); LID_DEG.L_LoEyeLidJ_LOD02 = IDLE_LO - 4.4; ticks(3)
check(w("ウィンク") < 1e-6, "lower lid up without a smile (battle cry squint) -> no ^^ eyes")
idle_face()
-- a blink during the ^^ (happy 2): the ^^ fades as the eye closes, or both keys stack and her
-- lashes sink into the face (kevin, 2026-10-13: ^^ 0.75 + blink 1.0 hides the lashes)
LID_DEG.L_LoEyeLidJ_LOD02 = IDLE_LO - 4.4; pose("L_cornerLip_LOD02", { 0, 0.008, 0 })
LID_DEG.L_UpEyeLidJ_LOD02 = IDLE_LID + 30; ticks(3)
check(near(w("ウィンク２"), 1) and w("ウィンク") < 1e-6,
      string.format("^^ eyes + a full blink -> ウィンク２ %.3f, ウィンク %.3f (no stacking)", w("ウィンク２"), w("ウィンク")))
LID_DEG.L_UpEyeLidJ_LOD02 = IDLE_LID + 15; ticks(3)
local half = expect("lowerLidRaise.L", 4.4) * expect("mouthCornerUp.L", 0.008) * (1 - expect("eyeClose.L", 15))
check(near(w("ウィンク"), half), string.format("half blink -> ウィンク %.3f (want %.3f, ^^ x (1 - close))", w("ウィンク"), half))
idle_face()
-- the widest smile opens into a grin: い at half once both corners are near fully outward
pose("L_cornerLip_LOD02", { 0.009, 0, 0 }); pose("R_cornerLip_LOD02", { -0.009, 0, 0 }); ticks(3)
check(near(w("い"), 0.5), string.format("corners fully outward (9 mm) -> い %.3f (want 0.5)", w("い")))
pose("L_cornerLip_LOD02", { 0.005, 0, 0 }); pose("R_cornerLip_LOD02", { -0.005, 0, 0 }); ticks(3)
check(w("い") < 1e-6 and w("口_横幅1") > 0.2, string.format("corners 5 mm outward -> 口_横幅1 %.3f but no い", w("口_横幅1")))
idle_face(); ticks(3)
FC[1] = 0.006; LID_DEG.L_UpEyeLidJ_LOD02 = IDLE_LID + 10; ticks(3)
check(near(w("ウィンク２"), math.max(0.6, expect("eyeClose.L", 10))),
      string.format("an idle blink drives both (fcParam 0.6, lid 10 deg) -> ウィンク２ %.3f, the larger", w("ウィンク２")))
FC[1] = nil; idle_face()

-- the game's own face signals still drive the same keys (cutscenes): the louder of the two wins
FC[52] = 0.006; pose("C_Chin_LOD00", { 0, -0.005, 0 }); ticks(3)
check(near(w("あ"), math.max(0.6, expect("jawDrop", 0.005))), string.format("fcParam jawOpen 0.6 with a small bone drop -> あ %.3f", w("あ")))
FC[52] = nil; idle_face(); ticks(3)
check(w("あ") < 1e-6, "all back to idle -> あ 0")

HEAD.pos = { x = 0, y = 1.5, z = 0 }; HEAD.rot = { x = 0, y = 0, z = 0, w = 1 }
for k in pairs(BONE_OFF) do BONE_OFF[k] = nil end
for k in pairs(LID_DEG) do LID_DEG[k] = nil end

-- every profile tools/vrc_profiles/gen.py builds: a channel driven by one of these game signals
-- also reads the bone signal of the same motion, same side (the emote face)
local BONE_OF = { browOuterUp = "browRaise", browDown = "browLower", browBring = "browInnerDown",
                  cheekSquint = "cheekRaise", jawOpen = "jawDrop", smile = "mouthCornerUp",
                  frown = "mouthCornerDown", stretch = "mouthCornerOut", blink = "eyeClose",
                  eyeWide = "eyeWiden" }
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
