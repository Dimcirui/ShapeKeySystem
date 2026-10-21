-- ShapeKeySystem: resolve the visible Leon head and its current buffer identity.
--
-- Only the gameplay head under `cp_A000` is supported. Shadow and weapon trees are excluded.
-- Engine objects are returned to the caller and never retained by this module.
local R = {}
local mesh_type, motion_type, scene_type

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
function R.mesh(face) return R.component(call(face, "get_GameObject"), mesh_type) end
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
function R.is_head(face)
    local go = call(face, "get_GameObject")
    return call(go, "get_Name") ~= "Shadow"
        and R.path(R.mesh(face)) == "character/ch/ch01/0100/10/00/ch0100_10_00.mesh"
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

function R.find(root)
    local scene = R.scene()
    local current = R.root(scene)
    if not current or root and R.address(root) ~= R.address(current) then return nil end
    local found, seen, visited = {}, {}, 0
    local function visit(tr, depth)
        local address = R.address(tr)
        if not address or seen[address] or depth > 8 or visited >= 256 then return end
        seen[address], visited = true, visited + 1
        local mesh = R.mesh(tr)
        if R.path(mesh):match("^character/wp/") then return end
        if R.is_head(tr) then
            local cn, wc, length = R.bounds(mesh)
            local motion = R.component(call(tr, "get_GameObject"), motion_type)
            local generation = call(motion, "get_SkeletonConstructCount")
            if cn and R.integer(generation, 0xFFFFFFFF) then
                local id = table.concat({R.address(scene), R.address(current), address, R.address(mesh),
                    tostring(generation), tostring(cn), tostring(wc), tostring(length)}, ":")
                found[#found + 1] = {root = current, face = tr, mesh = mesh, count = cn, identity = id}
            end
        end
        local child, siblings, n = call(tr, "get_Child"), {}, 0
        while child and n < 128 do
            local id = R.address(child)
            if not id or siblings[id] then break end
            siblings[id], n = true, n + 1
            visit(child, depth + 1)
            child = call(child, "get_Next")
        end
    end
    visit(current, 0)
    if #found == 1 then return found[1] end
end

function R.init()
    scene_type = sdk.find_type_definition("via.SceneManager")
    if not scene_type or not sdk.find_type_definition("via.render.Mesh")
        or not sdk.find_type_definition("via.motion.Motion") then return false, "RE9 场景或网格类型不可用" end
    mesh_type, motion_type = sdk.typeof("via.render.Mesh"), sdk.typeof("via.motion.Motion")
    return mesh_type ~= nil and motion_type ~= nil
end
return R
