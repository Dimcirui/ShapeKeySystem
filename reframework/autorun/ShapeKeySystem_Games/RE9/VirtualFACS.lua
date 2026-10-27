-- ShapeKeySystem: Virtual 96 RE9 FACS Evaluation Engine (Bulletproof)
-- Safely extracts official PlayerFacialAnimationDriver + _FacialMotion deforms
-- into a normalized 96-channel Virtual FACS table (00..95) by exact name hash.

local Hash = require("ShapeKeySystem_Core.NameHash")
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Defs = require("ShapeKeySystem_Games.RE9.Native96Def")
local Motion = require("ShapeKeySystem_Games.RE9.Motion")

local VF = {}

local DEF_LIST = Defs.DEFINITIONS
local NAME_TO_IDX = {}
local SHORT_TO_IDX = {}

-- Pre-calculate hashes for each definition
for idx = 0, #DEF_LIST do
    local item = DEF_LIST[idx]
    if item then
        NAME_TO_IDX[item.name] = idx
        SHORT_TO_IDX[item.short] = idx
        item.hash = Hash.hash(item.name)
        item.raw_hash = Hash.hash(item.short)
    end
end

-- Live 96 channel values buffer
local LIVE_VALUES = {}
for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

-- Motion Deform hash-to-index cache
local cached_motion_id = nil
local deform_indices = {}

local function get_deform_index(dm, h1, h2)
    if not dm then return nil end
    local addr = R.address(dm)
    if addr ~= cached_motion_id then
        cached_motion_id = addr
        deform_indices = {}
        local dhashes = R.call(dm, "get_DeformNameHashes")
        local len = dhashes and (R.call(dhashes, "get_Length") or R.call(dhashes, "get_Count")) or 0
        for i = 0, len - 1 do
            local h = Hash.hash_at(dhashes, i, true)
            if h then deform_indices[h] = i end
        end
    end
    return deform_indices[h1] or (h2 and deform_indices[h2])
end

-- Driver tracking
local cached_driver = nil
local last_driver_check = 0

local function resolve_driver(head)
    local now = os.clock()
    if cached_driver and (now - last_driver_check) < 0.5 then
        return cached_driver
    end
    last_driver_check = now

    pcall(function()
        if head and head.root then
            local root_go = R.call(head.root, "get_GameObject")
            if root_go then
                local drv = R.component(root_go, sdk.typeof("app.PlayerFacialAnimationDriver"))
                    or R.component(root_go, sdk.typeof("app.CharacterFacialAnimationDriver"))
                if drv then
                    cached_driver = drv
                    return
                end
            end
        end

        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and cm:call("getPlayerContextRefFast")
        local updater = pc and pc:get_field("<Updater>k__BackingField")
        if updater then
            local board = updater:call("get_ManagedDrivers")
            if board then
                local drivers = board:get_field("Drivers")
                local count = 0
                if drivers then
                    count = (drivers.get_Length and drivers:get_Length())
                        or (drivers.call and drivers:call("get_Count")) or 0
                end
                for i = 0, count - 1 do
                    local d = drivers[i] or (drivers.call and drivers:call("get_Item", i))
                    if d then
                        local t = d:get_type_definition()
                        local tname = t and t:get_full_name() or ""
                        if tname:find("FacialAnimationDriver") then
                            cached_driver = d
                            return
                        end
                    end
                end
            end
        end
    end)

    return cached_driver
end

-- Safely evaluate all 96 virtual channels per frame
function VF.evaluate(head, motion_context)
    for i = 0, #DEF_LIST do LIVE_VALUES[i] = 0.0 end

    pcall(function()
        if not head then return end
        local mesh = head.mesh or (head.face and R.mesh(head.face))
        local cn = mesh and R.call(mesh, "get_BlendShapeChannelNum") or 0
        local is_native_mesh = (cn == 96)

        -- 1. Resolve Deform Motion and Values buffer
        local face_go = head.face and R.call(head.face, 'get_GameObject')
        local root_go = head.root and R.call(head.root, 'get_GameObject')
        local fm = face_go and R.component(face_go, sdk.typeof('via.motion.Motion'))
        local rm = root_go and R.component(root_go, sdk.typeof('via.motion.Motion'))

        local driver = resolve_driver(head)
        local fmotion = driver and driver:get_field("_FacialMotion")
        local dm = fmotion or fm or rm or (motion_context and (motion_context.deform_motion or motion_context.motion))

        local dvals = dm and R.call(dm, "get_DeformValues")
        local dlen = dvals and (R.call(dvals, "get_Length") or R.call(dvals, "get_Count")) or 0

        -- 2. Read all 96 motion deform tracks with hash matching
        for i = 0, #DEF_LIST do
            local item = DEF_LIST[i]
            local val = nil

            -- Native mesh channel check
            if is_native_mesh and mesh and i < cn then
                val = R.call(mesh, "getBlendShapeChannelWeightParam(System.UInt64)", i)
                if val == nil then val = R.call(mesh, "getBlendShapeChannelWeightParam", i) end
            end

            -- Hash lookup on Motion Deform tracks
            if (val == nil or not is_native_mesh) and dm and dvals then
                local didx = get_deform_index(dm, item.hash, item.raw_hash)
                if didx and didx < dlen then
                    val = R.call(dvals, "get_Item", didx)
                end
            end

            if type(val) == "number" and val == val then
                local net = val - (item.baseline or 0.0)
                if net > 0.0005 then
                    LIVE_VALUES[i] = math.max(0.0, math.min(1.0, net))
                end
            end
        end

    end)

    return LIVE_VALUES
end

function VF.get(name_or_idx)
    if type(name_or_idx) == "number" then
        return LIVE_VALUES[name_or_idx] or 0.0
    end
    if type(name_or_idx) == "string" then
        local idx = SHORT_TO_IDX[name_or_idx] or NAME_TO_IDX[name_or_idx]
        if idx then return LIVE_VALUES[idx] or 0.0 end
    end
    return 0.0
end

function VF.get_all()
    return LIVE_VALUES
end

return VF
