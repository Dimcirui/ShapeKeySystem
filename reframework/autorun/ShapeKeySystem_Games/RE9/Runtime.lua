-- ShapeKeySystem: RE9 player parts. Facial animation plays on part "10" whatever mesh a mod puts
-- there, so that part's Motion is the signal source; any part mesh may carry the custom keys.
--
-- Shadow copies, sticky props and weapon meshes are excluded. Engine objects are returned to the
-- caller; the lookup cache keeps them only until the engine callback ends.
local Perf = require("ShapeKeySystem_Core.Perf")
local R = {}
local mesh_type, motion_type, scene_type
R.FACE_PART = "10"
local EXCLUDED = {Shadow = true, ShadowBody = true, StickyPropObject = true}

-- 单次引擎回调内的查找缓存：场景、玩家根对象与面部只解析一次，回调结束即丢弃。
local memo, memo_token = nil, 0
function R.cache_begin() memo_token = memo_token + 1; memo = {token = memo_token} end
function R.cache_end() memo = nil end
-- 当前缓存窗口的编号，窗口外为 nil；只用于比较，不含引擎对象
function R.cache_token() return memo and memo.token end

function R.call(object, method, ...)
    if type(object)~='table'and type(object)~='userdata'then return nil end
    local ok, value = pcall(object.call, object, method, ...)
    if ok then return value end
end
local call = R.call
function R.address(object)
    if type(object)~='table'and type(object)~='userdata'then return nil end
    local ok, value = pcall(object.get_address, object)
    return ok and tostring(value) or nil
end
local function raw_address(object)
    if type(object)~='table'and type(object)~='userdata'then return nil end
    local ok, value = pcall(object.get_address, object)
    return ok and math.type(value) == "integer" and value or nil
end
function R.integer(value, cap)
    return type(value) == "number" and value >= 0 and value <= cap and value % 1 == 0
end
function R.component(go, kind) return call(go, "getComponent(System.Type)", kind) end
function R.mesh(tr) return R.component(call(tr, "get_GameObject"), mesh_type) end
function R.motion(tr) return R.component(call(tr, "get_GameObject"), motion_type) end
function R.name(tr) return call(call(tr, "get_GameObject"), "get_Name") end
function R.path(mesh)
    local path = call(call(mesh, "getMesh"), "get_ResourcePath")
    return type(path) == "string" and path:gsub("\\", "/"):lower():gsub("^@?/?", ""):gsub("%.mesh%.%d+$", ".mesh") or ""
end
local function current_scene()
    local manager = sdk.get_native_singleton("via.SceneManager")
    if not manager or not scene_type then return nil end
    local ok, scene = pcall(sdk.call_native_func, manager, scene_type, "get_CurrentScene")
    return ok and scene or nil
end
function R.scene()
    if not memo then return current_scene() end
    if memo.scene == nil then memo.scene = current_scene() or false end
    return memo.scene or nil
end
-- 可驱动的玩家角色：里昂 cp_A000、格蕾丝 cp_A100（场景搜索按此顺序）
R.ROOT_NAMES = {"cp_A000", "cp_A100"}
local ROOT_NAME = {}
for _, name in ipairs(R.ROOT_NAMES) do ROOT_NAME[name] = true end
local function drawn(go) return call(go, "get_Valid") == true and call(go, "get_DrawSelf") == true end
-- 当前玩家是其中之一时，CharacterManager 的玩家上下文直接给出根对象，省去按名字搜索整个场景
local function player_root()
    local ok, manager = pcall(sdk.get_managed_singleton, "app.CharacterManager")
    local go = ok and call(call(manager, "getPlayerContextRefFast"), "get_GameObject") or nil
    if go and ROOT_NAME[call(go, "get_Name")] and drawn(go) then return go end
end
local function find_root(scene)
    local started = os.clock()
    local go = not scene and player_root() or nil
    if not go then
        scene = scene or R.scene()
        for _, name in ipairs(R.ROOT_NAMES) do
            local found = call(scene, "findGameObject(System.String)", name)
            if drawn(found) then go = found; break end
        end
    end
    Perf.record("root_lookup", os.clock() - started)
    return go and call(go, "get_Transform")
end
function R.root(scene)
    if scene or not memo then return find_root(scene) end
    if memo.root == nil then memo.root = find_root() or false end
    return memo.root or nil
end
-- The face is the part the facial driver animates: a direct child named "10" with a skeleton.
function R.is_face(tr)
    if R.name(tr) ~= R.FACE_PART then return false end
    local count = call(R.motion(tr), "get_JointCount")
    return R.integer(count, 8192) and count > 0
end
function R.bounds(mesh)
    local cn = call(mesh, "get_BlendShapeChannelNum")
    local wc = call(mesh, "get_BlendShapeChannelWeightCount")
    local length = call(call(mesh, "get_ChannelWeightList"), "get_Length")
    if call(mesh, "get_MeshReady") ~= true or call(mesh, "get_BlendShapeEnable") ~= true
        or call(mesh, "get_BlendShapeReleasedBuffers") ~= false then return nil end
    if not R.integer(cn, 8192) or cn == 0 or not R.integer(wc, 8192)
        or not R.integer(length, 8192) or wc < cn or length < cn then return nil end
    return cn, wc, length
end

-- visit(child, index): index counts from 0 along the sibling chain
local function children(tr, visit)
    local child, seen, n = call(tr, "get_Child"), {}, 0
    while child and n < 256 do
        local id = R.address(child)
        if not id or seen[id] then break end
        seen[id], n = true, n + 1
        visit(child, n - 1)
        child = call(child, "get_Next")
    end
end

-- 上次找到的面部在根节点子链中的位置；只存地址字符串与序号，每次仍重新取对象并核对
local face_hint
local function find_face(current, root_address)
    local hint = face_hint
    if hint and hint.root == root_address then
        local child = call(current, "get_Child")
        for _ = 1, hint.index do child = call(child, "get_Next") end
        if child and R.address(child) == hint.face and R.is_face(child) then return child end
    end
    local face, index
    children(current, function(child, i)
        if not face and R.is_face(child) then face, index = child, i end
    end)
    face_hint = face and {root = root_address, index = index, face = R.address(face)} or nil
    return face
end

local function find_head()
    local scene = R.scene()
    local current = R.root()
    if not current then return nil end
    local root_address = R.address(current)
    local face = find_face(current, root_address)
    if not face then return nil end
    local motion = R.motion(face)
    local generation, count = call(motion, "get_SkeletonConstructCount"), call(motion, "get_JointCount")
    if not R.integer(generation, 0xFFFFFFFF) or not R.integer(count, 8192) then return nil end
    local id = table.concat({R.address(scene), root_address, R.address(face), R.address(motion),
        tostring(generation), tostring(count)}, ":")
    return {root = current, face = face, identity = id, root_address = root_address,
        motion = motion, generation = generation, count = count}
end
-- 缓存窗口内各调用方共享同一结果，不得修改或跨回调保存
function R.find(root)
    local head
    if not memo or memo.head == nil then
        local started = os.clock()
        head = find_head()
        Perf.record("face_lookup", os.clock() - started)
        if memo then memo.head = head or false end
    else head = memo.head or nil end
    if not head or root and R.address(root) ~= head.root_address then return nil end
    return head
end

-- Every player part below the root that may carry custom keys; Core keeps those with channels.
-- routes[i]: the child indices from the root to found[i].
function R.parts(root)
    local found, routes, visited, route = {}, {}, 0, {}
    local function visit(tr, depth)
        if depth > 8 or visited >= 256 then return end
        visited = visited + 1
        local go = call(tr, "get_GameObject")
        if EXCLUDED[call(go, "get_Name")] then return end
        if depth > 0 then
            local mesh = R.component(go, mesh_type)
            if mesh and not R.path(mesh):match("^character/wp/") then
                found[#found + 1] = tr
                routes[#found] = {table.unpack(route)}
            end
        end
        children(tr, function(child, index)
            route[depth + 1] = index
            visit(child, depth + 1)
            route[depth + 1] = nil
        end)
    end
    visit(root, 0)
    return found, routes
end

-- "character/ch/ch01/0100/40/01/ch0100_40_01.mesh" -> "ch0100_40_01"
function R.part_id(tr)
    local file = R.path(R.mesh(tr)):match("([^/]+)%.mesh$")
    return file or R.name(tr) or "?"
end

-- Part membership, channel counts and channel name lists: a mesh or resource swap, or an added key
-- part, rescans the rig. The second result holds the numeric routes R.routes_valid checks between
-- full reads (nil when a part has no readable address).
function R.parts_signature(root)
    local out, layout = {}, {}
    local parts, routes = R.parts(root)
    for i, tr in ipairs(parts) do
        local mesh = R.mesh(tr)
        local cn = call(mesh, "get_BlendShapeChannelNum")
        local names = R.integer(cn, 8192) and cn > 0 and R.address(call(mesh, "get_ChannelNameHash")) or "-"
        out[#out + 1] = (R.address(mesh) or "?") .. "/" .. tostring(cn) .. "/" .. names
        local transform, mesh_address = raw_address(tr), raw_address(mesh)
        if layout and transform and mesh_address then
            layout[#layout + 1] = {steps = routes[i], transform = transform, mesh = mesh_address}
        else layout = nil end
    end
    return table.concat(out, "|"), layout
end

-- Whether every route still reaches the same transform and mesh. Channel counts and name lists are
-- left to the full signature; writes check their own bounds in between.
function R.routes_valid(root, layout)
    local root_address = raw_address(root)
    if not root_address then return false end
    local native = rawget(_G, "sks_native")
    if type(native) == "table" and type(native.layout_walk) == "function" then
        local flat = layout.native
        if not flat then
            flat = {}
            for _, route in ipairs(layout) do
                flat[#flat + 1] = 0
                flat[#flat + 1] = #route.steps
                for _, index in ipairs(route.steps) do flat[#flat + 1] = index end
                flat[#flat + 1] = route.transform
                flat[#flat + 1] = route.mesh
            end
            layout.native = flat
        end
        local ok, same = pcall(native.layout_walk, root_address, 0, flat)
        if ok and type(same) == "boolean" then return same end
    end
    -- routes sharing a parent walk its sibling chain once: {[index] = node, last = highest index, route}
    local tree = layout.tree
    if not tree then
        tree = {last = -1}
        for _, route in ipairs(layout) do
            local node = tree
            for _, index in ipairs(route.steps) do
                if index > node.last then node.last = index end
                node[index] = node[index] or {last = -1}
                node = node[index]
            end
            node.route = route
        end
        layout.tree = tree
    end
    local function walk(tr, node)
        local route = node.route
        if route and (raw_address(tr) ~= route.transform or raw_address(R.mesh(tr)) ~= route.mesh) then return false end
        local child = node.last >= 0 and call(tr, "get_Child") or nil
        for index = 0, node.last do
            if not child then return false end
            if node[index] and not walk(child, node[index]) then return false end
            if index < node.last then child = call(child, "get_Next") end
        end
        return true
    end
    return walk(root, tree)
end

function R.init()
    scene_type = sdk.find_type_definition("via.SceneManager")
    if not scene_type or not sdk.find_type_definition("via.render.Mesh")
        or not sdk.find_type_definition("via.motion.Motion") then return false, "RE9 场景或网格类型不可用" end
    mesh_type, motion_type = sdk.typeof("via.render.Mesh"), sdk.typeof("via.motion.Motion")
    return mesh_type ~= nil and motion_type ~= nil
end
return R
