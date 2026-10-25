-- face mocap (Mocap.lua): live.json -> External leases owned by "mocap", the 面捕 page
local SKS = require("ShapeKeySystem_Core.API")
local Mocap = require("ShapeKeySystem_Core.Mocap")
local U = require("ShapeKeySystem_Core.Util")
local Panel = require("ShapeKeySystem_UI.Panel")
local st = SKS.state
local mfails = 0
local function check(cond, what)
    print((cond and "ok   " or "FAIL ") .. "[mocap] " .. what)
    if not cond then mfails = mfails + 1 end
end
local function ticks(n) for _ = 1, n or 1 do CB.tick(); CB.frame() end end
local function mesh_idx(key)
    for i, n in ipairs(CHANNELS) do
        if n:match("([^%.]+)$") == key then return i - 1 end
    end
end
local function wait(sec) local t = os.clock() + sec; while os.clock() < t do end end
local LIVE = U.path("mocap", "live.json")
local seq = 0
local function frame_in(vals, head)
    seq = seq + 1
    local w = {}
    for i, n in ipairs(st.mocap.names) do w[i] = vals[n] or 0 end
    json.dump_file(LIVE, { seq = seq, w = w, head = head or { 0, 0, 0, 0, 0, 0 } })
end
local function held_by_mocap()
    local n = 0
    for _, h in ipairs(st.external.held) do if h.owner == "mocap" then n = n + 1 end end
    return n
end

-- an ARKit face for this file; the earlier groups' channel list comes back at the end
local saved_channels = {}
for i, n in ipairs(CHANNELS) do saved_channels[i] = n end
local function set_channels(list)
    for i = 1, #CHANNELS do CHANNELS[i] = nil end
    for i, n in ipairs(list) do CHANNELS[i] = n end
    SKS.call("rescan"); ticks(80)
end
set_channels({ "blendShape1.eyeBlinkLeft", "blendShape1.eyeBlinkRight", "blendShape1.jawOpen",
               "blendShape1.mouthSmileLeft", "blendShape1.browInnerUp" })
check(st.mocap and #st.mocap.names == 52, "state.mocap exposes the 52 ARKit channels")
check(st.mocap.cfg.enabled == false and held_by_mocap() == 0, "off by default, holds nothing")
check(CB.motion ~= nil, "UpdateMotion hook registered")

-- a bad patch changes nothing
local ok, err = SKS.call("mocap", { patch = { gain = 2, mirror = "yes" } })
check(not ok and err == "E_BAD_ARGS" and st.mocap.cfg.gain == 1, "invalid patch rejected without partial writes")
ok, err = SKS.call("mocap", { patch = { channel_gains = { notAKey = 2 } } })
check(not ok and err == "E_BAD_ARGS", "unknown channel gain rejected")
ok, err = SKS.call("mocap", { patch = { head = { order = { yaw = 4 } } } })
check(not ok and err == "E_BAD_ARGS", "head.order outside 1..3 rejected")

ok = SKS.call("mocap", { patch = { enabled = true, smoothing = 0, fade_sec = 0, timeout = 5 } })
check(ok and st.mocap.cfg.enabled, "enable through the mocap command")
frame_in({ eyeBlinkLeft = 0.3 }); ticks(2)   -- the first file seen is treated as stale
check(held_by_mocap() == 0 and not st.mocap.live, "a live.json left over from before is not live")
frame_in({ eyeBlinkLeft = 0.8, jawOpen = 0.5 })
for _ = 1, 40 do wait(0.002); ticks(1) end
local bi, ji = mesh_idx("eyeBlinkLeft"), mesh_idx("jawOpen")
check(st.mocap.live and st.mocap.fade == 1, "stream live, fully faded in")
check(held_by_mocap() == 52, "52 keys held by owner mocap")
check(math.abs((WEIGHTS[bi] or -1) - 0.8) < 1e-3, "eyeBlinkLeft from the phone reaches the mesh")
check(math.abs((WEIGHTS[ji] or -1) - 0.5) < 1e-3, "jawOpen from the phone reaches the mesh")
check(st.mocap.resolved == 5, "coverage counts the 5 ARKit keys on the face")

-- gain, mirror, per-channel gain
SKS.call("mocap", { patch = { channel_gains = { jawOpen = 0.5 } } }); ticks(2)
check(math.abs(WEIGHTS[ji] - 0.25) < 1e-3, "per-channel gain scales one key")
SKS.call("mocap", { patch = { channel_gains = { jawOpen = 1 } } })
check(st.mocap.cfg.channel_gains.jawOpen == nil, "gain 1 is stored as no override")
SKS.call("mocap", { patch = { mirror = true } }); ticks(2)
check((WEIGHTS[bi] or 1) < 1e-3, "mirror moves eyeBlinkLeft to the right eye")
SKS.call("mocap", { patch = { mirror = false } }); ticks(2)

-- calibration: the current face becomes the rest pose
ok = SKS.call("mocap_calibrate", { what = "face" })
check(ok and math.abs((st.mocap.cfg.neutral.eyeBlinkLeft or 0) - 0.8) < 1e-6, "calibrate face stores the neutral pose")
ticks(2)
check((WEIGHTS[bi] or 1) < 1e-3, "calibrated pose reads as zero")
check(U.load_json(U.path("user", "mocap.json")) ~= nil, "calibration saved to user/mocap.json")
SKS.call("mocap_calibrate", { what = "clear" })
check(next(st.mocap.cfg.neutral) == nil, "clear removes the neutral pose")
check(not SKS.call("mocap_calibrate", { what = "nose" }), "unknown calibration target rejected")
check(st.mocap.cfg.scheme == "ifacialmocap" and #st.mocap.schemes == 2, "default scheme iFacialMocap, RhyLive offered too")
ok, err = SKS.call("mocap", { patch = { scheme = "facecap" } })
check(not ok and err == "E_BAD_ARGS" and st.mocap.cfg.scheme == "ifacialmocap", "unknown scheme rejected")
-- RhyLive reads the same live.json but sends no head: the head turn runs only as the test pose
SKS.call("mocap", { patch = { head = { enabled = true } } })
frame_in({ jawOpen = 0.6 }); ticks(2)
check(Mocap.wants_head(), "iFacialMocap stream drives the head turn")
ok = SKS.call("mocap", { patch = { scheme = "rhylive" } })
check(ok and st.mocap.cfg.scheme == "rhylive", "scheme RhyLive selected")
json.dump_file(LIVE, { seq = seq + 1, w = (function() local w = {}; for i = 1, 52 do w[i] = 0 end; w[25] = 0.4; return w end)() })
seq = seq + 1
ticks(2)
check(math.abs((WEIGHTS[ji] or -1) - 0.4) < 1e-3, "RhyLive frame without head reaches the mesh")
check(not Mocap.wants_head(), "RhyLive stream leaves the head alone")
SKS.call("mocap", { patch = { test = { on = true } } })
check(Mocap.wants_head(), "test pose still turns the head under RhyLive")
SKS.call("mocap", { patch = { scheme = "ifacialmocap", test = { on = false }, head = { enabled = false } } })

-- the stream stops: fades out and hands the keys back
SKS.call("mocap", { patch = { timeout = 0.1 } })
wait(0.15); ticks(3)
check(not st.mocap.live and held_by_mocap() == 0, "stale stream releases every mocap key")

-- head turn needs a driven primary rig; with the head off nothing is touched
local okm = pcall(CB.motion)
check(okm and st.mocap.head_status ~= nil, "UpdateMotion hook runs with the head turn off")

-- page
Panel.set_open(true)
SKS.call("set_setting", { key = "advanced", value = true })
DRAWS = {}; CB.d2d_draw()
local rail
for _, d in ipairs(DRAWS) do if d.s == "面捕" then rail = d end end
check(rail ~= nil, "advanced rail lists 面捕")
if rail then
    local function frame() CB.tick(); CB.frame(); DRAWS = {}; CB.d2d_draw() end
    MOUSE.x, MOUSE.y = rail.x + 4, rail.y + 6
    frame()
    MOUSE.down = true; frame()
    MOUSE.down = false; frame()
end
local function drawn(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return true end end end
check(Panel.ui.page == "mocap", "rail click opens the 面捕 page")
check(drawn("面捕总配置") and drawn("基础配置 · iFacialMocap") and drawn("校准面部") and drawn("头部转动")
    and not drawn("页面出错"), "面捕 page cards drawn")
SKS.call("mocap", { patch = { scheme = "rhylive" } })
local h_page = Panel.ui.win.h
Panel.ui.win.h = 2000   -- the head card sits below the fold at the default height
DRAWS = {}; CB.d2d_draw()
Panel.ui.win.h = h_page
check(drawn("基础配置 · RhyLive") and drawn("rhylive_bridge.py") and drawn("不发送头部数据")
    and not drawn("校准正前方") and not drawn("页面出错"), "RhyLive scheme box, head card without phone controls")
SKS.call("mocap", { patch = { scheme = "ifacialmocap" } })
DRAWS = {}; CB.d2d_draw()
Panel.ui.page_state.mocap.channels_open = true
local h_before = Panel.ui.win.h
Panel.ui.win.h = 2000
DRAWS, CMDS = {}, {}; CB.d2d_draw()
check(drawn("各通道强度") and drawn("browDownLeft") and not drawn("页面出错"), "channel list drawn")
SNAPS[#SNAPS + 1] = { name = "面捕", cmds = CMDS }
Panel.ui.page_state.mocap.channels_open = nil
Panel.ui.win.h = h_before
Panel.set_open(false)
SKS.call("mocap", { patch = { enabled = false, timeout = 0.5, fade_sec = 0.25, smoothing = 0.3 } }); ticks(2)
SKS.call("set_setting", { key = "advanced", value = false })
-- a face without ARKit keys: nothing to drive, coverage says so
set_channels({ "blendShape1.eye_close_L", "blendShape1.mouth_a1" })
SKS.call("mocap", { patch = { enabled = true, timeout = 5, fade_sec = 0 } })
frame_in({ eyeBlinkLeft = 0.8 }); for _ = 1, 5 do wait(0.002); ticks(1) end
check(st.mocap.resolved == 0, "coverage 0 on a face without ARKit keys")
SKS.call("mocap", { patch = { enabled = false, timeout = 0.5, fade_sec = 0.25 } }); ticks(2)
set_channels(saved_channels)
print("MOCAP FAILS:", mfails)
