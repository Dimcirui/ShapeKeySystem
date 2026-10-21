-- ShapeKeySystem: MH Rise condition getters for ShapeKeySystem_Core/Conditions.lua.
-- The hunter is snow.player.PlayerManager:findMasterPlayer(), an instance of the weapon's player
-- class (snow.player.GreatSword, snow.player.DualBlades, ...), so weapon state fields sit on it
-- directly. Ids match the Wilds adapter where the meaning is the same; `weapon_type` values follow
-- snow.player.PlayerWeaponType and differ from Wilds.
--
-- Constraints:
-- - Field and method names come from ArmorVariantManager 3.1.4 (Rise) and are unverified in game.
-- - No HP source yet: hp_pct / hp_decreased / hp_increased stay unread (nil = not satisfied).
-- - `scroll` reads the HUD skill-swap icon, which only exists for the local player and only while
--   the HUD is built; any failure leaves it nil.

local C = {}

C.WEAPONS = { [0] = "大剑", "斩斧", "太刀", "轻弩", "重弩", "大锤", "铳枪", "长枪", "片手剑", "双刀",
              "狩猎笛", "盾斧", "操虫棍", "弓" }

local GREAT_SWORD, SWITCH_AXE, LONG_SWORD, HAMMER, DUAL_BLADES, CHARGE_AXE, BOW = 0, 1, 2, 5, 9, 11, 13

local ctx = { player = nil, refresh_at = 0 }

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

-- numbers, and enums boxed as objects (value__)
local function num(v)
    if type(v) == "number" then return v end
    local n = field(v, "value__")
    if type(n) == "number" then return n end
    return nil
end

local function bool(v) if type(v) == "boolean" then return v end return nil end

-- ---------------------------------------------------------------- definitions
local defs = {}
C.defs = defs
local function def(d) defs[#defs + 1] = d end

def({ id = "weapon_on", kind = "bool", label = "拔刀" })
local weapon_options = {}
for i = 0, #C.WEAPONS do weapon_options[#weapon_options + 1] = { value = i, label = C.WEAPONS[i] } end
def({ id = "weapon_type", kind = "enum", label = "武器类型", options = weapon_options })
def({ id = "weapon_form", kind = "enum", label = "武器形态", options = {
    { value = "normal", label = "普通" },
    { value = "db_kijin", label = "双刀 · 鬼人化" }, { value = "db_enhanced", label = "双刀 · 鬼人强化" },
    { value = "sa_axe", label = "斩斧 · 斧" }, { value = "sa_sword", label = "斩斧 · 剑" },
    { value = "sa_awakened", label = "斩斧 · 高出力" },
    { value = "cb_axe", label = "盾斧 · 斧" }, { value = "cb_axe_buff", label = "盾斧 · 红斧" },
    { value = "cb_sword", label = "盾斧 · 剑" }, { value = "cb_shield", label = "盾斧 · 红盾" },
    { value = "cb_sword_buff", label = "盾斧 · 红剑" }, { value = "cb_both", label = "盾斧 · 红盾红剑" },
} })
def({ id = "spirit_level", kind = "number", label = "太刀气刃等级", min = 0, max = 3 })
def({ id = "charge_level", kind = "number", label = "蓄力等级", min = 0, max = 4 })
def({ id = "scroll", kind = "enum", label = "替换技书", options = {
    { value = "red", label = "红书" }, { value = "blue", label = "蓝书" },
} })

-- ---------------------------------------------------------------- sampling
local function weapon_form(wt, p)
    if wt == DUAL_BLADES then
        if field(p, "IsKijinKyouka") == true then return "db_enhanced" end
        if num(field(p, "<DBState>k__BackingField")) == 1 then return "db_kijin" end
    elseif wt == SWITCH_AXE then
        local awake = num(field(p, "_BottleAwakeDurationTimer"))
        if awake and awake > 0 then return "sa_awakened" end
        return (num(call(p, "get_Mode")) == 1) and "sa_sword" or "sa_axe"
    elseif wt == CHARGE_AXE then
        -- get_Mode: 0 = sword, 1 = axe
        if num(call(p, "get_Mode")) == 1 then
            return (field(p, "_IsChainsawBuff") == true) and "cb_axe_buff" or "cb_axe"
        end
        local shield = (num(field(p, "_ShieldBuffTimer")) or 0) > 0
        local sword = (num(field(p, "_SwordBuffTimer")) or 0) > 0
        if shield and sword then return "cb_both" end
        if shield then return "cb_shield" end
        if sword then return "cb_sword_buff" end
        return "cb_sword"
    end
    return "normal"
end

local function charge_level(wt, p)
    if wt == GREAT_SWORD then return num(field(p, "_TameLv")) or 0 end
    if wt == HAMMER then return num(field(p, "<NowChargeLevel>k__BackingField")) or 0 end
    if wt == BOW then return num(call(p, "get_ChargeLv")) or 0 end
    return nil
end

-- pnl_scrollicon play state -> scroll; a swap animation counts as the scroll it starts from
local SCROLL_STATES = { DEFAULT_RED = "red", RED_TO_BLUE = "red", DEFAULT_BLUE = "blue", BLUE_TO_RED = "blue" }

local function scroll()
    local hud = call(sdk.get_managed_singleton("snow.gui.GuiManager"), "get_refGuiHud_WeaponTechniqueMySet")
    local state = call(field(hud, "pnl_scrollicon"), "get_PlayState")
    return SCROLL_STATES[state]
end

-- forget the hunter (scene change, equipment rebuild): re-fetched on the next sample
function C.reset() ctx.player = nil end

-- One read of every condition into the cleared V; false when there is no hunter. The hunter is
-- re-fetched every 60 frames.
function C.sample(V, frame)
    frame = frame or 0
    if not ctx.player or frame >= ctx.refresh_at then
        ctx.player = call(sdk.get_managed_singleton("snow.player.PlayerManager"), "findMasterPlayer")
        ctx.refresh_at = frame + 60
    end
    local p = ctx.player
    if not p then return false end
    local on = bool(call(p, "isWeaponOn"))
    if on == nil then on = bool(call(p, "get_IsWeaponOn")) end
    V.weapon_on = on
    local wt = num(field(p, "_playerWeaponType"))
    if wt then
        V.weapon_type = wt
        V.weapon_form = weapon_form(wt, p)
        V.charge_level = charge_level(wt, p)
        if wt == LONG_SWORD then V.spirit_level = num(field(p, "_LongSwordGaugeLv")) or 0 end
    end
    V.scroll = scroll()
    return true
end

return C
