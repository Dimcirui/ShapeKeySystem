-- ShapeKeySystem: player discovery, actor calibration and shape-key targets for RE4R.
--
-- The current player's head selects its calibration. Objects are resolved per call;
-- rig handles are released when the topology changes.
local Signals = require("ShapeKeySystem_Games.RE4R.Signals")
local NativeFace = require("ShapeKeySystem_Games.RE4R.NativeFace")
local BoneHold = require("ShapeKeySystem_Games.RE4R.BoneHold")
local Conditions = require("ShapeKeySystem_Games.RE4R.Conditions")
local Playback = require("ShapeKeySystem_Games.RE4R.Playback")
local Cutscene = require("ShapeKeySystem_Games.RE4R.Cutscene")
local L = require("ShapeKeySystem_Core.I18n")
local A = { id = "re4", name = "Resident Evil 4", strict_bounds = true, hash_names = true, hash_item_only = true,
    rewrite_active_weights = true, scene_search = false, scoped_bindings = true,
    conditions = Conditions,
    playback = Playback,
    input = require("ShapeKeySystem_Games.RE4R.Input"),
    terms = { primary = "主角色", part = "部件" }, raw = Signals.raw,
    read = Signals.read, channel_writable = Signals.writable }
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
local function path(tr)
    local p = call(call(mesh(tr), "getMesh"), "get_ResourcePath")
    return type(p) == "string" and p:gsub("\\", "/"):lower() or ""
end
local function head()
    local ctx = context()
    local go = call(call(call(ctx, "get_BodyUpdater"), "get_HeadMotion"), "get_GameObject")
        or call(ctx, "get_HeadGameObject")
    return transform(go)
end
local function actor_of_path(p)
    if p:find("/cha000/", 1, true) then return "leon" end
    for _, id in ipairs({"cha200", "cha800", "cha801", "cha803"}) do
        if p:find("/" .. id .. "/", 1, true) then return "ada" end
    end
end

function A.bind(face, keys)
    return Signals.bind(face, keys, calibrations[actor_of_path(path(face))])
end

function A.primary_root()
    local ctx = context()
    return transform(call(ctx, "get_BodyGameObject") or call(ctx, "get_GameObject"))
end
function A.is_face(tr)
    local p = path(tr)
    -- Head identity follows its actor and mesh slot; replacement rigs may omit individual face joints.
    return actor_of_path(p) ~= nil and p:match("/cha%d%d%d_1[01]%.mesh") ~= nil
end
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
            local p, who = path(child), actor_of_path(path(child))
            if who and who ~= actor then foreign = true end
            if who == actor and p:match("/cha%d%d%d_00%.mesh") then body = true end
            child = call(child, "get_Next")
        end
        if foreign then break end
        if body then return parent end
        node = parent
    end
    return face
end

function A.face_root(face, root)
    return face == head() and root or A.instance_root(face)
end

function A.additional_faces()
    local result, seen = {}, {}
    local player = head()
    local owned = {}
    local root = A.primary_root()
    if root then
        for _, part in ipairs(A.parts(root)) do owned[part:get_address()] = true end
    end
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local components = scene and scene:call("findComponents(System.Type)", sdk.typeof("via.motion.Motion"))
    if not components then return result end
    for i = 0, components:call("get_Length") - 1 do
        local component = components:call("GetValue(System.Int32)", i)
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
function A.face_rank(face) return path(face):match("_10%.mesh") and 2 or 1 end
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
    local actor = id and actor_of_path("/" .. id .. "/") or actor_of_path(path(head()))
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
function A.signature(root)
    local out = {}
    for _, tr in ipairs(A.parts(root)) do
        local m = mesh(tr)
        local ok, addr = pcall(m.get_address, m)
        out[#out+1] = A.part_id(tr) .. "@" .. tostring(ok and addr or "-") .. ":" .. tostring(call(m, "get_BlendShapeChannelNum"))
    end
    table.sort(out)
    return table.concat(out, "|")
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
        local custom = false
        for i, name in ipairs(part.names) do
            if Signals.writable(name, m, i - 1) then custom = true; break end
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

function A.native_snapshot()
    if not A.primary_ready() then return nil, "角色头部尚未就绪" end
    local h = head()
    local result = Signals.snapshot(h, calibrations[actor_of_path(path(h))])
    result.source = A.signature(A.primary_root())
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
                Signals.release_deforms()
                events.rebuilt()
            end, nil) end
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
return A
