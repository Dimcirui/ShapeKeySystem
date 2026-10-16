-- ShapeKeySystem: replay RE4R recorded signals through the current expression profile.
--
-- Sessions retain player addresses and signatures only. Signal replacement writes no native
-- animation values; stopping restores live input on the next SKS update.
local Names = require("ShapeKeySystem_Core.Names")
local Hash = require("ShapeKeySystem_Core.NameHash")
local NativeRecording = require("ShapeKeySystem_Core.NativeRecording")
local A = { final_unit = 1, default_mode = "final", final_only = true, signal_replay = true,
    modes = { {value = "final", label = "录制信号回放"} },
    recording_dirs = { {source = "user", path = "", pattern = "^native_signals_re4_"} },
    decode = NativeRecording.decode }
local resolve, session

function A.configure(resolver) resolve = resolver end
function A.describe(data) return NativeRecording.describe(data, "re4") end
function A.now() return os.clock() end
function A.attach() end
function A.catalog()
    local result = {}
    for key, name in ipairs(Names.ARKIT52) do result[key] = Hash.hash(name) end
    return result
end

function A.connect()
    local address, signature = resolve()
    assert(address, "请进入角色可用的游戏场景")
    session = {address = address, signature = signature}
end

function A.healthy()
    local address, signature = resolve()
    assert(session and address == session.address and signature == session.signature,
        "角色或部件已重建，信号回放已停止")
end

function A.matches(rig)
    return session ~= nil and rig.primary and rig.parent and rig.parent:get_address() == session.address
end

function A.apply_angles(rig, values, clip, eyes)
    for _, side in ipairs({"L", "R"}) do
        local columns, target = clip.eye_columns[side], rig.angles[side]
        if columns then
            local neutral = eyes.neutral[side]
            target[1] = (values[columns[1]] - neutral.yaw) * (eyes.invert.yaw and -1 or 1)
            target[2] = (values[columns[2]] - neutral.pitch) * (eyes.invert.pitch and -1 or 1)
        else target[1], target[2] = 0, 0 end
    end
end

function A.message(clip)
    local suffix = clip.eye_columns.L and clip.eye_columns.R and "含录制视线" or "未录制的眼球角度归零"
    return "通过当前 Profile 回放录制信号 · " .. suffix
end

function A.stop() session = nil end
return A
