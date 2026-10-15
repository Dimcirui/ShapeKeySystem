-- game adapters: Registry.pick, the entry on an unsupported game or a failed adapter init,
-- adapters calling no sdk while loading, no game names in Core / UI, every builtin profile
-- against every game's dictionary
local SKS = require("ShapeKeySystem_Core.API")
local Games = require("ShapeKeySystem_Games.Registry")
local Wilds = require("ShapeKeySystem_Games.Wilds.Adapter")
local Profile = require("ShapeKeySystem_Core.Profile")
local gf = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[games] " .. what)
    if not cond then gf = gf + 1 end
end
local function short(path) return path:match("autorun/(.+)$") or path end

check(Games.game_name() == "mhwilds" and Games.pick("mhwilds") == Wilds and SKS.adapter == Wilds, "mhwilds picks the Wilds adapter")
check(Games.pick("unsupported_test_game") == nil and Games.pick(nil) == nil, "an unknown game picks nothing")
local Onimusha = Games.pick("onimusha_wots")
check(Onimusha and Onimusha.raw and Onimusha.bind and Onimusha.read,
    "onimusha_wots picks the bsControl adapter")

-- the entry script run again; returns what it registered, hooked, wrote and showed
local function run_entry(game)
    local saved_cb, saved_re, saved_dump, saved_hooks = {}, {}, json.dump_file, HOOKS
    for k, v in pairs(CB) do saved_cb[k] = v end
    local regs, dumps = {}, 0
    for k, f in pairs(re) do
        saved_re[k] = f
        re[k] = function(...) regs[#regs + 1] = k; return f(...) end
    end
    json.dump_file = function(...) dumps = dumps + 1; return saved_dump(...) end
    HOOKS, TEXTS, GAME_NAME = {}, {}, game
    dofile(ENTRY)
    local ui = CB.ui
    if ui then ui() end
    local out = { regs = table.concat(regs, ","), hooked = next(HOOKS) ~= nil, dumps = dumps, text = table.concat(TEXTS, "\n") }
    for k, f in pairs(saved_re) do re[k] = f end
    for k in pairs(CB) do CB[k] = nil end
    for k, v in pairs(saved_cb) do CB[k] = v end
    json.dump_file, HOOKS, GAME_NAME = saved_dump, saved_hooks, "mhwilds"
    return out
end

local r = run_entry("unsupported_test_game")
check(r.regs == "on_draw_ui" and not r.hooked and r.dumps == 0, "unsupported game: only a menu line, no hooks, nothing written (" .. r.regs .. ")")
check(r.text:find("暂不支持当前游戏（unsupported_test_game）", 1, true) ~= nil, "unsupported game: the menu names the game")

local find_type = sdk.find_type_definition
sdk.find_type_definition = function(n) if n == "app.PlayerManager" then return nil end return find_type(n) end
r = run_entry("mhwilds")
local oni_failed = run_entry("onimusha_wots")
sdk.find_type_definition = find_type
check(r.regs == "on_draw_ui" and not r.hooked and r.dumps == 0, "adapter init fails: same as unsupported (" .. r.regs .. ")")
check(r.text:find("找不到类型 app.PlayerManager", 1, true) ~= nil, "adapter init fails: the menu gives the reason")
check(oni_failed.regs == "on_draw_ui" and not oni_failed.hooked and oni_failed.dumps == 0
    and oni_failed.text:find("找不到类型 app.PlayerManager", 1, true), "Onimusha init failure leaves only the menu reason")

-- D3: adapter files call no sdk at load (only the picked adapter's init may)
local real_sdk = sdk
sdk = setmetatable({}, { __index = function(_, k) error("sdk." .. tostring(k) .. " while loading", 2) end })
for _, f in ipairs(lua_files("ShapeKeySystem_Games")) do
    local chunk, err = loadfile(f)
    local ok, e = false, err
    if chunk then ok, e = pcall(chunk) end
    check(ok, "loads without sdk: " .. short(f) .. (ok and "" or (" " .. tostring(e))))
end
sdk = real_sdk

-- Core and UI name no game: no app.* types, fcParam joints or ch02 / ch03 parts outside comments
local TOKENS = { "app.", "fcParam_", "ch02", "ch03" }
local hits = {}
for _, sub in ipairs({ "ShapeKeySystem_Core", "ShapeKeySystem_UI" }) do
    for _, f in ipairs(lua_files(sub)) do
        local fh = io.open(f, "rb")
        local src = fh:read("a"); fh:close()
        src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
        local n = 0
        for line in (src .. "\n"):gmatch("(.-)\r?\n") do
            n = n + 1
            local code = line:gsub("%-%-.*$", "")
            for _, t in ipairs(TOKENS) do
                if code:find(t, 1, true) then hits[#hits + 1] = short(f) .. ":" .. n .. " " .. t end
            end
        end
    end
end
check(#hits == 0, "Core / UI code names no game " .. table.concat(hits, ", "))

-- D6: every builtin profile compiles against every game's dictionary
local keep = Profile.adapter
for _, A in ipairs(Games.list) do
    Profile.adapter = A
    local sig = Profile.load_signals()
    Profile.load_all()
    local bad = {}
    for _, e in ipairs(Profile.list) do
        if e.source == "builtin" then
            local res = Profile.resolve(e.id)
            local pr, _, m = res and Profile.compile(res, {})
            if not pr then bad[#bad + 1] = e.id .. " " .. tostring(m) end
        end
    end
    check((#sig.list > 0 or (sig.none and A.raw == nil)) and #bad == 0,
        A.id .. ": every builtin profile compiles " .. table.concat(bad, "; "))
end
Profile.adapter = keep
Profile.load_signals()
Profile.load_all()

print("GAMES FAILS:", gf)
