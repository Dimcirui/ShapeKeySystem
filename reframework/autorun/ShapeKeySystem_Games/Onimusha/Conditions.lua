-- ShapeKeySystem: sample Onimusha player state for conditional expressions.
--
-- The controlling player is resolved for each sample: PlayerManager -> cPlayerManageInfo ->
-- cGameContextHolder, whose Chara part holds the health manager and whose Player part the oni
-- gauges. Core derives HP change events; a changed player identity clears the HP baseline without
-- retaining engine references.
-- Action states are the bits of PlayerCharacter.getActionState (CharacterDef.ACTION_STATE_BIT);
-- their values are read from the enum on the first sample that finds it. The speaker of the
-- current voice line is the context holder of SpeakManager's single work.
local C = { defs = {} }
local last_context
local bits             -- ACTION_STATE_BIT name -> value, once read

local function call(object, method)
    if not object then return nil end
    local ok, value = pcall(object.call, object, method)
    if ok then return value end
end

local function field(object, name)
    if not object then return nil end
    local ok, value = pcall(object.get_field, object, name)
    if ok then return value end
end

local function address(object)
    if not object then return nil end
    local ok, value = pcall(object.get_address, object)
    if ok then return value end
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function pct(value, maximum)
    if finite(value) and finite(maximum) and maximum > 0 then return value / maximum * 100 end
end

-- PlayerManager queries about the controlling player
local BOOLS = {
    { "dead", "isPlayerDead", "死亡" },
    { "dying", "isPlayerDying", "濒死" },
    { "use_item", "isUseItemAction", "使用道具中" },
    { "wall_run", "isWallRunAction", "跑墙中" },
    { "revive", "isReviveAction", "复活动作中" },
    { "dead_heat", "isDeadHeatAction", "死斗中" },
    { "oni_gate_absorb", "isOniGateAbsorption", "吸收鬼门中" },
}

-- action state bits; the enum name stays in the label, the meaning of some is a guess
local STATES = {
    { "act_idle", "IDLE", "待机（IDLE）" },
    { "act_stand", "STAND", "站立（STAND）" },
    { "act_moving", "MOVING", "移动中（MOVING）" },
    { "act_crouch", "CROUCH", "蹲伏（CROUCH）" },
    { "act_air", "AIR", "空中（AIR）" },
    { "act_wall", "WALL", "贴墙（WALL）" },
    { "act_water", "WATER", "水中（WATER）" },
    { "act_diving", "DIVING", "潜水（DIVING）" },
    { "act_attack", "ATTACK", "攻击中（ATTACK）" },
    { "act_smash", "SMASH", "重击（SMASH）" },
    { "act_shell_attack", "SHELL_ATTACK", "射击攻击（SHELL_ATTACK）" },
    { "act_feint", "FEINT", "佯攻（FEINT）" },
    { "act_grapple", "GRAPPLE", "投技（GRAPPLE）" },
    { "act_evade", "EVADE", "闪避中（EVADE）" },
    { "act_guard_wait", "GUARD_WAIT", "架刀防御（GUARD_WAIT）" },
    { "act_block", "BLOCK", "格挡（BLOCK）" },
    { "act_guard_hit", "GUARD_HIT", "防御受击（GUARD_HIT）" },
    { "act_guard_break", "GUARD_BREAK", "被破防（GUARD_BREAK）" },
    { "act_parry", "PARRY", "弹刀（PARRY）" },
    { "act_parried", "PARRIED", "被弹开（PARRIED）" },
    { "act_atemi", "ATEMI", "当身（ATEMI）" },
    { "act_blocked", "BLOCKED", "攻击被挡（BLOCKED）" },
    { "act_damage", "DAMAGE", "受击中（DAMAGE）" },
    { "act_down", "DOWN", "倒地（DOWN）" },
    { "act_em_grab", "EM_GRAB", "被敌人抓住（EM_GRAB）" },
    { "act_em_after_grapple", "EM_ATTACK_AFTER_GRAPPLE", "被抓后受追击（EM_ATTACK_AFTER_GRAPPLE）" },
    { "act_em_unavoidable", "EM_UNAVOIDABLE", "受不可防御攻击（EM_UNAVOIDABLE）" },
}

local function def(value) C.defs[#C.defs + 1] = value end
def({ id = "hp_pct", kind = "number", label = "血量 %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "掉血事件（配合保持时间）" })
def({ id = "hp_increased", kind = "bool", label = "回血事件（配合保持时间）" })
for _, row in ipairs(BOOLS) do def({ id = row[1], kind = "bool", label = row[3] }) end
def({ id = "oni_mode", kind = "bool", label = "鬼变身中" })
def({ id = "oni_energy_pct", kind = "number", label = "鬼力 %", min = 0, max = 100 })
def({ id = "oni_change_pct", kind = "number", label = "鬼变身槽 %", min = 0, max = 100 })
def({ id = "oni_ultimate_ready", kind = "bool", label = "奥义槽已满" })
def({ id = "bow_aim", kind = "bool", label = "开弓瞄准中" })
def({ id = "bow_quick_shot", kind = "bool", label = "弓快射中" })
def({ id = "weapon_on", kind = "bool", label = "拔刀中" })
def({ id = "in_battle", kind = "bool", label = "战斗中" })
def({ id = "boss_battle", kind = "bool", label = "Boss 战中" })
def({ id = "lock_on", kind = "bool", label = "锁定目标中" })
def({ id = "player_speaking", kind = "bool", label = "主角说话中" })
def({ id = "anyone_speaking", kind = "bool", label = "有人说话中" })
def({ id = "menu_pause", kind = "bool", label = "菜单暂停中" })
def({ id = "event_start", kind = "bool", label = "事件进行中" })
for _, row in ipairs(STATES) do def({ id = row[1], kind = "bool", label = row[3] }) end

local function read_bits()
    local td = sdk.find_type_definition("app.CharacterDef.ACTION_STATE_BIT")
    if not td then return nil end
    local found, any = {}, false
    for _, row in ipairs(STATES) do
        local ok, value = pcall(function() return td:get_field(row[2]):get_data(nil) end)
        if ok and math.type(value) == "integer" and value ~= 0 then found[row[2]] = value; any = true end
    end
    return any and found or nil
end

function C.reset() last_context = nil end

function C.sample(V)
    local manager = sdk.get_managed_singleton("app.PlayerManager")
    local info = call(manager, "getControllingPlayer")
    local context = call(info, "get_Context")
    if not context then last_context = nil; return false end
    local here = address(context)
    local changed = here ~= nil and last_context ~= nil and last_context ~= here
    last_context = here
    for _, row in ipairs(BOOLS) do
        local value = call(manager, row[2])
        if type(value) == "boolean" then V[row[1]] = value end
    end
    local ok, target = pcall(manager.call, manager, "getInternalLockOnTarget")
    if ok then V.lock_on = target ~= nil end
    local health = call(call(context, "get_Chara"), "get_HealthManager")
    local current, maximum = call(health, "get_Health"), call(health, "get_MaxHealth")
    if not changed and finite(current) and current >= 0 and finite(maximum) and maximum > 0 then
        V.hp, V.hp_max = current, maximum
    end
    local player = call(context, "get_Player")
    if player then
        local oni = call(player, "get_IsOniModeOn")
        if type(oni) == "boolean" then V.oni_mode = oni end
        V.oni_energy_pct = pct(call(player, "get_OniEnergy"), call(player, "get_OniEnergyMax"))
        V.oni_change_pct = pct(call(player, "get_OniChangeEnergy"), call(player, "get_OniChangeEnergyMax"))
        local ready = call(player, "isOniUltimateAttackEnergyMax")
        if type(ready) == "boolean" then V.oni_ultimate_ready = ready end
    end

    -- the bow is the sub weapon: aiming has no action state bit of its own
    local entity = call(info, "get_CharacterEntity")
    local sub = call(entity, "get_SubWeapon")
    local aim, quick = call(sub, "isSubWeaponActionBowTwoHand"), call(sub, "isSubWeaponActionBowQuickShot")
    if type(aim) == "boolean" then V.bow_aim = aim end
    if type(quick) == "boolean" then V.bow_quick_shot = quick end
    local drawn = call(call(entity, "get_AutoWeaponOnOffSupporter"), "isWeaponOn")
    if type(drawn) == "boolean" then V.weapon_on = drawn end

    local character = call(info, "get_Character")
    local event = call(character, "get_IsEventStart")
    if type(event) == "boolean" then V.event_start = event end
    bits = bits or read_bits()
    local state = call(character, "getActionState")
    if bits and math.type(state) == "integer" then
        for _, row in ipairs(STATES) do
            local bit = bits[row[2]]
            if bit then V[row[1]] = state & bit == bit end
        end
    end

    local enemies = sdk.get_managed_singleton("app.EnemyManager")
    local battle, boss = call(enemies, "isCheckBattleMode"), call(enemies, "isCheckBossBattleMode")
    if type(battle) == "boolean" then V.in_battle = battle end
    if type(boss) == "boolean" then V.boss_battle = boss end

    local speak = sdk.get_managed_singleton("app.SpeakManager")
    local speaking = call(speak, "isWorking")
    if type(speaking) == "boolean" then
        V.anyone_speaking = speaking
        local work = call(field(speak, "_SingleWorkManager"), "get_Work")
        local speaker = speaking and call(work, "get_Finished") == false
            and address(call(call(work, "get_Param"), "get_ContextHolder"))
        V.player_speaking = speaker ~= nil and speaker ~= false and speaker == here
    end

    local pause = call(sdk.get_managed_singleton("app.PauseManager"), "get_IsMenuPause")
    if type(pause) == "boolean" then V.menu_pause = pause end
    return true
end

return C
