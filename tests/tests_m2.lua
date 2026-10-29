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
check(key("EyeBlinkLeft") and key("EyeBlinkLeft").locked and key("EyeBlinkLeft").owner == "expression", "EyeBlinkLeft shown, locked")
check(key("Waist_thin") and key("Waist_thin").owner == "self" and not key("Waist_thin").locked, "Waist_thin editable")
local ok, code = SKS.call("set_sculpt_key", { name = "EyeBlinkLeft", value = 1 })
check(not ok and code == "E_EXPRESSION_OWNED", "editing an expression key -> E_EXPRESSION_OWNED")
ok, code = SKS.call("reset_sculpt_key", { name = "JawOpen" })
check(not ok and code == "E_EXPRESSION_OWNED", "resetting an expression key -> E_EXPRESSION_OWNED")
check(WEIGHTS[i_waist] == nil, "unchanged channel: no write")

ok, code = SKS.call("set_sculpt_key", { name = "nope", value = 1 })
check(not ok and code == "E_NOT_FOUND", "unknown sculpt key -> E_NOT_FOUND")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.7 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 0.7) < 1e-6, "set_sculpt_key writes on the next tick")
local w1 = #writes; ticks(10)
check(#writes == w1, "lazy: no rewrite while the value stays")
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 3 }); ticks(1)
check(math.abs(WEIGHTS[i_waist] - 2.0) < 1e-6, "clamped to the 0..2 range")
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
check(load("user\\" .. M .. "\\sculpt\\Body A.json").values.EyeBlinkLeft == nil, "expression keys are not stored in a sculpt preset")
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

-- one binding per model: the slot-2 file, then default.json; part files of earlier versions are ignored
dump("mods\\" .. M .. "\\ch03_012_0012.json", { deleted = true })
ARMOR._name = "ch03_012_0014"; ticks(130)
check(st.scene.parts[1].id == "ch03_012_0014", "now wearing ch03_012_0014 (same model 001, slot 4)")
dump("user\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", profile = "My Test" })
SKS.call("rescan"); ticks(3)
check(st.presets.binding and st.presets.binding.hit == "user/" .. M .. "/ch03_012_0012.json", "the model's slot-2 file is used")
check(st.expression.profile.id == "My Test" and st.expression.binding_source == "user/" .. M .. "/ch03_012_0012.json", "model file picked the profile")
dump("user\\" .. M .. "\\ch03_012_0014.json", { schema = "sks.binding/1", profile = "arkit" })
SKS.call("rescan"); ticks(3)
check(st.presets.binding.hit == "user/" .. M .. "/ch03_012_0012.json" and st.expression.profile.id == "My Test", "a part file left by an earlier version does not win")
check(#st.presets.legacy == 1 and st.presets.legacy[1].path == "user/" .. M .. "/ch03_012_0014.json", "the part file is listed as legacy")
local legacy_noted = false
for _, n in ipairs(st.runtime.notices) do if n.text:find("ch03_012_0014.json", 1, true) then legacy_noted = true end end
check(legacy_noted, "legacy part file reported")
ok = SKS.call("adopt_legacy_binding", { part = "ch03_012_0014" }); ticks(3)
check(ok and st.expression.profile.id == "arkit" and load("user\\" .. M .. "\\ch03_012_0012.json").profile == "arkit",
    "adopting the part file rewrites the model's binding")
check(load("user\\" .. M .. "\\ch03_012_0014.json").deleted == true and #st.presets.legacy == 0, "the adopted part file is tombstoned")
ok = SKS.call("write_binding", { part = "ch03_012_0014", expression = "My Test" }); ticks(3)
check(ok and load("user\\" .. M .. "\\ch03_012_0012.json").profile == "My Test" and load("user\\" .. M .. "\\ch03_012_0014.json").deleted == true,
    "write_binding for a slot-4 part writes the model's slot-2 file")
dump("user\\" .. M .. "\\ch03_012_0012.json", { deleted = true })
dump("mods\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", profile = "My Test", fingerprints = { ch03_012_0014 = "deadbeef" } })
SKS.call("rescan"); ticks(3)
check(st.presets.binding == nil and st.expression.profile.id == "arkit", "stale mod binding skipped, back to the global profile")
local warned = false
for _, n in ipairs(st.runtime.notices) do if n.text:find("指纹") then warned = true end end
check(warned, "stale mod binding reported once")
dump("mods\\" .. M .. "\\ch03_012_0012.json", { schema = "sks.binding/1", profile = "My Test", fingerprints = { ch03_012_0014 = st.scene.parts[1].fingerprint } })
SKS.call("rescan"); ticks(3)
check(st.presets.binding and st.presets.binding.hit == "mods/" .. M .. "/ch03_012_0012.json", "matching fingerprint: mod binding used")
dump("mods\\" .. M .. "\\ch03_012_0012.json", { deleted = true })
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
