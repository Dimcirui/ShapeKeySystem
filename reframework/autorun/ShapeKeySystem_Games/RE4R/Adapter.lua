-- ShapeKeySystem: player discovery, actor calibration and shape-key targets for RE4R.
--
-- The current player's head selects its calibration. Lookup references live for one callback;
-- rig handles are released when the topology changes.
--
-- A head's identity is the group of its mesh file name (`cha000_10` -> `cha000`): mods replace the
-- file contents, not the logical path, and costume groups reuse the base head.
--
-- Without a player context the figure shown in the model viewer is the primary character:
-- `FigureGuiManager.get_ModelController()` gives it each frame, its head is the descendant named
-- `Head`, and its root is the mesh-less `..._Body` node that holds the Motion.
local Signals = require("ShapeKeySystem_Games.RE4R.Signals")
local NativeFace = require("ShapeKeySystem_Games.RE4R.NativeFace")
local BoneHold = require("ShapeKeySystem_Games.RE4R.BoneHold")
local Conditions = require("ShapeKeySystem_Games.RE4R.Conditions")
local Playback = require("ShapeKeySystem_Games.RE4R.Playback")
local Cutscene = require("ShapeKeySystem_Games.RE4R.Cutscene")
local FaceMirror = require("ShapeKeySystem_Games.FaceMirror")
local L = require("ShapeKeySystem_Core.I18n")
local A = { id = "re4", name = "Resident Evil 4", strict_bounds = true, hash_names = true, hash_item_only = true,
    rewrite_active_weights = true, scene_search = false, scoped_bindings = true,
    active_sculpt = true, batch_weights = true, native_write = true, cache_channels = true, inspect_before_scan = true, skip_empty_actors = true,
    instance_auto_profile = true,
    conditions = Conditions,
    playback = Playback,
    -- the GUI is the system image plane (one Texture element); the head is its own GameObject, but the
    -- body skeleton carries a Head joint, so all joints are on the body
    face_mirror = FaceMirror.new({
        rtex = "_Chainsaw/UI/FaceMirror/rtt_facemirror_00.rtex",
        gui_asset = "systems/gui/imageplane_1920x1080.gui", gui_elem = "Image", gui_folder = "Gui",
        main_camera = "MainCamera",
        binds = { { id = "Head", name = "头部（Head）" }, { id = "Neck_0", name = "脖子（Neck_0）" }, { id = "Spine_2", name = "胸部（Spine_2）" },
                  { id = "Hip", name = "臀部（Hip）" } },
        rigs = {
            Head = { dist = 0.6, aim = { x = 0, y = 0.07, z = 0.08 }, rot = { x = -6, y = 0, z = 0 } },
            Neck_0 = { dist = 0.6, aim = { x = 0, y = 0.12, z = 0.08 }, rot = { x = -6, y = 0, z = 0 } },
            Spine_2 = { dist = 0.6, aim = { x = 0, y = 0.35, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
            Hip = { dist = 0.6, aim = { x = 0, y = 0.5, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
        },
        parts = { { id = "body", name = "躯干" }, { id = "weapon", name = "武器", hide = true } },
        -- character meshes by slot (10 head, 20 hair, the rest body); weapons and their attachments
        part = function(_, path)
            if path:find("/character/wp/", 1, true) then return "weapon" end
            local slot = path:match("/character/ch/.-/(%d%d)/[^/]+%.mesh$")
            if slot then return (slot == "10" or slot == "20") and "head" or "body" end
            return "other"
        end,
        isolate = true, clip = { 1, 2 },
    }),
    input = require("ShapeKeySystem_Games.RE4R.Input"),
    terms = { primary = "主角色", part = "部件" }, raw = Signals.raw,
    read = Signals.read, channel_writable = Signals.writable, write_context = Signals.write_context }
local T_MESH
local calibrations = {}
local function call(obj, method, ...)
    if not obj then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    return ok and value or nil
end
local function context()
    return call(sdk.get_managed_singleton("chainsaw.CharacterManager"), "getPlayerContextRef()")
end
local function transform(go) return call(go, "get_Transform") end
local function mesh(tr) return call(call(tr, "get_GameObject"), "getComponent(System.Type)", T_MESH) end
local function resource(m) return call(m, "getMesh") end
local function resource_path(m)
    local p = call(resource(m), "get_ResourcePath")
    return type(p) == "string" and p:gsub("\\", "/"):lower() or ""
end
local function path(tr)
    return resource_path(mesh(tr))
end
local function figure_head()
    local manager = call(sdk.get_managed_singleton("chainsaw.BonusContentsGuiManager"), "get_FigureManager")
    local root = transform(call(call(manager, "get_ModelController"), "get_GameObject"))
    local function find(tr, depth)
        local c, seen = call(tr, "get_Child"), {}
        while c and not seen[c] do
            seen[c] = true
            local name = call(call(c, "get_GameObject"), "get_Name")
            if type(name) == "string" and name:lower() == "head" then return c end
            local hit = depth < 6 and find(c, depth + 1)
            if hit then return hit end
            c = call(c, "get_Next")
        end
    end
    return root and find(root, 1) or nil
end
local function head()
    local ctx = context()
    if not ctx then return figure_head() end
    local go = call(call(call(ctx, "get_BodyUpdater"), "get_HeadMotion"), "get_GameObject")
        or call(ctx, "get_HeadGameObject")
    return transform(go)
end
-- head groups of the actors with a calibration
local ACTORS = { cha000 = "leon", cha005 = "leon", cha006 = "leon", cha500 = "leon",
    cha200 = "ada", cha800 = "ada", cha801 = "ada", cha803 = "ada" }
-- head groups of other characters: their meshes mark another actor in `A.instance_root`
local OTHERS = { cha100 = "ashley", cha102 = "ashley", cha300 = "luis", chi100 = "luis",
    chb700 = "krauser", chi200 = "krauser", cha600 = "wesker", chj000 = "wesker", chi300 = "hunk" }
local function group_of(p)
    local base = p:match("([^/]+)$")
    return base and base:match("^(ch%a%d%d%d)_") or nil
end
local function character_of_path(p)
    local g = group_of(p)
    return g and (ACTORS[g] or OTHERS[g]) or nil
end
local function actor_of_path(p)
    local g = group_of(p)
    return g and ACTORS[g] or nil
end

function A.bind(face, keys)
    return Signals.bind(face, keys, calibrations[actor_of_path(path(face))])
end

function A.primary_root()
    local ctx = context()
    if not ctx then
        local h = figure_head()
        return h and A.instance_root(h) or nil
    end
    return transform(call(ctx, "get_BodyGameObject") or call(ctx, "get_GameObject"))
end
-- Head identity follows its actor and mesh slot; replacement rigs may omit individual face joints.
local function face_path(p)
    return actor_of_path(p) ~= nil and p:match("/cha%d%d%d_1[01][_%w]*%.mesh") ~= nil
end
function A.is_face(tr) return face_path(path(tr)) end
function A.primary_ready()
    local h = head()
    return A.primary_root() ~= nil and h ~= nil and A.is_face(h)
end
function A.faces() local h = head(); return h and {h} or {} end
function A.instance_root(face)
    local actor, node = actor_of_path(path(face)), face
    for _ = 1, 6 do
        local parent = call(node, "get_Parent")
        if not parent then break end
        local body, foreign, child = false, false, call(parent, "get_Child")
        local seen = {}
        while child and not seen[child] do
            seen[child] = true
            local p = path(child)
            local who = character_of_path(p)
            if who and who ~= actor then foreign = true end
            -- a skin's body has a group of its own (a figure's cha002_00 under a cha000 head)
            if (who == actor or who == nil) and p:match("/cha%d%d%d_00[_%w]*%.mesh") then body = true end
            child = call(child, "get_Next")
        end
        if foreign then break end
        if body then return parent end
        node = parent
    end
    return face
end

-- the player's head groups under the player's root even while another character is edited
-- (Core then passes that character's root as `root`)
function A.face_root(face)
    return face == head() and A.primary_root() or A.instance_root(face)
end

-- the person a head belongs to (Core/Actors.lua): "leon" / "ada"
function A.actor_of(face) return actor_of_path(path(face)) end

-- components of a type in the current scene, or nil
local function components(type_name)
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local t = sdk.typeof(type_name)
    return scene and t and call(scene, "findComponents(System.Type)", t) or nil
end

function A.additional_faces()
    local result, seen = {}, {}
    local player = head()
    local owned = {}
    local root = A.primary_root()
    if root then
        for _, part in ipairs(A.parts(root)) do owned[part:get_address()] = true end
    end
    -- ShapeKeySystem_Native.dll lists every Motion's transform and mesh path in one call
    local native = rawget(_G, "sks_native")
    local listed = type(native) == "table" and type(native.motion_meshes) == "function"
        and select(2, pcall(native.motion_meshes))
    if type(listed) == "table" then
        local player_address = player and player:get_address()
        for i = 1, #listed - 1, 2 do
            local address, p = listed[i], listed[i + 1]
            if address ~= player_address and not owned[address] and not seen[address] and face_path(p) then
                local tr = sdk.to_managed_object(address)
                if tr then
                    seen[address] = true
                    result[#result + 1] = tr
                end
            end
        end
        return result
    end
    local list = components("via.motion.Motion")
    for i = 0, (list and call(list, "get_Length") or 0) - 1 do
        local component = list:call("GetValue(System.Int32)", i)
        local tr = transform(call(component, "get_GameObject"))
        if tr and tr ~= player and not owned[tr:get_address()] and not seen[tr] and A.is_face(tr) then
            seen[tr] = true
            result[#result + 1] = tr
        end
    end
    return result
end

function A.instances_ready(cutscene_drive)
    local playing = Cutscene.playing()
    if playing and cutscene_drive == false then return false end
    return A.primary_ready() or playing == true
end
function A.face_rank(face) return path(face):match("_10[_%w]*%.mesh") and 2 or 1 end
function A.is_part() return false end
function A.parts(root, face)
    local out, seen = {}, {}
    local function visit(tr, depth)
        if not tr or depth > 6 or #out >= 64 or seen[tr] then return end
        seen[tr] = true
        if mesh(tr) then out[#out + 1] = tr end
        local c = call(tr, "get_Child")
        local siblings, n = {}, 0
        while c and not siblings[c] and n < 256 do
            siblings[c], n = true, n + 1
            visit(c, depth + 1); c = call(c, "get_Next")
        end
    end
    visit(face or (root == A.primary_root() and head() or nil), 0); visit(root, 0)
    return out
end
function A.part_id(tr)
    local p = path(tr):match("([^/]+)%.mesh")
    local name = call(call(tr, "get_GameObject"), "get_Name") or "part"
    return (p or name):gsub("[^%w_%-]", "_")
end
A.model_names = "character_names.json"
A.slot_names = { ["00"] = "身体", ["10"] = "头部", ["20"] = "头发" }

function A.model_of(part)
    if part == "leon" or part == "ada" then return part end
    local id = part:match("^(cha%d%d%d)_")
    local actor = id and ACTORS[id] or actor_of_path(path(head()))
    local slot = part:match("^cha%d%d%d_(%d%d)$")
    return actor or "leon", A.slot_names[slot] and slot or part
end
function A.representative_of(part) return (A.model_of(part)) end
function A.eye_joints(face)
    return {L = call(face, "getJointByName(System.String)", "L_Eye") or NativeFace.eye(face, "L_Eye"),
            R = call(face, "getJointByName(System.String)", "R_Eye") or NativeFace.eye(face, "R_Eye")}
end
function A.eye_angles(eye)
    local q = type(eye) == "table" and eye.animation_eye and NativeFace.eye_rotation(eye)
        or type(eye) ~= "table" and call(eye, "get_LocalRotation()") or nil
    if q then return require("ShapeKeySystem_Core.Expression").quat_to_yaw_pitch(q) end
end
A.expression_joints = BoneHold.joints
A.face_layers = BoneHold.layers
function A.channel_stamp(m)
    local hashes = call(m, "get_ChannelNameHash")
    -- getMesh returns a transient resource wrapper; its address changes between callbacks.
    local p = resource_path(m)
    if p == "" then return nil end
    local ok, key = pcall(function()
        return p .. ":" .. tostring(hashes:get_address())
    end)
    return ok and key or nil
end
function A.signature(root)
    local out = {}
    for _, tr in ipairs(A.parts(root)) do
        local m = mesh(tr)
        local ok, addr = pcall(m.get_address, m)
        local n = call(m, "get_BlendShapeChannelNum")
        if type(n) == "number" and n > 0 then
            out[#out+1] = A.part_id(tr) .. "@" .. tostring(ok and addr or "-") .. ":" .. tostring(n)
                .. ":" .. tostring(A.channel_stamp(m))
        end
    end
    table.sort(out)
    return table.concat(out, "|")
end

local function object_address(o)
    local ok, value = pcall(function() return o:get_address() end)
    return ok and value or nil
end

-- Store numeric routes, not transform references. Resolve them from live anchors on every check.
function A.capture_layout(root, face, parts)
    local layout = {root = object_address(root), primary = root == A.primary_root(), routes = {}}
    if not layout.root or #parts == 0 then return end
    local wanted, seen, found, visited = {}, {}, 0, 0
    for _, part in ipairs(parts) do
        local addr = object_address(part.mesh)
        if not addr then return end
        wanted[addr] = part
    end
    local function visit(tr, route, anchor, depth)
        if not tr or depth > 6 or seen[tr] or visited >= 4096 or found >= #parts then return end
        seen[tr] = true
        visited = visited + 1
        local m = mesh(tr)
        local addr = m and object_address(m)
        local part = addr and wanted[addr]
        if part then
            local steps = {}; for i, step in ipairs(route) do steps[i] = step end
            local stamp = A.channel_stamp(m)
            local transform_address = object_address(tr)
            if not stamp or not transform_address then return end
            layout.routes[#layout.routes+1] = {anchor = anchor, steps = steps,
                transform = transform_address, mesh = addr, channels = part.n, stamp = stamp}
            found = found + 1
        end
        local child, siblings, index = call(tr, "get_Child"), {}, 0
        while child and not siblings[child] and index < 256 and found < #parts and visited < 4096 do
            siblings[child] = true; route[#route+1] = index
            visit(child, route, anchor, depth+1); route[#route] = nil
            child, index = call(child, "get_Next"), index+1
        end
    end
    if layout.primary then
        local h = head()
        layout.head = object_address(h)
        if not layout.head then return end
        visit(h, {}, "head", 0)
    end
    visit(root, {}, "root", 0)
    if found ~= #parts then return end
    return layout
end

-- Every check compares the object addresses along the stored routes; the channel count and the
-- resource stamp (string work) are compared on every 15th check. Writes check their own bounds,
-- so a resource swapped in place in between is never written out of range.
local FULL_LAYOUT_CHECK = 15
function A.layout_valid(root, layout)
    if object_address(root) ~= layout.root then return false end
    local h = layout.primary and head()
    if layout.primary and object_address(h) ~= layout.head then return false end
    layout.checks = (layout.checks or 0) + 1
    local full = layout.checks % FULL_LAYOUT_CHECK == 1
    for _, route in ipairs(layout.routes) do
        local tr = route.anchor == "head" and h or root
        for _, index in ipairs(route.steps) do
            tr = call(tr, "get_Child")
            for _ = 1, index do tr = call(tr, "get_Next") end
            if not tr then return false end
        end
        if object_address(tr) ~= route.transform then return false end
        local m = mesh(tr)
        if object_address(m) ~= route.mesh then return false end
        if full and (call(m, "get_BlendShapeChannelNum") ~= route.channels
            or A.channel_stamp(m) ~= route.stamp) then return false end
    end
    return true
end
function A.gate(_, cutscene_drive)
    if not A.primary_ready() then return false, "Player or supported head unavailable" end
    if cutscene_drive == false then
        local playing = Cutscene.playing()
        if playing == nil then return false, "Cutscene state unavailable" end
        if playing then return false, "Cutscene drive disabled" end
    end
    return true
end

-- Core passes only current targets after checking the player's signature and readiness.
function A.prepare_mesh(m) call(m, "set_LodLevel", 0) end

-- Prepare custom channels only after the engine has allocated their complete weight list.
function A.prepare_parts(parts)
    for _, part in ipairs(parts) do
        local m, n = part.mesh, part.n
        local wc = call(m, "get_BlendShapeChannelWeightCount")
        local length = call(call(m, "get_ChannelWeightList"), "get_Length")
        local custom = part.has_writable
        if custom == nil then
            custom = false
            for i, name in ipairs(part.names) do
                if Signals.writable(name, m, i - 1) then custom = true; break end
            end
        end
        if custom and type(wc) == "number" and wc >= 0 and wc < n
            and type(length) == "number" and length >= n and call(m, "get_BlendShapeChannelNum") == n
            and call(m, "get_MeshReady") == true and call(m, "get_BlendShapeReleasedBuffers") ~= true then
            call(m, "set_BlendShapeChannelWeightCount", n)
            wc = call(m, "get_BlendShapeChannelWeightCount")
        end
        part.weights = { count = wc, length = length, channels = n }
    end
end

-- The live view samples every 0.2 s: reuse its handle while the head and the parts stay the same.
local snapshot_cache
function A.native_snapshot()
    if not A.primary_ready() then snapshot_cache = nil; return nil, "角色头部尚未就绪" end
    local h = head()
    local sig = A.signature(A.primary_root())
    local calibration = calibrations[actor_of_path(path(h))]
    local c = snapshot_cache
    if not (c and c.sig == sig and c.face == h:get_address() and c.calibration == calibration) then
        c = {sig = sig, face = h:get_address(), calibration = calibration}
        snapshot_cache = c
    end
    local ok, result = pcall(Signals.snapshot, h, calibration, c)
    if not ok then snapshot_cache = nil; error(result, 0) end
    result.source = sig
    return result
end

function A.probe(output)
    local lines = { "RE4R " .. tostring(actor_of_path(path(head()))) .. "; native inputs are read-only" }
    local input = A.input.diagnostics()
    pcall(json.dump_file, "ShapeKeySystem\\re4r_input_status.json", input, 2)
    lines[#lines + 1] = A.input.status()
    lines[#lines + 1] = "cutscene playing: " .. tostring(Cutscene.playing())
    if not A.primary_ready() then return { "Player or supported head unavailable" } end
    local h = A.bind(head(), { Signals.raw.parse("jawOpen") })
    Signals.read(h, {}, 1)
    for name, state in pairs(h.status) do lines[#lines + 1] = name .. ": " .. state end
    table.sort(lines)
    local f = io.open(output, "w")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    return lines
end

function A.init(events)
    if not sdk.find_type_definition("chainsaw.CharacterManager") then return false, "找不到 chainsaw.CharacterManager" end
    T_MESH = sdk.typeof("via.render.Mesh")
    local ready, why = Cutscene.init()
    if not ready then return false, why end
    if events and events.rebuilt then
        local work = sdk.find_type_definition("chainsaw.TimelineEventWork")
        for _, name in ipairs({"play", "skip", "unload", "changeEventPhase"}) do
            local method = work and work:get_method(name)
            if method then sdk.hook(method, function()
                A.cache_end()
                Signals.release_deforms()
                events.rebuilt()
            end, nil) end
        end
        -- the model viewer swaps its figure through these; references go before the old one is destroyed
        local figures = sdk.find_type_definition("chainsaw.BonusContentsGuiManager.FigureGuiManager")
        for _, name in ipairs({"requestInstantiateModel", "requestDestroyInstantiatedModel"}) do
            local method = figures and figures:get_method(name)
            if method then sdk.hook(method, function() A.cache_end(); events.rebuilt() end, nil) end
        end
    end
    Conditions.init()
    Playback.configure(function()
        if not A.primary_ready() then return end
        local root = A.primary_root()
        return root:get_address(), A.signature(root)
    end)
    for _, actor in ipairs({"leon", "ada"}) do
        local ok, d = pcall(json.load_file, "ShapeKeySystem/builtin/re4/" .. actor .. ".json")
        if not ok then return false, L.f("%s 标定文件无法读取", actor) end
        local configured, valid, why = pcall(Signals.validate, d)
        if not configured then return false, L.f("%s 标定格式无效", actor) end
        if not valid then return false, why end
        calibrations[actor] = d
    end
    return Signals.configure(calibrations.leon)
end
-- Lookup results, including absent objects, live only within one engine callback.
local lookup
local absent = {}
function A.cache_begin() lookup = {} end
function A.cache_end() lookup, snapshot_cache = nil, nil end
local function memo(fn)
    local bucket = {}
    return function(key, second)
        if not lookup then return fn(key, second) end
        local group = lookup[bucket]
        if not group then group = {}; lookup[bucket] = group end
        local k, k2 = key == nil and absent or key, second == nil and absent or second
        local row = group[k]
        if not row then row = {}; group[k] = row end
        local value = row[k2]
        if value == nil then
            value = fn(key, second)
            if value == nil then value = absent end
            row[k2] = value
        end
        if value == absent then return nil end
        return value
    end
end
context, mesh, resource, path = memo(context), memo(mesh), memo(resource), memo(path)
resource_path = memo(resource_path)
head, figure_head = memo(head), memo(figure_head)
for _, name in ipairs({"primary_root", "primary_ready", "faces", "parts", "part_id", "instance_root", "signature", "channel_stamp"}) do
    A[name] = memo(A[name])
end
return A
