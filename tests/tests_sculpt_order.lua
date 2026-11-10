-- Sculpt key list: channel order, section titles from separator channels and names files.
local S = require("ShapeKeySystem_Core.Sculpt")
local Labels = require("ShapeKeySystem_Core.Labels")
local U = require("ShapeKeySystem_Core.Util")
local fails, asserts = 0, 0
local function check(ok, what)
    asserts = asserts + 1
    if ok then print("ok   [order] " .. what) else fails = fails + 1; print("FAIL [order] " .. what) end
end

local function mesh(addr) return { get_address = function() return addr end } end
Labels.sections[U.norm("Second")] = "OTHER"
local parts = {
    { id = "p1", mesh = mesh(0x100), names = { "bs.Zeta", "bs.=====EYE=====", "bs.alpha", "bs.Mid",
        "bs.======= MOUTH =======", "bs.beta" } },
    { id = "p2", mesh = mesh(0x200), names = { "bs.Second", "bs.alpha" } },
}
local keys = S.rebuild(parts, {}, function() return nil end)
local order = {}
for i, k in ipairs(keys) do order[i] = k.name end
check(table.concat(order, ",") == "Zeta,alpha,Mid,beta,Second",
    "keys follow the channel order of their first part, not the alphabet (" .. table.concat(order, ",") .. ")")
check(S.K.by_name["=====EYE====="] == nil and S.K.by_name["======= MOUTH ======="] == nil,
    "separator channels are not keys")
check(S.K.by_name.alpha.section == "EYE" and S.K.by_name.beta.section == "MOUTH" and S.K.by_name.Zeta.section == nil
    and S.K.by_name.Mid.section == nil, "a separator channel titles the key after it")
check(S.K.by_name.Second.section == "OTHER", "a names-file section titles its first key")
local t1
for _, t in ipairs(S.K.targets) do if t.id == "p1" then t1 = t end end
local written = {}
for _, item in ipairs(t1.items) do written[#written + 1] = item.key.name end
check(#written == 4, "no write item for a separator channel (" .. #written .. ")")
Labels.sections = {}

-- another character: nothing of the previous one's edits or saved state carries over
S.apply_preset({ values = { alpha = .5 }, overrides = {}, key_groups = { { name = "G", value = 0, options = {} } } })
S.mark_saved()
local other = { { id = "q1", mesh = mesh(0x300), names = { "bs.alpha", "bs.only_here" } } }
S.forget_edits()
S.rebuild(other, {}, function() return nil end)
check(not S.is_dirty() and S.K.by_name.alpha.value == 0 and #S.K.groups == 0 and not S.can_undo(),
    "forget_edits: the next character starts clean from its own presets")
S.forget_edits()
S.rebuild(parts, {}, function() return nil end)
S.apply_preset({ values = { alpha = .5 }, overrides = {}, key_groups = {} })
S.mark_saved()
S.rebuild(other, {}, function() return nil end)
check(S.is_dirty(), "without forget_edits the saved state of other keys makes the new keys unsaved (the bug)")

print("SCULPT ORDER " .. asserts .. " assertions; FAILS: " .. fails)
