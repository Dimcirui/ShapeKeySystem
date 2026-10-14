-- ShapeKeySystem: game-state conditions for the conditional expression layer (CondExpr.lua).
--
-- Design taken from the user's RE4 MOD Variant Manager (Conditions/Registry.lua):
--   def = { id (stored in configs, never rename), kind = "bool" | "number" | "enum", label,
--           get(V) -> value | nil, options = {{value, label}} for enums }
--   nil means "cannot read" and counts as NOT satisfied (never as false).
--   cond = { type, op, value, band }   rule = { conditions, logic = "AND" | "OR", hold }
--   An empty rule never matches; an unknown condition id evaluates false (retired ids degrade).
-- Values are sampled once per update (C.sample) into V; get() only reads V, so evaluating a rule
-- many times per frame (rules, UI) costs nothing and stateful conditions stay frame-consistent.
--
-- Game-specific getters live in the adapter (`A.conditions`): `install` registers its defs, and
-- `sample` hands it a cleared V. Core owns the HP-derived values so every game gets them the same:
-- the adapter writes `V.hp` / `V.hp_max`, Core turns them into hp_pct, hp_decreased, hp_increased.

local C = {}

local V = {}            -- sampled values of this update (id -> value)
C.V = V
local game = nil        -- A.conditions of the adapter in use

-- ---------------------------------------------------------------- definitions
local defs, order = {}, {}
C.defs, C.order = defs, order

local function def(d)
    if defs[d.id] then return end
    d.get = d.get or function() return V[d.id] end
    defs[d.id] = d
    order[#order + 1] = d
end

function C.install(conditions)
    game = conditions
    for _, d in ipairs(conditions and conditions.defs or {}) do def(d) end
end

C.NUM_OPS = { "<=", "<", ">=", ">", "==" }
C.ENUM_OPS = { "==", "~=" }

-- ---------------------------------------------------------------- sampling
local last_hp, last_max = nil, nil

-- forget the cached game objects (scene change, equipment rebuild): re-fetched on the next sample
function C.reset()
    if game and game.reset then game.reset() end
    last_hp, last_max = nil, nil
    for k in pairs(V) do V[k] = nil end
end

-- one read of every condition. frame: the update counter
function C.sample(frame)
    for k in pairs(V) do V[k] = nil end
    if not (game and game.sample and game.sample(V, frame)) then last_hp, last_max = nil, nil; return false end
    local hp, maxhp = V.hp, V.hp_max
    V.hp, V.hp_max = nil, nil
    if hp and maxhp and maxhp > 0 then
        V.hp_pct = hp / maxhp * 100
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

-- display text of a value
function C.value_text(id, v)
    local d = defs[id]
    if v == nil then return "—" end
    if d and d.kind == "enum" then
        for _, o in ipairs(d.options) do if o.value == v then return o.label end end
    end
    if type(v) == "number" then return string.format("%.1f", v) end
    if type(v) == "boolean" then return v and "是" or "否" end
    return tostring(v)
end

return C
