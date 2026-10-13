-- facial presets (Facial.lua + PageFacial): an avatar's numbered whole-face keys ("1".."10" on
-- Maya's face mesh) set with sliders on their own page. While one is up the emote-driven face fades
-- out by the same amount (gaze stays live), and other plugins still win (kevin, 2026-10-13).
local SKS = require("ShapeKeySystem_Core.API")
local L = require("ShapeKeySystem_Core.I18n")
local st = SKS.state
local ff = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[facial] " .. what)
    if not cond then ff = ff + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-6 end
local function idx_of(full)
    for i, n in ipairs(CHANNELS) do if n == full then return i - 1 end end
end
local function facial_names()
    local out = {}
    for i, k in ipairs(st.facial and st.facial.keys or {}) do out[i] = k.name end
    return table.concat(out, ",")
end
local function facial_value(name)
    for _, k in ipairs(st.facial.keys) do if k.name == name then return k.value end end
end

-- Maya's face as tests_bones leaves it (her own key names, the maya profile), plus her gaze keys
local saved_channels = {}
for i, n in ipairs(CHANNELS) do saved_channels[i] = n end
for _, n in ipairs({ "瞳左", "瞳右" }) do CHANNELS[#CHANNELS + 1] = n end
SKS.call("set_profile", { id = "maya" })
SKS.call("set_eye_cfg", { patch = { sets = { eye_look = true, look = true }, invert = { yaw = false, pitch = false } } })
FC[1] = 0.006   -- an idle blink: ウィンク２ at 0.6 (tests_bones)
SKS.call("rescan"); ticks(5)
check(st.facial ~= nil and facial_names() == "", "no numbered keys worn: the facial page lists nothing")

-- her face mesh carries "1".."10" under ===Facial===; the mock gets 2, 10, 1 and a LOD copy of 1
for _, n in ipairs({ "2", "10", "1", "1_LOD1" }) do CHANNELS[#CHANNELS + 1] = n end
SKS.call("rescan"); ticks(5)
check(facial_names() == "1,2,10", "numbered keys found, in number order: " .. facial_names())
local in_sculpt = false
for _, k in ipairs(st.sculpt.keys) do if k.name == "1" or k.name == "2" or k.name == "10" then in_sculpt = true end end
check(not in_sculpt, "numbered keys are not listed on the sculpt page")

local bi, gaze_i = idx_of("ウィンク２"), idx_of("瞳左")
local i1, i2, i10, i1lod = idx_of("1"), idx_of("2"), idx_of("10"), idx_of("1_LOD1")
local function hold_gaze() SKS.call("gaze_hold", { yaw = 10, pitch = 0, frames = 600 }) end
hold_gaze(); ticks(3)
local w0, g0 = WEIGHTS[bi], WEIGHTS[gaze_i]
check(w0 ~= nil and w0 > 0.5, string.format("driven blink is up before any preset (%.2f)", w0 or -1))
check(g0 ~= nil and g0 > 0.05, string.format("a gaze channel is up before any preset (%.2f)", g0 or -1))

local ok, code = SKS.call("set_facial", { name = "2", value = 0.6 }); ticks(3)
check(ok and near(WEIGHTS[i2], 0.6), "slider 2 at 0.6 writes 0.6 to key 2")
check(near(st.facial.level, 0.6) and near(facial_value("2"), 0.6), "state.facial: level = the highest slider, value per key")
check(near(WEIGHTS[bi], w0 * 0.4), string.format("the driven blink fades by the same amount (%.4f)", WEIGHTS[bi] or -1))
check(near(WEIGHTS[gaze_i], g0), "gaze stays live")
SKS.call("set_facial", { name = "10", value = 1.0 }); ticks(3)
check(near(WEIGHTS[i2], 0.6) and near(WEIGHTS[i10], 1.0), "two presets mix")
check(near(WEIGHTS[bi], 0), "a preset at 1 hides the driven face")
check(near(WEIGHTS[gaze_i], g0), "gaze still live with a preset at 1")
SKS.call("set_facial", { name = "1", value = 0.3 }); ticks(3)
check(near(WEIGHTS[i1], 0.3) and near(WEIGHTS[i1lod], 0.3), "every LOD copy of a key follows its slider")

ok, code = SKS.call("set_facial", { name = "Waist_thin", value = 0.5 })
check(not ok and code == "E_NOT_FOUND", "only numbered keys of the worn parts are facial keys")
ok, code = SKS.call("set_facial", { name = "2", value = "x" })
check(not ok and code == "E_BAD_ARGS", "value must be a number")
SKS.call("set_facial", { name = "2", value = 3 }); ticks(2)
check(near(WEIGHTS[i2], 1.0), "values clamp to 0..1")

ShapeKeySystemAPI.set("tester", "2", 0.25, { ttl = 0 }); ticks(2)
check(near(WEIGHTS[i2], 0.25), "a plugin holding key 2 overrides the slider")
local v, ctl = ShapeKeySystemAPI.get("10")
check(near(v, 1.0) and ctl == "facial", "API get reports a facial key's slider value and controller 'facial'")
ShapeKeySystemAPI.release("tester", "2"); ticks(2)
check(near(WEIGHTS[i2], 1.0), "released: back to the slider")

ticks(70)   -- save_soon writes 60 frames after the change
local saved = json.load_file("ShapeKeySystem\\settings.json")
check(saved ~= nil and saved.facial ~= nil and near(tonumber(saved.facial["10"]), 1.0)
    and near(tonumber(saved.facial["2"]), 1.0), "slider values saved in settings.json")

ok = SKS.call("clear_facial"); ticks(3)
check(ok and near(WEIGHTS[i1], 0) and near(WEIGHTS[i2], 0) and near(WEIGHTS[i10], 0), "all off: every preset at 0")
check(near(WEIGHTS[bi], w0) and near(st.facial.level, 0), "all off: the driven face is back")

-- a saved value for a key the worn parts no longer carry does not hide the face
SKS.call("set_facial", { name = "10", value = 1.0 }); ticks(2)
table.remove(CHANNELS, i10 + 1)
SKS.call("rescan"); ticks(5); hold_gaze(); ticks(2)
check(facial_names() == "1,2", "key 10 gone after a rescan: " .. facial_names())
check(near(st.facial.level, 0) and near(WEIGHTS[idx_of("ウィンク２")], w0),
    "a slider for a key no longer worn does not fade the face")

-- panel page
local Panel = require("ShapeKeySystem_UI.Panel")
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(s, exact)
    for _, d in ipairs(DRAWS) do
        if (exact and d.s == s) or (not exact and d.s:find(s, 1, true)) then return d end
    end
end
if not Panel.open then KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame() end
local rail = find(L.t("page.facial"), true)
check(rail ~= nil, "rail entry: " .. L.t("page.facial"))
if rail then MOUSE.x, MOUSE.y = rail.x + 4, rail.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(Panel.ui.page == "facial", "rail click opens the facial page")
MOUSE.x, MOUSE.y = 1500, 900; frame()
check(find("页面出错", false) == nil, "facial page draws without a page error")
local row = find("2", true)
check(row ~= nil and find("1", true) ~= nil, "one row per numbered key")
if row then
    MOUSE.x, MOUSE.y, MOUSE.down = row.x + 300, row.y + 6, true; frame()
    MOUSE.x = row.x + 3000; frame()
    MOUSE.down = false; frame()
    check(near(facial_value("2"), 1.0), "dragging row 2's slider to the right end sets 1.0")
end
SKS.call("set_facial", { name = "1", value = 0.35 }); MOUSE.x, MOUSE.y = 1500, 900; frame()
SNAPS[#SNAPS + 1] = { name = "facial", file = "facial_page", cmds = CMDS }
local off = find(L.t("facial.all_off"), true)
check(off ~= nil, "all-off button drawn")
if off then MOUSE.x, MOUSE.y = off.x + 4, off.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end
check(near(st.facial.level, 0) and near(facial_value("2"), 0), "all-off button clears every slider")

-- English mode: nothing Chinese on this page
SKS.call("set_setting", { key = "language", value = "en" }); frame(); frame()
local cjk = nil
for _, d in ipairs(DRAWS) do
    for _, c in utf8.codes(d.s) do
        if (c >= 0x3000 and c <= 0x30FF) or (c >= 0x3400 and c <= 0x9FFF) or (c >= 0xFF00 and c <= 0xFFEF) then cjk = d.s end
    end
end
check(find(L.t("page.facial"), true) ~= nil and cjk == nil, "English: page drawn with no Chinese" .. (cjk and (" (" .. cjk .. ")") or ""))
SKS.call("set_setting", { key = "language", value = "zh" })

-- empty state: no numbered keys worn
for i = #CHANNELS, 1, -1 do CHANNELS[i] = nil end
for i, n in ipairs(saved_channels) do CHANNELS[i] = n end
SKS.call("rescan"); ticks(5); frame(); frame()
check(facial_names() == "" and find(L.t("facial.none"), true) ~= nil, "no numbered keys: the page says so")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
SKS.call("clear_facial"); ticks(70)

print("FACIAL FAILS:", ff)
