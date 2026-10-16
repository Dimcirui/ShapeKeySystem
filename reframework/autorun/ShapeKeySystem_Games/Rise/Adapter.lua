-- ShapeKeySystem: Monster Hunter Rise character discovery (sculpt and presets only).
-- The game has no shape key driver joints, so there is no `raw` / `bind` / `read`: Core shows the
-- expression page without game signals.
--
-- Constraints:
-- - Channel names come from get_ChannelNameHash through get_Item (`hash_item_only`).
--   getBlendShapeChannelName returns "" from Lua and crashed the game when called from C#.
-- - Mod meshes in armor slots come with a weight count of 0 (no weight buffer), so Core never
--   writes them. prepare_parts raises the count to the channel count, and only when the managed
--   weight list is already that long: writing past the buffer can freeze the game.
-- - face_base (the player's face) only anchors the rig and is not a part: Core zeroes parts when it
--   lets go, which would wipe the character's face sculpt values.
local A = {
    id = "mhrise",
    name = "Monster Hunter Rise",
    terms = { primary = "猎人", part = "防具" },
    hash_names = true, hash_item_only = true,
    scene_search = false,
}

local M_JBN
local FACE = "face_base"

local function master()
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    return pm, pm and pm:call("findMasterPlayer")
end

function A.primary_root()
    local ok, tr = pcall(function()
        local _, pl = master()
        return pl:call("get_GameObject"):call("get_Transform")
    end)
    return ok and tr or nil
end

function A.primary_ready()
    local ok, ready = pcall(function()
        local pm, pl = master()
        return pl ~= nil and pm:call("isReadyPlayerLoad") == true
    end)
    return ok and ready == true
end

local function go_name(tr)
    local ok, name = pcall(function() return tr:call("get_GameObject"):call("get_Name") end)
    return ok and name or nil
end

function A.is_face(tr)
    if go_name(tr) ~= FACE or not M_JBN then return false end
    local ok, joint = pcall(M_JBN.call, M_JBN, tr, "Head_00")
    return ok and joint ~= nil
end

function A.face_rank(tr) return go_name(tr) == FACE and 1 or 0 end

-- armor slots: f_ / m_ (sex) + slot + equipment number, e.g. f_body279
local SLOTS = { arm = "腕甲", body = "铠甲", helm = "头盔", leg = "腿甲", wst = "腰甲" }
function A.is_part(name)
    local slot = type(name) == "string" and name:match("^[fm]_(%a+)%d+$")
    return slot ~= nil and SLOTS[slot] ~= nil
end

A.slot_names = SLOTS

-- f_body279 -> "f_279", "body": the parts of one equipment number share a binding; the body part
-- represents the set
function A.model_of(part)
    if not A.is_part(part) then return nil end
    local sex, slot, number = part:match("^([fm])_(%a+)(%d+)$")
    return sex .. "_" .. number, slot
end

function A.representative_of(part)
    local model = A.model_of(part)
    if not model then return nil end
    local sex, number = model:match("^([fm])_(%d+)$")
    return sex .. "_body" .. number
end

function A.eye_joints() return {} end

local function call(obj, method, ...)
    local ok, v = pcall(obj.call, obj, method, ...)
    if ok then return v end
    return nil
end

-- Per scanned part: allocate the weight buffer.
function A.prepare_parts(parts)
    for _, part in ipairs(parts) do
        local m, n = part.mesh, part.n
        local wc = call(m, "get_BlendShapeChannelWeightCount")
        if type(wc) == "number" and wc < n and call(m, "get_MeshReady") == true then
            local list = call(m, "get_ChannelWeightList")
            local length = list and call(list, "get_Length")
            if type(length) == "number" and length >= n and call(m, "get_BlendShapeChannelNum") == n then
                call(m, "set_BlendShapeChannelWeightCount", n)
            end
        end
    end
end

function A.gate()
    if not A.primary_ready() then return false, "player not ready" end
    return true
end

function A.init()
    for _, spec in ipairs({
        { "snow.player.PlayerManager", "findMasterPlayer()", "isReadyPlayerLoad()" },
        { "via.Transform", "getJointByName(System.String)" },
        { "via.render.Mesh", "set_BlendShapeChannelWeightCount(System.UInt64)", "get_ChannelWeightList()", "get_MeshReady()" },
    }) do
        local t = sdk.find_type_definition(spec[1])
        if not t then return false, "找不到类型 " .. spec[1] end
        for i = 2, #spec do
            if not t:get_method(spec[i]) then return false, "找不到方法 " .. spec[1] .. "." .. spec[i] end
        end
    end
    M_JBN = sdk.find_type_definition("via.Transform"):get_method("getJointByName(System.String)")
    return true
end

return A
