-- ShapeKeySystem: shape key control by other plugins (the public API in API.lua builds on this).
--
-- Model: an external value OVERRIDES the expression and sculpt layers for one key while it is
-- held. Priority: external > expression > sculpt. The last owner that set a key holds it.
-- Every value is a lease: it expires ttl seconds after its last set() (default 0.5 s), so a
-- plugin that crashes or is removed cannot leave a value stuck on the hunter. ttl = 0 means
-- "until release".
--
-- Keys are matched case-insensitively against the sculpt key names (mesh channel name without
-- prefix and _LODn), the expression profile's canonical names and, through the profile index,
-- alias / mesh spellings. Nothing here touches the engine: values are applied by the writers
-- (API.drive -> X.apply over rig.W; Sculpt value_for) on the next update.

local E = {}

E.DEFAULT_TTL = 0.5
E.MAX_TTL = 60

local entries = {}     -- norm key -> { name, owner, value, ttl, expires }
E.entries = entries
E.rev = 0              -- bumped when the set of held keys or their owners change (not on value)
local slot_cache = nil -- norm key -> expression slot (or false), rebuilt when the profile changes
local slot_cache_for = nil

local clock = os.clock

local function norm(name) return (tostring(name):gsub("[%s_%-%.]", ""):lower()) end
E.norm = norm

local function bump() E.rev = E.rev + 1; slot_cache = nil end

-- set(owner, name, value, ttl) -> changed_structure
function E.set(owner, name, value, ttl)
    local k = norm(name)
    local e = entries[k]
    local structural = (e == nil) or e.owner ~= owner
    ttl = ttl or E.DEFAULT_TTL
    if not e then e = {}; entries[k] = e end
    e.name, e.owner, e.value, e.ttl = name, owner, value, ttl
    e.expires = (ttl > 0) and (clock() + ttl) or nil
    if structural then bump() end
    return structural
end

function E.release(owner, name)
    local k = norm(name)
    local e = entries[k]
    if e and (owner == nil or e.owner == owner) then
        entries[k] = nil
        bump()
        return true
    end
    return false
end

function E.release_all(owner)
    local n = 0
    for k, e in pairs(entries) do
        if owner == nil or e.owner == owner then entries[k] = nil; n = n + 1 end
    end
    if n > 0 then bump() end
    return n
end

-- drop expired leases; returns true when anything was dropped
function E.expire()
    if next(entries) == nil then return false end
    local now = clock()
    local dropped = false
    for k, e in pairs(entries) do
        if e.expires and now > e.expires then entries[k] = nil; dropped = true end
    end
    if dropped then bump() end
    return dropped
end

function E.get(name)
    local e = entries[norm(name)]
    return e and e.value or nil, e and e.owner or nil
end

function E.any() return next(entries) ~= nil end

-- external value for a sculpt key (by its name)
function E.for_key(key_name)
    local e = entries[norm(key_name)]
    return e and e.value or nil
end

-- expression slots overridden right now: resolve(name) -> slot or nil is given by the caller
-- (profile canonical name / alias index). Cached per profile.
function E.slots(prog, resolve)
    if next(entries) == nil then return nil end
    if not slot_cache or slot_cache_for ~= prog then
        slot_cache, slot_cache_for = {}, prog
        for k, e in pairs(entries) do slot_cache[k] = resolve(e.name) or false end
    end
    return slot_cache
end

-- write the overrides into a rig's weight array (after the expression compute). Returns the
-- set of overridden slots (written as is, not mixed with the sculpt rest value) or nil.
local held_slots = {}
function E.apply(prog, resolve, Wt)
    local sc = E.slots(prog, resolve)
    if not sc then return nil end
    for s in pairs(held_slots) do held_slots[s] = nil end
    local any = false
    for k, s in pairs(sc) do
        if s then
            local e = entries[k]
            if e then Wt[s] = e.value; held_slots[s] = true; any = true end
        end
    end
    return any and held_slots or nil
end

return E
