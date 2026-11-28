-- ShapeKeySystem: RE9 Leon. Signals come from the facial Motion on part "10"; custom keys may sit
-- on any part mesh (some mods build the head on part 20 or 40).
--
-- Only named custom channels are writable. The face identity and the part list enter the
-- signature so Core releases cached targets before reading or writing a rebuilt or swapped part.
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Signals = require("ShapeKeySystem_Games.RE9.Signals")
local Input = require("ShapeKeySystem_Games.RE9.Input")
local Eyes = require('ShapeKeySystem_Games.RE9.Eyes')
local A = {id = "re9", name = "Resident Evil Requiem", strict_bounds = true, hash_names = true,
    hash_item_only = true, rewrite_active_weights = true, scene_search = false, scoped_bindings = true,
    active_sculpt = true, batch_weights = true,
    terms = {primary = "里昂", part = "部件"}, raw = Signals.raw, read = Signals.read,
    channel_writable = Signals.writable, write_context = Signals.write_context,
    native_snapshot = Signals.snapshot, input = Input}
function A.primary_root() return R.root() end
function A.primary_ready() return R.find() ~= nil end
function A.is_face(face) return R.is_face(face) end
function A.face_rank() return 1 end
function A.faces(root) local h = R.find(root); return h and {h.face} or {} end
function A.face_root(_, root) return root end
function A.parts(root, face)
    local h = R.find(root)
    if not h or face and R.address(face) ~= R.address(h.face) then return {} end
    return R.parts(h.root)
end
function A.is_part() return false end
function A.part_id(part) return R.part_id(part) end
function A.model_of(part)
    if part == "leon" then return "leon" end
    local slot = type(part) == "string" and part:match("^ch0100_(%d%d)_%d%d$")
    if slot then return "leon", slot end
end
function A.representative_of(part) return A.model_of(part) end
A.model_names = "character_names.json"
A.slot_names = {["10"] = "头部"}
function A.eye_joints(face)return Eyes.bind(face)end
function A.eye_angles(handle)
    local yaw,pitch=Eyes.angles(handle)
    if yaw~=nil then return yaw,pitch end
    -- Core subtracts the user's neutral. Return that neutral on an unavailable source
    -- so a failed eye read cannot retain its previous animated direction.
    local api=package.loaded['ShapeKeySystem_Core.API']
    local state=api and api.state
    local side=type(handle)=='table'and handle.side
    local neutral=state and state.eyes and state.eyes.neutral and state.eyes.neutral[side]
    return neutral and neutral.yaw or 0,neutral and neutral.pitch or 0
end
function A.bind(face, keys) return Signals.bind(face, keys) end
-- Core checks the signature every frame (strict bounds). Between full reads, every
-- FULL_SIGNATURE_CHECK-th check, only the recorded part routes are compared; a callback reuses its
-- first answer. The cache holds strings and numbers only.
A.FULL_SIGNATURE_CHECK = 30
local signature_cache
function A.signature(root)
    local h = R.find(root)
    if not h then signature_cache = nil; return "RE9 face unavailable" end
    local c, token = signature_cache, R.cache_token()
    if c and c.identity == h.identity then
        if token and c.token == token then return c.signature end
        c.checks = c.checks + 1
        if c.layout and c.checks % A.FULL_SIGNATURE_CHECK ~= 0 and R.routes_valid(h.root, c.layout) then
            c.token = token
            return c.signature
        end
    end
    local parts, layout = R.parts_signature(h.root)
    signature_cache = {identity = h.identity, signature = h.identity .. "#" .. parts, layout = layout,
        checks = 0, token = token}
    return signature_cache.signature
end
-- 部件变化由每帧签名检查发现并触发重扫，定期扫描只比对签名
A.inspect_before_scan = true
function A.cache_begin() R.cache_begin() end
function A.cache_end() R.cache_end() end
function A.gate()
    if R.find() then return true end
    return false, "里昂面部尚未就绪", "setup"
end
function A.init()
    local ok, why = R.init()
    if not ok then return false, why end
    local loaded, data = pcall(json.load_file, "ShapeKeySystem/builtin/re9/leon.json")
    if not loaded then return false, "RE9 原生通道表无法读取" end
    return Signals.configure(data)
end
return A
