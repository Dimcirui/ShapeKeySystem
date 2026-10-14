-- ShapeKeySystem: MH Wilds condition getters for ShapeKeySystem_Core/Conditions.lua.
-- Hunter state comes from getMasterPlayer():get_Character() (app.HunterCharacter); HP from
-- get_HunterHealth().<HealthMgr>k__BackingField. `sample` writes `V.hp` / `V.hp_max`; Core turns
-- them into hp_pct, hp_decreased and hp_increased.

local C = {}

C.WEAPONS = { [0] = "大剑", "片手剑", "双刀", "太刀", "大锤", "狩猎笛", "长枪", "铳枪", "斩斧", "盾斧",
              "操虫棍", "弓", "重弩", "轻弩" }

local ctx = { hunter = nil, refresh_at = 0 }

local function call(obj, name)
    if not obj then return nil end
    local ok, v = pcall(obj.call, obj, name)
    if ok then return v end
    return nil
end

local function field(obj, name)
    if not obj then return nil end
    local ok, v = pcall(obj.get_field, obj, name)
    if ok then return v end
    return nil
end

local function num(v)
    if type(v) == "number" then return v end
    if v ~= nil then
        local ok, n = pcall(function() return v:call("get_Value") end)
        if ok and type(n) == "number" then return n end
    end
    return nil
end

local function bool(v) if type(v) == "boolean" then return v end return nil end

-- ---------------------------------------------------------------- definitions
-- bool getters on app.HunterCharacter, one row each
local HUNTER_BOOLS = {
    { "combat",        "get_IsCombat",          "战斗中" },
    { "combat_boss",   "get_IsCombatBoss",      "大型怪物战斗中" },
    { "combat_angry",  "get_IsCombatAngryBoss", "怪物愤怒中" },
    { "half_combat",   "get_IsHalfCombat",      "半战斗（警戒）" },
    { "riding",        "get_IsPorterRiding",    "骑乘鸟车" },
    { "climbing",      "get_IsClimbWall",       "攀爬中" },
    { "in_tent",       "get_IsInAllTent",       "在帐篷里" },
    { "base_camp",     "get_IsInBaseCamp",      "在营地" },
    { "life_area",     "get_IsInLifeArea",      "在生活区域" },
    { "hot_area",      "get_IsInHotArea",       "炎热区域" },
    { "cold_area",     "get_IsInColdArea",      "寒冷区域" },
    { "enemy_wave",    "get_IsInEnemyWave",     "怪物群袭中" },
}

local defs = {}
C.defs = defs
local function def(d) defs[#defs + 1] = d end

def({ id = "weapon_on", kind = "bool", label = "拔刀" })
def({ id = "enemy_aware", kind = "bool", label = "被怪物察觉" })
for _, b in ipairs(HUNTER_BOOLS) do def({ id = b[1], kind = "bool", label = b[3] }) end
def({ id = "dead", kind = "bool", label = "倒地（力尽）" })
def({ id = "hp_pct", kind = "number", label = "血量 %", min = 0, max = 100 })
def({ id = "red_hp_pct", kind = "number", label = "红血 %", min = 0, max = 100 })
def({ id = "stamina_pct", kind = "number", label = "耐力 %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "受伤（掉血的那一帧，配合保持时间）" })
def({ id = "hp_increased", kind = "bool", label = "回血（回血的那一帧，配合保持时间）" })
local weapon_options = {}
for i = 0, #C.WEAPONS do weapon_options[#weapon_options + 1] = { value = i, label = C.WEAPONS[i] } end
def({ id = "weapon_type", kind = "enum", label = "武器类型", options = weapon_options })
def({ id = "weapon_form", kind = "enum", label = "武器形态", options = {
    { value = "normal", label = "普通" },
    { value = "db_kijin", label = "双刀 · 鬼人化" }, { value = "db_enhanced", label = "双刀 · 鬼人强化" },
    { value = "sa_axe", label = "斩斧 · 斧" }, { value = "sa_axe_enhanced", label = "斩斧 · 斧强化" },
    { value = "sa_sword", label = "斩斧 · 剑" }, { value = "sa_sword_awakened", label = "斩斧 · 剑觉醒" },
    { value = "cb_sword", label = "盾斧 · 剑" }, { value = "cb_axe", label = "盾斧 · 斧" },
    { value = "cb_shield", label = "盾斧 · 盾强化" }, { value = "cb_triple", label = "盾斧 · 三重强化" },
    { value = "ig_red", label = "操虫棍 · 红灯" }, { value = "ig_white", label = "操虫棍 · 白灯" },
    { value = "ig_orange", label = "操虫棍 · 橙灯" }, { value = "ig_triple", label = "操虫棍 · 三灯" },
} })
def({ id = "spirit_level", kind = "number", label = "太刀气刃等级", min = 0, max = 4 })
def({ id = "charge_level", kind = "number", label = "蓄力等级", min = 0, max = 4 })

-- ---------------------------------------------------------------- sampling
local function weapon_form(wt, wh)
    if not wh then return "normal" end
    if wt == 2 then
        if call(wh, "get_IsKijinEnhancement") then return "db_enhanced" end
        if call(wh, "get_IsKijinOn") then return "db_kijin" end
    elseif wt == 8 then
        if call(wh, "get_Mode") == 0 then
            return call(wh, "get_IsAxeEnhanced") and "sa_axe_enhanced" or "sa_axe"
        end
        return call(wh, "get_IsSwordAwaken") and "sa_sword_awakened" or "sa_sword"
    elseif wt == 9 then
        local s, a, w = call(wh, "get_IsShieldEnhanced"), call(wh, "get_IsAxeEnhanced"), call(wh, "get_IsSwordEnhanced")
        if s and a and w then return "cb_triple" end
        if s then return "cb_shield" end
        return (call(wh, "get_Mode") == 0) and "cb_sword" or "cb_axe"
    elseif wt == 10 then
        if call(wh, "get_IsTrippleUp") then return "ig_triple" end
        if call(wh, "get_IsRed") then return "ig_red" end
        if call(wh, "get_IsOrange") then return "ig_orange" end
        if call(wh, "get_IsWhite") then return "ig_white" end
    end
    return "normal"
end

-- forget the hunter (scene change, equipment rebuild): re-fetched on the next sample
function C.reset() ctx.hunter = nil end

-- One read of every condition into the cleared V; false when there is no hunter. The hunter is
-- re-fetched every 60 frames.
function C.sample(V, frame)
    if not ctx.hunter or frame >= ctx.refresh_at then
        ctx.hunter = nil
        pcall(function()
            ctx.hunter = sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Character")
        end)
        ctx.refresh_at = frame + 60
    end
    local h = ctx.hunter
    if not h then return false end
    for _, b in ipairs(HUNTER_BOOLS) do V[b[1]] = bool(call(h, b[2])) end
    local won = bool(field(h, "_IsWeaponOn"))
    if won == nil then won = bool(call(h, "get_IsWeaponOn")) end
    V.weapon_on = won
    local feel = call(h, "get_EnemyFeelRateType")
    V.enemy_aware = (type(feel) == "number") and feel ~= 0 or nil
    -- health
    local hh = call(h, "get_HunterHealth")
    local mgr = field(hh, "<HealthMgr>k__BackingField")
    local hp, maxhp = num(call(mgr, "get_Health")), num(call(mgr, "get_MaxHealth"))
    V.dead = bool(call(hh, "get_IsDead"))
    V.hp, V.hp_max = hp, maxhp
    if hp and maxhp and maxhp > 0 then
        local red = num(call(hh, "get_RedHealth"))
        V.red_hp_pct = red and (red / maxhp * 100) or nil
    end
    local st = call(h, "get_HunterStamina")
    local sv, sm = num(call(st, "get_Stamina")), num(call(st, "get_MaxStamina"))
    V.stamina_pct = (sv and sm and sm > 0) and (sv / sm * 100) or nil
    -- weapon
    local wt = call(h, "get_WeaponType")
    if type(wt) == "number" then
        V.weapon_type = wt
        local wh = call(h, "get_WeaponHandling")
        V.weapon_form = weapon_form(wt, wh)
        if wt == 3 then V.spirit_level = num(call(wh, "get_AuraLevel")) end
        if wt == 0 then V.charge_level = num(call(wh, "get_ChargeLevel"))
        elseif wt == 4 or wt == 11 then V.charge_level = num(call(wh, "get_ChargeLv")) end
    end
    return true
end

return C
