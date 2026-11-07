-- RE4R merged conditions: derivation from the old booleans, migration of old rules, hidden defs.
local Cnd = require("ShapeKeySystem_Core.Conditions")
local RC = require("ShapeKeySystem_Games.RE4R.Conditions")
local CondExpr = require("ShapeKeySystem_Core.CondExpr")
local fails, asserts = 0, 0
local function check(ok, what)
    asserts = asserts + 1
    if not ok then fails = fails + 1; print("FAIL [re4r-cond] " .. what) end
end

Cnd.install(RC)
local V = Cnd.V
local function clear() for k in pairs(V) do V[k] = nil end end

-- every group: all combinations of its booleans; first true tier wins, none true is 0
for _, g in ipairs(RC.GROUPS) do
    local n = #g
    for mask = 0, (1 << n) - 1 do
        clear()
        local want = 0
        for i, tier in ipairs(g) do
            local on = (mask >> (i - 1)) & 1 == 1
            V[tier[2]] = on
            if on and want == 0 then want = tier[1] end
        end
        RC.derive(V)
        check(V[g.id] == want, g.id .. " mask " .. mask .. " -> " .. tostring(V[g.id]) .. ", want " .. want)
    end
    clear(); RC.derive(V)
    check(V[g.id] == nil, g.id .. ": nothing read stays nil")
end

-- migration: the old and the rewritten condition agree on every flag combination of the group
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
local migrated = 0
for _, g in ipairs(RC.GROUPS) do
    local n = #g
    for _, tier in ipairs(g) do
        for _, value in ipairs({ true, false }) do
            local old = { type = tier[2], value = value }
            local new = copy(old)
            if RC.migrate(new) then
                migrated = migrated + 1
                check(new.type == g.id, tier[2] .. " migrates into " .. g.id)
                for mask = 0, (1 << n) - 1 do
                    clear()
                    for i, t in ipairs(g) do V[t[2]] = (mask >> (i - 1)) & 1 == 1 end
                    -- is_holding covers aiming and wheeling: a mask with them on and it off cannot happen
                    local possible = not (g.id == "hold_state" and V.is_holding == false
                        and (V.is_aiming or V.is_wheel))
                    -- the HP change flags come from one sample and never hold together
                    if g.id == "hp_change" and V.hp_decreased and V.hp_increased then possible = false end
                    if possible then
                        RC.derive(V)
                        check(Cnd.eval_condition(old) == Cnd.eval_condition(new),
                            tier[2] .. "=" .. tostring(value) .. " mask " .. mask .. " agrees after migration")
                    end
                end
            else
                check(new.type == tier[2], tier[2] .. " is left as it is")
            end
        end
    end
end
-- top tier of 10 groups plus is_holding, true and false each
check(migrated == 22, "22 old conditions migrate (" .. migrated .. ")")
check(not RC.migrate({ type = "is_pull_trigger", value = true }), "is_pull_trigger stays independent")

-- a loaded set is migrated in memory; a migrated condition is not migrated again
local d = CondExpr.normalize({ states = { { clip = "a", rules = { { conditions = {
    { type = "is_aiming", value = true }, { type = "is_holding", value = false }, { type = "is_run", value = true } } } } } } })
local c = d.states[1].rules[1].conditions
check(c[1].type == "hold_state" and c[1].op == "==" and c[1].value == 1, "is_aiming=true -> hold_state == 1")
check(c[2].type == "hold_state" and c[2].op == "~=" and c[2].value == RC.ANY, "is_holding=false -> hold_state ~= any stage")
check(c[3].type == "is_run" and c[3].value == true, "a lower tier keeps its old id")
CondExpr.normalize(d)
check(c[1].type == "hold_state" and c[1].value == 1 and c[2].value == RC.ANY, "normalizing again changes nothing")

-- "any stage": every value but none; an unread value matches neither way
for _, case in ipairs({ { 2, true }, { 3, true }, { 0, false } }) do
    clear(); V.hold_state = case[1]
    check(Cnd.eval_condition({ type = "hold_state", op = "==", value = RC.ANY }) == case[2]
        and Cnd.eval_condition({ type = "hold_state", op = "~=", value = RC.ANY }) == not case[2],
        "hold_state " .. case[1] .. (case[2] and " is" or " is not") .. " any stage")
end
clear()
check(not Cnd.eval_condition({ type = "hold_state", op = "==", value = RC.ANY })
    and not Cnd.eval_condition({ type = "hold_state", op = "~=", value = RC.ANY }), "an unread merged condition matches neither way")
local any_first = true
for _, def in ipairs(RC.defs) do
    if def.any_value and not (def.options[1].value == RC.ANY and def.options[2].value == 0) then any_first = false end
end
check(any_first, "every merged condition lists its any-stage option first, then none")

-- the old booleans stay defined (old rules, cond() in driver formulas) but are not listed
local hidden, shown = {}, {}
for _, def in ipairs(RC.defs) do if def.hidden then hidden[def.id] = true else shown[def.id] = true end end
check(hidden.is_aiming and hidden.is_holding and hidden.hp_decreased and Cnd.defs.is_aiming ~= nil,
    "merged booleans are hidden but still defined")
check(shown.hold_state and shown.hp_change and shown.is_pull_trigger and shown.is_burning and shown.is_grappled and shown.weapon_kind
    and shown.is_talk_acting and shown.is_slip_through and shown.last_hit_part and shown.chapter and shown.stage_id
    and shown.is_run_loop and shown.is_paused and shown.dead_type and not shown.is_wounded,
    "merged and independent conditions are listed; is_wounded is hidden")
clear()

-- categories as in ArmorVariantManager: every def has one, listed in category order
do
    local rank = { ["血量"] = 1, ["战斗与武器"] = 2, ["移动"] = 3, ["受击"] = 4, ["其他"] = 5 }
    local sorted, all_known, cat = true, true, {}
    for i, def in ipairs(RC.defs) do
        cat[def.id] = def.category
        if not rank[def.category] then all_known = false end
        local prev = RC.defs[i - 1]
        if prev and rank[prev.category] and rank[def.category] and rank[prev.category] > rank[def.category] then sorted = false end
    end
    check(all_known and sorted, "every condition has a known category, listed in category order")
    check(RC.defs[1].category == "血量" and cat.is_battle == "战斗与武器" and cat.locomotion == "移动"
        and cat.is_grappled == "受击" and cat.is_wounded == "受击" and cat.is_paused == "其他" and cat.hp_change == "血量",
        "categories follow ArmorVariantManager")
end

-- sampling only the conditions someone reads (the panel closed)
do
    local saved = sdk.get_managed_singleton
    local calls = {}
    local function obj(values)
        return { get_address = function() return 0x10 end, get_field = function() return nil end,
            call = function(_, name) calls[name] = (calls[name] or 0) + 1; return values[name] end }
    end
    local hp = obj({ get_CurrentHitPoint = 800, get_DefaultHitPoint = 1000 })
    local arm_index = 4
    local ctx = obj({ get_IsAiming = false, get_IsWheel = true, get_IsHolding = true, get_IsBattle = true, get_HitPoint = hp,
        get_IsInGrappleDamage = true, get_IsTalkActing = true, get_State = 0x24, get_StateOld = 0x100, get_LastDamageCategory = 0,
        get_LastDamageSide = 2, get_CurrentStageID = 47410, get_IsArmorCostume = true,
        get_IsRunLoop = true, get_DeadType = 3, get_BodyUpdater = { get_field = function(_, name)
            if name == "_CurrentBurnEffectID" then return -1 end
        end, call = function(_, name) if name == "get_NextAddArmIndex" then return arm_index end end } })
    local campaign = obj({ get_CurrentChapter = 22300 })
    local pause, no_player = obj({ ["isPaused()"] = true }), false
    -- engine enums as static fields: PlayerDefine.State bits, BodyPartsCategory, ChapterID
    local function enum(t)
        local fields = {}
        for name, value in pairs(t) do
            fields[#fields + 1] = { is_static = function() return true end, get_data = function() return value end,
                get_name = function() return name end }
        end
        return { get_fields = function() return fields end }
    end
    local enums = {
        ["chainsaw.PlayerDefine.State"] = enum({ SlipThrough = 0x4, ParentGimmick = 0x8, BodyDrawOff = 0x20, Jacked = 0x100 }),
        ["chainsaw.character.BodyPartsCategory"] = enum({ Head = 0, Body = 1, Arms = 2 }),
        ["chainsaw.ChapterID"] = enum({ Invalid = -1, Chapter1 = 22300 }),
        ["chainsaw.PlayerDefine.DeadType"] = enum({ None = 0, Normal = 1, Beheaded = 2, BodyCut = 3 }),
    }
    local saved_td = sdk.find_type_definition
    sdk.find_type_definition = function(name) return enums[name] or saved_td(name) end
    RC.init()
    sdk.find_type_definition = saved_td
    local part_def, chapter_def
    for _, def in ipairs(RC.defs) do
        if def.id == "last_hit_part" then part_def = def elseif def.id == "chapter" then chapter_def = def end
    end
    check(#part_def.options == 3 and part_def.options[1].label == "头（Head）" and part_def.options[3].label == "手臂（Arms）",
        "last_hit_part options come from BodyPartsCategory, labelled")
    check(#chapter_def.options == 1 and chapter_def.options[1].value == 22300, "chapter options from ChapterID, Invalid hidden")
    sdk.get_managed_singleton = function(name)
        if name == "chainsaw.CharacterManager" then return obj({ ["getPlayerContextRef()"] = not no_player and ctx or nil }) end
        if name == "share.PauseManager" then return pause end
        if name == "chainsaw.CampaignManager" then return campaign end
        return saved(name)
    end
    RC.reset()
    clear(); calls = {}
    RC.sample(V, 1, { hold_state = true }); RC.derive(V)
    check(V.hold_state == 2 and calls.get_IsAiming and calls.get_IsHolding and not calls.get_IsBattle and not calls.get_HitPoint,
        "a merged condition reads its group's booleans and nothing else")
    clear(); calls = {}
    RC.sample(V, 2, { hp_change = true })
    check(V.hp == 800 and calls.get_HitPoint and not calls.get_IsAiming, "the HP change reads the HP")
    clear(); calls = {}
    RC.sample(V, 3, nil)
    check(V.is_battle == true and V.hp == 800 and calls.get_IsAiming, "without a list every condition is read")
    clear(); calls = {}
    RC.sample(V, 4, { is_grappled = true })
    check(V.is_grappled == true and calls.get_IsInGrappleDamage and not calls.get_IsAiming,
        "is_grappled reads get_IsInGrappleDamage only")
    clear(); calls = {}
    RC.sample(V, 5, { is_slip_through = true, is_parent_gimmick = true, is_body_draw_off = true, is_crouch_switching = true })
    check(V.is_slip_through == true and V.is_parent_gimmick == false and V.is_body_draw_off == true
        and V.is_crouch_switching == nil and calls.get_State == 1,
        "State bits: one get_State read; a bit the enum lacks stays unread")
    check(not calls.get_StateOld, "StateOld is read only for is_jacked")
    clear(); calls = {}
    RC.sample(V, 5, { is_jacked = true })
    check(V.is_jacked == true and calls.get_StateOld == 1, "is_jacked: the Jacked bit left in StateOld counts")
    clear(); calls = {}
    RC.sample(V, 6, { last_hit_part = true, last_hit_side = true, chapter = true, stage_id = true, is_talk_acting = true })
    check(V.last_hit_part == 0 and V.last_hit_side == 2 and V.chapter == 22300 and V.stage_id == 47410
        and V.is_talk_acting == true and not calls.get_State, "hit part / side, chapter, stage and talk acting are read")
    clear(); calls = {}
    RC.sample(V, 7, { has_armor_mesh = true })
    check(V.has_armor_mesh == true and calls.get_IsArmorCostume, "no armor mesh but an armor costume: has armor")
    clear(); calls = {}
    RC.sample(V, 8, { is_run_loop = true, is_paused = true, dead_type = true })
    check(V.is_run_loop == true and V.is_paused == true and V.dead_type == 3 and not calls.get_IsRun,
        "run loop, paused (PauseManager) and death type are read")
    clear(); calls = {}; no_player = true
    RC.sample(V, 9, { is_paused = true })
    check(V.is_paused == true, "is_paused is read without a player")
    no_player = false
    clear(); RC.sample(V, 10, { is_wounded = true })
    check(V.is_wounded == true, "an added arm layer (4): holding a wound")
    arm_index = -1; clear(); RC.sample(V, 11, { is_wounded = true })
    check(V.is_wounded == false, "no added arm layer (-1): not holding a wound")
    for _, idx in ipairs({ 0, 2 }) do
        arm_index = idx; clear(); RC.sample(V, 12, { is_wounded = true })
        check(V.is_wounded == false, "arm layer " .. idx .. " (weapon switch / one-hand idle) is not a wound")
    end
    arm_index = 5; clear(); RC.sample(V, 13, { is_wounded = true })
    check(V.is_wounded == true, "arm layer 5 is a wound")
    local dead_def
    for _, def in ipairs(RC.defs) do if def.id == "dead_type" then dead_def = def end end
    check(#dead_def.options == 4 and dead_def.options[4].label == "腰斩（BodyCut）", "dead_type options from DeadType, labelled")
    sdk.get_managed_singleton = saved
    RC.reset(); clear()
end

print("RE4R CONDITIONS " .. asserts .. " assertions; FAILS: " .. fails)
