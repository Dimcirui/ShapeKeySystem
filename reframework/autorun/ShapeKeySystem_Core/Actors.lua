-- ShapeKeySystem: the characters in the scene, grouped by person, and which one the panel edits.
--
-- A character is a person (`A.actor_of(face)`), not a scene object: the player, a cutscene copy
-- and a model viewer figure of the same person form one character. The edited character's faces
-- become the primary scan (`Scene.override`); every other face goes to ActorInstances. Without
-- `actor_of` and `additional_faces` there is one character with id "" and nothing is overridden.
--
-- Constraints:
-- - Face and root references live until the next `refresh` or `clear`; API clears them with its
--   rigs on every release, so none outlives a cutscene teardown or part rebuild.

local M = { list = {}, wanted = nil, selected = "", player = "", rev = 0 }
local adapter = nil
local groups = {}   -- id -> { faces, player }

function M.init(a)
    adapter = a
    M.list, M.wanted, M.selected, M.player, groups = {}, nil, "", "", {}
end

function M.enabled()
    return adapter ~= nil and adapter.actor_of ~= nil and adapter.additional_faces ~= nil
end

function M.clear() groups = {} end

local function id_of(face)
    local ok, id = pcall(adapter.actor_of, face)
    return ok and type(id) == "string" and id or nil
end
M.id_of = function(face) return M.enabled() and id_of(face) or nil end

local function address(face)
    local ok, a = pcall(face.get_address, face)
    return ok and tostring(a) or tostring(face)
end

-- Collects the characters again. name_of(id) gives the display name. Returns true when the
-- edited character or its set of faces changed (the primary scan has to run again).
function M.refresh(name_of)
    if not M.enabled() then return false end
    local before = M.signature()
    local g, order = {}, {}
    local function add(face, player)
        local id = face and id_of(face)
        if not id then return end
        local e = g[id]
        if not e then e = { faces = {}, player = false }; g[id] = e; order[#order + 1] = id end
        for _, f in ipairs(e.faces) do if f == face then return end end
        if player then
            e.player = true
            table.insert(e.faces, 1, face)
        else
            e.faces[#e.faces + 1] = face
        end
    end
    local root = adapter.primary_root and adapter.primary_root()
    if root and adapter.faces then
        for _, f in ipairs(adapter.faces(root)) do if adapter.is_face(f) then add(f, true) end end
    end
    local ok, extra = pcall(adapter.additional_faces)
    for _, f in ipairs(ok and extra or {}) do add(f, false) end
    groups = g
    local player = ""
    for _, id in ipairs(order) do if g[id].player then player = id; break end end
    M.player = player
    if M.wanted and g[M.wanted] then M.selected = M.wanted
    elseif g[player] then M.selected = player
    else M.selected = order[1] or "" end
    local list = {}
    for _, id in ipairs(order) do
        list[#list + 1] = { id = id, name = name_of and name_of(id) or id, player = g[id].player, copies = #g[id].faces }
    end
    -- the player's character first, then by name
    table.sort(list, function(a, b)
        if a.player ~= b.player then return a.player end
        return a.name < b.name
    end)
    M.list = list
    M.rev = M.rev + 1
    return M.signature() ~= before
end

-- the edited character and its faces, for change detection (addresses only)
function M.signature()
    local e = groups[M.selected]
    if not e then return M.selected end
    local t = { M.selected }
    for _, f in ipairs(e.faces) do t[#t + 1] = address(f) end
    return table.concat(t, "|")
end

-- The primary scan's root and faces for the edited character, or nil (the adapter's own player).
function M.override()
    local e = groups[M.selected]
    if not e or #e.faces == 0 then return nil end
    local root
    if e.player then root = adapter.primary_root()
    else root = adapter.face_root and adapter.face_root(e.faces[1], nil) or e.faces[1]:call("get_Parent") end
    if not root then return nil end
    return { root = root, faces = e.faces }
end

-- every face that is not the edited character's, for ActorInstances
function M.instance_faces()
    local out = {}
    for id, e in pairs(groups) do
        if id ~= M.selected then
            for _, f in ipairs(e.faces) do out[#out + 1] = f end
        end
    end
    return out
end

function M.has(id) return groups[id] ~= nil end

-- The character a scene object belongs to (public API): a GameObject or Transform of the
-- character's root, its head, or a part under that root. Faces are those of the last refresh.
local function try_call(o, method)
    local ok, r = pcall(function() return o:call(method) end)
    return ok and r or nil
end

function M.object_actor(obj)
    if not M.enabled() or obj == nil then return nil end
    local tr = try_call(obj, "get_Transform") or obj
    -- every node from each face up to its character root
    local owner = {}
    for id, e in pairs(groups) do
        for _, face in ipairs(e.faces) do
            local ok, root = pcall(adapter.face_root or function() end, face)
            local stop = ok and root and address(root) or nil
            local node = face
            for _ = 1, 8 do
                if not node then break end
                local a = address(node)
                owner[a] = owner[a] or id
                if a == stop then break end
                node = try_call(node, "get_Parent")
            end
        end
    end
    local node = tr
    for _ = 1, 8 do
        if not node then break end
        local id = owner[address(node)]
        if id then return id end
        node = try_call(node, "get_Parent")
    end
    return nil
end

return M
