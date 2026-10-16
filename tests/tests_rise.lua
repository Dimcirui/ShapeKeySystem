-- A separate runtime for the real Rise adapter: no raw channels, channel names from get_Item
-- hashes only, the face anchors the rig without being a part, and a mod part's missing weight
-- buffer is allocated.
local NameHash = require("ShapeKeySystem_Core.NameHash")
local W = require("ShapeKeySystem_Core.Writer")
local U = require("ShapeKeySystem_Core.Util")
U.save_json(U.path("mods", "names", "rise-test.json"),
    { schema = "sks.names/1", names = { "eye_close", "Waist_thin" } })
-- the engine's getBlendShapeChannelName answers "" here; the adapter must not depend on it
W.M_CNAME = { call = function() return "" end }
HASH = NameHash.hash
-- eye_nagomi_1 is known only through builtin/names (shared by every game)
CHANNELS = { "eye_close", "jawOpen", "Waist_thin", "Mystery_key", "eye_nagomi_1" }

local face = ROOT:get_Child()
face._name = "face_base"
face._joints.Head_00 = {}
ARMOR._name = "f_body279"
ARMOR._mesh.get_ChannelNameHash = function()
    -- boxed get_elements values are garbage in this engine; get_Item returns the numbers
    return { get_elements = function() return { 1, 1, 1, 1 } end,
             call = function(_, m, i) if m == "get_Item" then return HASH(CHANNELS[i + 1]) end end }
end
-- a mod mesh in an armor slot arrives without a weight buffer
local weights = { count = 0, list = 2 }
ARMOR._mesh.get_BlendShapeChannelWeightCount = function() return weights.count end
ARMOR._mesh.set_BlendShapeChannelWeightCount = function(_, n) weights.count = n end
ARMOR._mesh.get_ChannelWeightList = function()
    return { call = function(_, m) if m == "get_Length" then return weights.list end end }
end

local flags = { ready = true }
local original_singleton = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "snow.player.PlayerManager" then
        return { call = function(_, m)
            if m == "isReadyPlayerLoad" then return flags.ready end
            if m == "findMasterPlayer" then
                return { call = function(_, p) if p == "get_GameObject" then return ROOT:get_GameObject() end end }
            end
        end }
    end
    return original_singleton(name)
end

GAME_NAME = "mhrise"
dofile(ENTRY)
package.searchers[2] = function(name) return "autorun module after load: " .. name end
local SKS = require("ShapeKeySystem_Core.API")
local A = SKS.adapter
local st = SKS.state
local failures = 0
local function check(ok, text)
    print((ok and "ok   " or "FAIL ") .. "[rise] " .. text)
    if not ok then failures = failures + 1 end
end
local function ticks(n) for _ = 1, n do CB.tick(); CB.frame() end end

check(A.id == GAME_NAME and next(HOOKS) == nil, "selected, no hooks")
check(A.primary_root() == ROOT and A.primary_ready(), "master player resolved")
check(A.is_face(face) and A.face_rank(face) == 1 and not A.is_part("face_base"),
    "face_base anchors the rig and is not a part")
check(A.is_part("f_body279") and A.is_part("m_helm001") and not A.is_part("f_hair033")
    and not A.is_part("B_Bow014") and not A.is_part("PlHeadMessage"), "armor slots are parts, hair and weapons are not")
local model, slot = A.model_of("f_arm279")
check(model == "f_279" and slot == "arm" and A.representative_of("f_wst279") == "f_body279"
    and A.model_of("m_arm279") ~= model, "one binding per sex and equipment number, the body represents it")
check(st.expression.no_signals == true, "no raw channels: the expression page has no game signals")

ticks(60)
check(weights.count == 0, "a weight list shorter than the channels: the weight count stays 0")
weights.list = #CHANNELS
SKS.call("sculpt_scan"); ticks(5)
check(weights.count == #CHANNELS, "the next scan allocates the weight buffer once the weight list is long enough")
SKS.call("sculpt_scan"); ticks(5)
local by = {}
for _, k in ipairs(st.sculpt.keys) do by[k.name] = k end
check(by.eye_close and by.Waist_thin and by[NameHash.label(HASH("Mystery_key"))],
    "names come from get_Item hashes")
check(by.eye_nagomi_1 ~= nil, "the builtin names table resolves a mod key no profile or label knows")
local t0 = os.clock()
local table_size = 0
for _ in pairs(NameHash.table(NameHash.table_names())) do table_size = table_size + 1 end
print(string.format("     [rise] name table: %d hashes in %.0f ms", table_size, (os.clock() - t0) * 1000))
-- the newly allocated buffer must stay ready for Guard.STABLE_FRAMES before the first write
SKS.call("set_sculpt_key", { name = "Waist_thin", value = 0.6 }); ticks(40)
check(math.abs((WEIGHTS[2] or 0) - 0.6) < 1e-6, "a sculpt value is written (" .. tostring(WEIGHTS[2]) .. ")")

flags.ready = false; ticks(5)
check(not A.gate(), "player not ready: the gate closes")
weights.count = 0
flags.ready = true; ticks(60); SKS.call("sculpt_scan"); ticks(5)
check(weights.count == #CHANNELS, "a rebuilt part gets its weight buffer again")

print("RISE FAILS:", failures)
