-- interface language: the setting switches I18n, tr / f look Chinese text up, the panel's draw
-- layer measures the translation; table coverage is checked by i18n_check.py
local SKS = require("ShapeKeySystem_Core.API")
local L = require("ShapeKeySystem_Core.I18n")
local D = require("ShapeKeySystem_UI.Draw")
local fails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[i18n] " .. what)
    if not cond then fails = fails + 1 end
end

check(L.lang == "zh" and L.tr("保存") == "保存", "Chinese by default: text comes back unchanged")
check(SKS.call("set_setting", { key = "language", value = "en" }) and L.lang == "en", "the setting switches to English")
check(SKS.state.settings.language == "en", "the settings state shows the language")
local en = L.table("en")
check(en ~= nil and next(en) ~= nil, "the English table loads")
en = en or {}
check(L.tr("保存") == en["保存"] and L.tr("保存") ~= "保存", "a known string is translated")
check(L.tr("没有这个条目的文字") == "没有这个条目的文字" and L.tr(42) == 42, "unknown text and non-strings come back unchanged")
local key
for k, v in pairs(en) do
    local _, n = k:gsub("%%", "")
    if n == 1 and k:find("%%s") and v:find("%%s") then key = k; break end
end
check(key and L.f(key, "Maya") == string.format(en[key], "Maya"), "f formats the translated template")
local ok = SKS.call("set_setting", { key = "language", value = "fr" })
check(not ok and L.lang == "en", "an unknown language is rejected and changes nothing")

-- the draw layer measures what it draws: the translation, not the Chinese key
local f = { measure = function(_, s) return #s * 10, 10 end }
check(D.measure(f, "保存") == D.measure(f, L.tr("保存")) and #L.tr("保存") ~= #"保存",
    "Draw measures the translated text")
check(D.fit(f, "保存", 1000) == L.tr("保存"), "Draw fits the translated text")

check(SKS.call("set_setting", { key = "language", value = "zh" }) and L.lang == "zh" and L.tr("保存") == "保存",
    "back to Chinese")
print("I18N RUNTIME FAILS:", fails)
