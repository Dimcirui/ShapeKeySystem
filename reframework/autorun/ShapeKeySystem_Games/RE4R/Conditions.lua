-- ShapeKeySystem: sample RE4R player state for conditional expressions.
--
-- Player and health objects are resolved for each sample. Core derives HP change events;
-- a changed player identity clears the HP baseline without retaining engine references.
local C = { defs = {} }
local last_context

local function call(object, method)
    if not object then return nil end
    local ok, value = pcall(object.call, object, method)
    if ok then return value end
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local BOOLS = {
    { "is_battle", "get_IsBattle", "战斗状态" },
    { "is_aiming", "get_IsAiming", "瞄准中" },
    { "is_wheel", "get_IsWheel", "站定瞄准或举刀" },
    { "is_holding", "get_IsHolding", "持械中" },
    { "is_combating", "get_IsCombating", "近战攻击中" },
    { "is_shooting", "get_IsShooting", "射击中" },
    { "is_pull_trigger", "get_IsPullTrigger", "扣动扳机" },
    { "is_shoot_dry_fire", "get_IsShootDryFire", "空枪击发" },
    { "is_pump_action", "get_IsPumpAction", "拉动枪机" },
    { "is_throwing", "get_IsThrowing", "投掷中" },
    { "is_reloading", "get_IsReloading", "换弹中" },
    { "is_weapon_changing", "get_IsWeaponChanging", "切换武器中" },
    { "is_parry", "get_IsParry", "招架中" },
    { "is_big_parry", "get_IsBigParry", "完美招架" },
    { "is_fatal_kick", "get_IsFatalKick", "踢击体术" },
    { "is_fatal_round_kick", "get_IsFatalRoundKick", "回旋踢体术" },
    { "is_fatal_kill", "get_IsFatalKill", "处决击杀" },
    { "is_dodging", "get_IsDodging", "闪避中" },
    { "is_crouch", "get_IsCrouch", "蹲伏中" },
    { "is_walk", "get_IsWalk", "行走中" },
    { "is_run", "get_IsRun", "奔跑中" },
    { "is_quick_turn", "get_IsQuickTurn", "快速转身" },
    { "is_jumping", "get_IsJumping", "跳跃中" },
    { "is_falling", "get_IsFalling", "下落中" },
    { "is_landing", "get_IsLanding", "落地中" },
    { "is_ladder", "get_IsLadder", "梯子动作中" },
    { "is_hook_shot", "get_IsHookShot", "钩索动作中" },
    { "is_boat", "get_IsBoat", "乘船中" },
    { "is_damaging", "get_IsDamaging", "受伤动作中" },
    { "is_upper_body_damage", "get_IsUpperBodyDamage", "上半身受伤动作" },
    { "is_burning", "get_IsInBurnDamage", "燃烧伤害中" },
    { "is_invincible", "get_IsInvincible", "无敌状态" },
}

for _, row in ipairs(BOOLS) do
    C.defs[#C.defs + 1] = { id = row[1], kind = "bool", label = row[3] }
end
local function def(value) C.defs[#C.defs + 1] = value end
def({ id = "hp_pct", kind = "number", label = "血量 %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "掉血事件（配合保持时间）" })
def({ id = "hp_increased", kind = "bool", label = "回血事件（配合保持时间）" })
def({ id = "has_armor_mesh", kind = "bool", label = "护甲网格存在" })
def({ id = "dead", kind = "bool", label = "死亡" })
local vital = { id = "hp_vital", kind = "enum", label = "游戏生命状态", options = {
    { value = 0, label = "正常（Fine）" }, { value = 2, label = "危险（Danger）" }, { value = 4, label = "死亡（Dead）" },
} }
def(vital)
-- 粗分类取自 PlayerEquipment 的四个布尔，判定顺序即优先级；值写进配置，新增档位只能往后加。
def({ id = "weapon_kind", kind = "enum", label = "手持武器类型", options = {
    { value = 0, label = "枪械" }, { value = 1, label = "刀" }, { value = 2, label = "投掷物" },
    { value = 3, label = "徒手" }, { value = 4, label = "其他" },
} })
local WEAPON_FLAGS = { "get_IsEquipGun", "get_IsEquipKnife", "get_IsEquipGrenade", "get_IsBareHands" }

function C.init()
    local ok, fields = pcall(function()
        local td = sdk.find_type_definition("chainsaw.character.Vital")
        return td and td:get_fields()
    end)
    if not ok or not fields then return end
    local options, seen = {}, {}
    -- whole labels, so the draw layer finds each one in the translation table
    local labels = { Fine = "正常（Fine）", Caution = "注意（Caution）", Danger = "危险（Danger）",
        Poison = "中毒（Poison）", Dead = "死亡（Dead）" }
    for _, field in ipairs(fields) do
        local valid, value, name = pcall(function()
            if field:is_static() then return field:get_data(nil), field:get_name() end
        end)
        if valid and finite(value) and type(name) == "string" and not seen[value] then
            seen[value] = true
            options[#options + 1] = { value = value, label = labels[name] or name }
        end
    end
    if #options > 0 then
        table.sort(options, function(a, b) return a.value < b.value end)
        vital.options = options
    end
end

function C.reset() last_context = nil end

function C.sample(V)
    local context = call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef()")
    if not context then last_context = nil; return false end
    local ok, address = pcall(context.get_address, context)
    local changed = ok and last_context ~= nil and last_context ~= address
    last_context = ok and address or nil
    for _, row in ipairs(BOOLS) do
        local value = call(context, row[2])
        if type(value) == "boolean" then V[row[1]] = value end
    end
    local hp = call(context, "get_HitPoint")
    local current, maximum = call(hp, "get_CurrentHitPoint"), call(hp, "get_DefaultHitPoint")
    if not changed and finite(current) and current >= 0 and finite(maximum) and maximum > 0 then
        V.hp, V.hp_max = current, maximum
    end
    local status = call(context, "getHitPointVital")
    if finite(status) then V.hp_vital = status end
    if finite(current) then V.dead = current <= 0 end
    local armor = call(call(context, "get_BodyUpdater"), "get_HasArmorMesh")
    if type(armor) == "boolean" then V.has_armor_mesh = armor end
    -- PlayerEquipment 挂在头部对象上，只能经 HeadUpdater 的字段取到。
    local head = call(context, "get_HeadUpdater")
    local fok, equipment = pcall(function() return head and head:get_field("<Equipment>k__BackingField") end)
    if fok and equipment and sdk.is_managed_object(equipment) then
        V.weapon_kind = 4
        for index, method in ipairs(WEAPON_FLAGS) do
            if call(equipment, method) == true then V.weapon_kind = index - 1; break end
        end
    end
    return true
end

return C
