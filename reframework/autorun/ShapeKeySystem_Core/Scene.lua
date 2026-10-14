-- ShapeKeySystem: finds the faces that carry driver joints (the primary character, the preview
-- character, optionally others) and the part meshes next to them. What counts as a face or a part
-- is the adapter's call (`S.adapter`: is_face, face_rank, is_part, eye_joints).

local U = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")
local W = require("ShapeKeySystem_Core.Writer")

local S = {}
S.adapter = {}   -- set by SKS.init

local M_CN, M_CNAME = W.M_CN, W.M_CNAME
local clock = os.clock

S.no_targets = {}   -- parent transform -> children signature known to hold no hunter mesh

function S.go_name(transform)
    local ok, n = pcall(function() return transform:call("get_GameObject"):call("get_Name") end)
    return ok and n or "?"
end

function S.primary_root()
    local f = S.adapter.primary_root
    return f and f() or nil
end

function S.children_signature(root)
    if not root then return "" end
    local parts, c = {}, root:call("get_Child")
    while c do parts[#parts + 1] = S.go_name(c); c = c:call("get_Next") end
    return table.concat(parts, "|")
end

local function find_faces(root, scene_search)
    local A = S.adapter
    local faces, seen = {}, {}
    local function add(tr)
        if tr and not seen[tr] and A.is_face(tr) then
            seen[tr] = true; faces[#faces + 1] = tr
        end
    end
    if root then
        local c = root:call("get_Child")
        while c do
            if A.face_rank(c) > 0 then add(c) end
            c = c:call("get_Next")
        end
    end
    if scene_search then
        pcall(function()
            local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = scene:call("findComponents(System.Type)", W.MOTION_TYPE)
            for i = 0, (arr:call("get_Length") or 0) - 1 do
                local comp = arr:call("GetValue(System.Int32)", i)
                if comp then pcall(function() add(comp:call("get_GameObject"):call("get_Transform")) end) end
            end
        end)
    end
    return faces
end

-- Part meshes under one parent: every child the adapter calls a part, with blendshape channels.
-- Returns parts = { {id, mesh, names, n} } (names = every channel name, read once per scan).
local function read_parts(parent)
    local parts = {}
    local child = parent and parent:call("get_Child")
    while child do
        local cname = S.go_name(child)
        if S.adapter.is_part(cname) then
            local mesh
            pcall(function() mesh = child:call("get_GameObject"):call("getComponent(System.Type)", W.MESH_TYPE) end)
            local n = mesh and (M_CN:call(mesh) or 0) or 0
            if n > 0 then
                local names = {}
                for i = 0, n - 1 do names[i + 1] = M_CNAME:call(mesh, i) or "" end
                parts[#parts + 1] = { id = cname, mesh = mesh, names = names, n = n }
            end
        end
        child = child:call("get_Next")
    end
    return parts
end

-- Expression targets for one part: every channel the profile index matches (LOD copies too).
-- Returns target or nil when fewer than min_hits distinct profile channels match.
local function build_target(part, index, min_hits, mesh_name_of)
    local slots, idxs, distinct, count = {}, {}, {}, 0
    local hits = 0
    local sel = Names.match_part(index, part.names)
    for i, cn in ipairs(part.names) do
        local s = sel[i]
        if s then
            count = count + 1
            slots[count] = s; idxs[count] = i - 1
            if not distinct[s] then
                distinct[s] = true; hits = hits + 1
                if mesh_name_of[s] == nil then mesh_name_of[s] = cn:match("^[^%.]+%.(.+)$") or cn end
            end
        end
    end
    if hits < min_hits then return nil end
    local last = {}
    for k = 1, count do last[k] = -1 end   -- force the first write
    local ok, addr = pcall(part.mesh.get_address, part.mesh)
    return { mesh = part.mesh, addr = ok and addr or nil, name = part.id, slots = slots, idxs = idxs,
             last = last, count = count, distinct = hits, ready = false, stable = 0 }
end

-- opts = { index, scene_search (bool), min_hits }
function S.scan(opts)
    local t0 = clock()
    local root = S.primary_root()
    local sig = S.children_signature(root)
    local faces = find_faces(root, opts.scene_search)
    -- one face per parent: a cutscene actor can carry several transforms with driver joints
    -- (all of them would drive the same part meshes); the higher face_rank wins
    local by_parent, order = {}, {}
    for _, face in ipairs(faces) do
        local parent = face:call("get_Parent")
        if parent then
            local cur = by_parent[parent]
            if not cur then
                by_parent[parent] = face; order[#order + 1] = parent
            elseif S.adapter.face_rank(face) > S.adapter.face_rank(cur) then
                by_parent[parent] = face
            end
        end
    end
    local rigs, parts_by_id, part_list, instances = {}, {}, {}, {}
    local mesh_name_of = {}
    local skipped = 0
    local seen_parents = {}
    for _, parent in ipairs(order) do
        local face = by_parent[parent]
        local primary = (parent == root)
        -- NPC faces whose siblings did not change since the last scan are skipped
        local psig = (not primary) and S.children_signature(parent) or nil
        local parts = {}
        if psig and S.no_targets[parent] == psig then
            skipped = skipped + 1
        else
            parts = read_parts(parent)
            if #parts == 0 and psig then S.no_targets[parent] = psig end
        end
        if #parts > 0 then seen_parents[#seen_parents + 1] = string.format("%s(%d)", S.go_name(parent), #parts) end
        local targets = {}
        for _, part in ipairs(parts) do
            instances[#instances + 1] = part
            if not parts_by_id[part.id] then
                parts_by_id[part.id] = part
                part_list[#part_list + 1] = part
            end
            local t = build_target(part, opts.index, opts.min_hits or 3, mesh_name_of)
            if t then targets[#targets + 1] = t end
        end
        if #targets > 0 then
            -- params / dict_params / use_eyes are filled in by the caller (the adapter's bind), which knows
            -- which channels the targets actually use
            rigs[#rigs + 1] = {
                label = S.go_name(parent), primary = primary, face = face,
                parent = parent, psig = psig or sig,
                params = {}, dict_params = {}, use_eyes = false,
                eyes = S.adapter.eye_joints(face),
                targets = targets, angles = { L = { 0, 0 }, R = { 0, 0 } },
                W = {}, V = {},
            }
        end
    end
    table.sort(rigs, function(a, b) return a.primary and not b.primary end)
    for _, part in ipairs(instances) do
        local sorted = {}
        for i, n in ipairs(part.names) do sorted[i] = n end
        table.sort(sorted)
        part.fingerprint = U.fnv(table.concat(sorted, "\n"))
    end
    -- parts: one entry per part id (bindings, coverage); instances: every mesh found (the same
    -- part worn by the player, the guild card copy, a cutscene copy ...), for the sculpt layer
    return { rigs = rigs, parts = part_list, instances = instances, parents = seen_parents, faces = #faces, skipped = skipped,
             sig = sig, mesh_name_of = mesh_name_of, ms = (clock() - t0) * 1000 }
end

return S
