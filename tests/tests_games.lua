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
-- face mirror: Wilds, RE4R and Onimusha each build their own, with their own joints
local RE4 = Games.pick("re4")
check(Wilds.face_mirror and RE4 and RE4.face_mirror and Wilds.face_mirror ~= RE4.face_mirror
    and Wilds.face_mirror.view.binds[4].id == "COG" and RE4.face_mirror.view.binds[4].id == "Hip"
    and Wilds.face_mirror.view.binds[2].id == "Neck_0" and RE4.face_mirror.cfg.rigs.Neck_0
    and RE4.face_mirror.cfg.rigs.Hip and not RE4.face_mirror.cfg.rigs.COG and Onimusha.face_mirror
    and Onimusha.face_mirror ~= Wilds.face_mirror and Onimusha.face_mirror.view.binds[4].id == "COG",
    "face mirror per game: Wilds and Onimusha COG, RE4R Hip")
local rp, wp = RE4.face_mirror.part, Wilds.face_mirror.part
check(rp("head", "_chainsaw/character/ch/cha0/cha000/10/cha000_10.mesh") == "head"
    and rp("hair", "_chainsaw/character/ch/cha0/cha000/20/cha000_20.mesh") == "head"
    and rp("body", "_chainsaw/character/ch/cha0/cha000/00/cha000_00.mesh") == "body"
    and rp("wp4001", "_chainsaw/character/wp/wp40/wp4000/21/wp4000_21.mesh") == "weapon"
    and rp("wp5401", "_chainsaw/ui/ui2000/mesh/throwtarget_mesh.mesh") == "other",
    "RE4R face mirror parts: head / hair, body, weapon, other")
check(wp("Player_Face", "") == "head" and wp("ch03_012_0013", "") == "helm" and wp("ch03_012_0012", "") == "body"
    and wp("ch03_012_0011", "") == "arm" and wp("ch03_012_0014", "") == "legs" and wp("ch03_012_0015", "") == "waist"
    and wp("ch03_057_0016", "") == "body" and wp("Acc000_010", "") == "acc" and wp("Wp_Parent", "") == "weapon"
    and wp("WpSub_ReserveParent", "") == "weapon" and wp("HunterKnifeBase_R", "") == "weapon"
    and wp("SlingerRope", "") == "weapon" and wp("HeadToHip", "") == "other",
    "Wilds face mirror parts: face, armour by slot, accessories, weapons, other")
local op = Onimusha.face_mirror.part
check(op("Head", "art/model/character/ch0/ch001_00/20/ch001_00_20.mesh") == "head" and op("OniHead", "") == "head"
    and op("Body", "") == "body" and op("Gauntlet", "") == "body" and op("Amulet", "") == "body" and op("OniBody", "") == "body"
    and op("Cloak", "") == "cloak" and op("Gm800_000_00", "art/model/item/it0/it000_0210/it000_0210_00.mesh") == "weapon"
    and op("Body_Obstacle", "") == "other",
    "Onimusha face mirror parts: head / hair, body, cloak, swords and items, other")
check(Wilds.face_mirror.cfg.hide.weapon == true and Wilds.face_mirror.cfg.hide.legs == false
    and RE4.face_mirror.cfg.hide.weapon == true and RE4.face_mirror.cfg.hide.body == false and RE4.face_mirror.cfg.hide.legs == nil,
    "face mirror hide defaults per game: weapons hidden")
check(RE4.face_mirror.cfg.clip_front == 1 and Wilds.face_mirror.cfg.clip_front == 0.2
    and Onimusha.face_mirror.cfg.clip_front == 0.2 and Onimusha.face_mirror.cfg.hide.weapon == true
    and Wilds.face_mirror.cfg.follow_meter == true and Wilds.face_mirror.cfg.ev == -2
    and Onimusha.face_mirror.cfg.follow_meter == false and Onimusha.face_mirror.cfg.ev == 0,
    "face mirror per-game defaults: clip range (wide in RE4R, isolated), weapons hidden, Onimusha meters on its own")

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

-- Onimusha conditions: HP, PlayerManager queries, oni gauges, action state bits, battle, lock-on and
-- speech of the controlling player; a new player context gives no HP for one sample (Core then
-- drops the baseline)
do
    local OC = Onimusha.conditions
    local function obj(addr, methods, fields)
        return { get_address = function() return addr end,
            get_field = function(_, n) return fields and fields[n] end,
            call = function(_, m) local v = methods[m]; if type(v) == "function" then return v() end; return v end }
    end
    local addr = 1
    local ENUM = { IDLE = 1, STAND = 2, ATTACK = 4, GUARD_WAIT = 8, DAMAGE = 16 }
    local health = obj(10, { get_Health = 605, get_MaxHealth = 1210 })
    local player = obj(11, { get_IsOniModeOn = true, get_OniEnergy = 1000, get_OniEnergyMax = 1250,
        get_OniChangeEnergy = 0, get_OniChangeEnergyMax = 1000, isOniUltimateAttackEnergyMax = false })
    local character = obj(12, { get_IsEventStart = false, getActionState = ENUM.STAND | ENUM.ATTACK })
    local context = function()
        return obj(addr, { get_Chara = obj(4, { get_HealthManager = health }), get_Player = player })
    end
    local manager = obj(2, { isPlayerDead = false, isPlayerDying = true, isUseItemAction = false,
        isWallRunAction = false, isReviveAction = false, isDeadHeatAction = false, isOniGateAbsorption = false,
        getInternalLockOnTarget = obj(13, {}),
        getControllingPlayer = function()
            return obj(3, { get_Context = context, get_Character = character, get_CharacterEntity = obj(14, {
                get_SubWeapon = obj(15, { isSubWeaponActionBowTwoHand = true, isSubWeaponActionBowQuickShot = false }),
                get_AutoWeaponOnOffSupporter = obj(16, { isWeaponOn = true }) }) })
        end })
    local work = obj(20, { get_Finished = false, get_Param = function()
        return obj(21, { get_ContextHolder = obj(1, {}) })
    end })
    local singletons = {
        ["app.PlayerManager"] = manager,
        ["app.EnemyManager"] = obj(30, { isCheckBattleMode = true, isCheckBossBattleMode = false }),
        ["app.SpeakManager"] = obj(31, { isWorking = true }, { _SingleWorkManager = obj(32, { get_Work = work }) }),
        ["app.PauseManager"] = obj(33, { get_IsMenuPause = false }),
    }
    local enum = { get_field = function(_, n)
        return { get_data = function() if ENUM[n] then return ENUM[n] end; return 0 end }
    end }
    local keep_sdk = sdk
    sdk = { get_managed_singleton = function(n) return singletons[n] end,
        find_type_definition = function(n) return n == "app.CharacterDef.ACTION_STATE_BIT" and enum or nil end }
    OC.reset()
    local V = {}
    local sampled = OC.sample(V)
    check(sampled and V.hp == 605 and V.hp_max == 1210 and V.dying == true and V.dead == false
        and V.oni_mode == true and V.oni_energy_pct == 80 and V.oni_change_pct == 0
        and V.oni_ultimate_ready == false, "Onimusha conditions read HP, player queries and oni gauges")
    check(V.act_stand == true and V.act_attack == true and V.act_idle == false and V.act_damage == false
        and V.act_parry == nil, "Onimusha conditions: action state bits, unknown bits unread")
    check(V.in_battle == true and V.boss_battle == false and V.lock_on == true and V.menu_pause == false
        and V.event_start == false, "Onimusha conditions: battle, boss, lock-on, pause and event")
    check(V.anyone_speaking == true and V.player_speaking == true, "Onimusha conditions: the player speaks")
    check(V.bow_aim == true and V.bow_quick_shot == false and V.weapon_on == true,
        "Onimusha conditions: bow aim, quick shot and drawn weapon")
    addr = 5
    V = {}
    OC.sample(V)
    check(V.hp == nil and V.dying == true, "Onimusha conditions: a new player context skips one HP sample")
    check(V.anyone_speaking == true and V.player_speaking == false, "Onimusha conditions: someone else speaks")
    sdk = { get_managed_singleton = function() return nil end }
    check(OC.sample({}) == false, "Onimusha conditions: no player manager samples nothing")
    sdk = keep_sdk
    local ids = {}
    for _, d in ipairs(OC.defs) do ids[d.id] = true end
    check(ids.hp_pct and ids.dead and ids.oni_mode and ids.oni_energy_pct and ids.use_item and ids.act_guard_wait
        and ids.player_speaking, "Onimusha conditions define HP %, dead, oni, item use, guard and speech")
end

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
    if A.id == "onimusha_wots" then
        -- bsControl signals fall back to the face bones the auto lip and talk motions move
        local n, lost = 0, {}
        for _, s in ipairs(sig.list) do
            if s.fallback then
                n = n + 1
                if s.key == nil or s.key >= 1000 or #s.fallback ~= 1 or s.fallback[1] < 1000 then lost[#lost + 1] = s.name end
            end
        end
        check(n == 25 and #lost == 0 and sig.by_name.jawOpen.fallback and sig.by_name["blink.L"].fallback,
            "onimusha_wots: 25 bsControl signals fall back to one bone signal each (" .. n .. ") " .. table.concat(lost, ", "))
    end
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

-- Wilds bone signals: named dictionary signals read from face joints (BoneReads)
do
    local near = function(a, b) return a and math.abs(a - b) < 1e-6 end
    local ID = { w = 1, x = 0, y = 0, z = 0 }
    local up, turn = 0, 0   -- lip corner rise (mm) on top of its rest; eyelid turn (degrees)
    local head = { get_Name = function() return "Head" end,
                   get_Position = function() return { x = 0, y = 1.5, z = 0 } end,
                   get_Rotation = function() return ID end }
    local base = { x = 0.02, y = -0.05, z = 0.08 }
    local corner = { get_Name = function() return "L_cornerLip_LOD02" end, get_Parent = function() return head end,
                     get_BaseLocalPosition = function() return base end, get_BaseLocalRotation = function() return ID end,
                     get_BaseLocalScale = function() return { x = 1, y = 1, z = 1 } end,
                     get_Position = function() return { x = base.x, y = 1.5 + base.y + up / 1000, z = base.z } end }
    local lid = { get_Name = function() return "L_UpEyeLidJ_LOD02" end, get_Parent = function() return head end,
                  get_BaseLocalRotation = function() return ID end,
                  get_LocalRotation = function()
                      local h = math.rad(turn) / 2
                      return { x = math.sin(h), y = 0, z = 0, w = math.cos(h) }
                  end }
    local joints = { Head = head, L_cornerLip_LOD02 = corner, L_UpEyeLidJ_LOD02 = lid }
    local face = { getJointByName = function(_, n) return joints[n] end, get_address = function() return 0xB0E end }
    local kc, kl = Wilds.raw.parse("bone.mouthCornerUp.L"), Wilds.raw.parse("bone.eyeClose.L")
    check(kc and kc > 200 and kl and kl > 200 and Wilds.raw.label(kc) == "bone.mouthCornerUp.L",
        "wilds bone signals: bone.<name> parses above the fcParam range and labels back")
    check(Wilds.raw.parse("bone.nope") == nil and Wilds.raw.parse(201) == nil,
        "wilds bone signals: unknown names and fcParam numbers past 200 are rejected")
    local h, n = Wilds.bind(face, { kc, kl, Wilds.raw.parse("bone.browRaise.L") })
    check(h.signals and #h.signals.list == 2 and n == 2, "wilds bone signals: only signals whose joint the face has are bound")
    local P = {}
    -- rest -1.4 mm, deadzone 0.2 of 10 mm: -1.4 + 2 + 4 mm reads 0.6, past the deadzone 0.5
    up = -1.4 + 6; turn = -0.8 + 30 * (0.05 + 0.95 * 0.5)
    Wilds.read(h, P, 100)
    check(near(P[kc], 0.5) and near(P[kl], 0.5), "wilds bone signals: pos and rot read past rest and deadzone")
    up, turn = -5, -10
    Wilds.read(h, P, 100)
    check(P[kc] == 0 and P[kl] == 0, "wilds bone signals: motion against the sign reads 0")
    up, turn = 30, 90
    Wilds.read(h, P, 100)
    check(P[kc] == 1 and P[kl] == 1, "wilds bone signals: past full stays at 1")
    local sig = Profile.load_signals()
    check(sig.by_name["eyeClose.L"] and sig.by_name["eyeClose.L"].key == kl,
        "wilds bone signals: the dictionary maps the name to the bone key")
    -- Maya's smiling eyes: lower lid lift x mouth corner up, fading as a blink closes the eye
    Profile.load_all()
    local maya = Profile.compile(Profile.resolve("maya"), {})
    local slot
    for i, c in ipairs(maya and maya.channels or {}) do if c.name == "ウィンク" then slot = i end end
    local key = function(name) return sig.by_name[name].key end
    local ctx = { P = { [key("lowerLidRaise.L")] = 1, [key("mouthCornerUp.L")] = 0.75 }, A = {}, V = {} }
    local wink = slot and maya.channels[slot].fn
    check(wink and near(wink(ctx), 0.75), "maya: smiling eyes follow lower lid x mouth corner")
    ctx.P[key("eyeClose.L")] = 0.5
    check(wink and near(wink(ctx), 0.375), "maya: smiling eyes fade as the eye closes")
end

print("GAMES FAILS:", gf)
