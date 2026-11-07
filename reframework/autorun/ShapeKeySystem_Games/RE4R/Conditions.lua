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

-- 合成条件：同一件事的几个阶段合成一个枚举，与 ArmorVariantManager 共用 id 和取值。
-- 档位按优先级排列，取第一个为真的旧布尔，都不为真为 0；旧布尔全部读不到时为 nil。
-- 取值写进配置，发布后不改；新增档位只能用新的整数。
local GROUPS = {
    { id = "hold_state", label = "持械", none = "无",
        { 1, "is_aiming", "举着移动" }, { 2, "is_wheel", "站定瞄准" }, { 3, "is_holding", "起手或放下" } },
    { id = "shoot_action", label = "射击动作", none = "无",
        { 1, "is_shooting", "开火" }, { 2, "is_shoot_dry_fire", "空枪击发" }, { 3, "is_pump_action", "拉栓" } },
    { id = "melee_action", label = "近战动作", none = "无",
        { 4, "is_fatal_kill", "处决击杀" }, { 3, "is_fatal_round_kick", "处决回旋踢" },
        { 2, "is_fatal_kick", "处决踢" }, { 1, "is_combating", "近战攻击" } },
    { id = "parry", label = "招架", none = "无",
        { 2, "is_big_parry", "完美招架" }, { 1, "is_parry", "招架" } },
    { id = "weapon_op", label = "武器操作", none = "无",
        { 3, "is_throwing", "投掷" }, { 2, "is_weapon_changing", "换武器" }, { 1, "is_reloading", "换弹" } },
    { id = "locomotion", label = "移动", none = "静止",
        { 3, "is_quick_turn", "快速转身" }, { 2, "is_run", "跑动" }, { 1, "is_walk", "行走" } },
    { id = "airborne", label = "空中", none = "地面",
        { 3, "is_landing", "落地" }, { 2, "is_falling", "下落" }, { 1, "is_jumping", "起跳" } },
    { id = "traversal", label = "特殊移动", none = "无",
        { 1, "is_ladder", "爬梯" }, { 2, "is_hook_shot", "钩索" }, { 3, "is_boat", "乘船" } },
    { id = "hit", label = "受击", none = "无",
        { 2, "is_upper_body_damage", "上半身受击" }, { 1, "is_damaging", "受击" } },
    { id = "hp_change", label = "血量变化", none = "无",
        { 1, "hp_decreased", "减少" }, { 2, "hp_increased", "增加" } },
}
C.GROUPS = GROUPS

-- 旧布尔仍然采样并能求值（旧规则、驱动公式里的 cond(id)），只是不在条件列表里列出。
local merged = {}
for _, g in ipairs(GROUPS) do
    for _, tier in ipairs(g) do merged[tier[2]] = true end
end
local defs_by_id = {}
local function def(value)
    if merged[value.id] then value.hidden = true end
    C.defs[#C.defs + 1] = value
    defs_by_id[value.id] = value
end
for _, row in ipairs(BOOLS) do def({ id = row[1], kind = "bool", label = row[3] }) end
def({ id = "hp_pct", kind = "number", label = "血量 %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "掉血事件（配合保持时间）" })
def({ id = "hp_increased", kind = "bool", label = "回血事件（配合保持时间）" })
def({ id = "has_armor_mesh", kind = "bool", label = "护甲网格存在" })
def({ id = "dead", kind = "bool", label = "死亡" })
local vital = { id = "hp_vital", kind = "enum", label = "游戏生命状态", options = {
    { value = 0, label = "正常（Fine）" }, { value = 2, label = "危险（Danger）" }, { value = 4, label = "死亡（Dead）" },
} }
def(vital)
for _, g in ipairs(GROUPS) do
    local options = { { value = 0, label = g.none } }
    for _, tier in ipairs(g) do options[#options + 1] = { value = tier[1], label = tier[3] } end
    table.sort(options, function(a, b) return a.value < b.value end)
    def({ id = g.id, kind = "enum", label = g.label, options = options })
end
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

-- 采样和 Core 的血量推导之后调用：由旧布尔算出合成条件。
function C.derive(V)
    for _, g in ipairs(GROUPS) do
        local value, read = 0, false
        for _, tier in ipairs(g) do
            local b = V[tier[2]]
            if b ~= nil then read = true end
            if b == true then value = tier[1]; break end
        end
        V[g.id] = read and value or nil
    end
end

-- 载入时把旧条件改写成语义完全等价的合成条件；其余旧 id 原样保留。
-- 每组优先级最高的一档：该布尔为真 ⇔ 合成值等于这一档。
local MIGRATE = { is_holding = { "hold_state", 0, true } }
for _, g in ipairs(GROUPS) do MIGRATE[g[1][2]] = { g.id, g[1][1], false } end
function C.migrate(cond)
    local m = type(cond) == "table" and MIGRATE[cond.type]
    if not m then return false end
    local want = cond.value ~= false
    -- is_holding 为真 ⇔ hold_state ≠ 无；其余为真 ⇔ 合成值 = 最高档
    if m[3] then want = not want end
    cond.type, cond.op, cond.value, cond.band = m[1], want and "==" or "~=", m[2], nil
    return true
end

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
    local body = call(context, "get_BodyUpdater")
    local armor = call(body, "get_HasArmorMesh")
    if type(armor) == "boolean" then V.has_armor_mesh = armor end
    -- 普通火焰攻击只挂燃烧特效、不置 IsInBurnDamage；特效编号熄灭后回到 -1。
    local bok, burn = pcall(function() return body and body:get_field("_CurrentBurnEffectID") end)
    if bok and type(burn) == "number" and burn >= 0 then V.is_burning = true end
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
