-- 表情详情: choosing a profile in the list shows it below (read-only) before 应用
local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local pf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[preview] " .. what)
    if not cond then pf = pf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(t) for _, d in ipairs(DRAWS) do if d.s:find(t, 1, true) then return d end end end

local ex = st.expression
local active = ex.profile and ex.profile.id
local other
for _, p in ipairs(st.presets.expression or {}) do if p.id ~= active then other = p.id; break end end
check(active and other, "two profiles to compare: " .. tostring(active) .. " / " .. tostring(other))

check(SKS.call("preview_profile", { id = other }), "preview_profile")
local pv = ex.preview
check(pv and pv.id == other and #pv.channels > 0 and #pv.groups > 0, "preview holds the other profile's channels")
check(ex.profile.id == active, "the face keeps its profile (nothing applied)")
local n_present = 0
for _, c in ipairs(pv.channels) do if c.present then n_present = n_present + 1 end end
check(pv.present == n_present and pv.total == #pv.channels, string.format("present count %d / %d", pv.present, pv.total))
local okx, code = SKS.call("preview_profile", { id = "no_such_profile" })
check(not okx and code == "E_NOT_FOUND", "unknown profile -> E_NOT_FOUND")
SKS.call("rescan"); ticks(5)
check(ex.preview and ex.preview.id == other, "preview survives a rescan")

-- panel: pick in the dropdown -> rows of the other profile + 正在浏览 banner, no gain sliders
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
local adv_was = st.runtime.advanced
SKS.call("set_setting", { key = "advanced", value = true })
Panel.ui.page = "expr"
local ps = Panel.ui.page_state.expr or {}
Panel.ui.page_state.expr = ps
local plist = st.presets.expression
for i, p in ipairs(plist) do if p.id == other then ps.pick_profile = i end end
ps.collapsed, ps.filter, ps.only_active = {}, nil, false
frame(); frame()
check(find("正在浏览：") ~= nil, "browse banner shown")
PREVIEW_CMDS = CMDS
check(find("应用") ~= nil and find("取消") ~= nil, "应用 / 取消 offered")
check(find("测试") == nil, "read-only: no 测试 buttons while browsing")
local first = pv.channels[pv.groups[1].channel_slots[1]]
check(find(first.label or first.name) ~= nil, "a channel of the browsed profile is listed: " .. (first.label or first.name))
-- 取消 -> back to the active profile, preview cleared
local cancel = find("取消")
MOUSE.x, MOUSE.y = cancel.x + 4, cancel.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame(); frame()
check(ps.pick_profile == nil and ex.preview == nil, "取消 clears the preview")
check(find("正在浏览：") == nil, "banner gone")
-- 应用 through set_profile also clears it
SKS.call("preview_profile", { id = other })
local okp, c1, m1 = SKS.call("set_profile", { id = other }); ticks(2)
check(ex.preview == nil, string.format("applying the browsed profile ends the preview (set_profile %s %s %s, now %s)",
    tostring(okp), tostring(c1), tostring(m1), tostring(ex.profile and ex.profile.id)))
SKS.call("set_profile", { id = active }); ticks(2)
SKS.call("set_setting", { key = "advanced", value = adv_was == true })
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
-- 设置与调试 → 关于: version, author, latest release notes (Core/Version.lua)
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "debug"; frame(); frame()
local Version = require("ShapeKeySystem_Core.Version")
-- every "；"-separated item of the notes is a line of its own
local notes_shown = true
do -- 按完整的「；」拆分；[^；] 是字节类，会切开汉字
    local notes, start = Version.history[1].notes, 1
    repeat
        local i, j = notes:find("；", start, true)
        local part = notes:sub(start, (i or 0) - 1)
        if part ~= "" and not find(part) then notes_shown = false end
        start = (j or #notes) + 1
    until not i
end
check(find("关于") and find("v" .. Version.number) and find(Version.author) and notes_shown,
    "about card: v" .. Version.number .. " · " .. Version.author .. " · " .. Version.history[1].notes)
check(SKS.version == Version.number and _G.ShapeKeySystemAPI.plugin_version == Version.number, "SKS.version / API plugin_version follow Version.lua")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
print("PREVIEW FAILS:", pf)
