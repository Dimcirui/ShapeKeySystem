-- ShapeKeySystem: resolve the visible Leon head and its current buffer identity.
--
-- Supports both normal gameplay (cp_A000) and cutscenes / CG (ch0100_00, ch0100, etc.).
-- Engine objects are returned to the caller and never retained by this module.
local R = {}
local mesh_type, motion_type, scene_type
local gui_field_canDemoSkip = nil

local function ensure_types()
    if not scene_type then scene_type = sdk.find_type_definition("via.SceneManager") end
    if not mesh_type then mesh_type = sdk.typeof("via.render.Mesh") end
    if not motion_type then motion_type = sdk.typeof("via.motion.Motion") end
end

local TARGET_PREFIXES = { "ch0100", "ch01", "cp_a000" }

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
function R.mesh(face)
    ensure_types()
    return R.component(call(face, "get_GameObject"), mesh_type)
end

function R.path(mesh)
    local path = call(call(mesh, "getMesh"), "get_ResourcePath")
    return type(path) == "string" and path:gsub("\\", "/"):lower():gsub("^@?/?", ""):gsub("%.mesh%.%d+$", ".mesh") or ""
end

function R.scene()
    ensure_types()
    local manager = sdk.get_native_singleton("via.SceneManager")
    if not manager or not scene_type then return nil end
    local ok, scene = pcall(sdk.call_native_func, manager, scene_type, "get_CurrentScene")
    return ok and scene or nil
end

function R.check_if_in_cg()
    -- 1. Check GuiManager canDemoSkip (fast, definitive in RE9)
    local gui_mgr = sdk.get_managed_singleton(sdk.game_namespace("GuiManager"))
    if gui_mgr then
        if not gui_field_canDemoSkip then
            local td = gui_mgr:get_type_definition()
            local fields = td and td:get_fields() or {}
            for _, f in ipairs(fields) do
                if f:get_name():find("canDemoSkip") then
                    gui_field_canDemoSkip = f
                    break
                end
            end
        end
        if gui_field_canDemoSkip and gui_field_canDemoSkip:get_data(gui_mgr) == true then
            return true
        end
    end
    -- 2. Check TimelineEventMediator IsPlaying / IsPlayingCutScene
    local tlm_mgr = sdk.get_managed_singleton(sdk.game_namespace("TimelineEventMediator"))
    if tlm_mgr then
        local ok, is_playing = pcall(tlm_mgr.call, tlm_mgr, "IsPlaying")
        if ok and is_playing == true then return true end
        local ok2, is_cutscene = pcall(tlm_mgr.call, tlm_mgr, "get_IsPlayingCutScene")
        if ok2 and is_cutscene == true then return true end
    end
    return false
end

function R.check_layer_cg(go)
    if not go then return false end
    local ok, result = pcall(function()
        if call(go, "get_DrawSelf") ~= true or call(go, "get_Valid") ~= true then return false end
        local motion = R.component(go, motion_type)
        if not motion then return false end
        local layer0 = call(motion, "getLayer", 0)
        if not layer0 then return false end
        local bank0 = call(layer0, "get_MotionBankID")
        local mot0  = call(layer0, "get_MotionID")
        return bank0 == 0 and mot0 ~= nil and mot0 >= 0 and (mot0 % 100 == 0 or mot0 == 0)
    end)
    return ok and result == true
end

function R.is_head(face)
    local go = call(face, "get_GameObject")
    if not go or call(go, "get_Name") == "Shadow" then return false end
    local p = R.path(R.mesh(face))
    local gname = tostring(call(go, "get_Name") or "")
    return p == "character/ch/ch01/0100/10/00/ch0100_10_00.mesh"
        or p:find("ch0100_10_00%.mesh") ~= nil
        or gname == "10" or gname == "ch0100_10_00"
end

function R.bounds(mesh)
    local cn = call(mesh, "get_BlendShapeChannelNum")
    local wc = call(mesh, "get_BlendShapeChannelWeightCount")
    local length = call(call(mesh, "get_ChannelWeightList"), "get_Length")
    if call(mesh, "get_MeshReady") ~= true then return nil end
    if call(mesh, "get_BlendShapeEnable") ~= true then
        pcall(mesh.call, mesh, "set_BlendShapeEnable", true)
        if call(mesh, "get_BlendShapeEnable") ~= true then return nil end
    end
    if call(mesh, "get_BlendShapeReleasedBuffers") == true then return nil end
    if not R.integer(cn, 8192) or cn == 0 or not R.integer(wc, 8192)
        or not R.integer(length, 8192) or wc < cn or length < cn then return nil end
    return cn, wc, length
end

local function has_leon_head_mesh(tr)
    if not tr then return false end
    local seen, visited = {}, 0
    local function check_mesh(node, depth)
        if not node or depth > 8 or visited > 128 then return false end
        local addr = R.address(node)
        if not addr or seen[addr] then return false end
        seen[addr], visited = true, visited + 1
        local go = call(node, "get_GameObject")
        if go and call(go, "get_Name") ~= "Shadow" then
            local m = R.mesh(node)
            if m then
                local p = R.path(m)
                local gname = tostring(call(go, "get_Name") or "")
                if p == "character/ch/ch01/0100/10/00/ch0100_10_00.mesh"
                    or p:find("ch0100_10_00%.mesh") ~= nil
                    or gname == "10" or gname == "ch0100_10_00" then
                    return true
                end
            end
        end
        local child = call(node, "get_Child")
        while child do
            if check_mesh(child, depth + 1) then return true end
            child = call(child, "get_Next")
        end
        return false
    end
    return check_mesh(tr, 0)
end

local function find_best_root(scene, in_cg)
    local first = call(scene, "get_FirstTransform")
    if not first then return nil end

    local candidates = {}
    local visited = 0

    local function walk(tr, depth)
        if not tr or depth > 10 or visited > 800 then return end
        visited = visited + 1
        local go = call(tr, "get_GameObject")
        if go then
            local name = tostring(call(go, "get_Name") or "")
            local lower = name:lower()

            local is_candidate = false
            for _, pfx in ipairs(TARGET_PREFIXES) do
                if lower:find("^" .. pfx) then
                    is_candidate = true
                    break
                end
            end

            if is_candidate then
                local p_tr = call(tr, "get_Parent")
                local p_go = p_tr and call(p_tr, "get_GameObject")
                local p_name = p_go and tostring(call(p_go, "get_Name") or ""):lower() or ""
                local parent_is_candidate = false
                for _, pfx in ipairs(TARGET_PREFIXES) do
                    if p_name:find("^" .. pfx) then
                        parent_is_candidate = true
                        break
                    end
                end

                if not parent_is_candidate and call(go, "get_Valid") == true and call(go, "get_DrawSelf") == true then
                    -- Hard requirement: MUST contain Leon's head mesh!
                    if has_leon_head_mesh(tr) then
                        local score = 100
                        local is_cg_layer = R.check_layer_cg(go)
                        local is_ch01 = lower:find("^ch01") ~= nil
                        local is_cp_a = lower:find("^cp_a000") ~= nil

                        if in_cg then
                            if is_ch01 then score = score + 50 end
                            if is_cg_layer then score = score + 30 end
                        else
                            if is_cp_a then score = score + 50 end
                        end

                        candidates[#candidates + 1] = { tr = tr, score = score, name = name }
                    end
                end
            end
        end

        local child = call(tr, "get_Child")
        while child do
            walk(child, depth + 1)
            child = call(child, "get_Next")
        end
    end

    local cur = first
    while cur do
        walk(cur, 0)
        cur = call(cur, "get_Next")
    end

    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    return candidates[1].tr
end

local cached_root = nil
local cached_in_cg = nil
local last_cache_time = 0

function R.invalidate_root_cache()
    cached_root = nil
    cached_in_cg = nil
end

function R.root(scene)
    local s = scene or R.scene()
    if not s then return nil end

    local in_cg = R.check_if_in_cg()
    local now = os.clock()

    if cached_in_cg ~= in_cg then
        cached_root = nil
        cached_in_cg = in_cg
    end

    if cached_root then
        local go = call(cached_root, "get_GameObject")
        if go and call(go, "get_Valid") == true and call(go, "get_DrawSelf") == true and has_leon_head_mesh(cached_root) then
            if not in_cg or (now - last_cache_time < 1.5) then
                return cached_root
            end
        end
        cached_root = nil
    end

    if not in_cg then
        local p_go = call(s, "findGameObject(System.String)", "cp_A000")
        if p_go and call(p_go, "get_Valid") == true and call(p_go, "get_DrawSelf") == true then
            local tr = call(p_go, "get_Transform")
            if has_leon_head_mesh(tr) then
                cached_root = tr
                last_cache_time = now
                return cached_root
            end
        end
    end

    local best = find_best_root(s, in_cg)
    if best then
        cached_root = best
        last_cache_time = now
        return cached_root
    end

    local fallback_go = call(s, "findGameObject(System.String)", "cp_A000")
    if fallback_go and call(fallback_go, "get_Valid") == true and call(fallback_go, "get_DrawSelf") == true then
        local tr = call(fallback_go, "get_Transform")
        if has_leon_head_mesh(tr) then
            cached_root = tr
            last_cache_time = now
            return cached_root
        end
    end

    return nil
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
                or R.component(call(current, "get_GameObject"), motion_type)
            local generation = motion and call(motion, "get_SkeletonConstructCount") or 1
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
    if #found >= 1 then return found[1] end
end

local function hook_timeline_reset()
    local rst_t = sdk.find_type_definition("app.TimelineEventResetSimulation")
    if rst_t then
        local start_m = rst_t:get_method("start")
        if start_m then
            sdk.hook(start_m, function(args)
                R.invalidate_root_cache()
            end, nil)
        end
    end
end

function R.init()
    ensure_types()
    pcall(hook_timeline_reset)
    return mesh_type ~= nil and motion_type ~= nil and scene_type ~= nil
end
return R
