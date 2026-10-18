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

-- Core and UI name no game: no app.* / snow.* types, fcParam joints or ch02 / ch03 parts outside comments
local TOKENS = { "app.", "snow.", "fcParam_", "ch02", "ch03" }
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

-- Wilds bone fallback: face joints back up fcParam channels with the larger of the two values
do
    local cal = json.load_file("ShapeKeySystem/builtin/mhwilds/face.json")
    local fc, offset = {}, {}   -- fc[n] = fcParam z; offset[joint id] = degrees or millimetres along the axis
    local function qmul(a, b)
        return { x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y, y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                 z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w, w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z }
    end
    local joints = {}
    for n = 0, 200 do
        joints[string.format("fcParam_%03d", n)] = { get_LocalPosition = function() return { x = 0, y = 0, z = fc[n] or 0 } end }
    end
    local function add_bones()
        for id, spec in pairs(cal.joints) do
            local nt, ax = spec.neutral, spec.axis
            joints[spec.bone] = {
                get_LocalPosition = function()
                    local d = (offset[id] or 0) / 1000
                    return { x = nt[1] + ax[1] * d, y = nt[2] + ax[2] * d, z = nt[3] + ax[3] * d }
                end,
                get_LocalRotation = function()
                    local h = math.rad(offset[id] or 0) / 2
                    local s = math.sin(h)
                    return qmul({ x = nt[4], y = nt[5], z = nt[6], w = nt[7] },
                        { x = ax[1] * s, y = ax[2] * s, z = ax[3] * s, w = math.cos(h) })
                end,
            }
        end
    end
    local face = { getJointByName = function(_, name) return joints[name] end, get_address = function() return 0xFACE end }
    local function read(keys)
        local h = Wilds.bind(face, keys)
        local P = {}
        Wilds.read(h, P, 100)
        return P, h
    end
    local near = function(a, b) return math.abs(a - b) < 1e-3 end

    local P, h = read({ 1, 2, 33, 34, 52 })
    check(h.bones == nil and P[52] == 0, "wilds bones: a face without the calibrated joints reads fcParam only")
    add_bones()
    P, h = read({ 1, 2, 33, 34, 52 })
    check(h.bones ~= nil and #h == 10 and P[1] == 0 and P[2] == 0 and P[33] == 0 and P[52] == 0,
        "wilds bones: neutral joints add nothing and the handle still counts fcParam pairs")
    offset["jaw.open"] = 12; offset["L_UpEyeLid.close"] = 37; offset["L_cornerLip.smile"] = 10
    P = read({ 1, 2, 33, 34, 52 })
    check(near(P[52], 0.75) and near(P[1], 1) and P[2] == 0 and near(P[33], 1) and P[34] == 0,
        "wilds bones: jaw, eyelid and lip corner fill silent fcParam channels per side")
    offset["jaw.open"] = 6.5; fc[52] = 0.008
    P = read({ 52 })
    check(near(P[52], 0.8), "wilds bones: a larger fcParam value wins over the bone value")
    fc[52] = 0.002
    P = read({ 52 })
    check(near(P[52], 0.375), "wilds bones: a larger bone value wins over a small fcParam value")
    offset["L_UpEyeLid.close"] = 10
    P = read({ 1 })
    check(P[1] == 0, "wilds bones: an eyelid lowered by a downward gaze is not a blink")
    P, h = read({ 52 })
    check(#h.bones.calibration.rules == 1 and P[1] == nil and P[33] == nil,
        "wilds bones: only rules for bound fcParam channels are evaluated")
end

print("GAMES FAILS:", gf)
