-- ShapeKeySystem: finds the faces that carry fcParam joints (the master player, the guild-card
-- preview hunter, optionally other hunters) and the hunter armour meshes next to them.
-- Only children named ch02_* / ch03_* are considered: NPC faces also carry fcParam.

local U = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")
local W = require("ShapeKeySystem_Core.Writer")

local S = {}

local M_JBN, M_CN, M_CNAME = W.M_JBN, W.M_CN, W.M_CNAME
local clock = os.clock

S.no_targets = {}   -- parent transform -> children signature known to hold no hunter mesh

function S.go_name(transform)
    local ok, n = pcall(function() return transform:call("get_GameObject"):call("get_Name") end)
    return ok and n or "?"
end

function S.master_root()
    local ok, tr = pcall(function()
        return sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Object"):call("get_Transform")
    end)
    return ok and tr or nil
end

-- The children a scan depends on: faces (Player_Face*) and armour parts (ch02 / ch03, as
-- read_parts picks them). Other children come and go during play (emote props, effects);
-- counting them dropped and re-armed the rigs every few frames, so the face froze through
-- emotes and talking (kevin, 2026-10-13).
local function scanned_child(name)
    return name:find("Player_Face", 1, true) == 1 or name:find("ch02", 1, true) ~= nil
        or name:find("ch03", 1, true) ~= nil
end

function S.children_signature(root)
    if not root then return "" end
    local parts, c = {}, root:call("get_Child")
    while c do
        local name = S.go_name(c)
        if scanned_child(name) then parts[#parts + 1] = name end
        c = c:call("get_Next")
    end
    return table.concat(parts, "|")
end

-- "+added -removed" between two signatures, for the trail.
function S.signature_diff(old, new)
    local function set(sig)
        local t = {}
        for n in (sig or ""):gmatch("[^|]+") do t[n] = (t[n] or 0) + 1 end
        return t
    end
    local a, b, out = set(old), set(new), {}
    for n, k in pairs(b) do if (a[n] or 0) < k then out[#out + 1] = "+" .. n end end
    for n, k in pairs(a) do if (b[n] or 0) < k then out[#out + 1] = "-" .. n end end
    table.sort(out)
    return table.concat(out, " ")
end

local function find_faces(root, scene_search)
    local faces, seen = {}, {}
    local function add(tr)
        if tr and not seen[tr] and M_JBN:call(tr, "fcParam_001") then
            seen[tr] = true; faces[#faces + 1] = tr
        end
    end
    if root then
        local c = root:call("get_Child")
        while c do
            if S.go_name(c):find("Player_Face", 1, true) == 1 then add(c) end
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

-- Hunter armour meshes under one parent: every ch02/ch03 child with blendshape channels.
-- Returns parts = { {id, mesh, names, n} } (names = every channel name, read once per scan).
local function read_parts(parent)
    local parts = {}
    local child = parent and parent:call("get_Child")
    while child do
        local cname = S.go_name(child)
        if cname:find("ch02", 1, true) or cname:find("ch03", 1, true) then
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

-- fcParam joints of a face for a list of param numbers -> { n1, joint1, n2, joint2, ... }
function S.joints(face, list)
    local out = {}
    for _, n in ipairs(list) do
        if n <= 200 then
            local j = M_JBN:call(face, string.format("fcParam_%03d", n))
            if j then out[#out + 1] = n; out[#out + 1] = j end
        end
    end
    return out
end

-- v (array) rotated by unit quaternion q ({x, y, z, w}); inverse = rotate by the conjugate
function S.qrot(q, x, y, z, inverse)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    if inverse then qx, qy, qz = -qx, -qy, -qz end
    local tx, ty, tz = 2 * (qy * z - qz * y), 2 * (qz * x - qx * z), 2 * (qx * y - qy * x)
    return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
end

-- A bone's rest position in the head's frame: its base (bind) local pose composed up the parent
-- chain to the Head joint. nil when the chain cannot be walked (no parent getter, no Head above).
local function rest_in_head(j)
    local M_PARENT, M_BLPOS, M_BLROT, M_BLSCL, M_JNAME = W.M_PARENT, W.M_BLPOS, W.M_BLROT, W.M_BLSCL, W.M_JNAME
    if not (M_PARENT and M_BLPOS and M_BLROT and M_JNAME) then return nil end
    local x, y, z = 0, 0, 0
    local node = j
    for _ = 1, 32 do
        if not node then return nil end
        if M_JNAME:call(node) == "Head" then return { x, y, z } end
        local p, q = M_BLPOS:call(node), M_BLROT:call(node)
        local s = M_BLSCL and M_BLSCL:call(node)
        if not p or not q then return nil end
        if s then x, y, z = x * s.x, y * s.y, z * s.z end
        x, y, z = S.qrot(q, x, y, z)
        x, y, z = x + p.x, y + p.y, z + p.z
        node = M_PARENT:call(node)
    end
    return nil
end

-- Bone signal reads of a face for a list of bone signals ({param, bone, axis, sign, full,
-- deadzone}). Returns { head = Head joint, list = { {id, j, rest, axis, sign, full, deadzone} } };
-- a bone the face lacks is left out, so its signal stays 0. rest = nil: taken from the first read.
function S.bone_reads(face, sigs)
    local head = (#sigs > 0) and M_JBN:call(face, "Head") or nil
    local out = { head = head, list = {} }
    if not head then return out end
    for _, sig in ipairs(sigs) do
        local j = M_JBN:call(face, sig.bone)
        if j then
            local ok, rest = pcall(rest_in_head, j)
            out.list[#out.list + 1] = { id = sig.param, j = j, rest = ok and rest or nil, axis = sig.axis,
                                        sign = sig.sign, full = sig.full, deadzone = sig.deadzone or 0, name = sig.bone }
        end
    end
    return out
end

-- opts = { index, scene_search (bool), min_hits }
function S.scan(opts)
    local t0 = clock()
    local root = S.master_root()
    local sig = S.children_signature(root)
    local faces = find_faces(root, opts.scene_search)
    -- one face per parent: a cutscene actor can carry several transforms with fcParam joints
    -- (all of them would drive the same armour meshes); a Player_Face* child wins
    local by_parent, order = {}, {}
    for _, face in ipairs(faces) do
        local parent = face:call("get_Parent")
        if parent then
            local cur = by_parent[parent]
            if not cur then
                by_parent[parent] = face; order[#order + 1] = parent
            elseif S.go_name(cur):find("Player_Face", 1, true) ~= 1 and S.go_name(face):find("Player_Face", 1, true) == 1 then
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
            -- params / dict_params / use_eyes are filled in by the caller (S.joints), which knows
            -- which channels the targets actually use
            rigs[#rigs + 1] = {
                label = S.go_name(parent), primary = primary, face = face,
                parent = parent, psig = psig or sig,
                params = {}, dict_params = {}, use_eyes = false,
                eyes = { L = M_JBN:call(face, "L_EyeJ_LOD02"), R = M_JBN:call(face, "R_EyeJ_LOD02") },
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
