-- ShapeKeySystem: resolve the visible Leon head and its current buffer identity.
--
-- Supports both normal gameplay (cp_A000) and cutscenes / CG (ch0100_00, ch0100, etc.).
-- Learns strictly from cg_weapon_snap.lua:
-- - Traverses scene objects to store ALL character instances in cached_chars (keyed by Transform, NOT by name).
-- - Fully supports multiple instances with the same name (e.g. three ch0100_00 instances across camera cuts).
-- - Evaluates check_layer_cg per frame with zero lag (no recursive scene tree walks during frames).
-- - Scans scene only once on entering CG (or throttled periodic).
-- - Excludes Grace and non-Leon characters.
local R = {}
local mesh_type, motion_type, scene_type
local gui_field_canDemoSkip = nil

local function ensure_types()
    if not scene_type then scene_type = sdk.find_type_definition("via.SceneManager") end
    if not mesh_type then mesh_type = sdk.typeof("via.render.Mesh") end
    if not motion_type then motion_type = sdk.typeof("via.motion.Motion") end
end

local TARGET_CHARS = { "cp_a000", "ch0100", "ch01", "cp01", "cp_e800" }

local function sc(obj, method, ...)
    if type(obj) ~= 'table' and type(obj) ~= 'userdata' then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    if ok and value ~= nil then return value end
    if type(method) == "string" and method:find("%(%)$") then
        local clean = method:gsub("%(%)$", "")
        local ok2, value2 = pcall(obj.call, obj, clean, ...)
        if ok2 then return value2 end
    end
    if ok then return value end
end
R.call = sc
local call = sc

function R.address(object)
    if type(object) ~= 'table' and type(object) ~= 'userdata' then return nil end
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
    local gui_mgr = sdk.get_managed_singleton("app.GuiManager") or sdk.get_managed_singleton(sdk.game_namespace("GuiManager"))
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
        if gui_field_canDemoSkip then
            local ok, val = pcall(gui_field_canDemoSkip.get_data, gui_field_canDemoSkip, gui_mgr)
            if ok and val == true then return true end
        end
    end
    local tlm_mgr = sdk.get_managed_singleton("app.TimelineEventMediator") or sdk.get_managed_singleton(sdk.game_namespace("TimelineEventMediator"))
    if tlm_mgr then
        local ok, is_playing = pcall(tlm_mgr.call, tlm_mgr, "IsPlaying")
        if ok and is_playing == true then return true end
        local ok2, is_cutscene = pcall(tlm_mgr.call, tlm_mgr, "get_IsPlayingCutScene")
        if ok2 and is_cutscene == true then return true end
    end
    return false
end

local in_cutscene_state = false
local cutscene_end_time = 0

function R.is_in_cg_debounced()
    local now = os.clock()
    local cg_now = R.check_if_in_cg()
    if cg_now then
        cutscene_end_time = 0
        in_cutscene_state = true
        return true
    else
        if in_cutscene_state then
            if cutscene_end_time == 0 then cutscene_end_time = now end
            if now - cutscene_end_time < 0.8 then
                return true
            else
                in_cutscene_state = false
                return false
            end
        end
        return false
    end
end

-- Exact check_layer_cg from cg_weapon_snap.lua:
-- Bank 0, MotID >= 0, and (mot0 % 100 == 0 or mot0 == 0 or mot0 == 1)
function R.check_layer_cg(go)
    if not go then return false end
    ensure_types()
    local ok, result = pcall(function()
        if call(go, "get_DrawSelf") ~= true or call(go, "get_Valid") ~= true then return false end
        local motion = R.component(go, motion_type)
        if not motion then return false end
        local layer0 = call(motion, "getLayer", 0)
        if not layer0 then return false end
        local bank0 = call(layer0, "get_MotionBankID")
        local mot0  = call(layer0, "get_MotionID")
        return (bank0 == 0 and mot0 ~= nil and mot0 >= 0 and (mot0 % 100 == 0 or mot0 == 0 or mot0 == 1))
    end)
    return ok and result == true
end

function R.is_head(face)
    local go = call(face, "get_GameObject")
    if not go or call(go, "get_Name") == "Shadow" then return false end
    local gname = tostring(call(go, "get_Name") or "")
    if gname == "10" or gname:find("^ch0100_10") then return true end
    local p = R.path(R.mesh(face))
    return p == "character/ch/ch01/0100/10/00/ch0100_10_00.mesh"
        or p:find("ch0100_10") ~= nil
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

function R.is_part_drawn(face_tr, mesh)
    if not face_tr then return false end
    local go = call(face_tr, "get_GameObject")
    if not go or call(go, "get_Valid") ~= true then return false end

    -- Check GameObject: get_Draw() checks entire parent chain; get_DrawSelf() checks this node
    local ok_draw, d = pcall(go.call, go, "get_Draw")
    if ok_draw and d == false then return false end

    local ok_ds, ds = pcall(go.call, go, "get_DrawSelf")
    if ok_ds and ds == false then return false end

    -- Check Mesh component draw flag if available
    local m = mesh or R.mesh(face_tr)
    if m then
        local ok_m, md = pcall(m.call, m, "get_DrawDefault")
        if ok_m and md == false then return false end
    end

    return true
end

-- Find head inside character root (fast bounded search, cached by root address)
-- Requires the head part (部件) to be ACTUALLY DRAWN (is_part_drawn == true)
local cached_head_by_root = {}

local function find_head_in_root(current)
    if not current then return nil end
    local addr = R.address(current)
    local cached = cached_head_by_root[addr]
    if cached then
        if R.is_part_drawn(cached.face, cached.mesh) then
            local cn = R.bounds(cached.mesh)
            if cn then return cached end
        end
        cached_head_by_root[addr] = nil
    end

    local scene = R.scene()
    local found = nil
    local function check_face(tr)
        if not tr then return false end
        local a = R.address(tr)
        local mesh = R.mesh(tr)
        if mesh and R.is_head(tr) and R.is_part_drawn(tr, mesh) then
            local cn, wc, length = R.bounds(mesh)
            local motion = R.component(call(tr, "get_GameObject"), motion_type)
                or R.component(call(current, "get_GameObject"), motion_type)
            local generation = motion and call(motion, "get_SkeletonConstructCount") or 1
            if cn and R.integer(generation, 0xFFFFFFFF) then
                local id = table.concat({R.address(scene), addr, a, R.address(mesh),
                    tostring(generation), tostring(cn), tostring(wc), tostring(length)}, ":")
                found = {root = current, face = tr, mesh = mesh, count = cn, identity = id}
                return true
            end
        end
        return false
    end

    -- Fast Pass 1: Direct children scan (RE Engine parts are almost always direct children of the character root)
    local direct_child = call(current, "get_Child")
    while direct_child and not found do
        if check_face(direct_child) then break end
        direct_child = call(direct_child, "get_Next")
    end

    -- Pass 2: Bounded search for nested parts (depth <= 4, max 512 nodes, skipping weapons/items/effects)
    if not found then
        local visited = 0
        local function search_head(tr, depth)
            if not tr or depth > 4 or visited >= 512 or found then return end
            visited = visited + 1
            if check_face(tr) then return end

            local go = call(tr, "get_GameObject")
            local name = go and tostring(call(go, "get_Name") or ""):lower() or ""
            -- Skip descending into weapon, fluid, obstacle, shadow, or ampoule sub-trees
            if name:find("^arm") or name:find("fluid") or name:find("obstacle")
                or name:find("shadow") or name:find("ampoule") or name:find("stamp") then
                return
            end

            local c = call(tr, "get_Child")
            while c and not found do
                search_head(c, depth + 1)
                c = call(c, "get_Next")
            end
        end
        search_head(current, 0)
    end

    if found then
        cached_head_by_root[addr] = found
        return found
    end
    return nil
end

local function camera_position()
    ensure_types()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not scene_type then return nil end
    local ok, cam = pcall(sdk.call_native_func, sm, scene_type, "get_MainCamera")
    if not ok or not cam then return nil end
    local go = call(cam, "get_GameObject")
    local tr = go and call(go, "get_Transform")
    return tr and call(tr, "get_Position")
end

local function dist_sq(p1, p2)
    if not p1 or not p2 then return 999999 end
    local dx = (p1.x or 0) - (p2.x or 0)
    local dy = (p1.y or 0) - (p2.y or 0)
    local dz = (p1.z or 0) - (p2.z or 0)
    return dx*dx + dy*dy + dz*dz
end

-- Candidate characters pool (maintains ALL character instances, including multiple instances with the same name)
local cached_chars = {}   -- list of { name = string, go = GameObject, transform = Transform, lower = string }
local has_scanned_cg = false
local last_scan_time = 0
local last_scene_address = nil

local function scan_scene_characters(scene)
    cached_chars = {}
    local seen = {}

    -- Explicitly ensure cp_A000 is in candidate pool from the start (matches cg_weapon_snap.lua priority)
    local p_go = call(scene, "findGameObject(System.String)", "cp_A000")
    if p_go and call(p_go, "get_Valid") == true then
        local p_tr = call(p_go, "get_Transform")
        local addr = p_tr and R.address(p_tr)
        if addr and not seen[addr] then
            seen[addr] = true
            cached_chars[#cached_chars + 1] = {
                name = "cp_A000",
                go = p_go,
                transform = p_tr,
                lower = "cp_a000"
            }
        end
    end

    local function scan_objects(cur, depth)
        while cur do
            if depth > 100 then return end
            local go = call(cur, "get_GameObject")
            if go then
                local name = tostring(call(go, "get_Name") or "")
                local lower = name:lower()

                -- Match Leon prefixes, exclude Grace
                local is_candidate = false
                if not (lower:find("cp_a100") or lower:find("ch0200") or lower:find("ch02") or lower:find("cp_a110") or lower:find("cp_e900") or lower:find("ch0250")) then
                    for _, pfx in ipairs(TARGET_CHARS) do
                        if lower:find(pfx) then
                            is_candidate = true
                            break
                        end
                    end
                end

                if is_candidate then
                    -- Parent must NOT be a character (ensures we only pick true character roots, not accessories/meshes)
                    local p_t = call(cur, "get_Parent")
                    local p_go = p_t and call(p_t, "get_GameObject")
                    local p_name = p_go and tostring(call(p_go, "get_Name") or ""):lower() or ""
                    local parent_is_char = false
                    for _, pfx in ipairs(TARGET_CHARS) do
                        if p_name:find(pfx) then
                            parent_is_char = true
                            break
                        end
                    end

                    if not parent_is_char then
                        local addr = R.address(cur)
                        if addr and not seen[addr] then
                            -- Character root MUST have arm hand joints
                            local j_rhand = call(cur, "getJointByName", "R_Arm_Hand")
                            local j_lhand = call(cur, "getJointByName", "L_Arm_Hand")
                            if j_rhand or j_lhand then
                                seen[addr] = true
                                cached_chars[#cached_chars + 1] = {
                                    name = name,
                                    go = go,
                                    transform = cur,
                                    lower = lower
                                }
                            end
                        end
                    end
                end
            end

            local child = call(cur, "get_Child")
            if child then scan_objects(child, depth + 1) end
            cur = call(cur, "get_Next")
        end
    end

    local first = call(scene, "get_FirstTransform")
    if first then scan_objects(first, 0) end
    last_scan_time = os.clock()
end

function R.invalidate_root_cache()
    cached_chars = {}
    cached_head_by_root = {}
    has_scanned_cg = false
    last_scan_time = 0
end

function R.root(scene)
    ensure_types()
    local s = scene or R.scene()
    if not s then return nil end

    local s_addr = R.address(s)
    if s_addr ~= last_scene_address then
        last_scene_address = s_addr
        R.invalidate_root_cache()
    end

    local now = os.clock()
    local in_cg = R.is_in_cg_debounced()

    if in_cg then
        -- In CG: Scan ONCE upon entering cutscene
        if not has_scanned_cg or #cached_chars == 0 then
            scan_scene_characters(s)
            has_scanned_cg = true
        end

        local cam_pos = camera_position()
        local active_candidates = {}

        -- Collect all candidates that are drawn and valid and pass check_layer_cg
        for _, c in ipairs(cached_chars) do
            if call(c.go, "get_Valid") == true and call(c.go, "get_DrawSelf") == true then
                if R.check_layer_cg(c.go) then
                    local head = find_head_in_root(c.transform)
                    if head then
                        local pos = call(c.transform, "get_Position")
                        local d = dist_sq(pos, cam_pos)
                        -- Slight bias to player cp_A000 so if camera is equidistant, player wins
                        if c.name:find("cp_A000") or c.lower:find("cp_a000") then
                            d = d - 2.0
                        end
                        active_candidates[#active_candidates + 1] = {
                            transform = c.transform,
                            dist = d,
                            name = c.name
                        }
                    end
                end
            end
        end

        if #active_candidates > 0 then
            table.sort(active_candidates, function(a, b) return a.dist < b.dist end)
            return active_candidates[1].transform
        end

        -- If none satisfies check_layer_cg, check cp_A000 directly
        local p_go = call(s, "findGameObject(System.String)", "cp_A000")
        if p_go and call(p_go, "get_Valid") == true and call(p_go, "get_DrawSelf") == true then
            local p_tr = call(p_go, "get_Transform")
            if find_head_in_root(p_tr) then
                return p_tr
            end
        end

        -- Fallback: any visible candidate with head, closest to camera
        local fallback_candidates = {}
        for _, c in ipairs(cached_chars) do
            if call(c.go, "get_Valid") == true and call(c.go, "get_DrawSelf") == true then
                if find_head_in_root(c.transform) then
                    local pos = call(c.transform, "get_Position")
                    fallback_candidates[#fallback_candidates + 1] = {
                        transform = c.transform,
                        dist = dist_sq(pos, cam_pos)
                    }
                end
            end
        end
        if #fallback_candidates > 0 then
            table.sort(fallback_candidates, function(a, b) return a.dist < b.dist end)
            return fallback_candidates[1].transform
        end

        -- Refresh pool if 3 seconds elapsed without hit
        if now - last_scan_time > 3.0 then
            scan_scene_characters(s)
        end
    else
        has_scanned_cg = false
        -- Gameplay: fast O(1) hash lookup of player cp_A000
        local p_go = call(s, "findGameObject(System.String)", "cp_A000")
        if p_go and call(p_go, "get_Valid") == true and call(p_go, "get_DrawSelf") == true then
            return call(p_go, "get_Transform")
        end
        -- Fallback to CharacterManager
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        if cm then
            local pc = call(cm, "getPlayerContextRefFast")
            local pc_go = pc and call(pc, "get_GameObject")
            if pc_go and call(pc_go, "get_Valid") == true and call(pc_go, "get_DrawSelf") == true then
                return call(pc_go, "get_Transform")
            end
        end
        -- Fallback gameplay candidate
        for _, name in ipairs({ "ch0100_00", "ch0100", "cp01" }) do
            local go = call(s, "findGameObject(System.String)", name)
            if go and call(go, "get_Valid") == true and call(go, "get_DrawSelf") == true then
                return call(go, "get_Transform")
            end
        end
    end

    return nil
end

function R.find(root)
    local current = root or R.root()
    if not current then return nil end
    return find_head_in_root(current)
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
