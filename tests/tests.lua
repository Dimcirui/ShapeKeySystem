local SKS = require("ShapeKeySystem_Core.API")
local st, live = SKS.state, SKS.live
local fails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. what)
    if not cond then fails = fails + 1 end
end
local function ticks(n) for _ = 1, n do CB.tick(); CB.frame() end end
local function slot(name) for _, c in ipairs(st.expression.channels) do if c.canonical == name then return c.slot, c end end end
local function idx(chname) for i, n in ipairs(CHANNELS) do if n == chname then return i - 1 end end end

FC[1] = 0.01; FC[52] = 0.005; FC[33] = 0.004; FC[31] = 0.004; FC[175] = 0.01; FC[176] = 0.0
ticks(30)
check(#writes == 0, "no writes during the 60-frame warm-up")
ticks(45)
print("status:", st.debug.status)
check(#st.scene.rigs == 1 and st.scene.rigs[1].primary, "one primary rig")
check(#st.scene.parts == 1 and st.scene.parts[1].id == "ch03_012_0012", "only ch03 part listed (NPC ch00 filtered)")
local t = st.scene.rigs[1].targets[1]
print("target:", t.name, t.channels, t.writes)
check(t.channels == 8, "8 distinct matched channels (blink, jaw, lookIn, smile alias, innerUp, pucker, eyeLookIn, tongue)")
check(t.writes == 9, "9 mesh indices incl. JawOpen_LOD1")
print("reads per frame:", st.scene.rigs[1].reads)
check(st.scene.rigs[1].reads == 10, "reads pruned to the mesh's channels: 8 fcParams + 2 eyes (was 51)")
check(math.abs(WEIGHTS[idx("blendShape1.EyeBlinkLeft")] - 1.0) < 1e-6, "eyeBlinkLeft = 1.0 (case-insensitive)")
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 0.5) < 1e-6, "JawOpen = 0.5")
check(math.abs(WEIGHTS[idx("blendShape1_LOD1.JawOpen_LOD1")] - 0.5) < 1e-6, "JawOpen_LOD1 driven too")
check(math.abs(WEIGHTS[idx("blendShape1.Mouth_Smile_Left")] - 0.6) < 1e-6, "SRanipal alias Mouth_Smile_Left = 0.4 + 0.4*0.5")
check(math.abs(WEIGHTS[idx("blendShape1.mouthPucker")] - 0.5) < 1e-6, "mouthPucker = 0.5*fc175")
check(WEIGHTS[idx("blendShape1.Other")] == nil, "unmatched channel never written")
local s_look = slot("LookInLeft")
print("eye L yaw", live.eye_angle.L.yaw, "LookInLeft w", live.weight[s_look])
check(math.abs(live.eye_angle.L.yaw - 10) < 0.1 and math.abs(live.weight[s_look] - 0.4) < 0.01, "eye yaw 10 deg -> LookInLeft 0.4 (25 deg full)")

local cov = st.expression.coverage
print("coverage", cov.arkit_hit, cov.arkit_total, cov.extra, cov.recommended)
check(cov.arkit_hit == 7, "ARKit coverage 7 (blink, jaw, smile, innerUp, pucker, eyeLookIn, tongue)")

-- gains
local s_jaw = slot("jawOpen")
check(SKS.call("set_master_gain", { value = 2 }), "set_master_gain")
ticks(1)
check(math.abs(live.weight[s_jaw] - 1.0) < 1e-6, "master gain 2 -> jaw 1.0")
SKS.call("set_region_gain", { region = "mouth", value = 0.5 })
ticks(1)
check(math.abs(live.weight[s_jaw] - 0.5) < 1e-6, "mouth region 0.5 (jaw group in mouth region)")
SKS.call("set_master_gain", { value = 1 }); SKS.call("set_region_gain", { region = "mouth", value = 1 })
SKS.call("set_channel_gain", { name = "jawOpen", value = 1.5 })
ticks(1)
check(math.abs(live.weight[s_jaw] - 0.75) < 1e-6, "channel gain 1.5 -> 0.75")
SKS.call("set_channel_gain", { name = "jawOpen", value = 1 })
SKS.call("set_gaze_gain", { value = 0 })
ticks(1)
check(live.weight[s_look] == 0, "gaze gain 0 -> LookInLeft 0")
SKS.call("set_gaze_gain", { value = 1 })
SKS.call("set_eye_cfg", { patch = { sets = { look = false } } })
ticks(1)
check(live.weight[s_look] == 0 and live.weight[slot("eyeLookInLeft")] > 0.3, "look set off, eye_look still on")
SKS.call("set_eye_cfg", { patch = { sets = { look = true } } })
SKS.call("calibrate_eye_neutral")
ticks(1)
check(math.abs(live.eye_angle.L.yaw) < 1e-6, "calibrate neutral -> yaw 0")

-- force / errors
local s_t = slot("tongueOut")
SKS.call("force_channel", { name = "tongueOut", on = true }); ticks(1)
check(WEIGHTS[idx("blendShape1.tongueOut")] == 1.0, "force tongueOut -> 1")
SKS.call("force_channel", { name = "tongueOut", on = false }); ticks(1)
check(WEIGHTS[idx("blendShape1.tongueOut")] == 0, "unforce -> 0")
local ok, code = SKS.call("set_channel_gain", { name = "nope", value = 1 })
check(not ok and code == "E_NOT_FOUND", "unknown channel -> E_NOT_FOUND")
ok, code = SKS.call("sculpt_scan")
check(ok, "sculpt_scan implemented (M2)")

-- mapping editor
ok, code = SKS.call("edit_node", { name = "tongueOut", node = { mul = { { ref = "jawOpen" }, { s = "smile.L" } } } })
check(ok, "edit_node tongueOut = jawOpen × smile.L")
ticks(1)
print("tongue", live.weight[s_t], select(2, slot("tongueOut")).source_text)
check(math.abs(live.weight[s_t] - 0.2) < 1e-6, "ref × signal = 0.5 × 0.4")
ok, code = SKS.call("edit_node", { name = "jawOpen", node = { ref = "tongueOut" } })
check(not ok and code == "E_NODE_INVALID", "ref cycle rejected")
ok, code = SKS.call("edit_node", { name = "jawOpen", node = { s = "nope" } })
check(not ok and code == "E_NODE_INVALID", "unknown signal rejected")
ok, code = SKS.call("edit_node", { name = "browInnerUp", node = { p = 120, curve = { deadzone = 0.5 } } })
check(ok, "raw param node accepted")
FC[120] = 0.0075; ticks(3)
check(math.abs(live.weight[slot("browInnerUp")] - 0.5) < 1e-6, "new raw param read after auto rescan, deadzone 0.5 on 0.75 -> 0.5")
ok, code = SKS.call("save_profile", {})
check(not ok and code == "E_READONLY", "overwrite builtin -> E_READONLY")
local ok2, c2, m2, res = SKS.call("save_profile", { as_name = "My Test" })
check(ok2 and res.id == "My Test", "save as user profile")
check(st.expression.profile.source == "user", "now on user profile")
SKS.call("set_profile", { id = "arkit" }); ticks(3)
check(st.expression.profile.id == "arkit" and live.weight[s_t] == 0, "back to builtin arkit, tongue 0 again")
SKS.call("set_profile", { id = "My Test" }); ticks(3)
check(math.abs(live.weight[slot("tongueOut")] - 0.2) < 1e-6, "saved profile reloads its edit")

-- live signals / ui
SKS.set_ui_open(true, true); ticks(1)
check(math.abs(live.signal[1] - 1.0) < 1e-6, "live.signal[blink.L] = 1")
check(live.region_activity[2] >= 1.0, "eye region activity")
CB.ui()

-- disable
local n0 = #writes
SKS.call("set_enabled", { on = false }); ticks(2)
check(WEIGHTS[idx("blendShape1.EyeBlinkLeft")] == 0 and WEIGHTS[idx("blendShape1.JawOpen")] == 0, "disable zeroes channels")
local n1 = #writes; ticks(5)
check(#writes == n1, "no writes while disabled")

-- write skipping
SKS.call("set_enabled", { on = true }); ticks(3)
local n2 = #writes; ticks(10)
check(#writes == n2, "steady state: no writes when values are unchanged")
-- periodic rescan keeps warm-up and last values (no pause, no rewrite)
local n3 = #writes
SKS.call("rescan"); ticks(3)
check(#st.scene.rigs == 1 and #writes == n3, "rescan of the same mesh: no warm-up pause, no rewrite")
FC[52] = 0.008; ticks(1)
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 0.8) < 1e-6, "still writing right after rescan")

-- cutscene gate (cutscene_drive off)
check(st.settings.cutscene_drive == true, "cutscene_drive defaults to on")
SKS.call("set_setting", { key = "cutscene_drive", value = false })
DEMO.busy = true; ticks(1)
check(#st.scene.rigs == 1 and st.debug.status:find("paused"), "cutscene: paused")
check(WEIGHTS[idx("blendShape1.JawOpen")] == 0, "cutscene: weights zeroed before letting go")
local n4 = #writes; FC[52] = 0.01; ticks(20)
check(#writes == n4, "cutscene: nothing written while paused")
DEMO.busy = false; ticks(40)
check(#writes == n4, "after cutscene: settle + warm-up before writing")
ticks(70)
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 1.0) < 1e-6, "after cutscene: writing again")

-- skip request / equipment rebuild / mesh not ready
SKS.on_release("requestSkip")
check(#st.scene.rigs == 1, "state.scene keeps last scan info")
local n5 = #writes; FC[52] = 0.002; ticks(5)
check(#writes == n5, "skip request: all rigs released immediately")
ticks(200)
check(#writes > n5, "skip request: rescans on its own after settle + warm-up")
SKS.on_rebuilt(); local n6 = #writes; ticks(20)
check(#writes == n6, "equip rebuild: released, waiting to rescan")
ticks(100)
MESH_STATE.ready = false; local n7 = #writes; FC[52] = 0.009; ticks(3)
check(#writes == n7, "mesh not ready: no writes, rig dropped")
MESH_STATE.ready = true; ticks(130)
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 0.9) < 1e-6, "mesh ready again: writing resumes")

-- player not set up: menu mode (title / save select), hunters in the scene are driven
SETUP = false; local m0 = #writes; FC[52] = 0.003; ticks(12)
check(#writes == m0, "menu mode: let go on entering, nothing written yet")
ticks(60)
check(st.debug.status:find("[menu]", 1, true) ~= nil, "menu mode: scanned with scene search")
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 0.3) < 1e-6, "menu mode: hunter driven")
for _ = 1, 5000 do SKS.on_menu("GUI010100", false) end; ticks(1)   -- per-frame spam
for _ = 1, 5000 do SKS.on_menu("GUI010100", false) end; ticks(1)

SKS.on_menu("GUI010102", true); local m1 = #writes; FC[52] = 0.006; ticks(5)
check(#writes == m1, "menu GUI open: released")
ticks(60)
check(math.abs(WEIGHTS[idx("blendShape1.JawOpen")] - 0.6) < 1e-6, "menu GUI open: driving again")
SETUP = true; local m2 = #writes; ticks(12)
check(#writes == m2, "player set up: let go first")
ticks(130)
local ok_u, _, _, r_u = SKS.call("sculpt_undo")
check(ok_u == true and r_u and r_u.done == false, "undo with nothing to undo: no-op, not an error")

do
-- M2: parent presets (bindings), per-part tuning and the sculpt layer. Default mock channels,
-- part ch03_012_0012 (model folder ch03_012_001).
SKS.call("set_profile", { id = "arkit" }); ticks(3)
local function key(name) for _, k in ipairs(st.sculpt.keys) do if k.name == name then return k end end end
local function dump(path, t) json.dump_file("ShapeKeySystem\\" .. path, t) end
local function load(path) return json.load_file("ShapeKeySystem\\" .. path) end
local i_waist, i_other = idx("blendShape1.Waist_thin"), idx("blendShape1.Other")
local M = "ch03_012_001"

-- every channel is listed; the ones the profile drives are locked
check(st.sculpt.scan and st.sculpt.scan.keys == 10, "sculpt lists all 10 keys (JawOpen_LOD1 merged into JawOpen)")
check(st.sculpt.scan.expression_keys == 8, "8 of them driven by the expression profile")
check(key("EyeBlinkLeft") and key("EyeBlinkLeft").mixed and not key("EyeBlinkLeft").locked and key("EyeBlinkLeft").owner == "expression", "EyeBlinkLeft shown, editable (mixed with the expression)")
check(key("Waist_thin") and key("Waist_thin").owner == "self" and not key("Waist_thin").locked, "Waist_thin editable")
-- (expression keys are editable since 2026-10-10; mixing is tested in tests_api.lua)
local ok, code
check(WEIGHTS[i_waist] == nil, "unchanged channel: no write")

ok, code = SKS.call("set_sculpt_key", { name = "nope", value = 1 })
check(not ok and code == "E_NOT_FOUND", "unknown sculpt key -> E_NOT_FOUND")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.7 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.7) < 1e-6, "set_sculpt_key writes on the next tick")
local w1 = #writes; ticks(10)
check(#writes == w1, "lazy: no rewrite while the value stays")
check(st.settings.sculpt_max == 1, "sculpt slider cap defaults to 1")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 3 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 1.0) < 1e-6, "default cap: clamped to 0..1")
SKS.call("set_setting", { key = "sculpt_max", value = 2 }); ticks(1)
local kw; for _, k in ipairs(st.sculpt.keys) do if k.name == "Waist_thin" then kw = k end end
check(kw and kw.range[2] == 2, "cap 2: slider range follows")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 3 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 2.0) < 1e-6, "clamped to the 0..2 range")
SKS.call("set_setting", { key = "sculpt_max", value = 1.5 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 1.5) < 1e-6, "lowering the cap clamps existing values")
SKS.call("set_setting", { key = "sculpt_max", value = 2 }); ticks(1)
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 3 }); ticks(1)
check(st.sculpt.dirty and st.sculpt.can_undo, "dirty + undo available")

-- undo / redo; a drag (repeated set of one key) is one step
SKS.call("sculpt_undo"); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.7) < 1e-6, "undo -> 0.7")
SKS.call("sculpt_redo"); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 2.0) < 1e-6, "redo -> 2.0")
SKS.call("set_edit_mode", { on = true })
for _, v in ipairs({ 0.1, 0.2, 0.3 }) do SKS.call("set_sculpt_key", { name = "Waist_thin", value = v }); ticks(1) end
SKS.call("set_edit_mode", { on = false }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.3) < 1e-6, "edit mode drag ends at 0.3")
SKS.call("sculpt_undo"); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 2.0) < 1e-6, "one undo reverts the whole drag")
SKS.call("sculpt_redo"); ticks(1)

-- save a sculpt preset into the model folder and bind it
local ok2, c2, m2, res = SKS.call("save_sculpt", { name = "Body A" })
check(ok2 and res.id == "Body A" and res.folder == M, "save_sculpt -> user/ch03_012_001/sculpt/Body A.json")
check(load("user\\" .. M .. "\\sculpt\\Body A.json") ~= nil, "file is in the model folder")
check(not st.sculpt.dirty and st.sculpt.preset.name == "Body A", "saved, shown as current")
check(load("user\\" .. M .. "\\sculpt\\Body A.json").values.EyeBlinkLeft ~= nil, "expression keys are stored in a sculpt preset too")
ok, code = SKS.call("write_binding", { part = "ch03_012_0012", expression = "ARKit 52", sculpt = "Body A", gains = true })
check(ok, "write_binding with profile name, sculpt and current tuning")
local bfile = load("user\\" .. M .. "\\ch03_012_0012.json")
check(bfile and bfile.gains and bfile.gains.for_profile == "arkit" and bfile.eyes and bfile.eyes.full_deg, "binding stores gains (for_profile arkit) and gaze settings")
ok, code = SKS.call("write_binding", { part = "ch03_012_0012", sculpt = "missing" })
check(not ok and code == "E_NOT_FOUND", "binding to a missing sculpt preset -> E_NOT_FOUND")
ticks(3)
check(st.presets.binding and st.presets.binding.hit == "user/" .. M .. "/ch03_012_0012.json", "binding in effect: user/<model>/<part>.json")
check(st.scene.parts[1].binding == "user/" .. M .. "/ch03_012_0012.json", "part reports its binding")
check(st.presets.binding.sculpt_found, "binding's sculpt preset found in the model folder")

-- a mod ships its own preset: it becomes the default (reset / A-B), the user binding still wins
dump("mods\\" .. M .. "\\sculpt\\ModFace.json", { schema = "sks.sculpt/1", name = "ModFace", values = { Waist_thin = 0.25, Other = 1.5 } })
dump("mods\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", part = "ch03_012_0012", profile = "arkit", sculpt = "ModFace" })
SKS.call("sculpt_scan"); ticks(3)
check(key("Waist_thin").default == 0.25 and key("Other").default == 1.5, "mod preset values are the defaults")
check(math.abs(key("Waist_thin").value - 0.3) < 1e-6, "user value kept (user binding wins)")
check(key("Other").value == 0, "Other from the user preset (0)")
SKS.call("set_ab_preview", { on = true }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.25) < 1e-6 and math.abs(WEIGHTS[i_other] - 1.5) < 1e-6, "A/B preview shows the mod defaults")
SKS.call("set_ab_preview", { on = false }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.3) < 1e-6 and WEIGHTS[i_other] == 0, "preview off: back to the user values")
SKS.call("reset_sculpt_key", { name = "Waist_thin" }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.25) < 1e-6, "reset -> mod default 0.25")

-- load a general preset by hand: values change, no binding is written
dump("user\\sculpt\\Slim.json", { schema = "sks.sculpt/1", name = "Slim", values = { Waist_thin = 1.2 } })
SKS.call("sculpt_scan"); ticks(3)
ok = SKS.call("load_sculpt", { name = "Slim" }); ticks(1)
check(ok and math.abs(WEIGHTS[i_waist] - 1.2) < 1e-6, "load_sculpt applies the general preset Slim")
check(st.sculpt.preset and st.sculpt.preset.name == "Slim" and st.sculpt.preset.folder == nil, "Slim shown as current (general)")
check(load("user\\" .. M .. "\\ch03_012_0012.json").sculpt == "Body A", "loading did not touch the binding")
check(math.abs(key("Other").value - 1.5) < 1e-6, "keys Slim does not name fall back to the mod default")
SKS.call("sculpt_undo"); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.25) < 1e-6, "loading is one undo step")
ok, code = SKS.call("load_sculpt", { name = "nope" })
check(not ok and code == "E_NOT_FOUND", "unknown preset -> E_NOT_FOUND")

-- back to the mod binding: untouched keys follow the mod preset, touched ones stay
ok = SKS.call("restore_mod_binding", { part = "ch03_012_0012" }); ticks(3)
check(ok and st.presets.binding.hit == "mods/" .. M .. "/ch03_012_0012.json", "restore_mod_binding -> mods file in effect")
check(math.abs(key("Waist_thin").value - 0.25) < 1e-6, "touched Waist_thin keeps its value")
ok, code = SKS.call("restore_mod_binding", { part = "ch03_012_0012" })
check(not ok and code == "E_NOT_FOUND", "no user binding left -> E_NOT_FOUND")

-- lookup per part: global model preset > own file > the model's slot-2 file > default.json
dump("mods\\" .. M .. "\\ch03_012_0012.json", { deleted = true })
ARMOR._name = "ch03_012_0014"; ticks(130)
check(st.scene.parts[1].id == "ch03_012_0014", "now wearing ch03_012_0014 (same model 001, slot 4)")
dump("user\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", profile = "My Test" })
SKS.call("rescan"); ticks(3)
check(st.presets.binding and st.presets.binding.hit == "user/" .. M .. "/ch03_012_0012.json", "no own file: the model's slot-2 file is used")
check(st.expression.profile.id == "My Test" and st.expression.binding_source == "user/" .. M .. "/ch03_012_0012.json", "model file picked the profile")
dump("user\\" .. M .. "\\ch03_012_0014.json", { schema = "sks.binding/1", profile = "arkit" })
SKS.call("rescan"); ticks(3)
check(st.presets.binding.hit == "user/" .. M .. "/ch03_012_0014.json" and st.expression.profile.id == "arkit", "the part's own file wins")
dump("user\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", profile = "My Test", global = true })
SKS.call("rescan"); ticks(3)
check(st.presets.binding.hit == "user/" .. M .. "/ch03_012_0012.json" and st.expression.profile.id == "My Test", "global=true on the slot-2 file overrides own files")
dump("user\\" .. M .. "\\ch03_012_0012.json", { deleted = true })
dump("user\\" .. M .. "\\ch03_012_0014.json", { deleted = true })
dump("mods\\" .. M .. "\\ch03_012_0014.json", { schema = "sks.binding/1", profile = "My Test", fingerprints = { ch03_012_0014 = "deadbeef" } })
SKS.call("rescan"); ticks(3)
check(st.presets.binding == nil and st.expression.profile.id == "arkit", "stale mod binding skipped, back to the global profile")
local warned = false
for _, n in ipairs(st.runtime.notices) do if n.text:find("指纹") then warned = true end end
check(warned, "stale mod binding reported once")
dump("mods\\" .. M .. "\\ch03_012_0014.json", { schema = "sks.binding/1", profile = "My Test", fingerprints = { ch03_012_0014 = st.scene.parts[1].fingerprint } })
SKS.call("rescan"); ticks(3)
check(st.presets.binding and st.presets.binding.hit == "mods/" .. M .. "/ch03_012_0014.json", "matching fingerprint: mod binding used")
dump("mods\\" .. M .. "\\ch03_012_0014.json", { deleted = true })
ARMOR._name = "ch03_012_0012"; ticks(130)

-- tuning follows the part: default.json gains + gaze, edits stay out of settings.json
dump("user\\default.json", { schema = "sks.binding/1", gains = { master_gain = 0.5 }, eyes = { full_deg = { yaw = 50 } } })
SKS.call("rescan"); ticks(3)
check(st.presets.binding.hit == "user/default.json", "default.json in effect")
check(st.expression.profile.id == "arkit", "no profile in the binding: the global profile")
check(st.expression.master_gain == 0.5 and st.eyes.full_deg.yaw == 50, "binding gains and gaze loaded")
check(st.expression.tuning.source == "binding" and st.expression.tuning.path == "user/default.json", "tuning source: the binding")
SKS.call("set_master_gain", { value = 0.8 }); ticks(70)
check(st.expression.tuning.dirty, "editing a per-part gain: unsaved")
SKS.call("rescan"); ticks(3)
check(st.expression.master_gain == 0.8 and st.expression.tuning.dirty, "unsaved edit survives a rescan")
check(load("settings.json").expression.master_gain ~= 0.8 and load("settings.json").eyes.full_deg.yaw == 25, "settings.json keeps the global fallback")
ok = SKS.call("save_tuning"); ticks(3)
check(ok and load("user\\default.json").gains.master_gain == 0.8 and not st.expression.tuning.dirty, "save_tuning writes the binding")
-- channel gains tuned for another profile are ignored; for the active one they apply
dump("user\\default.json", { schema = "sks.binding/1", gains = { for_profile = "My Test", channel_gains = { jawOpen = 2 } } })
SKS.call("rescan"); ticks(3)
check(st.expression.tuning.profile_mismatch and select(2, slot("jawOpen")).gain == 1, "for_profile My Test vs arkit: channel gains ignored")
dump("user\\default.json", { schema = "sks.binding/1", gains = { for_profile = "arkit", channel_gains = { jawOpen = 1.5 } } })
SKS.call("rescan"); ticks(3)
check(not st.expression.tuning.profile_mismatch and select(2, slot("jawOpen")).gain == 1.5, "for_profile arkit: channel gain 1.5 applied")
dump("user\\default.json", { deleted = true })
SKS.call("rescan"); ticks(3)
check(st.presets.binding == nil and st.expression.tuning.source == "settings", "no binding: global settings again")
check(st.expression.master_gain == 1 and st.eyes.full_deg.yaw == 25 and select(2, slot("jawOpen")).gain == 1, "fallback values restored")

-- deleting: only user files, with confirmation
ok, code = SKS.call("request_delete", { kind = "sculpt", name = "ModFace" })
check(not ok and code == "E_READONLY", "mod sculpt preset cannot be deleted")
ok = SKS.call("request_delete", { kind = "sculpt", name = "Body A" })
check(ok and st.presets.pending_delete and st.presets.pending_delete.name == "Body A", "delete pending")
SKS.call("confirm_delete")
local still = false
for _, e in ipairs(st.presets.sculpt) do if e.name == "Body A" then still = true end end
check(not still, "Body A deleted")

-- disable zeroes the sculpt layer, enable restores it
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.6 }); ticks(1)
SKS.call("set_enabled", { on = false }); ticks(1)
check(WEIGHTS[i_waist] == 0, "disable: sculpt channels zeroed")
SKS.call("set_enabled", { on = true }); ticks(80)
check(math.abs(WEIGHTS[i_waist] - 0.6) < 1e-6, "enable: sculpt values written again")

-- cutscene pause: references dropped, nothing written, values back after
DEMO.busy = true; ticks(1)
local w2 = #writes
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.9 }); ticks(10)
check(#writes == w2, "paused: no sculpt writes")
DEMO.busy = false; ticks(130)
check(math.abs(WEIGHTS[i_waist] - 0.9) < 1e-6, "after the pause: pending sculpt value written")

-- clean up for the following sections
dump("mods\\" .. M .. "\\sculpt\\ModFace.json", { deleted = true })
dump("user\\sculpt\\Slim.json", { deleted = true })
SKS.call("sculpt_scan"); ticks(3)
SKS.call("reset_sculpt_key", { name = "Waist_thin" }); SKS.call("reset_sculpt_key", { name = "Other" }); ticks(2)
CB.ui()   -- draw the debug panel with the sculpt / preset sections populated
check(true, "debug UI drew sculpt + preset sections")
-- the next section swaps the mesh's channels in place: forget what this section wrote
WEIGHTS[i_waist], WEIGHTS[i_other] = nil, nil
end

-- Shinano-native mesh: current profile drives nothing -> switch to shinano
SKS.call("set_profile", { id = "arkit" }); ticks(2)
for i = 1, #CHANNELS do CHANNELS[i] = nil end
for i, n in ipairs({ "blendShape1.eye_close_L", "blendShape1.eye_close_R", "blendShape1.mouth_a1",
                     "blendShape1.mouth_smile_L", "blendShape1.option_jaw_narrow", "blendShape1.eye_look_up" }) do CHANNELS[i] = n end
SKS.call("rescan"); ticks(5)
print("profile now:", st.expression.profile.id, st.runtime.notices[#st.runtime.notices].text)
check(st.expression.profile.id == "shinano", "auto-switched to shinano profile")
ticks(70)
check(math.abs(WEIGHTS[idx("blendShape1.eye_close_L")] - 1.0) < 1e-6, "shinano eye_close_L driven by blink.L")
check(WEIGHTS[idx("blendShape1.option_jaw_narrow")] == nil, "sculpt key untouched")

-- experimental cutscene mode (segments from DemoMediator hooks)
local s_close = idx("blendShape1.eye_close_L")
check(HOOKS.onPlayStartTimeline and HOOKS.unload and HOOKS.requestSkip, "DemoMediator hooks registered")
check(SKS.call("set_setting", { key = "cutscene_drive", value = true }), "enable cutscene_drive")
DEMO.load = true; ticks(5)                       -- cutscene loading: paused
check(st.debug.status:find("paused") ~= nil, "cutscene load: paused")
COPY_ON = true
HOOKS.onPlayStartTimeline({ nil, nil, 0 })       -- segment 0 starts
DEMO.load = false; DEMO.busy = true
local c0 = #writes; FC[1] = 0.005; ticks(25)
check(#writes == c0, "segment 0: nothing while settling")
ticks(80)
print("cs:", st.debug.status, "rigs:", #st.scene.rigs)
check(#st.scene.rigs == 2, "segment 0: whole-scene search found master + cutscene copy Pl000_00")
check(math.abs(WEIGHTS[s_close] - 0.5) < 1e-6 and math.abs(WEIGHTS2[s_close] - 0.5) < 1e-6, "segment 0: both hunters driven")
local ok_sk, c_sk, m_sk = SKS.call("set_sculpt_key", { name = "option_jaw_narrow", value = 0.5 }); ticks(2)
local j = idx("blendShape1.option_jaw_narrow")
print("sculpt copy:", ok_sk, c_sk, m_sk, WEIGHTS[j], WEIGHTS2[j])
check(WEIGHTS[j] == 0.5 and WEIGHTS2[j] == 0.5, "sculpt reaches the cutscene copy of the part too")
HOOKS.requestSkip()
local c1 = #writes; FC[1] = 0.01; ticks(60)
check(#writes == c1, "skip: released, nothing written")
HOOKS.onPlayStartTimeline({ nil, nil, 1 })       -- multi-part: next segment, IsBusy stays on
ticks(110)
check(math.abs(WEIGHTS2[s_close] - 1.0) < 1e-6, "segment 1 after a skip: driving again")
HOOKS.requestSkip()                              -- skip again, next segment reports no hook
local c15 = #writes; FC[1] = 0.003; ticks(60)
check(#writes == c15, "skip without a following hook: released")
ticks(90)
check(math.abs(WEIGHTS2[s_close] - 0.3) < 1e-6, "still playing after the skip: re-armed and driving")
HOOKS.unload()                                   -- natural end (unload runs twice)
HOOKS.unload()
local c2 = #writes; FC[1] = 0.004; ticks(10)
check(#writes == c2, "unload: released")
DEMO.busy = false; DEMO.load = true; ticks(5)
check(#writes == c2, "end-of-cutscene load: nothing written")
DEMO.load = false; COPY_ON = false; ticks(130)
check(math.abs(WEIGHTS[s_close] - 0.4) < 1e-6 and #st.scene.rigs == 1, "gameplay again, master player only")
-- cutscene without a segment hook: playback start counts as the segment start
DEMO.busy = true; COPY_ON = true; FC[1] = 0.007; ticks(120)
check(math.abs(WEIGHTS2[s_close] - 0.7) < 1e-6, "no segment hook: driving after settle from playback start")
DEMO.busy = false; COPY_ON = false; ticks(130)
SKS.call("set_setting", { key = "cutscene_drive", value = false })
DEMO.busy = true; ticks(1)
check(st.debug.status:find("paused") ~= nil, "switch off: cutscenes pause again")
DEMO.busy = false; ticks(130)

-- signal layer: dictionary raw / param / lo / hi / no_signal, p through the adapter, game tags
local Profile = require("ShapeKeySystem_Core.Profile")
local U = require("ShapeKeySystem_Core.Util")
Profile.load_signals({ full = 0.01, signals = {
    { name = "a", raw = 1 }, { name = "b", raw = 2, lo = 0.002, hi = 0.006 },
    { name = "gone" }, { name = "old", param = 3 } } })
local tp = Profile.compile({ id = "t", name = "t", aliases = {}, channels = {
    { name = "A", s = "a" }, { name = "B", s = "b" }, { name = "G", s = "gone" },
    { name = "O", s = "old" }, { name = "R", p = 120 } } })
local tctx = { P = { [1] = 0.5, [2] = 0.4, [3] = 0.7, [120] = 0.9 }, A = {}, V = {} }
check(tp ~= nil, "dictionary test profile compiles")
tp = tp or { channels = {} }
local function tv(i) local c = tp.channels[i]; return c and c.fn and c.fn(tctx) end
check(tv(1) == 0.5 and not tp.channels[1].no_signal, "signal without lo / hi reads raw / full")
check(math.abs((tv(2) or 0) - 0.5) < 1e-9, "lo / hi: raw 0.004 in 0.002..0.006 -> 0.5")
check(tp.channels[3] and tp.channels[3].no_signal and tv(3) == 0, "signal without raw: no_signal, reads 0")
check(tv(4) == 0.7, "sks.signals/1 `param` still read")
check(tp.channels[5] and tp.channels[5].source_text == "fcParam_120" and tv(5) == 0.9, "p node parsed and labelled by the adapter")
local _, tcode = Profile.compile({ id = "t", name = "t", aliases = {}, channels = { { name = "X", s = "typo" } } })
check(tcode == "E_NODE_INVALID", "a name missing from the dictionary is still an error")
local _, tcode2, tmsg2 = Profile.compile({ id = "t", name = "t", aliases = {}, channels = { { name = "X", p = 300 } } })
check(tcode2 == "E_NODE_INVALID" and tostring(tmsg2):find("out of range", 1, true) ~= nil, "p outside the game's range is an error")
local with_p = { id = "t", aliases = {}, channels = { { name = "R", sum = { { s = "a" }, { p = 120 } } } } }
check(Profile.to_json(with_p, {}, "t", "t").game == "mhwilds", "a saved profile using p is tagged with the game")
check(Profile.to_json({ id = "t", aliases = {}, channels = { { name = "A", s = "a" } } }, {}, "t", "t").game == nil,
    "a saved profile using only s stays game-neutral")
Profile.load_signals()
for _, e in ipairs(Profile.list) do
    if e.source == "builtin" then
        local r = Profile.resolve(e.id)
        local pr, _, m = r and Profile.compile(r, {})
        check(pr ~= nil, "builtin profile compiles against the dictionary: " .. e.id .. " " .. tostring(m or ""))
    end
end
U.save_json(U.path("user", "profiles", "zz_other.json"), { schema = "sks.profile/1", id = "zz_other", game = "other", channels = {} })
U.save_json(U.path("user", "profiles", "zz_here.json"), { schema = "sks.profile/1", id = "zz_here", game = "mhwilds", channels = {} })
Profile.load_all()
check(Profile.registry.zz_other == nil and Profile.registry.zz_here ~= nil, "profiles tagged with another game are skipped")
U.save_json(U.path("user", "profiles", "zz_other.json"), {})
U.save_json(U.path("user", "profiles", "zz_here.json"), {})

-- builtin data per game: only builtin/<id>/ is read, files left in the old place are ignored
U.save_json(U.path("builtin", "signals.json"), { full = 0.01, signals = { { name = "stale", raw = 1 } } })
local sig5 = Profile.load_signals()
local n5 = #U.load_json(U.path("builtin", "mhwilds", "signals.json")).signals
check(#sig5.list == n5 and sig5.by_name.stale == nil and sig5.by_name["blink.L"] ~= nil,
    "the dictionary comes from builtin/mhwilds, a stale builtin/signals.json is ignored")
U.save_json(U.path("builtin", "profiles", "zz_game.json"), { schema = "sks.profile/1", id = "zz_game", name = "shared", channels = {} })
U.save_json(U.path("builtin", "mhwilds", "profiles", "zz_game.json"), { schema = "sks.profile/1", id = "zz_game", name = "game", channels = {} })
Profile.load_all()
local zg = Profile.registry.zz_game
check(zg and zg.name == "game" and zg.source == "builtin", "builtin/mhwilds/profiles overrides builtin/profiles")
U.save_json(U.path("builtin", "signals.json"), {})
U.save_json(U.path("builtin", "profiles", "zz_game.json"), {})
U.save_json(U.path("builtin", "mhwilds", "profiles", "zz_game.json"), {})
Profile.load_signals()
Profile.load_all()

local Probe = require("ShapeKeySystem_Games.Wilds.Probe")
MM3 = Probe.murmur3("eyeBlinkLeft")
ticks(70)
print(string.format("perf total %.4f ms", st.debug.perf.total))
print("FAILS:", fails)
