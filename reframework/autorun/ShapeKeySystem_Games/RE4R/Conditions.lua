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
    { "is_hold_start", "get_IsHoldStart", "举枪起手" },
    { "is_hold_idle", "get_IsHoldIdle", "举枪站定" },
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
    { "is_box_break", "get_IsBoxBreak", "砸箱子" },
    { "is_knife_hold_without_knife", "get_IsKnifeHoldWithoutKnife", "无刀举刀" },
    { "is_crouch", "get_IsCrouch", "蹲伏中" },
    { "is_walk", "get_IsWalk", "行走中" },
    { "is_run", "get_IsRun", "奔跑中" },
    { "is_run_start", "get_IsRunStart", "起跑" },
    { "is_run_loop", "get_IsRunLoop", "持续奔跑" },
    { "is_run_turn", "get_IsRunTurn", "奔跑转向" },
    { "is_idle", "get_IsIdle", "站立待机" },
    { "is_quick_turn", "get_IsQuickTurn", "快速转身" },
    { "is_jumping", "get_IsJumping", "跳跃中" },
    { "is_falling", "get_IsFalling", "下落中" },
    { "is_landing", "get_IsLanding", "落地中" },
    { "is_ladder", "get_IsLadder", "梯子动作中" },
    { "is_hook_shot", "get_IsHookShot", "钩索动作中" },
    { "is_boat", "get_IsBoat", "乘船中" },
    { "is_talk_acting", "get_IsTalkActing", "对话动作" },
    { "is_wireless_call", "get_IsWirelessCall", "无线电通话" },
    { "is_event_locked", "get_IsEventLocked", "事件锁定" },
    { "is_restriction_all", "get_IsRestrictionAll", "不受控制" },
    { "is_damaging", "get_IsDamaging", "受伤动作中" },
    { "is_upper_body_damage", "get_IsUpperBodyDamage", "上半身受伤动作" },
    { "is_burning", "get_IsInBurnDamage", "燃烧伤害中" },
    { "is_grappled", "get_IsInGrappleDamage", "被束缚" },
    { "is_invincible", "get_IsInvincible", "无敌状态" },
}

-- get_State() 是 chainsaw.PlayerDefine.State 的位集，位值在 C.init 里从枚举取。
-- 第四项为真时也看 get_StateOld()：被抓和挣脱反击期间 Jacked 位只留在 StateOld 里
local STATE_BITS = {
    { "is_slip_through", "SlipThrough", "钻过缝隙" },
    { "is_parent_gimmick", "ParentGimmick", "附着机关" },
    { "is_crouch_switching", "CrouchSwitching", "蹲起切换" },
    { "is_body_draw_off", "BodyDrawOff", "身体隐藏" },
    { "is_jacked", "Jacked", "被抓 / 刚挣脱", true },
}
local state_bit = {}

-- 合成条件：同一件事的几个阶段合成一个枚举，与 ArmorVariantManager 共用 id 和取值。
-- 档位按优先级排列，取第一个为真的旧布尔，都不为真为 0；旧布尔全部读不到时为 nil。
-- 选项 -1（any）表示「不是 0」，即任一阶段，只用于比较，不是采样值。
-- 取值写进配置，发布后不改；新增档位只能用新的整数。
local GROUPS = {
    { id = "hold_state", label = "持械", none = "无", any = "持械中",
        { 1, "is_aiming", "举着移动" }, { 2, "is_wheel", "站定瞄准" }, { 3, "is_holding", "起手或放下" } },
    { id = "shoot_action", label = "射击动作", none = "无", any = "射击中",
        { 1, "is_shooting", "开火" }, { 2, "is_shoot_dry_fire", "空枪击发" }, { 3, "is_pump_action", "拉栓" } },
    { id = "melee_action", label = "近战动作", none = "无", any = "近战中",
        { 4, "is_fatal_kill", "处决击杀" }, { 3, "is_fatal_round_kick", "处决回旋踢" },
        { 2, "is_fatal_kick", "处决踢" }, { 1, "is_combating", "近战攻击" } },
    { id = "parry", label = "招架", none = "无", any = "招架中",
        { 2, "is_big_parry", "完美招架" }, { 1, "is_parry", "招架" } },
    { id = "weapon_op", label = "武器操作", none = "无", any = "操作武器中",
        { 3, "is_throwing", "投掷" }, { 2, "is_weapon_changing", "换武器" }, { 1, "is_reloading", "换弹" } },
    { id = "locomotion", label = "移动", none = "静止", any = "移动中",
        { 3, "is_quick_turn", "快速转身" }, { 2, "is_run", "跑动" }, { 1, "is_walk", "行走" } },
    { id = "airborne", label = "空中", none = "地面", any = "离地",
        { 3, "is_landing", "落地" }, { 2, "is_falling", "下落" }, { 1, "is_jumping", "起跳" } },
    { id = "traversal", label = "特殊移动", none = "无", any = "特殊移动中",
        { 1, "is_ladder", "爬梯" }, { 2, "is_hook_shot", "钩索" }, { 3, "is_boat", "乘船" } },
    { id = "hit", label = "受击", none = "无", any = "受击中",
        { 2, "is_upper_body_damage", "上半身受击" }, { 1, "is_damaging", "受击" } },
    { id = "hp_change", label = "血量变化", none = "无", any = "有变化",
        { 1, "hp_decreased", "减少" }, { 2, "hp_increased", "增加" } },
}
C.GROUPS = GROUPS
local ANY = -1
C.ANY = ANY

-- 旧布尔仍然采样并能求值（旧规则、驱动公式里的 cond(id)），只是不在条件列表里列出。
local merged = {}
for _, g in ipairs(GROUPS) do
    for _, tier in ipairs(g) do merged[tier[2]] = true end
end

-- 条件列表的分类与 ArmorVariantManager 相同，按下面的顺序排；没列出的归「战斗与武器」
local CATEGORIES = { "血量", "战斗与武器", "移动", "受击", "其他" }
local CATEGORY = {
    hp_pct = "血量", hp_vital = "血量", hp_decreased = "血量", hp_increased = "血量", hp_change = "血量", dead = "血量",
    locomotion = "移动", airborne = "移动", traversal = "移动",
    is_crouch = "移动", is_walk = "移动", is_run = "移动", is_quick_turn = "移动", is_jumping = "移动",
    is_falling = "移动", is_landing = "移动", is_ladder = "移动", is_hook_shot = "移动", is_boat = "移动",
    is_slip_through = "移动", is_parent_gimmick = "移动", is_crouch_switching = "移动",
    is_run_start = "移动", is_run_loop = "移动", is_run_turn = "移动", is_idle = "移动",
    hit = "受击", is_damaging = "受击", is_upper_body_damage = "受击", is_burning = "受击", is_grappled = "受击", is_jacked = "受击",
    is_invincible = "受击", is_wounded = "受击", last_hit_part = "受击", last_hit_side = "受击", dead_type = "受击",
    is_talk_acting = "其他", is_wireless_call = "其他", is_event_locked = "其他", is_restriction_all = "其他",
    is_body_draw_off = "其他", chapter = "其他", stage_id = "其他", is_paused = "其他", has_armor_mesh = "其他",
}
local defs_by_id = {}
local function def(value)
    if merged[value.id] then value.hidden = true end
    value.category = CATEGORY[value.id] or "战斗与武器"
    C.defs[#C.defs + 1] = value
    defs_by_id[value.id] = value
end
for _, row in ipairs(BOOLS) do def({ id = row[1], kind = "bool", label = row[3] }) end
for _, row in ipairs(STATE_BITS) do def({ id = row[1], kind = "bool", label = row[3] }) end
-- 捂伤口：BodyUpdater 叠加的手臂动作层，挨打后是 4（也见过 5），一直保持到放下手，与血量无关；
-- 挨打那一两帧会闪回 -1，配合保持时间使用。0 是切武器的一帧，2 是部分武器的单手待机，都不算。
-- 没捂伤口时也读到过 4，信号不可靠：照常求值（已用它的配置不受影响），但不在列表里显示
def({ id = "is_wounded", kind = "bool", label = "捂伤口", hidden = true })
-- 暂停时人物状态冻结；不依赖人物，没有玩家时也读
def({ id = "is_paused", kind = "bool", label = "游戏暂停" })
def({ id = "hp_pct", kind = "number", label = "血量 %", min = 0, max = 100 })
def({ id = "hp_decreased", kind = "bool", label = "掉血事件（配合保持时间）" })
def({ id = "hp_increased", kind = "bool", label = "回血事件（配合保持时间）" })
def({ id = "has_armor_mesh", kind = "bool", label = "有护甲" })
def({ id = "dead", kind = "bool", label = "死亡" })
local vital = { id = "hp_vital", kind = "enum", label = "游戏生命状态", options = {
    { value = 0, label = "正常（Fine）" }, { value = 2, label = "危险（Danger）" }, { value = 4, label = "死亡（Dead）" },
} }
def(vital)
for _, g in ipairs(GROUPS) do
    local options = { { value = ANY, label = g.any }, { value = 0, label = g.none } }
    for _, tier in ipairs(g) do options[#options + 1] = { value = tier[1], label = tier[3] } end
    table.sort(options, function(a, b) return a.value < b.value end)
    def({ id = g.id, kind = "enum", label = g.label, options = options, any_value = ANY, none_value = 0 })
end
-- 粗分类取自 PlayerEquipment 的四个布尔，判定顺序即优先级；值写进配置，新增档位只能往后加。
def({ id = "weapon_kind", kind = "enum", label = "手持武器类型", options = {
    { value = 0, label = "枪械" }, { value = 1, label = "刀" }, { value = 2, label = "投掷物" },
    { value = 3, label = "徒手" }, { value = 4, label = "其他" },
} })
local WEAPON_FLAGS = { "get_IsEquipGun", "get_IsEquipKnife", "get_IsEquipGrenade", "get_IsBareHands" }
-- 下面三个的档位在 C.init 里从引擎枚举取，取值是引擎原始整数，与 ArmorVariantManager 一致。
-- 上次受击的部位和左右会一直保持到下一次受击。
local hit_part = { id = "last_hit_part", kind = "enum", label = "上次受击部位", options = {
    { value = 1, label = "躯干（Body）" },
} }
def(hit_part)
local hit_side = { id = "last_hit_side", kind = "enum", label = "上次受击左右", options = {
    { value = 0, label = "中（Center）" },
} }
def(hit_side)
local chapter = { id = "chapter", kind = "enum", label = "当前章节", options = {} }
def(chapter)
-- 平时是 None，死亡时才是具体的死法
local dead_type = { id = "dead_type", kind = "enum", label = "死法", options = {
    { value = 0, label = "无（None）" },
} }
def(dead_type)
-- chainsaw.StageID 档位太多，做成数值；如 47410 = st47_410，同一区域前两位相同
def({ id = "stage_id", kind = "number", label = "所在区域 ID", min = 0, max = 99999 })

-- 定义完后按分类排序，分类内保持定义顺序；Core 按这个顺序列出条件
do
    local rank, pos = {}, {}
    for i, name in ipairs(CATEGORIES) do rank[name] = i end
    for i, d in ipairs(C.defs) do pos[d] = i end
    table.sort(C.defs, function(a, b)
        local ra, rb = rank[a.category], rank[b.category]
        if ra ~= rb then return ra < rb end
        return pos[a] < pos[b]
    end)
end

-- static fields of an engine enum as { value, name }, sorted by value (nil when unreadable)
local function enum_fields(type_name)
    local ok, fields = pcall(function()
        local td = sdk.find_type_definition(type_name)
        return td and td:get_fields()
    end)
    if not ok or not fields then return nil end
    local list, seen = {}, {}
    for _, field in ipairs(fields) do
        local valid, value, name = pcall(function()
            if field:is_static() then return field:get_data(nil), field:get_name() end
        end)
        if valid and finite(value) and type(name) == "string" and not seen[value] then
            seen[value] = true
            list[#list + 1] = { value = value, name = name }
        end
    end
    table.sort(list, function(a, b) return a.value < b.value end)
    return #list > 0 and list or nil
end

-- labels: whole labels, so the draw layer finds each one in the translation table
local function enum_options(d, type_name, labels, hide)
    local list = enum_fields(type_name)
    if not list then return end
    local options = {}
    for _, e in ipairs(list) do
        if not (hide and hide[e.name]) then
            options[#options + 1] = { value = e.value, label = labels and labels[e.name] or e.name }
        end
    end
    d.options = options
end

function C.init()
    enum_options(vital, "chainsaw.character.Vital", { Fine = "正常（Fine）", Caution = "注意（Caution）",
        Danger = "危险（Danger）", Poison = "中毒（Poison）", Dead = "死亡（Dead）" })
    enum_options(hit_part, "chainsaw.character.BodyPartsCategory", { Head = "头（Head）", Body = "躯干（Body）",
        Arms = "手臂（Arms）", Legs = "腿（Legs）", Armor = "护甲（Armor）", Unique = "特殊部位（Unique）" })
    enum_options(hit_side, "chainsaw.character.BodyPartsSide", { Center = "中（Center）", Left = "左（Left）",
        Right = "右（Right）" })
    enum_options(chapter, "chainsaw.ChapterID", nil, { Invalid = true })
    enum_options(dead_type, "chainsaw.PlayerDefine.DeadType", {
        None = "无（None）", Normal = "普通（Normal）", Beheaded = "斩首（Beheaded）", BodyCut = "腰斩（BodyCut）",
        Breast = "胸口（Breast）", Burn = "烧死（Burn）", Burst = "炸死（Burst）", BurstFall = "炸飞坠落（BurstFall）",
        CarryUpDead = "被举起（CarryUpDead）", CautionDead = "警告死亡（CautionDead）", Crushed = "压死（Crushed）",
        Fall = "坠落（Fall）", Freeze = "冻死（Freeze）", Ladder = "梯子上（Ladder）",
        PartnerDead = "同伴死亡（PartnerDead）", Popup = "弹出（Popup）" })
    for _, e in ipairs(enum_fields("chainsaw.PlayerDefine.State") or {}) do
        state_bit[e.name] = math.tointeger(e.value)
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
-- 每组优先级最高的一档：该布尔为真 ⇔ 合成值等于这一档；is_holding 为真 ⇔ 持械 = 持械中。
local MIGRATE = { is_holding = { "hold_state", ANY } }
for _, g in ipairs(GROUPS) do MIGRATE[g[1][2]] = { g.id, g[1][1] } end
function C.migrate(cond)
    local m = type(cond) == "table" and MIGRATE[cond.type]
    if not m then return false end
    local want = cond.value ~= false
    cond.type, cond.op, cond.value, cond.band = m[1], want and "==" or "~=", m[2], nil
    return true
end

-- a merged condition needs every boolean of its group; the HP change needs the HP reading
local group_of = { hp_decreased = "hp_change", hp_increased = "hp_change" }
for _, g in ipairs(GROUPS) do
    for _, tier in ipairs(g) do group_of[tier[2]] = g.id end
end
local HEALTH = { hp_pct = true, hp_decreased = true, hp_increased = true, hp_change = true, dead = true }

-- wanted (optional): only the conditions someone reads are sampled; the rest stay nil
function C.sample(V, _, wanted)
    local function want(id) return not wanted or wanted[id] or (group_of[id] and wanted[group_of[id]]) end
    if want("is_paused") then
        local paused = call(sdk.get_managed_singleton("share.PauseManager"), "isPaused()")
        if type(paused) == "boolean" then V.is_paused = paused end
    end
    local context = call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef()")
    if not context then last_context = nil; return false end
    local ok, address = pcall(context.get_address, context)
    local changed = ok and last_context ~= nil and last_context ~= address
    last_context = ok and address or nil
    for _, row in ipairs(BOOLS) do
        if want(row[1]) then
            local value = call(context, row[2])
            if type(value) == "boolean" then V[row[1]] = value end
        end
    end
    local health = not wanted
    if wanted then for id in pairs(HEALTH) do if wanted[id] then health = true end end end
    if health then
        local hp = call(context, "get_HitPoint")
        local current, maximum = call(hp, "get_CurrentHitPoint"), call(hp, "get_DefaultHitPoint")
        if not changed and finite(current) and current >= 0 and finite(maximum) and maximum > 0 then
            V.hp, V.hp_max = current, maximum
        end
        if finite(current) then V.dead = current <= 0 end
    end
    if want("hp_vital") then
        local status = call(context, "getHitPointVital")
        if finite(status) then V.hp_vital = status end
    end
    local body = (want("has_armor_mesh") or want("is_burning") or want("is_wounded")) and call(context, "get_BodyUpdater")
    if want("is_wounded") then
        local arm = call(body, "get_NextAddArmIndex")
        if finite(arm) then V.is_wounded = arm == 4 or arm == 5 end
    end
    -- 护甲模型或游戏判定的护甲服装，任一为真就算有护甲
    if want("has_armor_mesh") then
        local armor = call(body, "get_HasArmorMesh")
        if armor ~= true then
            local costume = call(context, "get_IsArmorCostume")
            if type(costume) == "boolean" then armor = costume end
        end
        if type(armor) == "boolean" then V.has_armor_mesh = armor end
    end
    -- 普通火焰攻击只挂燃烧特效、不置 IsInBurnDamage；特效编号熄灭后回到 -1。
    if want("is_burning") then
        local bok, burn = pcall(function() return body and body:get_field("_CurrentBurnEffectID") end)
        if bok and type(burn) == "number" and burn >= 0 then V.is_burning = true end
    end
    local state, old
    for _, row in ipairs(STATE_BITS) do
        local bit = state_bit[row[2]]
        if bit and want(row[1]) then
            if state == nil then
                local raw = call(context, "get_State")
                state = type(raw) == "number" and math.tointeger(raw) or false
            end
            if row[4] and old == nil then
                local raw = call(context, "get_StateOld")
                old = type(raw) == "number" and math.tointeger(raw) or false
            end
            local bits = row[4] and (state or 0) | (old or 0) or state
            if state or (row[4] and old) then V[row[1]] = bits & bit ~= 0 end
        end
    end
    if want("last_hit_part") then
        local part = call(context, "get_LastDamageCategory")
        if finite(part) then V.last_hit_part = part end
    end
    if want("last_hit_side") then
        local side = call(context, "get_LastDamageSide")
        if finite(side) then V.last_hit_side = side end
    end
    if want("stage_id") then
        local stage = call(context, "get_CurrentStageID")
        if finite(stage) then V.stage_id = stage end
    end
    if want("dead_type") then
        local value = call(context, "get_DeadType")
        if finite(value) then V.dead_type = value end
    end
    if want("chapter") then
        local value = call(sdk.get_managed_singleton("chainsaw.CampaignManager"), "get_CurrentChapter")
        if finite(value) then V.chapter = value end
    end
    -- PlayerEquipment 挂在头部对象上，只能经 HeadUpdater 的字段取到。
    local head = want("weapon_kind") and call(context, "get_HeadUpdater")
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
