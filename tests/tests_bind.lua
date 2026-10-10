-- "当前绑定" / 绑定到 (bind_config), save-in-place, armor names
local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local bf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[bind] " .. what)
    if not cond then bf = bf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(t) for _, d in ipairs(DRAWS) do if d.s:find(t, 1, true) then return d end end end
local function click(d) MOUSE.x, MOUSE.y = d.x + 4, d.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end

SKS.call("rescan"); ticks(5)
local bi = st.presets.bind
check(bi and bi.model == "ch03_012_001" and bi.display == "刺花蜘蛛 α/β", "当前绑定 shows the armor name (" .. tostring(bi and bi.display) .. ")")

-- bind a sculpt preset: only that field changes, the rest of the binding stays
SKS.call("save_sculpt", { name = "Bind Test" }); ticks(2)
local before = st.presets.binding and st.presets.binding.profile_id
check(SKS.call("bind_config", { kind = "sculpt", name = "Bind Test" }), "bind_config sculpt")
SKS.call("rescan"); ticks(5)
check(st.presets.binding.sculpt == "Bind Test" and st.presets.binding.profile_id == before, "binding names the sculpt preset, profile kept")
check(st.presets.bind.active, "bind target is the binding in effect")
check(SKS.call("bind_config", { kind = "conditions", name = "Test Set" }), "bind_config conditions")
SKS.call("rescan"); ticks(5)
check(st.presets.binding.conditions == "Test Set" and st.presets.binding.sculpt == "Bind Test", "conditions bound, sculpt kept")
local okx, code = SKS.call("bind_config", { kind = "sculpt", name = "nope" })
check(not okx and code == "E_NOT_FOUND", "unknown config -> E_NOT_FOUND")

-- panel: sculpt row shows 已绑定 for the bound preset, 保存 overwrites your own preset without a prompt
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "sculpt"; frame(); frame()
check(find("Bind Test · 默认") ~= nil, "sculpt dropdown marks the default: Bind Test · 默认")
local function exact(t) for _, d in ipairs(DRAWS) do if d.s == t then return d end end end
check(exact("设为默认") == nil, "the default is selected -> no 设为默认 button")
local Sc = require("ShapeKeySystem_Core.Sculpt")
local k1 = st.sculpt.keys[1]
SKS.call("set_sculpt_key", { name = k1.name, value = (k1.value > 0.5) and 0.1 or 0.9 }); frame()
check(st.sculpt.dirty, "edited -> dirty")
PROMPT_OPEN = nil
local sv
for _, d in ipairs(DRAWS) do if d.s == "保存" then sv = d end end
if sv then click(sv) end
check(PROMPT_OPEN == nil and not st.sculpt.dirty, "保存 on your own preset: saved in place, no name prompt")
-- a different preset selected -> 绑定到 button
SKS.call("save_sculpt", { name = "Other" }); frame(); frame()
local bt
for _, d in ipairs(DRAWS) do if d.s == "设为默认" then bt = d end end
check(bt ~= nil, "another preset selected -> 设为默认 next to the dropdown")
if bt then click(bt) end
SKS.call("rescan"); ticks(5); frame(); frame()
check(st.presets.binding.sculpt == "Other" and find("Other") and find("· 默认") ~= nil and exact("设为默认") == nil, "设为默认 binds it")
-- expression page bind bar
SKS.call("set_setting", { key = "advanced", value = true })
Panel.ui.page = "expr"; frame()
check(not find("页面出错"), "expression page draws")
-- 设置与调试 holds the old presets page
Panel.ui.page = "debug"; Panel.ui.page_state.debug.files_open = true; Panel.ui.win.h = 1060; frame()
check(not find("页面出错"), "debug page with the binding / files section draws")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
print("BIND FAILS:", bf)
