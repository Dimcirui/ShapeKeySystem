-- ShapeKeySystem: Leon gameplay head targets and native expression inputs for RE9.
--
-- Only named custom channels are writable. Readiness and buffer identity enter the signature
-- so Core releases cached targets before reading or writing a rebuilt or hidden head.
local R = require("ShapeKeySystem_Games.RE9.Runtime")
local Signals = require("ShapeKeySystem_Games.RE9.Signals")
local Input = require("ShapeKeySystem_Games.RE9.Input")
local A = {id = "re9", name = "Resident Evil Requiem", strict_bounds = true, hash_names = true,
    hash_item_only = true, rewrite_active_weights = true, scene_search = false, scoped_bindings = true,
    terms = {primary = "里昂", part = "部件"}, raw = Signals.raw, read = Signals.read,
    channel_writable = Signals.writable, native_snapshot = Signals.snapshot, input = Input}
function A.primary_root() return R.root() end
function A.primary_ready() return R.find() ~= nil end
function A.is_face(face) return R.is_head(face) end
function A.face_rank() return 1 end
function A.faces(root) local h = R.find(root); return h and {h.face} or {} end
function A.face_root(_, root) return root end
function A.parts(root, face)
    local h = R.find(root)
    if not h or face and R.address(face) ~= R.address(h.face) then return {} end
    return {h.face}
end
function A.is_part() return false end
function A.part_id() return "ch0100_10_00" end
function A.model_of(part)
    if part == "leon" then return "leon" end
    if part == "ch0100_10_00" then return "leon", "10" end
end
function A.representative_of(part) return A.model_of(part) end
A.model_names = "character_names.json"
A.slot_names = {["10"] = "头部"}
function A.eye_joints() return {} end
function A.bind(face, keys) return Signals.bind(face, keys) end
function A.signature(root)
    local h = R.find(root)
    return h and h.identity or "RE9 head unavailable"
end
function A.gate()
    if R.find() then return true end
    return false, "里昂主头部或权重缓冲尚未就绪", "setup"
end
function A.init()
    local ok, why = R.init()
    if not ok then return false, why end
    local loaded, data = pcall(json.load_file, "ShapeKeySystem/builtin/re9/leon.json")
    if not loaded then return false, "RE9 原生通道表无法读取" end
    local read,setting=pcall(json.load_file,'ShapeKeySystem/user/re9_input.json')
    if not read or setting~=nil and(type(setting)~='table'or setting.schema~='sks.re9-input/1'
        or setting.mode~='legacy'and setting.mode~='bones_first')then return false,'RE9 输入模式配置无效'end
    return Signals.configure(data,setting and setting.mode)
end
return A
