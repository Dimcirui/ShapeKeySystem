-- ShapeKeySystem: game-state conditions for the conditional expression layer (CondExpr.lua).
--
-- Design taken from the user's RE4 MOD Variant Manager (Conditions/Registry.lua):
--   def = { id (stored in configs, never rename), kind = "bool" | "number" | "enum", label, label_en,
--           get(V) -> value | nil, options = {{value, label, label_en}} for enums }
--   label is Chinese (the default UI language), label_en English; I18n.field picks by language.
--   nil means "cannot read" and counts as NOT satisfied (never as false).
--   cond = { type, op, value, band }   rule = { conditions, logic = "AND" | "OR", hold }
--   An empty rule never matches; an unknown condition id evaluates false (retired ids degrade).
-- Values are sampled once per update (C.sample) into V; get() only reads V, so evaluating a rule
-- many times per frame (rules, UI) costs nothing and stateful conditions stay frame-consistent.
--
-- MH Wilds paths verified live 2026-10-10 (REE MCP): app.PlayerManager:getMasterPlayer():
-- get_Character() = app.HunterCharacter; HP: get_HunterHealth() -> <HealthMgr>k__BackingField
-- get_Health/get_MaxHealth; stamina: get_HunterStamina() get_Stamina/get_MaxStamina; weapon:
-- get_WeaponType(), get_WeaponHandling() (cHunterWpNNHandling). Per-weapon getters from
-- ArmorVariantManager's Conditions/ (MIT); bools from the 2026-05 visibility controller probes.

local I18n = require("ShapeKeySystem_Core.I18n")

local C = {}

C.WEAPONS = { [0] = "大剑", "片手剑", "双刀", "太刀", "大锤", "狩猎笛", "长枪", "铳枪", "斩斧", "盾斧",
              "操虫棍", "弓", "重弩", "轻弩" }
C.WEAPONS_EN = { [0] = "Great Sword", "Sword & Shield", "Dual Blades", "Long Sword", "Hammer", "Hunting Horn",
                 "Lance", "Gunlance", "Switch Axe", "Charge Blade", "Insect Glaive", "Bow", "Heavy Bowgun",
                 "Light Bowgun" }

local V = {}            -- sampled values of this update (id -> value)
C.V = V
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
local defs, order = {}, {}
C.defs, C.order = defs, order

local function def(d)
    if defs[d.id] then return end
    d.get = d.get or function() return V[d.id] end
    defs[d.id] = d
    order[#order + 1] = d
end

-- bool getters on app.HunterCharacter, one row each (RE4 PlayerBools style)
local HUNTER_BOOLS = {
    { "combat",        "get_IsCombat",          "战斗中",         "In combat" },
    { "combat_boss",   "get_IsCombatBoss",      "大型怪物战斗中", "Fighting a large monster" },
    { "combat_angry",  "get_IsCombatAngryBoss", "怪物愤怒中",     "Monster enraged" },
    { "half_combat",   "get_IsHalfCombat",      "半战斗（警戒）", "Half combat (alert)" },
    { "riding",        "get_IsPorterRiding",    "骑乘鸟车",       "Riding the Seikret" },
    { "climbing",      "get_IsClimbWall",       "攀爬中",         "Climbing" },
    { "in_tent",       "get_IsInAllTent",       "在帐篷里",       "In a tent" },
    { "base_camp",     "get_IsInBaseCamp",      "在营地",         "At a base camp" },
    { "life_area",     "get_IsInLifeArea",      "在生活区域",     "In a living area" },
    { "hot_area",      "get_IsInHotArea",       "炎热区域",       "Hot area" },
    { "cold_area",     "get_IsInColdArea",      "寒冷区域",       "Cold area" },
    { "enemy_wave",    "get_IsInEnemyWave",     "怪物群袭中",     "In a monster swarm" },
}

def({ id = "weapon_on", kind = "bool", label = "拔刀", label_en = "Weapon drawn" })
def({ id = "enemy_aware", kind = "bool", label = "被怪物察觉", label_en = "Spotted by a monster" })
for _, b in ipairs(HUNTER_BOOLS) do def({ id = b[1], kind = "bool", label = b[3], label_en = b[4] }) end
def({ id = "dead", kind = "bool", label = "倒地（力尽）", label_en = "Fainted (carted)" })
def({ id = "hp_pct", kind = "number", label = "血量 %", label_en = "Health %", min = 0, max = 100 })
def({ id = "red_hp_pct", kind = "number", label = "红血 %", label_en = "Red health %", min = 0, max = 100 })
def({ id = "stamina_pct", kind = "number", label = "耐力 %", label_en = "Stamina %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "受伤（掉血的那一帧，配合保持时间）",
      label_en = "Hit (1 frame, use a hold time)" })
def({ id = "hp_increased", kind = "bool", label = "回血（回血的那一帧，配合保持时间）",
      label_en = "Healed (1 frame, use a hold time)" })
local weapon_options = {}
for i = 0, #C.WEAPONS do weapon_options[#weapon_options + 1] = { value = i, label = C.WEAPONS[i], label_en = C.WEAPONS_EN[i] } end
def({ id = "weapon_type", kind = "enum", label = "武器类型", label_en = "Weapon type", options = weapon_options })
def({ id = "weapon_form", kind = "enum", label = "武器形态", label_en = "Weapon form", options = {
    { value = "normal", label = "普通", label_en = "Normal" },
    { value = "db_kijin", label = "双刀 · 鬼人化", label_en = "Dual Blades · Demon Mode" },
    { value = "db_enhanced", label = "双刀 · 鬼人强化", label_en = "Dual Blades · Archdemon Mode" },
    { value = "sa_axe", label = "斩斧 · 斧", label_en = "Switch Axe · Axe" },
    { value = "sa_axe_enhanced", label = "斩斧 · 斧强化", label_en = "Switch Axe · Power Axe" },
    { value = "sa_sword", label = "斩斧 · 剑", label_en = "Switch Axe · Sword" },
    { value = "sa_sword_awakened", label = "斩斧 · 剑觉醒", label_en = "Switch Axe · Amped Sword" },
    { value = "cb_sword", label = "盾斧 · 剑", label_en = "Charge Blade · Sword" },
    { value = "cb_axe", label = "盾斧 · 斧", label_en = "Charge Blade · Axe" },
    { value = "cb_shield", label = "盾斧 · 盾强化", label_en = "Charge Blade · Shield charged" },
    { value = "cb_triple", label = "盾斧 · 三重强化", label_en = "Charge Blade · Triple charged" },
    { value = "ig_red", label = "操虫棍 · 红灯", label_en = "Insect Glaive · Red extract" },
    { value = "ig_white", label = "操虫棍 · 白灯", label_en = "Insect Glaive · White extract" },
    { value = "ig_orange", label = "操虫棍 · 橙灯", label_en = "Insect Glaive · Orange extract" },
    { value = "ig_triple", label = "操虫棍 · 三灯", label_en = "Insect Glaive · Triple extract" },
} })
def({ id = "spirit_level", kind = "number", label = "太刀气刃等级", label_en = "Long Sword Spirit level", min = 0, max = 4 })
def({ id = "charge_level", kind = "number", label = "蓄力等级", label_en = "Charge level", min = 0, max = 4 })

C.NUM_OPS = { "<=", "<", ">=", ">", "==" }
C.ENUM_OPS = { "==", "~=" }

-- ---------------------------------------------------------------- sampling
local last_hp, last_max = nil, nil

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
function C.reset()
    ctx.hunter = nil
    last_hp, last_max = nil, nil
    for k in pairs(V) do V[k] = nil end
end

-- one read of every condition. frame: the update counter (hunter re-fetched every 60 frames)
function C.sample(frame)
    if not ctx.hunter or frame >= ctx.refresh_at then
        ctx.hunter = nil
        pcall(function()
            ctx.hunter = sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Character")
        end)
        ctx.refresh_at = frame + 60
    end
    local h = ctx.hunter
    for k in pairs(V) do V[k] = nil end
    if not h then last_hp, last_max = nil, nil; return false end
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
    if hp and maxhp and maxhp > 0 then
        V.hp_pct = hp / maxhp * 100
        local red = num(call(hh, "get_RedHealth"))
        V.red_hp_pct = red and (red / maxhp * 100) or nil
        -- hit / heal: absolute change with an unchanged maximum (a max-HP buff is no hit);
        -- an unreadable sample resets the baseline so the next reading is no fake hit
        if last_hp and last_max == maxhp then
            V.hp_decreased = hp < last_hp - 1e-3
            V.hp_increased = hp > last_hp + 1e-3
        else
            V.hp_decreased, V.hp_increased = false, false
        end
        last_hp, last_max = hp, maxhp
    else
        last_hp, last_max = nil, nil
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

-- ---------------------------------------------------------------- evaluation
local cmp = {
    ["<="] = function(a, b) return a <= b end, ["<"] = function(a, b) return a < b end,
    [">="] = function(a, b) return a >= b end, [">"] = function(a, b) return a > b end,
    ["=="] = function(a, b) return math.abs(a - b) < 1e-6 end,
}

-- last result per condition table, for the hysteresis band (weak: dropped with the config)
local was = setmetatable({}, { __mode = "k" })

-- cond = { type, op, value, band }
function C.eval_condition(cond)
    local d = defs[cond.type]
    if not d then return false end
    local cur = d.get()
    if cur == nil then was[cond] = false; return false end
    local r
    if d.kind == "bool" then
        r = cur == (cond.value ~= false)
    elseif d.kind == "enum" then
        local eq = cur == cond.value or (tonumber(cur) ~= nil and tonumber(cur) == tonumber(cond.value))
        r = (cond.op == "~=") and not eq or ((cond.op ~= "~=") and eq)
    else
        local v = tonumber(cond.value)
        if not v or type(cur) ~= "number" then was[cond] = false; return false end
        local op = cond.op or "<="
        local band = tonumber(cond.band) or 0
        -- hysteresis: once true, the threshold moves by `band` so the value must clearly leave
        if band > 0 and was[cond] then
            if op == "<=" or op == "<" then v = v + band elseif op == ">=" or op == ">" then v = v - band end
        end
        local f = cmp[op] or cmp["<="]
        r = f(cur, v)
    end
    was[cond] = r
    return r
end

-- rule = { conditions = {...}, logic = "AND" | "OR" }: empty never matches
function C.eval_rule(rule)
    local list = rule.conditions
    if type(list) ~= "table" or #list == 0 then return false end
    if rule.logic == "OR" then
        local any = false
        for _, c in ipairs(list) do if C.eval_condition(c) then any = true end end
        return any
    end
    local all = true
    for _, c in ipairs(list) do if not C.eval_condition(c) then all = false end end
    return all
end

-- display text of a value, in the interface language
function C.value_text(id, v)
    local d = defs[id]
    if v == nil then return "—" end
    if d and d.kind == "enum" then
        for _, o in ipairs(d.options) do if o.value == v then return I18n.field(o, "label") end end
    end
    if type(v) == "number" then return string.format("%.1f", v) end
    if type(v) == "boolean" then return v and I18n.t("cond.value_yes") or I18n.t("cond.value_no") end
    return tostring(v)
end

return C
