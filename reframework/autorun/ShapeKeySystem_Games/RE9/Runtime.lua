-- ShapeKeySystem: RE9 player parts. Facial animation plays on part "10" whatever mesh a mod puts
-- there, so that part's Motion is the signal source; any part mesh may carry the custom keys.
--
-- Shadow copies, sticky props and weapon meshes are excluded. Engine objects are returned to the
-- caller and never retained by this module.
local R = {}
local mesh_type, motion_type, scene_type
R.FACE_PART = "10"
local EXCLUDED = {Shadow = true, ShadowBody = true, StickyPropObject = true}

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
function R.scene()
    local manager = sdk.get_native_singleton("via.SceneManager")
    if not manager or not scene_type then return nil end
    local ok, scene = pcall(sdk.call_native_func, manager, scene_type, "get_CurrentScene")
    return ok and scene or nil
end
function R.root(scene)
    local go = call(scene or R.scene(), "findGameObject(System.String)", "cp_A000")
    if call(go, "get_Valid") ~= true or call(go, "get_DrawSelf") ~= true then return nil end
    return call(go, "get_Transform")
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

local function children(tr, visit)
    local child, seen, n = call(tr, "get_Child"), {}, 0
    while child and n < 256 do
        local id = R.address(child)
        if not id or seen[id] then break end
        seen[id], n = true, n + 1
        visit(child)
        child = call(child, "get_Next")
    end
end

function R.find(root)
    local scene = R.scene()
    local current = R.root(scene)
    if not current or root and R.address(root) ~= R.address(current) then return nil end
    local face
    children(current, function(child) if not face and R.is_face(child) then face = child end end)
    if not face then return nil end
    local motion = R.motion(face)
    local generation, count = call(motion, "get_SkeletonConstructCount"), call(motion, "get_JointCount")
    if not R.integer(generation, 0xFFFFFFFF) or not R.integer(count, 8192) then return nil end
    local id = table.concat({R.address(scene), R.address(current), R.address(face), R.address(motion),
        tostring(generation), tostring(count)}, ":")
    return {root = current, face = face, identity = id}
end

-- Every player part below the root that may carry custom keys; Core keeps those with channels.
function R.parts(root)
    local found, visited = {}, 0
    local function visit(tr, depth)
        if depth > 8 or visited >= 256 then return end
        visited = visited + 1
        if EXCLUDED[R.name(tr)] then return end
        if depth > 0 then
            local mesh = R.mesh(tr)
            if mesh and not R.path(mesh):match("^character/wp/") then found[#found + 1] = tr end
        end
        children(tr, function(child) visit(child, depth + 1) end)
    end
    visit(root, 0)
    return found
end

-- "character/ch/ch01/0100/40/01/ch0100_40_01.mesh" -> "ch0100_40_01"
function R.part_id(tr)
    local file = R.path(R.mesh(tr)):match("([^/]+)%.mesh$")
    return file or R.name(tr) or "?"
end

-- Part membership and channel counts: a mesh swap or an added key part rescans the rig.
function R.parts_signature(root)
    local out = {}
    for _, tr in ipairs(R.parts(root)) do
        local mesh = R.mesh(tr)
        out[#out + 1] = (R.address(mesh) or "?") .. "/" .. tostring(call(mesh, "get_BlendShapeChannelNum"))
    end
    return table.concat(out, "|")
end

function R.init()
    scene_type = sdk.find_type_definition("via.SceneManager")
    if not scene_type or not sdk.find_type_definition("via.render.Mesh")
        or not sdk.find_type_definition("via.motion.Motion") then return false, "RE9 场景或网格类型不可用" end
    mesh_type, motion_type = sdk.typeof("via.render.Mesh"), sdk.typeof("via.motion.Motion")
    return mesh_type ~= nil and motion_type ~= nil
end
return R
