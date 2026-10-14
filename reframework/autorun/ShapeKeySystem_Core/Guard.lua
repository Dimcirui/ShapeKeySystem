-- ShapeKeySystem: write safety. Ported from the SKS_Mocap crash investigation (2026-10-09):
--   * writing weights while a hunter part is rebuilt (entering the game, end of a cutscene)
--     crashed a game worker thread on a null blendshape buffer;
--   * holding Lua references to objects the game tears down (cutscene skip / end) crashed it
--     even with every weight at 0.
-- So: nothing is touched while a cutscene loads or plays or while the player is not set up,
-- every mesh must stay ready for STABLE_FRAMES before it is written, and references are dropped
-- (and collected) the moment any of that changes.

local W = require("ShapeKeySystem_Core.Writer")

local G = {}

-- (halved 2026-10-09: the crashes these guarded against were traced to BoneSystem.dll)
G.STABLE_FRAMES = 30   -- a mesh must stay ready this long before it is written to
G.SETTLE_FRAMES = 15   -- wait after a rebuild / cutscene before rescanning

local T_RMESH = sdk.find_type_definition("via.render.Mesh")
local M_READY  = T_RMESH:get_method("get_MeshReady")
local M_BS_ON  = T_RMESH:get_method("get_BlendShapeEnable")
local M_BS_REL = T_RMESH:get_method("get_BlendShapeReleasedBuffers")
local M_CN, M_WC = W.M_CN, W.M_WC

local function call(m, obj)
    if not m then return nil end
    local ok, v = pcall(m.call, m, obj)
    if ok then return v end
    return nil
end

-- Full check, used while a target warms up. (BlendShapeReleasedFixBuffers is deliberately not
-- checked: it is true on the drawn, working hunter face too.)
function G.mesh_ready(mesh)
    if not call(M_READY, mesh) then return false, "MeshReady=false" end
    if not call(M_BS_ON, mesh) then return false, "BlendShapeEnable=false" end
    if call(M_BS_REL, mesh) then return false, "BlendShapeReleasedBuffers" end
    local cn, wc = call(M_CN, mesh), call(M_WC, mesh)
    if not cn or not wc then return false, "channel count unreadable" end
    if wc < cn then return false, "weight buffer not allocated" end
    return true
end

-- Cheap per-frame check once a target is stable (2 calls).
function G.mesh_still_ready(mesh)
    return call(M_READY, mesh) == true and call(M_BS_REL, mesh) ~= true
end

-- Game-level gate (the adapter's `gate`): ok, reason, kind. Without one, the game counts as stable
-- whenever the primary character exists.
G.adapter = {}   -- set by SKS.init
function G.game_stable(frame)
    local A = G.adapter
    if A.gate then return A.gate(frame) end
    if A.primary_root and A.primary_root() then return true end
    return false, "no primary character", "setup"
end

function G.release_refs() collectgarbage("collect") end

return G
