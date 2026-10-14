-- ShapeKeySystem: face interactions from the panel's face navigator.
--   poke(zone)     forehead / cheek / eye: play that zone's clip (fade in, hold, fade out); a new
--                  poke restarts the hold
--   drag(x, y)     mouth: x, y in -1..1 (viewer's right / down positive) set the direction keys;
--   release()      the mouth springs back (fade out)
-- Blending is the same as CondExpr: e' = e * (1 - a) + target * a, applied after the conditional
-- clips and before other plugins (External). Priority: external > touch > conditions > expression.
--
-- Which keys a zone uses: the condition set's "interactions" section when present
--   { forehead = { values = {key = w}, hold = s }, cheek = ..., eye = ...,
--     mouth = { left = {key = w}, right = ..., up = ..., down = ... } }
-- otherwise auto-detected from the worn mesh's key names (Shinano / VRC / ARKit spellings).

local TargetIndex = require("ShapeKeySystem_Core.TargetIndex")
local E = {}

E.HOLD = 1.0          -- seconds a poke stays at full weight
E.FADE_IN = 0.08
E.FADE_OUT = 0.35
E.DRAG_FADE_OUT = 0.3

local norm = TargetIndex.norm
E.norm = norm

-- ---------------------------------------------------------------- key detection
-- candidates per role, first match wins (compared normalised); a role may take several keys
local ROLES = {
    forehead = { { { "eye_><", "eye_x" }, { "mouth_△", "mouth_△_small", "mouth_triangle" } },
                 { { "eyeSquintLeft" }, { "eyeSquintRight" }, { "mouthPucker", "Mouth_Pout" } } },
    cheek    = { { { "other_cheek_2", "other_cheek", "cheek_blush", "blush", "照れ", "頬染め" } },
                 { { "cheekPuffLeft", "Cheek_Puff_Left" }, { "cheekPuffRight", "Cheek_Puff_Right" } } },
    eye      = { { { "eye_close", "blink", "まばたき" } },
                 { { "eyeBlinkLeft", "Eye_Left_Blink" }, { "eyeBlinkRight", "Eye_Right_Blink" } } },
    left     = { { { "mouthLeft", "Mouth_Left" } } },
    right    = { { { "mouthRight", "Mouth_Right" } } },
    up       = { { { "mouthUpperUpLeft", "Mouth_Upper_UpLeft" }, { "mouthUpperUpRight", "Mouth_Upper_UpRight" } } },
    down     = { { { "mouthLowerDownLeft", "Mouth_Lower_DownLeft" }, { "mouthLowerDownRight", "Mouth_Lower_DownRight" } } },
}

-- names: list of available key names -> { forehead = {key = w}, ... , mouth = {left, right, up, down} }
function E.detect(names)
    local have = {}
    for _, n in ipairs(names) do have[norm(n)] = have[norm(n)] or n end
    local function role(r)
        for _, option in ipairs(ROLES[r]) do
            local got, all = {}, true
            for _, slot in ipairs(option) do
                local found
                for _, cand in ipairs(slot) do found = found or have[norm(cand)] end
                if found then got[found] = 1.0 else all = false end
            end
            if all and next(got) then return got end
        end
        return {}
    end
    return { forehead = { values = role("forehead") }, cheek = { values = role("cheek") }, eye = { values = role("eye") },
             mouth = { left = role("left"), right = role("right"), up = role("up"), down = role("down") } }
end

-- ---------------------------------------------------------------- runtime
E.map = nil           -- the mapping in use
local pokes = {}      -- zone -> { a, until_t }
local drag = { a = 0, active = false, values = {} }
local last_clock = nil
E.animating = false

local layers, target_indexes, layers_dirty = {}, {}, true
local drag_index

-- 映射由调用方替换；即使复用同一张表，也必须通过此入口使名称索引失效。
function E.set_map(m)
    E.map, target_indexes, layers_dirty = m, {}, true
end

function E.poke(zone)
    local m = E.map and E.map[zone]
    if not m or not m.values or next(m.values) == nil then return false end
    local p = pokes[zone] or { a = 0 }
    p.until_t = os.clock() + (tonumber(m.hold) or E.HOLD)
    pokes[zone] = p
    return true
end

-- x, y: -1..1 from the mouth centre, viewer's right / screen down positive. The face looks at the
-- viewer, so the viewer's right is the face's own left (ARKit mouthLeft).
function E.drag(x, y)
    local m = E.map and E.map.mouth
    if not m then return false end
    local v = drag.values
    for k in pairs(v) do v[k] = nil end   -- keys of the other directions go back to the expression
    local function put(set, w)
        if w <= 0 then return end
        for key, k in pairs(set or {}) do v[key] = math.max(v[key] or 0, math.min(1, w * k)) end
    end
    put(m.left, x); put(m.right, -x)
    put(m.down, y); put(m.up, -y)
    drag.active = true
    drag_index, layers_dirty = nil, true
    return true
end

function E.release() drag.active = false end

function E.reset()
    drag_index, layers_dirty = nil, true
    for k in pairs(pokes) do pokes[k] = nil end
    drag.a, drag.active = 0, false
    for k in pairs(drag.values) do drag.values[k] = nil end
    last_clock = nil
end

function E.update()
    layers_dirty = true
    local now = os.clock()
    local dt = last_clock and math.min(0.1, math.max(0, now - last_clock)) or 0
    last_clock = now
    local changed = false
    for zone, p in pairs(pokes) do
        local want = (now < p.until_t) and 1 or 0
        if p.a ~= want then
            if want > p.a then p.a = math.min(1, p.a + dt / E.FADE_IN) else p.a = math.max(0, p.a - dt / E.FADE_OUT) end
            changed = true
        end
        if p.a <= 0 and want == 0 then pokes[zone] = nil end
    end
    local want = drag.active and 1 or 0
    if drag.a ~= want then
        if want > drag.a then drag.a = 1 else drag.a = math.max(0, drag.a - dt / E.DRAG_FADE_OUT) end
        changed = true
    elseif drag.active then
        changed = true    -- values move with the mouse
    end
    E.animating = changed
    return changed
end

function E.any()
    if drag.a > 0 then return true end
    return next(pokes) ~= nil
end

-- every (target set, weight) pair with weight: pokes, then the mouth drag
-- 每次更新最多建立一次活跃层；拖拽修改目标后，下一次读取立即重建。
local function active_layers()
    if not layers_dirty then return layers end
    layers_dirty = false
    for i = #layers, 1, -1 do layers[i] = nil end
    local m = E.map
    if not m then return layers end
    for zone, p in pairs(pokes) do
        if p.a > 0 and m[zone] and m[zone].values then layers[#layers + 1] = { m[zone].values, p.a } end
    end
    if drag.a > 0 then layers[#layers + 1] = { drag.values, drag.a } end
    return layers
end

local slot_cache, slot_cache_for = {}, nil
function E.apply(prog, resolve, W)
    if slot_cache_for ~= prog then slot_cache, slot_cache_for = {}, prog end
    for _, l in ipairs(active_layers()) do
        local set, a = l[1], l[2]
        for key, target in pairs(set) do
            local s = slot_cache[key]
            if s == nil then s = resolve(key) or false; slot_cache[key] = s end
            if s then W[s] = (W[s] or 0) * (1 - a) + target * a end
        end
    end
end

-- 复用每层目标索引，保持触碰层先、嘴部拖拽层后的混合顺序。
function E.for_key(key_name, e)
    local active = active_layers()
    if #active == 0 then return e end
    local n, v = norm(key_name), e
    for _, layer in ipairs(active) do
        local set = layer[1]
        local index
        if set == drag.values then
            drag_index = drag_index or TargetIndex.build(set)
            index = drag_index
        else
            index = target_indexes[set]
            if not index then index = TargetIndex.build(set); target_indexes[set] = index end
        end
        v = TargetIndex.blend(index, n, v, layer[2])
    end
    return v
end

return E
