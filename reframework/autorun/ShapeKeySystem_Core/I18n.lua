-- ShapeKeySystem: interface language (settings.language = "zh" | "en"; zh is the default).
--
-- Interface text is written in Chinese and the Chinese text is the key: builtin/i18n/<lang>.json
-- maps each Chinese string to its translation. The panel's draw layer (Draw.lua) passes every
-- string through `L.tr`, so static text needs no call at its source. Text built from parts must
-- be one template: `L.f("已删除：%s", name)` instead of `"已删除：" .. name`, or the whole string
-- has no entry.
--
-- Constraints:
-- - Only display goes through the table. Stored values (setting values, condition ids, names in
--   user files) stay Chinese and are never translated before they are compared or saved.
-- - A string without an entry shows as it is, so a missing translation shows Chinese, not an
--   error. tests_i18n.lua checks that every Chinese literal in the scripts has an entry.
-- - Shape key, channel, signal and file names are never translated (they are not in the table).

local L = { lang = "zh" }

L.LANGS = { "zh", "en" }
-- shown in the language picker in their own script, whatever the interface language is
L.LANG_NAMES = { zh = "中文", en = "English" }

local tables = {}   -- lang -> { [chinese] = translation }
local active = nil  -- the table of L.lang; nil for Chinese

-- <lang>.json holds the script text, <lang>_data.json the text of builtin data (profile names,
-- descriptions and channel notes, signal notes); both are merged into one table.
local function load(lang)
    if tables[lang] == nil then
        local merged, any = {}, false
        for _, name in ipairs({ lang, lang .. "_data" }) do
            local ok, data = pcall(json.load_file, "ShapeKeySystem/builtin/i18n/" .. name .. ".json")
            if ok and type(data) == "table" and type(data.strings) == "table" then
                for k, v in pairs(data.strings) do merged[k] = v end
                any = true
            end
        end
        tables[lang] = any and merged or false
    end
    return tables[lang] or nil
end

-- Returns true when lang is known; an unknown value leaves the language unchanged.
function L.set(lang)
    if lang == "zh" then
        L.lang, active = "zh", nil
        return true
    end
    if lang ~= "en" then return false end
    L.lang, active = lang, load(lang)
    return true
end

-- s in the interface language; anything without an entry comes back unchanged.
function L.tr(s)
    if not active or type(s) ~= "string" then return s end
    local t = active[s]
    if t == nil or t == "" then return s end
    return t
end

-- string.format of the translated template.
function L.f(fmt, ...)
    return string.format(L.tr(fmt), ...)
end

-- tests: the loaded table of a language, or nil
function L.table(lang) return load(lang) end

return L
