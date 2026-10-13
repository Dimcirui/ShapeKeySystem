-- ShapeKeySystem: facial presets — an avatar's own numbered whole-face expressions (Maya's face
-- mesh carries "1".."10" under ===Facial===), set with sliders on their own panel page
-- (kevin, 2026-10-13).
--
-- A facial key is a sculpt key (merged name, Sculpt.key_of) that is a bare positive integer.
-- Values are 0..1 per key name, kept in settings.json ("facial"); a value for a key the worn parts
-- lack is kept but does nothing. The sculpt layer writes a facial key like an expression-driven
-- one, s + (1 - s) * v (Sculpt value_for), and other plugins (External) still win.
-- level = the highest value among the present keys. While it is up, every other expression
-- weight (fcParam / bone signals, conditional clips, face pokes) is scaled by 1 - level, gaze
-- excepted: a whole-face preset at 1 replaces the emote-driven face (kevin, 2026-10-13).

local F = {}

F.values = {}    -- key name -> value (> 0); API points this at settings.facial
F.present = {}   -- key name -> true, the facial keys of the worn parts (latest scan)
F.list = {}      -- present names in number order
F.level = 0

function F.is_facial(name)
    local n = type(name) == "string" and name:match("^%d+$") and tonumber(name)
    return n ~= nil and n >= 1
end

local function refresh()
    local m = 0
    for n in pairs(F.present) do
        local v = tonumber(F.values[n]) or 0
        if v > m then m = v end
    end
    F.level = math.min(m, 1.0)
end

-- names: every sculpt key name on the worn parts. Returns the facial ones in number order.
function F.set_present(names)
    local list, present = {}, {}
    for _, n in ipairs(names) do
        if F.is_facial(n) and not present[n] then present[n] = true; list[#list + 1] = n end
    end
    table.sort(list, function(a, b) return tonumber(a) < tonumber(b) end)
    F.present, F.list = present, list
    refresh()
    return list
end

-- the table settings.json keeps, edited in place: keys become strings (a loader may hand back
-- 1 for "1"), entries that are not positive numbers are dropped
function F.bind(values)
    local keep = {}
    for k, v in pairs(values) do
        v = tonumber(v)
        if v and v > 0 then keep[tostring(k)] = math.min(v, 1.0) + 0.0 end
    end
    for k in pairs(values) do values[k] = nil end
    for k, v in pairs(keep) do values[k] = v end
    F.values = values
    refresh()
end

function F.value(name) return tonumber(F.values[name]) or 0 end

-- v is clamped to 0..1; 0 removes the entry. Returns true when the value changed.
function F.set(name, v)
    v = math.max(0.0, math.min(1.0, v)) + 0.0
    local old = F.value(name)
    if v > 0 then F.values[name] = v else F.values[name] = nil end
    refresh()
    return math.abs(old - v) > 1e-9
end

-- every slider to 0; true when any was up
function F.clear()
    local any = next(F.values) ~= nil
    for k in pairs(F.values) do F.values[k] = nil end
    refresh()
    return any
end

function F.any() return F.level > 0 end

-- the share of the driven face that stays visible
function F.keep() return 1 - F.level end

-- slider value of a present facial key, nil for any other key
function F.for_key(name)
    if not F.present[name] then return nil end
    return F.value(name)
end

-- expression weights of one frame (a copy, see API drive): every slot but gaze scaled by 1 - level
function F.fade(prog, out)
    local k = 1 - F.level
    local ch = prog.channels
    for s = 1, prog.n do
        if ch[s].group ~= "gaze" then out[s] = out[s] * k end
    end
end

return F
