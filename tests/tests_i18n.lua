-- English UI (ShapeKeySystem_Core/I18n.lua): every message has zh + en text with the same format
-- params, data files carry English next to the Chinese, the panel and the imgui window draw no
-- Chinese in English mode (real data names excepted), and the language setting switches at once
-- and persists.
local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local W = require("ShapeKeySystem_UI.Widgets")
local P = require("ShapeKeySystem_UI.Prompt")
local st = SKS.state
local nf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[i18n] " .. what)
    if not cond then nf = nf + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function frame() CB.tick(); CB.frame(); DRAWS, DRAWN_IMAGES, CMDS = {}, {}, {}; CB.d2d_draw() end
local function find(t, exact)
    for _, d in ipairs(DRAWS) do
        if (exact and d.s == t) or (not exact and d.s:find(t, 1, true)) then return d end
    end
end
local function click(d) MOUSE.x, MOUSE.y = d.x + 4, d.y + 6; MOUSE.down = true; frame(); MOUSE.down = false; frame() end

-- Chinese / Japanese / full-width characters (kana, CJK ideographs and punctuation, full-width forms)
local function cjk_chars(s)
    local out = {}
    local ok = pcall(function()
        for _, c in utf8.codes(s) do
            if (c >= 0x3000 and c <= 0x30FF) or (c >= 0x3400 and c <= 0x9FFF) or (c >= 0xFF00 and c <= 0xFFEF)
                or (c >= 0xAC00 and c <= 0xD7AF) then
                out[#out + 1] = utf8.char(c)
            end
        end
    end)
    if not ok then out[#out + 1] = "?" end
    return out
end
local function has_cjk(s) return #cjk_chars(tostring(s or "")) > 0 end

-- s with every occurrence of the given names blanked out, but only where a name stands as a token:
-- the characters around it are not CJK (in English text a key name sits between spaces, quotes or
-- ASCII punctuation; "眉上" is untranslated text, not the MMD key "上")
local function char_before(s, a)
    if a <= 1 then return "" end
    local i = a - 1
    while i > 1 do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(i, a - 1)
end
local function char_after(s, b)
    if b >= #s then return "" end
    return s:match("^[%z\1-\127\194-\244][\128-\191]*", b + 1) or ""
end
local function strip_names(s, names)
    for _, k in ipairs(names) do
        if s:find(k, 1, true) then
            local i = 1
            while true do
                local a, b = s:find(k, i, true)
                if not a then break end
                if not has_cjk(char_before(s, a)) and not has_cjk(char_after(s, b)) then
                    s = s:sub(1, a - 1) .. " " .. s:sub(b + 1); i = a + 1
                else
                    i = b + 1
                end
            end
        end
    end
    return s
end

local okL, L = pcall(require, "ShapeKeySystem_Core.I18n")
check(okL and type(L) == "table" and type(L.t) == "function", "ShapeKeySystem_Core.I18n loaded at script load")
if not okL or type(L) ~= "table" or type(L.t) ~= "function" then
    print("I18N FAILS:", nf)
    return
end

check(L.lang == "zh" and st.settings.language == "zh", "default language zh (Dimi's default)")

-- ---------------------------------------------------------------- the message table
local function fmt_specs(s)
    local t = {}
    for spec in s:gsub("%%%%", ""):gmatch("%%[%-%+ #0]*%d*%.?%d*([sdifgxXqc])") do t[#t + 1] = spec end
    return table.concat(t, ",")
end
local n_ids, bad_lang, bad_fmt, en_cjk = 0, {}, {}, {}
for id, e in pairs(L.S) do
    n_ids = n_ids + 1
    if type(e) ~= "table" or type(e.zh) ~= "string" or e.zh == "" or type(e.en) ~= "string" or e.en == "" then
        bad_lang[#bad_lang + 1] = id
    else
        if fmt_specs(e.zh) ~= fmt_specs(e.en) then bad_fmt[#bad_fmt + 1] = id .. " (" .. fmt_specs(e.zh) .. " / " .. fmt_specs(e.en) .. ")" end
        if has_cjk(e.en) then en_cjk[#en_cjk + 1] = id .. ": " .. e.en end
    end
end
check(n_ids > 200, "message table has the panel's strings (" .. n_ids .. " ids)")
check(#bad_lang == 0, "every message id has zh and en text " .. table.concat(bad_lang, ", "))
check(#bad_fmt == 0, "zh and en take the same format params " .. table.concat(bad_fmt, "; "))
check(#en_cjk == 0, "no Chinese in the English text " .. table.concat(en_cjk, "; "))

-- format params and localized arguments
L.set("en")
local probe_id
for id, e in pairs(L.S) do if e.en:find("%s", 1, true) and not e.en:find("%%[^s]") then probe_id = id; break end end
check(probe_id and L.t(probe_id, "ABC"):find("ABC", 1, true) ~= nil, "format params reach the text (" .. tostring(probe_id) .. ")")
check(L.pick({ zh = "甲", en = "A" }) == "A" and L.pick("plain") == "plain", "pick: {zh, en} pair by language, strings as they are")
check(L.field({ name = "眼", name_en = "Eyes" }, "name") == "Eyes" and L.field({ name = "x" }, "name") == "x",
    "field: name_en in English, name when there is no English")
L.set("zh")
check(L.pick({ zh = "甲", en = "A" }) == "甲" and L.field({ name = "眼", name_en = "Eyes" }, "name") == "眼", "zh picks the Chinese")
check(not L.set("fr") and L.lang == "zh", "unknown language refused")

-- ---------------------------------------------------------------- sources: no Chinese literal left outside I18n
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a"); f:close(); return s
end
-- string literals of one Lua source (comments skipped): { {line, text} }
local function literals(src)
    local out, i, n, line = {}, 1, #src, 1
    while i <= n do
        local c = src:sub(i, i)
        if c == "\n" then line = line + 1; i = i + 1
        elseif src:sub(i, i + 1) == "--" then
            local lvl = src:match("^%-%-%[(=*)%[", i)
            local j
            if lvl then j = select(2, src:find("]" .. lvl .. "]", i, true)) else j = src:find("\n", i, true) end
            j = j or n
            if lvl then for _ in src:sub(i, j):gmatch("\n") do line = line + 1 end; j = j + 1 end
            i = j
        elseif c == '"' or c == "'" then
            local j, buf = i + 1, {}
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then buf[#buf + 1] = src:sub(j, j + 1); j = j + 2
                elseif d == c or d == "\n" then break
                else buf[#buf + 1] = d; j = j + 1 end
            end
            out[#out + 1] = { line, table.concat(buf) }
            i = j + 1
        elseif src:match("^%[=*%[", i) then
            local lvl = src:match("^%[(=*)%[", i)
            local _, j = src:find("]" .. lvl .. "]", i, true)
            j = j or n
            out[#out + 1] = { line, src:sub(i, j) }
            for _ in src:sub(i, j):gmatch("\n") do line = line + 1 end
            i = j + 1
        else i = i + 1 end
    end
    return out
end
-- every user-visible string goes through I18n: UI files, the imgui window and the backend's notices.
-- Definition files keep their Chinese next to an English field (checked further down); Touch.lua /
-- Util.lua hold shape-key names and kana tables, Draw.lua a glyph-height probe.
local NO_CJK = { "ShapeKeySystem_Core/API.lua", "ShapeKeySystem_Core/DebugUI.lua", "ShapeKeySystem_Core/Presets.lua",
    "ShapeKeySystem_Core/CondExpr.lua", "ShapeKeySystem_UI/Panel.lua", "ShapeKeySystem_UI/Widgets.lua",
    "ShapeKeySystem_UI/PageBasic.lua", "ShapeKeySystem_UI/PageSculpt.lua", "ShapeKeySystem_UI/PageExpression.lua",
    "ShapeKeySystem_UI/PageEyes.lua", "ShapeKeySystem_UI/PageConditions.lua", "ShapeKeySystem_UI/PageDebug.lua",
    "ShapeKeySystem_UI/PagePresets.lua", "ShapeKeySystem_UI/Prompt.lua", "ShapeKeySystem_UI/Faces.lua",
    "ShapeKeySystem_UI/InputBlocker.lua" }
local left, used_ids = {}, {}
for _, rel in ipairs(NO_CJK) do
    local src = read(AUTORUN_DIR .. "/" .. rel)
    check(src ~= nil, "read " .. rel)
    for _, lit in ipairs(src and literals(src) or {}) do
        if has_cjk(lit[2]) then left[#left + 1] = rel .. ":" .. lit[1] .. " " .. lit[2] end
    end
end
check(#left == 0, "no Chinese string literal outside I18n (" .. #left .. ")")
for i = 1, math.min(#left, 40) do print("  left: " .. left[i]) end
-- every literal id passed to L.t exists
local unknown = {}
for _, rel in ipairs(NO_CJK) do
    local src = read(AUTORUN_DIR .. "/" .. rel) or ""
    for id in src:gmatch("L%.t%(%s*\"([%w_%.]+)\"") do
        used_ids[id] = true
        -- "page." .. key: a prefix completed at run time (checked by L.missing below)
        if not id:find("%.$") and not L.S[id] then unknown[#unknown + 1] = rel .. ": " .. id end
    end
end
check(#unknown == 0, "every L.t id used in the sources exists " .. table.concat(unknown, ", "))

-- ---------------------------------------------------------------- definitions in Core
local X = require("ShapeKeySystem_Core.Expression")
local Cnd = require("ShapeKeySystem_Core.Conditions")
local Version = require("ShapeKeySystem_Core.Version")
local miss = {}
for _, r in ipairs(X.REGIONS) do if not r.name_en or has_cjk(r.name_en) then miss[#miss + 1] = "region " .. r.key end end
for _, g in ipairs(X.GROUPS) do if not g.name_en or has_cjk(g.name_en) then miss[#miss + 1] = "group " .. g.key end end
for _, d in ipairs(Cnd.order) do
    if not d.label_en or has_cjk(d.label_en) then miss[#miss + 1] = "condition " .. d.id end
    for _, o in ipairs(d.options or {}) do
        if not o.label_en or has_cjk(o.label_en) then miss[#miss + 1] = d.id .. "=" .. tostring(o.value) end
    end
end
if not Version.author_en or has_cjk(Version.author_en) then miss[#miss + 1] = "Version.author_en" end
for _, h in ipairs(Version.history) do if not h.notes_en or has_cjk(h.notes_en) then miss[#miss + 1] = "history " .. h.version end end
check(#miss == 0, "regions, groups, conditions, version notes have English " .. table.concat(miss, ", "))
local ex_reg = st.expression.regions[1]
check(ex_reg and ex_reg.name_en ~= nil and st.conditions.defs[1] and st.conditions.defs[1].label_en ~= nil,
    "state carries name_en / label_en for the UI to pick")

-- ---------------------------------------------------------------- data files
-- identifiers a note may quote: every channel / fallback name of every profile, real mesh key lists
local ident = {}
local function add_ident(s) if type(s) == "string" and s ~= "" then ident[#ident + 1] = s end end
local profile_files = fs.glob("ShapeKeySystem\\\\builtin\\\\profiles\\\\[^\\\\]+\\.json")
local profiles = {}
for _, p in ipairs(profile_files) do
    local d = json.load_file(p)
    profiles[#profiles + 1] = { path = p, data = d }
    for _, c in ipairs(d.channels or {}) do
        add_ident(c.name)
        for _, a in ipairs(c.any or {}) do add_ident(a) end
        for _, a in ipairs(c.unless or {}) do add_ident(a) end
    end
end
for _, list in pairs(VRC_FACES or {}) do for _, k in ipairs(list) do add_ident(k) end end
for _, list in pairs(MMD_NAMES or {}) do
    if type(list) == "table" then for _, k in ipairs(list) do add_ident(k) end else add_ident(list) end
end
do
    local seen_i, cj = {}, {}
    for _, k in ipairs(ident) do if has_cjk(k) and not seen_i[k] then seen_i[k] = true; cj[#cj + 1] = k end end
    ident = cj
end
table.sort(ident, function(a, b) return #a > #b end)
-- English data text may quote key names (or a part of one: "おっとり" for おっとり_L / _R): every run
-- of CJK characters left in it must occur inside some real key name
local NL = string.char(10)
local ident_blob = NL .. table.concat(ident, NL) .. NL
local function strip_idents(s)
    local out, run = {}, {}
    local function flush()
        if #run > 0 then
            local r = table.concat(run)
            if not ident_blob:find(r, 1, true) then out[#out + 1] = r end
            run = {}
        end
    end
    for _, c in utf8.codes(s) do
        local ch = utf8.char(c)
        if has_cjk(ch) then run[#run + 1] = ch else flush() end
    end
    flush()
    return table.concat(out, " ")
end
check(#profiles >= 16, "builtin profiles found (" .. #profiles .. ")")
local pmiss, nnotes = {}, 0
for _, p in ipairs(profiles) do
    local d, id = p.data, p.data.id
    if type(d.name_en) ~= "string" or has_cjk(strip_idents(d.name_en)) then pmiss[#pmiss + 1] = id .. ".name_en" end
    if d.description and (type(d.description_en) ~= "string" or has_cjk(strip_idents(d.description_en))) then
        pmiss[#pmiss + 1] = id .. ".description_en"
    end
    for _, c in ipairs(d.channels or {}) do
        if c.note then
            nnotes = nnotes + 1
            if type(c.note_en) ~= "string" or c.note_en == "" then pmiss[#pmiss + 1] = id .. "/" .. c.name .. " no note_en"
            elseif has_cjk(strip_idents(c.note_en)) then pmiss[#pmiss + 1] = id .. "/" .. c.name .. ": " .. c.note_en end
        end
    end
end
check(#pmiss == 0, "every builtin profile has name_en / description_en and every channel note a note_en (" .. nnotes .. " notes)")
for i = 1, math.min(#pmiss, 30) do print("  missing: " .. pmiss[i]) end
local sig = json.load_file("ShapeKeySystem\\builtin\\signals.json")
local smiss = {}
for _, s in ipairs(sig.signals) do
    -- notes that are only a joint name (Pose_01) need no English
    if s.note and has_cjk(s.note) and (type(s.note_en) ~= "string" or has_cjk(s.note_en)) then smiss[#smiss + 1] = s.name end
end
check(#smiss == 0, "every signal note has a note_en " .. table.concat(smiss, ", "))
local Profile = require("ShapeKeySystem_Core.Profile")
check(Profile.signals.by_name["blink.L"] and Profile.signals.by_name["blink.L"].note_en ~= nil, "signal note_en loaded")
local arm = json.load_file("ShapeKeySystem\\builtin\\armor_names.json")
local amiss, an = {}, 0
for m, e in pairs(arm.models) do
    an = an + 1
    if type(e.en) ~= "string" or e.en == "" or has_cjk(e.en) or type(e.zh) ~= "string" then amiss[#amiss + 1] = m end
end
check(#amiss == 0 and an > 400, "every armor name has en and zh (" .. an .. " models)")
local Faces = require("ShapeKeySystem_UI.Faces")
local fmiss = {}
for _, f in ipairs(Faces.list()) do if not f.name_en or has_cjk(f.name_en) then fmiss[#fmiss + 1] = f.id end end
check(#Faces.list() > 0 and #fmiss == 0, "face styles have name_en " .. table.concat(fmiss, ", "))
local reg_maya = Profile.registry["maya"]
check(reg_maya and reg_maya.name_en == "Maya", "profile registry carries name_en")

-- ---------------------------------------------------------------- notices: keys + params
SKS.call("rescan"); ticks(5)
SKS.call("sculpt_scan"); ticks(2)
SKS.call("save_sculpt", { name = "I18n Test" }); ticks(2)
local nlast = st.runtime.notices[#st.runtime.notices]
check(nlast and nlast.key ~= nil and nlast.text:find("I18n Test", 1, true) and has_cjk(nlast.text),
    "notice carries a key; its text is Chinese while zh is set (" .. tostring(nlast and nlast.text) .. ")")

-- ---------------------------------------------------------------- switching
local okset = SKS.call("set_setting", { key = "language", value = "en" })
check(okset and L.lang == "en" and st.settings.language == "en", "set_setting language en switches at once")
local okbad, code = SKS.call("set_setting", { key = "language", value = "fr" })
check(not okbad and code == "E_BAD_ARGS" and L.lang == "en", "unknown language refused by set_setting")
check(nlast.text and not has_cjk(nlast.text) and nlast.text:find("I18n Test", 1, true), "existing notices re-rendered in English: " .. tostring(nlast.text))
ticks(70)
local saved = json.load_file("ShapeKeySystem\\settings.json")
check(saved and saved.language == "en", "language persisted to settings.json")

-- ---------------------------------------------------------------- panel pages in English
-- data names a page may show as they are: channel / key / part / clip / user preset names, log lines
local function data_names()
    local t = {}
    local function add(s) if type(s) == "string" and has_cjk(s) then t[#t + 1] = s end end
    for _, c in ipairs(st.expression.channels or {}) do add(c.name); add(c.canonical) end
    local pv = st.expression.preview
    for _, c in ipairs(pv and pv.channels or {}) do add(c.name); add(c.canonical) end
    for _, k in ipairs(st.sculpt.keys or {}) do add(k.name); for _, p in ipairs(k.parts or {}) do add(p) end end
    for _, p in ipairs(st.scene.parts or {}) do add(p.id) end
    for _, r in ipairs(st.scene.rigs or {}) do add(r.label); for _, x in ipairs(r.targets or {}) do add(x.name) end end
    local cur = st.conditions.current
    if cur then
        add(cur.name)
        for id, c in pairs(cur.data.clips or {}) do add(id); for k in pairs(c.values or {}) do add(k) end end
    end
    for _, e in ipairs(st.conditions.sets or {}) do add(e.name) end
    for _, e in ipairs(st.presets.sculpt or {}) do add(e.name) end
    for _, e in ipairs(st.presets.expression or {}) do if e.source ~= "builtin" then add(e.name) end end
    for _, l in ipairs(st.debug.log or {}) do add(l.text) end
    for _, l in ipairs(st.debug.probe or {}) do add(l) end
    add(st.debug.status)
    for _, e in ipairs(st.external.held or {}) do add(e.name); add(e.owner) end
    for _, x in ipairs(ident) do add(x) end
    local seen_n, out = {}, {}
    for _, x in ipairs(t) do if not seen_n[x] then seen_n[x] = true; out[#out + 1] = x end end
    table.sort(out, function(a, b) return #a > #b end)
    return out
end
local allowed_chars
local function chinese_left(s, names)
    local r = strip_names(s, names)
    local left_c = cjk_chars(r)
    if #left_c == 0 then return nil end
    -- a data name cut with an ellipsis: its remaining characters belong to some data name
    if s:find("…", 1, true) then
        if not allowed_chars then
            allowed_chars = {}
            for _, k in ipairs(names) do for _, ch in ipairs(cjk_chars(k)) do allowed_chars[ch] = true end end
        end
        local all = true
        for _, ch in ipairs(left_c) do if not allowed_chars[ch] then all = false end end
        if all then return nil end
    end
    return r
end
local TIPS = {}
local tooltip0 = W.tooltip
W.tooltip = function(text, ...) if text then TIPS[#TIPS + 1] = text end; return tooltip0(text, ...) end
local function scan_page(what, file)
    allowed_chars = nil
    local names = data_names()
    local bad = {}
    for _, d in ipairs(DRAWS) do
        local r = chinese_left(d.s, names)
        if r then bad[#bad + 1] = d.s end
    end
    for _, t in ipairs(TIPS) do
        local r = chinese_left(t, names)
        if r then bad[#bad + 1] = "tooltip: " .. t end
    end
    TIPS = {}
    local err = find("Page error", false)
    check(#bad == 0 and err == nil and #DRAWS > 0, "en " .. what .. ": no Chinese drawn (" .. #DRAWS .. " texts)")
    for i = 1, math.min(#bad, 25) do print("  zh: " .. bad[i]) end
    if file then SNAPS[#SNAPS + 1] = { name = what, file = file, cmds = CMDS } end
end
local function truncated_report(what)
    local t = {}
    for _, d in ipairs(DRAWS) do if d.s:find("…", 1, true) then t[#t + 1] = d.s end end
    if #t > 0 then print("  [" .. what .. "] cut: " .. table.concat(t, " | ")) end
end

KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
check(Panel.open, "panel open")
SKS.call("set_setting", { key = "advanced", value = false })
Panel.ui.page = "basic"; Panel.ui.win.w, Panel.ui.win.h = 920, 640; frame(); frame()
check(find(L.t("page.basic"), true) and not find(L.t("page.debug"), true), "en rail: basic entries only while advanced is off")
scan_page("basic page (advanced off)", "en_basic_simple")
SKS.call("set_setting", { key = "advanced", value = true })
MOUSE.x, MOUSE.y = 1500, 900
Panel.ui.page = "basic"; frame(); frame()
scan_page("basic page", "en_basic"); truncated_report("basic")
check(find("Expression", false) ~= nil, "the English rail is drawn")

-- sculpt: scanned, a pending delete
Panel.ui.page = "sculpt"; frame(); frame()
scan_page("sculpt page", "en_sculpt"); truncated_report("sculpt")
SKS.call("load_sculpt", { name = "I18n Test" }); SKS.call("request_delete", { kind = "sculpt", name = "I18n Test", folder = st.sculpt.preset and st.sculpt.preset.folder })
frame(); frame()
scan_page("sculpt page, delete confirmation", "en_sculpt_delete")
SKS.call("cancel_delete")
Panel.ui.win.w = 640; frame(); frame()
scan_page("sculpt page, narrow window", "en_sculpt_narrow"); truncated_report("sculpt narrow")
Panel.ui.win.w = 920

-- expression details: gaze settings open, then browsing another profile (Japanese channel names)
local ps = Panel.ui.page_state.expr or {}
Panel.ui.page_state.expr = ps
ps.gaze_open, ps.collapsed, ps.filter, ps.only_active, ps.pick_profile = true, {}, nil, false, nil
Panel.ui.page = "expr"; Panel.ui.win.h = 1060; frame(); frame()
scan_page("expression page + gaze", "en_expr"); truncated_report("expr")
for i, p in ipairs(st.presets.expression) do if p.id == "maya" then ps.pick_profile = i end end
SKS.call("preview_profile", { id = "maya" })
frame(); frame()
check(find("Browsing", false) ~= nil, "browse banner in English")
scan_page("expression page browsing maya", "en_expr_browse"); truncated_report("expr browse")
ps.pick_profile = nil; SKS.call("preview_profile", {})

-- conditions: the fixture set with a rule form and a clip open, then nothing selected
SKS.call("cond_select", { name = "ShinanoOC", discard = true }); ticks(2)
local cps = Panel.ui.page_state.cond or {}
Panel.ui.page_state.cond = cps
cps.closed, cps.form = {}, { si = 1, ri = 1 }
local first_clip
for id in pairs(st.conditions.current and st.conditions.current.data.clips or {}) do first_clip = first_clip or id end
cps.open_clip = first_clip
Panel.ui.page = "cond"; frame(); frame()
scan_page("conditions page", "en_cond"); truncated_report("cond")
local enum_i
for i, d in ipairs(st.conditions.defs) do if d.kind == "enum" and not enum_i then enum_i = i end end
cps.form = { si = 1, ri = 1, type_i = enum_i }; frame(); frame()
scan_page("conditions page, enum condition form")
SKS.call("request_delete", { kind = "conditions", name = "ShinanoOC" }); frame(); frame()
scan_page("conditions page, delete confirmation")
SKS.call("cancel_delete")
cps.form = nil
SKS.call("cond_select", { name = "", discard = true }); frame(); frame()
scan_page("conditions page, no set", "en_cond_none")
SKS.call("cond_select", { name = "ShinanoOC", discard = true })

-- settings & debug: files section open, a key held by another plugin
_G.ShapeKeySystemAPI.set("I18nMod", "Waist_thin", 0.3, { ttl = 0 }); ticks(2)
Panel.ui.page_state.debug = Panel.ui.page_state.debug or {}
Panel.ui.page_state.debug.files_open = true
Panel.ui.page = "debug"; frame(); frame()
check(find("Language", false) ~= nil, "language row in the settings card")
scan_page("settings & debug page", "en_debug"); truncated_report("debug")
SKS.call("request_delete", { kind = "sculpt", name = "I18n Test", folder = st.sculpt.preset and st.sculpt.preset.folder }); frame(); frame()
scan_page("settings & debug page, delete confirmation")
SKS.call("cancel_delete")
_G.ShapeKeySystemAPI.release_all("I18nMod"); ticks(2)
Panel.ui.page_state.debug.files_open = false
Panel.ui.win.h = 640

-- the narrowest window (640 = Theme.m.min_w): English labels must still fit
SKS.call("cond_select", { name = "ShinanoOC", discard = true }); ticks(2)
Panel.ui.page_state.cond.form, Panel.ui.page_state.cond.open_clip = nil, nil
Panel.ui.win.w, Panel.ui.win.h = 640, 800
for _, pg in ipairs({ "basic", "expr", "cond", "debug" }) do
    Panel.ui.page = pg; frame(); frame()
    scan_page(pg .. " page, narrow window", "en_" .. pg .. "_narrow"); truncated_report(pg .. " narrow")
end
Panel.ui.win.w, Panel.ui.win.h = 920, 640

-- prompts: title, buttons and the extra checkbox
local labels = {}
local button0, checkbox0 = imgui.button, imgui.checkbox
imgui.button = function(l, ...) labels[#labels + 1] = l; return button0(l, ...) end
imgui.checkbox = function(l, ...) labels[#labels + 1] = l; return checkbox0(l, ...) end
Panel.ui.page = "sculpt"; frame(); frame()
local sa = find(L.t("sculpt.save_as"), true)
check(sa ~= nil, "sculpt save-as button drawn")
if sa then click(sa) end
check(PROMPT_OPEN ~= nil and not has_cjk(PROMPT_OPEN), "prompt title in English: " .. tostring(PROMPT_OPEN))
local pl = {}
for _, l in ipairs(labels) do if has_cjk(l) then pl[#pl + 1] = l end end
check(#labels > 0 and #pl == 0, "prompt buttons / checkbox in English " .. table.concat(pl, ", "))
P.close(); PROMPT_OPEN = nil
imgui.button, imgui.checkbox = button0, checkbox0

-- toasts: a failing command shows its toast in English
for i = #Panel.ui.toasts, 1, -1 do table.remove(Panel.ui.toasts, i) end
Panel.toast("warn", L.t("cond.unsaved_toast"))
frame()
local tz = {}
for _, t in ipairs(Panel.ui.toasts) do if has_cjk(t.text) then tz[#tz + 1] = t.text end end
check(#Panel.ui.toasts > 0 and #tz == 0, "toasts in English " .. table.concat(tz, ", "))
-- a toast made while zh was set is redrawn in English
L.set("zh"); Panel.toast("info", { k = "common.saved", args = { "T1" } }); L.set("en"); frame()
local tlast = Panel.ui.toasts[#Panel.ui.toasts]
check(tlast and tlast.text == "Saved: T1", "a toast follows a language switch: " .. tostring(tlast and tlast.text))
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()

-- ---------------------------------------------------------------- imgui debug window in English
local seen = {}
local saved_imgui = {}
for _, k in ipairs({ "tree_node", "checkbox", "slider_float", "slider_int", "button", "input_text", "text", "text_colored", "set_tooltip" }) do
    saved_imgui[k] = imgui[k]
    imgui[k] = function(l, ...) if type(l) == "string" then seen[#seen + 1] = l:gsub("##.*$", "") end; return saved_imgui[k](l, ...) end
end
saved_imgui.combo = imgui.combo
local lang_combo = false
imgui.combo = function(l, cur, items, ...)
    seen[#seen + 1] = l:gsub("##.*$", "")
    if l:find("Language", 1, true) then lang_combo = true end
    for _, it in ipairs(items or {}) do if it ~= "中文" then seen[#seen + 1] = it end end
    return saved_imgui.combo(l, cur, items, ...)
end
TEXTS = {}
CB.ui()
for _, s in ipairs(TEXTS) do seen[#seen + 1] = s end
for k, f in pairs(saved_imgui) do imgui[k] = f end
local names = data_names()
local iz = {}
allowed_chars = nil
for _, s in ipairs(seen) do if chinese_left(s, names) then iz[#iz + 1] = s end end
check(#seen > 50 and #iz == 0, "imgui window in English (" .. #seen .. " labels)")
for i = 1, math.min(#iz, 25) do print("  zh: " .. iz[i]) end
check(lang_combo, "imgui settings: language combo")

local missing = {}
for id in pairs(L.missing or {}) do missing[#missing + 1] = id end
check(#missing == 0, "no unknown message id looked up " .. table.concat(missing, ", "))

-- ---------------------------------------------------------------- back to Chinese
check(SKS.call("set_setting", { key = "language", value = "zh" }) and L.lang == "zh", "switch back to zh")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
Panel.ui.page = "basic"; frame(); frame()
check(find("表情", true) ~= nil and find("表情强度", true) ~= nil, "Chinese UI again after switching back")
KEYS[0x2E] = true; frame(); KEYS[0x2E] = false; frame()
W.tooltip = tooltip0
ticks(70)
print("I18N FAILS:", nf)
