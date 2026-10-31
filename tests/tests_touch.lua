-- face-navigator interactions (Touch.lua + PageBasic press handler)
local SKS = require("ShapeKeySystem_Core.API")
local Touch = require("ShapeKeySystem_Core.Touch")
local st = SKS.state
local tf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[touch] " .. what)
    if not cond then tf = tf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function wait(sec) local t = os.clock() + sec; while os.clock() < t do end end
local function run_for(sec) local t = os.clock() + sec; while os.clock() < t do wait(0.02); ticks(1) end end
local function mesh_idx(key)
    for i, n in ipairs(CHANNELS) do if n:match("([^%.]+)$") == key then return i - 1 end end
end

-- auto-detection on Shinano's real face keys
local shinano = { "eye_close", "eye_joy", "eye_><", "eye_x", "mouth_△", "mouth_△_small", "mouth_smile_L", "other_cheek_2",
                  "Mouth_Left", "Mouth_Right", "Mouth_Upper_UpLeft", "Mouth_Upper_UpRight", "Mouth_Lower_DownLeft",
                  "Mouth_Lower_DownRight", "Cheek_Puff_Left", "Cheek_Puff_Right", "Eye_Left_Blink", "Eye_Right_Blink" }
local m = Touch.detect(shinano)
check(m.forehead.values["eye_><"] and m.forehead.values["mouth_△"] and not m.forehead.values["eye_x"], "forehead -> eye_>< + mouth_△")
check(m.cheek.values["other_cheek_2"] and not m.cheek.values["Cheek_Puff_Left"], "cheek -> other_cheek_2 (blush first)")
check(m.eye.values["eye_close"] ~= nil, "eye -> eye_close")
check(m.mouth.left["Mouth_Left"] and m.mouth.right["Mouth_Right"] and m.mouth.up["Mouth_Upper_UpLeft"]
    and m.mouth.down["Mouth_Lower_DownRight"], "mouth directions -> Mouth_Left/Right/Upper_Up*/Lower_Down*")
local arkit = Touch.detect({ "eyeBlinkLeft", "eyeBlinkRight", "mouthLeft", "mouthRight", "cheekPuffLeft", "cheekPuffRight" })
check(arkit.eye.values.eyeBlinkLeft and arkit.eye.values.eyeBlinkRight and arkit.cheek.values.cheekPuffLeft, "ARKit fallbacks")

-- runtime on the mock mesh: the condition set carries its own interactions for these keys
local expr_key, self_key
for _, c in ipairs(ShapeKeySystemAPI.channels()) do
    if c.expression and not expr_key then expr_key = c.name end
    if not c.expression and not self_key then self_key = c.name end
end
local ei, si = mesh_idx(expr_key), mesh_idx(self_key)
local cur = st.conditions.current
local d = cur and cur.data or { auto = true, clips = {}, states = {} }
if not cur then SKS.call("cond_new", { name = "Touch" }) end
d = (st.conditions.current.data)
local copy = {}
for k, v in pairs(d) do copy[k] = v end
copy.interactions = { forehead = { values = { [expr_key] = 1.0, [self_key] = 0.9 }, hold = 0.2 },
                      mouth = { left = { [self_key] = 1.0 } } }
check(SKS.call("cond_edit", { data = copy }), "a set with its own interactions")
check(st.touch.zones.forehead and st.touch.zones.mouth, "state.touch.zones")
FC[1] = 0; ticks(2)
local base_e, base_s = WEIGHTS[ei], WEIGHTS[si]

SKS.call("touch_poke", { zone = "forehead" }); run_for(0.12)
check(math.abs(WEIGHTS[ei] - 1.0) < 1e-6 and math.abs(WEIGHTS[si] - (base_s + (1 - base_s) * 0.9)) < 1e-6,
    string.format("poke: forehead keys at full weight, sculpt-only key remapped (s %.2f -> %.4f)", base_s, WEIGHTS[si]))
run_for(0.65)
check(math.abs(WEIGHTS[ei] - base_e) < 1e-6 and math.abs(WEIGHTS[si] - base_s) < 1e-6, "after hold + fade: back to normal")
local ok, _, _, r = SKS.call("touch_poke", { zone = "cheek" })
check(ok and r.played == false, "a zone without keys plays nothing")

SKS.call("touch_drag", { x = 0.6, y = 0 }); ticks(2)
check(math.abs(WEIGHTS[si] - (base_s + (1 - base_s) * 0.6)) < 1e-6, "drag right 0.6 -> face's left key remapped from 0.6")
SKS.call("touch_drag", { x = -0.5, y = 0 }); ticks(2)
check(math.abs(WEIGHTS[si] - base_s) < 1e-6, "drag the other way: that key back to normal")
SKS.call("touch_drag", { x = 1, y = 0 }); ticks(1)
SKS.call("touch_release"); run_for(0.1)
local mid = WEIGHTS[si]
check(mid < 0.99 and mid > base_s, "release springs back (fading)")
run_for(0.35)
check(math.abs(WEIGHTS[si] - base_s) < 1e-6, "spring back finished")

-- panel: tap / drag on the face image
local Panel = require("ShapeKeySystem_UI.Panel")
local Faces = require("ShapeKeySystem_UI.Faces")
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
-- d2d loads images in its init callback, which may run before the first frame picks the backend
require("ShapeKeySystem_UI.Draw").set_backend(nil)
if CB.d2d_init then CB.d2d_init() end
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "basic"; frame()
local img
for _, c in ipairs(CMDS) do if c[1] == "image" and tostring(c[2]):find("face_lines.png", 1, true) then img = c end end
local style = Faces.get(st.settings.face_style)
check(img ~= nil and style ~= nil, "face image drawn (style " .. tostring(style and style.id) .. ")")
if img and style then
    local fx, fy, s = img[3], img[4], img[5] / style.w
    local function at(e) return fx + e[1] * s, fy + e[2] * s end
    local brow, mouth, eye
    for _, z in ipairs(style.zones) do
        if z.key == "brow" then brow = z.ells[1] elseif z.key == "mouth" then mouth = z.ells[1] elseif z.key == "eye" then eye = z.ells[1] end
    end
    local zone_before = Panel.ui.page_state.basic.zone
    -- forehead tap (above the brows)
    local x, y = at({ (brow[1] + 300) / 2, brow[2] - brow[4] * 3.2 })
    MOUSE.x, MOUSE.y, MOUSE.down = x, y, true; frame(); MOUSE.down = false; frame()
    run_for(0.12)
    check(math.abs(WEIGHTS[ei] - 1.0) < 1e-6, "tapping the forehead plays the forehead reaction")
    check(Panel.ui.page_state.basic.zone == zone_before, "tapping the face no longer selects a region")
    run_for(0.7)
    -- mouth drag to the viewer's right
    x, y = at(mouth)
    MOUSE.x, MOUSE.y, MOUSE.down = x, y, true; frame()
    MOUSE.x = x + mouth[3] * 2.5 * s; frame(); frame()
    check(math.abs(WEIGHTS[si] - 1.0) < 1e-6, "dragging the mouth pulls it (full at 2.5 half-widths)")
    MOUSE.down = false; frame(); run_for(0.4)
    check(math.abs(WEIGHTS[si] - base_s) < 1e-6, "mouth springs back after release")
    -- a mouth tap does nothing
    MOUSE.x, MOUSE.y, MOUSE.down = at(mouth); MOUSE.down = true; frame(); MOUSE.down = false; frame(); ticks(2)
    check(not Touch.any(), "tapping the mouth plays nothing")
end
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
-- sculpt: reset all (one undo step)
local function key(n) for _, k in ipairs(st.sculpt.keys) do if k.name == n then return k end end end
SKS.call("set_sculpt_key", { name = self_key, value = 0.7 })
SKS.call("set_sculpt_key", { name = expr_key, value = 0.3 }); ticks(2)
local d1, d2 = key(self_key).default, key(expr_key).default
local okr, _, _, rr = SKS.call("reset_sculpt_all"); ticks(2)
check(okr and rr.done and key(self_key).value == d1 and key(expr_key).value == d2, "reset_sculpt_all -> mod defaults")
check(math.abs(WEIGHTS[si] - d1) < 1e-6, "reset written to the mesh")
SKS.call("sculpt_undo"); ticks(2)
check(math.abs(key(self_key).value - 0.7) < 1e-6 and math.abs(key(expr_key).value - 0.3) < 1e-6, "one undo brings every value back")
SKS.call("sculpt_redo"); ticks(1)
check(key(self_key).value == d1, "redo resets again")
local _, _, _, rr2 = SKS.call("reset_sculpt_all")
check(rr2.done == false, "reset with nothing to reset: no undo step")
SKS.call("set_sculpt_key", { name = self_key, value = 0.55 }); ticks(1)
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "sculpt"; frame()
local rb
for _, dd in ipairs(DRAWS) do if dd.s == "重置" then rb = dd end end
check(rb ~= nil, "重置 button drawn")
if rb then MOUSE.x, MOUSE.y, MOUSE.down = rb.x + 4, rb.y + 6, true; frame(); MOUSE.down = false; frame() end
check(key(self_key).value == d1, "clicking 重置 resets")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
-- cap 1 read as the integer 1 (settings.json): a slider at the cap must still write a float
SKS.call("set_setting", { key = "sculpt_max", value = 1 })   -- integer, like json.load_file gives
INT_WRITES = 0
SKS.call("set_sculpt_key", { name = self_key, value = 5 }); ticks(2)   -- clamps to the cap
check(WEIGHTS[si] == 1 and math.type(WEIGHTS[si]) == "float", "cap 1: value at the cap is written as the float 1.0")
FC[1] = 0.05; ticks(3)                                                   -- expression clamped to 1
check(INT_WRITES == 0, "no integer ever reaches setBlendShapeChannelWeightParam")
FC[1] = 0
-- 5: a profile applied by hand is not switched back by the parent preset's profile
local part = st.scene.parts[1].id
SKS.call("write_binding", { part = part, expression = "arkit" }); SKS.call("rescan"); ticks(5)
check(st.expression.profile.id == "arkit", "binding names arkit -> arkit in effect")
SKS.call("set_profile", { id = "shinano" }); ticks(5); SKS.call("rescan"); ticks(5)
check(st.expression.profile.id == "shinano", "applied shinano by hand: still shinano after a rescan")
-- panel: choosing only pre-selects, 应用 switches
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
SKS.call("set_setting", { key = "advanced", value = true })
Panel.ui.page = "basic"; Panel.ui.page_state.basic.tab = "mapping"; frame()
local Pg = Panel.ui.page_state.basic
local list = st.presets.expression
local other
for i, p in ipairs(list) do if p.id ~= st.expression.profile.id then other = i end end
Pg.pick_profile = other; frame()
check(st.expression.profile.id == "shinano", "pre-selecting another profile changes nothing")
local ap
for _, dd in ipairs(DRAWS) do if dd.s == "应用" then ap = dd end end
check(ap ~= nil, "应用 button shown while a different profile is pre-selected")
local applied
if ap then MOUSE.x, MOUSE.y, MOUSE.down = ap.x + 4, ap.y + 6, true; frame(); applied = st.expression.profile.id; MOUSE.down = false; frame() end
-- (checked at once: on the mock mesh arkit drives nothing, so the scan right after auto-switches back)
check(applied == list[other].id, "应用 switches the profile")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
-- 归零: every key to 0, one undo step
SKS.call("set_sculpt_key", { name = self_key, value = 0.4 }); ticks(1)
local okz, _, _, rz = SKS.call("zero_sculpt_all"); ticks(2)
local allzero = true
for _, k in ipairs(st.sculpt.keys) do if k.value ~= 0 then allzero = false end end
check(okz and rz.done and allzero and WEIGHTS[si] == 0, "zero_sculpt_all -> every key 0")
SKS.call("sculpt_undo"); ticks(1)
check(math.abs(key(self_key).value - 0.4) < 1e-6, "undo after 归零 brings the values back")
-- gaze settings on the 映射配置 tab
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "basic"; Panel.ui.page_state.basic.tab = "mapping"; Panel.ui.page_state.basic.gaze_open = true; Panel.ui.win.h = 1060
local col = {}
for _, g in ipairs(st.expression.groups) do col[g.key] = true end
Panel.ui.page_state.basic.collapsed = col
frame(); frame()
local function has(t) for _, dd in ipairs(DRAWS) do if dd.s:find(t, 1, true) then return true end end end
check(has("视线设置") and has("满权重水平角") and not has("页面出错"), "映射配置 has the gaze settings section")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
print("TOUCH FAILS:", tf)
