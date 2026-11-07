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

print("SCULPT ORDER " .. asserts .. " assertions; FAILS: " .. fails)
