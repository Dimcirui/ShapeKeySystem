-- ShapeKeySystem: what differs between the RE Engine games it runs in. MH Wilds is the original
-- target and the default; Onimusha: Way of the Sword is the second (kevin's Maya port, 2026-10-14).
--
--                 MH Wilds                               Onimusha: Way of the Sword
--   player        PlayerManager:getMasterPlayer()        PlayerManager:getControllingPlayerInfo()
--   face          child Player_Face*, fcParam joints     child Head (OniHead in Oni form), face_joint*
--   shape keys    on the armour parts next to the face   on the face's own mesh: the face is its part
--   eyes          L_EyeJ_LOD02 / R_EyeJ_LOD02            eye_Lt / eye_Rt
--   signals       builtin/signals.json                   its names, unwired, + signals_onimusha.json
--   game hooks    cutscenes, equip, menus, input         none (no cutscene / input types known yet)

local G = {}

local function game_name()
    local ok, n = pcall(function() return reframework:get_game_name() end)
    return ok and n or nil
end

local function call(obj, m)
    local ok, v = pcall(function() return obj:call(m) end)
    if ok then return v end
    return nil
end

local wilds = {
    id = "mhwilds",
    face_markers = { "fcParam_001" },
    eyes = { L = "L_EyeJ_LOD02", R = "R_EyeJ_LOD02" },
    signals = { file = "signals.json" },
    face_is_part = false,   -- the keys live on the armour parts next to the face
    hooks = true,           -- Wilds' cutscene / equip / menu / guild card / input hooks
}

function wilds.master_root()
    local ok, tr = pcall(function()
        return sdk.get_managed_singleton("app.PlayerManager"):call("getMasterPlayer"):call("get_Object"):call("get_Transform")
    end)
    return ok and tr or nil
end

function wilds.is_face(name) return name:find("Player_Face", 1, true) == 1 end
function wilds.is_part(name) return name:find("ch02", 1, true) ~= nil or name:find("ch03", 1, true) ~= nil end

-- what a child of the player contributes to the parts signature
function wilds.child_key(name) return name end

local oni = {
    id = "onimusha",
    -- face_joint340 is the left upper lid (Altina's OnimushaEyeMovementIntensity); Face is the
    -- face skeleton's root
    face_markers = { "face_joint340", "Face" },
    eyes = { L = "eye_Lt", R = "eye_Rt" },
    -- no fcParams and no Wilds face bones in this game: Wilds' signal names stay declared (every
    -- profile compiles) but read 0, unless signals_onimusha.json wires them to Onimusha bones
    signals = { file = "signals.json", overlay = "signals_onimusha.json", unwire_base = true },
    face_is_part = true,
    hooks = false,
    FACE_NAMES = { Head = true, OniHead = true },
}

function oni.master_root()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    if not pm then return nil end
    local info = call(pm, "getControllingPlayerInfo") or call(pm, "get_ControllingPlayer")
    local go = info and call(info, "get_Object")
    return go and call(go, "get_Transform") or nil
end

function oni.is_face(name) return oni.FACE_NAMES[name] == true end
function oni.is_part(name) return oni.FACE_NAMES[name] == true end

-- The game can swap a face for a new object under the same name; the address tells them apart.
function oni.child_key(name, tr)
    local ok, a = pcall(tr.get_address, tr)
    return ok and a and (name .. "@" .. tostring(a)) or name
end

G.name = game_name()
local chosen = (G.name == "onimusha_wots") and oni or wilds
for k, v in pairs(chosen) do G[k] = v end

-- Onimusha has no fcParam joints: never ask for them
G.has_fcparams = (G.id == "mhwilds")

return G
