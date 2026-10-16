-- ShapeKeySystem: player discovery, actor calibration and shape-key targets for RE4R.
--
-- The current player's head selects its calibration. Objects are resolved per call;
-- rig handles are released when the topology changes.
local Signals = require("ShapeKeySystem_Games.RE4R.Signals")
local Conditions = require("ShapeKeySystem_Games.RE4R.Conditions")
local Playback = require("ShapeKeySystem_Games.RE4R.Playback")
local A = { id = "re4", name = "Resident Evil 4", strict_bounds = true, hash_names = true, hash_item_only = true,
    rewrite_active_weights = true,
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
    return actor_of_path(path(tr)) ~= nil
        and call(tr, "getJointByName(System.String)", "C_Chin") ~= nil
end
function A.primary_ready()
    local h = head()
    return A.primary_root() ~= nil and h ~= nil and A.is_face(h)
end
function A.faces() local h = head(); return h and {h} or {} end
function A.face_root(_, root) return root end
function A.face_rank() return 1 end
function A.is_part() return false end
function A.parts(root)
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
    visit(head(), 0); visit(root, 0)
    return out
end
function A.part_id(tr)
    local p = path(tr):match("([^/]+)%.mesh")
    local name = call(call(tr, "get_GameObject"), "get_Name") or "part"
    return (p or name):gsub("[^%w_%-]", "_")
end
function A.model_of(part)
    if part == "leon" or part == "ada" then return part, part end
    local id = part:match("^(cha%d%d%d)_")
    local actor = id and actor_of_path("/" .. id .. "/") or actor_of_path(path(head()))
    return actor or "leon", part
end
function A.representative_of(part) return (A.model_of(part)) end
function A.eye_joints(face)
    return {L = call(face, "getJointByName(System.String)", "L_Eye"),
            R = call(face, "getJointByName(System.String)", "R_Eye")}
end
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
function A.gate()
    if not A.primary_ready() then return false, "Player or supported head unavailable" end
    return true
end

-- Core passes only current targets after checking the player's signature and readiness.
function A.prepare_mesh(m) call(m, "set_LodLevel", 0) end

-- Called during a stable LateUpdate scan. Ada's custom head uses the same buffer preparation
-- as extra meshes; Leon keeps its engine-owned head count.
function A.prepare_parts(parts)
    local hm = mesh(head())
    for _, part in ipairs(parts) do
        local m, n = part.mesh, part.n
        local wc = call(m, "get_BlendShapeChannelWeightCount")
        local length = call(call(m, "get_ChannelWeightList"), "get_Length")
        local custom = false
        for i, name in ipairs(part.names) do
            if Signals.writable(name, m, i - 1) then custom = true; break end
        end
        local same_head = hm and call(hm, "get_GameObject") == call(m, "get_GameObject")
        local ada_head = same_head and actor_of_path(path(head())) == "ada"
        if (not same_head or ada_head) and custom and type(wc) == "number" and wc >= 0 and wc < n
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
    if not A.primary_ready() then return { "Player or supported head unavailable" } end
    local h = A.bind(head(), { Signals.raw.parse("jawOpen") })
    Signals.read(h, {}, 1)
    for name, state in pairs(h.status) do lines[#lines + 1] = name .. ": " .. state end
    table.sort(lines)
    local f = io.open(output, "w")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    return lines
end

function A.init()
    if not sdk.find_type_definition("chainsaw.CharacterManager") then return false, "找不到 chainsaw.CharacterManager" end
    T_MESH = sdk.typeof("via.render.Mesh")
    Conditions.init()
    Playback.configure(function()
        if not A.primary_ready() then return end
        local root = A.primary_root()
        return root:get_address(), A.signature(root)
    end)
    for _, actor in ipairs({"leon", "ada"}) do
        local ok, d = pcall(json.load_file, "ShapeKeySystem/builtin/re4/" .. actor .. ".json")
        if not ok then return false, actor .. " 标定文件无法读取" end
        local configured, valid, why = pcall(Signals.validate, d)
        if not configured then return false, actor .. " 标定格式无效" end
        if not valid then return false, why end
        calibrations[actor] = d
    end
    return Signals.configure(calibrations.leon)
end
return A
