-- MMD profile: width folding, "any" ranking, "unless", real key names of 6 PMX models
local U = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")
local Profile = require("ShapeKeySystem_Core.Profile")
local mf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[mmd] " .. what)
    if not cond then mf = mf + 1 end
end

check(U.norm("ｳｨﾝｸ２右") == U.norm("ウィンク2右"), "half-width kana + full-width digit fold")
check(U.norm("ｶﾞﾊﾟｳﾞ") == U.norm("ガパヴ"), "voiced / semi-voiced marks merge")
check(U.norm("星目 ") == U.norm("星目"), "trailing space ignored")
check(U.norm("目　閉じ") == U.norm("目閉じ"), "ideographic space ignored")
check(U.norm("ＷＩＮＫ＿Ｒ") == "winkr", "full-width ASCII -> lower ASCII")
check(U.norm("eyeBlink_Left") == "eyeblinkleft", "ASCII names unchanged")
check(pcall(U.norm, "bad\255\254name"), "invalid UTF-8 does not raise")

check(Profile.registry["mmd"] ~= nil, "mmd profile registered")
local r = Profile.resolve("mmd")
local prog = r and Profile.compile(r, {})
check(prog ~= nil, "mmd profile compiles")
for _, id in ipairs({ "eku", "milltina", "manuka", "chocolat", "airi", "kaguya", "karin", "kipfel",
                      "mafuyu", "maya", "moko", "nitco", "sairou" }) do
    local rr = Profile.resolve(id)
    local pp, code, msg = rr and Profile.compile(rr, {})
    check(pp ~= nil and pp.n == #rr.channels, id .. " profile compiles " .. tostring(msg or ""))
    local driven = 0
    for _, c in ipairs(pp and pp.channels or {}) do if c.has_signal then driven = driven + 1 end end
    check(pp ~= nil and driven == pp.n, id .. ": every channel has a signal")
end
local names = {}
for i, c in ipairs(prog.channels) do names[i] = c.name end
local idx = Names.build_index(names, r.aliases, r.channels)

local function pick(model)
    local list = MMD_NAMES[model]
    local sel = Names.match_part(idx, list)
    local out = {}
    for i, s in ipairs(sel) do
        if s then
            local ch = names[s]
            if out[ch] then out[ch] = out[ch] .. "|" .. list[i] else out[ch] = list[i] end
        end
    end
    return out
end

local expect = {
    Anon = { ["ウィンク２"] = "ウィンク２", ["ｳｨﾝｸ２右"] = "ｳｨﾝｸ２右", ["まばたき"] = false,
             ["口角上げ"] = false, ["口角上げ左"] = "口角上げ左", ["口角上げ右"] = "口角上げ右",
             ["口角下げ"] = false, ["口角下げ左"] = "口角下げ左", ["口横狭く"] = "口横狭く",
             ["あ"] = "あ", ["う"] = "う", ["上"] = "上", ["下"] = "下", ["困る"] = "困る", ["怒り"] = "怒り",
             ["びっくり"] = "びっくり", ["じと目"] = "じと目", ["下瞼上げ"] = false },
    PEKORA = { ["ウィンク２"] = "ウィンク2", ["ｳｨﾝｸ２右"] = "ウィンク右2", ["まばたき"] = false,
               ["口角上げ"] = "にこり口", ["口角下げ"] = "口角下げ", ["下瞼上げ"] = "下まつ毛上げ",
               ["上"] = false, ["下"] = false, ["困る"] = "困る", ["怒り"] = "怒り", ["口横広げ"] = false },
    ["白希1.0"] = { ["ウィンク２"] = "ウィンク２", ["ｳｨﾝｸ２右"] = "ｳｨﾝｸ２右", ["口横狭く"] = "口横缩げ",
                   ["びっくり"] = "びっくり", ["上"] = "上", ["下"] = "下" },
    ["绯英"] = { ["ウィンク２"] = "ウィンク２", ["ｳｨﾝｸ２右"] = "ｳｨﾝｸ２右", ["まばたき"] = false,
                ["怒り"] = "怒り", ["口上"] = "口上", ["口下"] = "口下", ["口横狭く"] = "口横缩げ" },
    ["莉奈娅"] = { ["ウィンク２"] = "ウィンク２", ["ｳｨﾝｸ２右"] = "ウィンク２右", ["まばたき"] = false,
                  ["じと目"] = "じと目", ["下瞼上げ"] = "下眼上", ["口横狭く"] = "口横狭め", ["口角下げ"] = false },
    ["菲娜2.0"] = { ["ウィンク２"] = "ウィンク２", ["ｳｨﾝｸ２右"] = "ｳｨﾝｸ２右", ["口角上げ"] = "口角上げ",
                   ["口上"] = "口上", ["口下"] = "口下", ["困る"] = "困る" },
}
local models = {}
for m in pairs(expect) do models[#models + 1] = m end
table.sort(models)
for _, m in ipairs(models) do
    local got = pick(m)
    local n = 0
    for _ in pairs(got) do n = n + 1 end
    for ch, want in pairs(expect[m]) do
        local g = got[ch] or false
        check(g == want, string.format("%s: %s -> %s (got %s)", m, ch, tostring(want), tostring(g)))
    end
    local need = (m == "PEKORA") and 10 or 12
    check(n >= need, string.format("%s: %d channels driven", m, n))
    check(Profile.match_count("mmd", MMD_NAMES[m], Names) > Profile.match_count("arkit", MMD_NAMES[m], Names),
          m .. ": mmd outranks ARKit for recommendation")
end

-- LOD copies of the chosen name stay, a lower-ranked candidate is dropped
local sel = Names.match_part(idx, { "blendShape1.ウィンク", "blendShape1.ウィンク２", "blendShape1_LOD1.ウィンク２_LOD1" })
check(not sel[1] and sel[2] and sel[3] == sel[2], "best candidate + its LOD copy, fallback dropped")

-- profiles without any/unless keep matching every alias
local ra = Profile.resolve("arkit")
local an = {}
for i, c in ipairs(ra.channels) do an[i] = c.name end
local aidx = Names.build_index(an, ra.aliases, ra.channels)
local asel = Names.match_part(aidx, { "eyeBlinkLeft", "EyeClosedLeft" })
check(asel[1] and asel[2] == asel[1], "ARKit: alias and canonical both kept (no ranking)")

-- VRChat avatar faces (real key lists from the "Body" mesh): coverage ranking picks the avatar's own profile
local VRC_EXPECT = { airi = "airi", chocolat = "chocolat", plum = "chocolat", lime = "chocolat",
    kaguya = "kaguya", karin = "karin", kipfel = "kipfel", mafuyu = "mafuyu", maya = "maya",
    moko = "moko", nitco = "nitco", sairou = "sairou", milltina = "milltina", shinano = "shinano",
    shinano_arkit = "arkit", manuka = "manuka", kumaly = "manuka", rindo = "manuka", selestia = "manuka" }
for face, want in pairs(VRC_EXPECT) do
    local best, best_n, second = nil, -1, -1
    for _, e in ipairs(Profile.list) do
        if e.source == "builtin" then   -- earlier groups save user copies of builtin profiles
            local n = Profile.match_count(e.id, VRC_FACES[face], Names)
            if n > best_n then best, best_n, second = e.id, n, best_n elseif n > second then second = n end
        end
    end
    check(best == want and best_n > second, string.format("vrc face %s -> %s (%d, next %d)", face, tostring(best), best_n, second))
end

print("MMD FAILS:", mf)
