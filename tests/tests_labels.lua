-- Display labels: builtin table, mod / user name tables, alias fallback, state fields
local U = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")
local Labels = require("ShapeKeySystem_Core.Labels")
local SKS = require("ShapeKeySystem_Core.API")
local st = SKS.state
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local lf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[labels] " .. what)
    if not cond then lf = lf + 1 end
end

Labels.load()
local n_arkit = 0
for _, n in ipairs(Names.ARKIT52) do if Labels.builtin[U.norm(n)] then n_arkit = n_arkit + 1 end end
check(n_arkit == 52, "every ARKit name has a builtin label (" .. n_arkit .. ")")
check(Labels.of("eyeBlinkLeft") == "左眼闭眼", "ARKit name")
check(Labels.of("blendShape1.EyeBlinkLeft_LOD1") == "左眼闭眼", "node prefix and _LODn suffix")
check(Labels.of("Eye_Left_Blink") == "左眼闭眼", "alias falls back to its ARKit label")
check(Labels.of("ｳｨﾝｸ２右") == "右眼闭眼", "MMD name, half-width kana")
check(Labels.of("口角上げ") == "嘴角上扬", "SKS mmd profile channel")
check(Labels.of("Waist_thin") == nil, "unknown name -> nil")
check(Labels.of("") == nil and Labels.of(nil) == nil, "empty / nil name -> nil")

-- mod and user tables: user wins over mod, both win over builtin
json.dump_file("ShapeKeySystem\\mods\\names\\LabelMod.json", { schema = "sks.names/1",
    labels = { Waist_thin = "腰变细(mod)", eyeBlinkLeft = "左眨眼(mod)", ["#1A2B3C4D"] = "眼睛大小" } })
json.dump_file("ShapeKeySystem\\user\\names\\LabelUser.json", { schema = "sks.names/1",
    labels = { Waist_thin = "腰变细" } })
json.dump_file("ShapeKeySystem\\user\\names\\Other.json", { schema = "other/1", labels = { Waist_thin = "x" } })
Labels.load()
check(Labels.of("Waist_thin") == "腰变细", "user label overrides the mod label")
check(Labels.of("eyeBlinkLeft") == "左眨眼(mod)", "mod label overrides the builtin label")
check(Labels.of("#1A2B3C4D") == "眼睛大小", "hash name can carry a label")
local listed = false
for _, n in ipairs(Labels.names) do if n == "Waist_thin" then listed = true end end
check(listed, "labelled names are offered to the hash lookup")

-- state: labels ride along, names stay the mesh names (this scene has no ARKit names)
SKS.call("sculpt_scan"); ticks(3)
local k1 = st.sculpt.keys and st.sculpt.keys[1]
local c1 = st.expression.channels and st.expression.channels[1]
check(k1 ~= nil and c1 ~= nil, "scene has sculpt keys and expression channels")
if k1 and c1 then
    local kname, cname = k1.name, c1.name
    json.dump_file("ShapeKeySystem\\user\\names\\LabelUser.json", { schema = "sks.names/1",
        labels = { Waist_thin = "腰变细", [kname] = "测试键", [cname] = "测试通道" } })
    Labels.load()
    SKS.call("set_profile", { id = SKS.state.expression.profile.id }); SKS.call("sculpt_scan"); ticks(3)
    local k, c
    for _, x in ipairs(st.sculpt.keys) do if x.name == kname then k = x end end
    for _, x in ipairs(st.expression.channels) do if x.name == cname then c = x end end
    check(k and k.label == "测试键" and k.name == kname, "sculpt key carries its label, name unchanged")
    check(c and c.label == "测试通道" and c.name == cname, "expression channel carries its label, name unchanged")
end

-- the mock has no file delete: empty the tables so later groups see builtin labels only
for _, p in ipairs({ "mods\\names\\LabelMod.json", "user\\names\\LabelUser.json", "user\\names\\Other.json" }) do
    json.dump_file("ShapeKeySystem\\" .. p, { schema = "sks.names/1" })
end
Labels.load()
check(Labels.of("Waist_thin") == nil, "tables emptied")
print("LABELS FAILS:", lf)
