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
               "blendShape1.mouthSmileLeft", "blendShape1.browInnerUp", "blendShape1.Other" })
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
check(st.mocap.cfg.scheme == "ifacialmocap" and #st.mocap.schemes == 3, "default scheme iFacialMocap, RhyLive and generic VMC offered too")
ok, err = SKS.call("mocap", { patch = { scheme = "facecap" } })
check(not ok and err == "E_BAD_ARGS" and st.mocap.cfg.scheme == "ifacialmocap", "unknown scheme rejected")
-- RhyLive reads the same live.json but sends no head: no head turn at all, not even the test pose
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
check(not Mocap.wants_head(), "test pose does not turn the head under RhyLive either")
SKS.call("mocap", { patch = { scheme = "ifacialmocap", test = { on = false }, head = { enabled = false } } })

-- the stream stops: fades out and hands the keys back
SKS.call("mocap", { patch = { timeout = 0.1 } })
wait(0.15); ticks(3)
check(not st.mocap.live and held_by_mocap() == 0, "stale stream releases every mocap key")

-- head turn needs a driven primary rig; with the head off nothing is touched
local okm = pcall(CB.motion)
check(okm and st.mocap.head_status ~= nil, "UpdateMotion hook runs with the head turn off")

-- in-game receiver (ShapeKeySystem_Mocap.dll): a fake sks_mocap_native, live.json is not read
local NAT = { starts = {}, stops = 0, seq = 0, w = {}, head = nil }
for i = 1, 52 do NAT.w[i] = 0 end
sks_mocap_native = {
    version = 1,
    start = function(scheme, port, ip) NAT.starts[#NAT.starts + 1] = { scheme, port, ip }; return true end,
    stop = function() NAT.stops = NAT.stops + 1 end,
    poll = function(t)
        t = t or {}
        t.running, t.scheme, t.port, t.seq, t.sender = true, "ifacialmocap", 49983, NAT.seq, "192.168.1.165"
        t.packets, t.rejected, t.error, t.w, t.head, t.extra = NAT.seq, 0, 0, NAT.w, NAT.head, NAT.extra
        return t
    end,
}
local function nat_frame(vals)
    NAT.seq = NAT.seq + 1
    for i, n in ipairs(st.mocap.names) do NAT.w[i] = vals[n] or 0 end
end
ok = SKS.call("mocap", { patch = { phone_ip = "192.168.1.165", timeout = 5 } })
check(ok and st.mocap.cfg.phone_ip == "192.168.1.165", "phone_ip saved")
check(not SKS.call("mocap", { patch = { phone_ip = "192.168.1" } }) and not SKS.call("mocap", { patch = { phone_ip = "1.2.3.400" } }),
    "incomplete or out-of-range phone_ip rejected")
check(not SKS.call("mocap", { patch = { port = 70000 } }), "port outside 0..65535 rejected")
frame_in({ eyeBlinkLeft = 0.1 })   -- live.json says something else: must be ignored
nat_frame({ eyeBlinkLeft = 0.6 })
for _ = 1, 20 do wait(0.002); ticks(1) end
local s1 = NAT.starts[1]
check(#NAT.starts == 1 and s1[1] == "ifacialmocap" and s1[2] == nil and s1[3] == "192.168.1.165",
    "native receiver started with scheme, default port and phone IP")
check(st.mocap.native.available and st.mocap.native.running and st.mocap.native.sender == "192.168.1.165",
    "state.mocap.native reports the receiver")
check(st.mocap.live and math.abs((WEIGHTS[bi] or -1) - 0.6) < 1e-3, "native frame reaches the mesh, live.json ignored")
SKS.call("mocap", { patch = { phone_ip = "192.168.1.166" } }); ticks(1)
check(#NAT.starts == 2 and NAT.starts[2][3] == "192.168.1.166", "changing the phone IP restarts the receiver")
-- page with the receiver: phone IP field instead of the bridge hint
Panel.set_open(true)
SKS.call("set_setting", { key = "advanced", value = true })
Panel.ui.page = "mocap"
DRAWS = {}; CB.d2d_draw()
local function seen(s) for _, d in ipairs(DRAWS) do if d.s:find(s, 1, true) then return true end end end
check(seen("Destination IP address") and seen("游戏内直接接收") and seen("来自 192.168.1.165")
    and not seen("手机 IP") and not seen("页面出错"), "基础配置 shows the in-game receiver, no phone IP field")
sks_mocap_native.local_ips = function() return { "192.168.1.190" } end
SKS.call("mocap", { patch = { enabled = false } }); ticks(1)   -- the IPs come without a running receiver
DRAWS = {}; CB.d2d_draw()
check(seen("本机 IP：192.168.1.190") and seen("端口 49983"), "PC IP and port shown while mocap is still off")
sks_mocap_native.local_ips = function() return { "10.0.0.5" } end
ticks(2); DRAWS = {}; CB.d2d_draw()
check(seen("本机 IP：192.168.1.190") and seen("刷新"), "PC IPs are looked up once, not polled")
SKS.call("mocap_refresh_ips"); ticks(1); DRAWS = {}; CB.d2d_draw()
check(seen("本机 IP：10.0.0.5"), "mocap_refresh_ips looks them up again")
sks_mocap_native.local_ips = function() return { "192.168.1.190" } end
SKS.call("mocap_refresh_ips")
SKS.call("mocap", { patch = { enabled = true } }); ticks(1)
SKS.call("mocap", { patch = { scheme = "rhylive" } }); ticks(1)
DRAWS = {}; CB.d2d_draw()
check(NAT.starts[#NAT.starts][1] == "rhylive" and seen("本机 IP：192.168.1.190") and not seen("手机 IP")
    and not seen("页面出错"), "RhyLive through the receiver: PC IP shown, no phone IP field")
SKS.call("mocap", { patch = { scheme = "vmc" } }); ticks(1)
local h_x = Panel.ui.win.h
Panel.ui.win.h = 2000   -- the head card sits below the fold at the default height
DRAWS = {}; CB.d2d_draw()
Panel.ui.win.h = h_x
check(NAT.starts[#NAT.starts][1] == "vmc" and seen("支持 VMC 协议") and seen("127.0.0.1、端口")
    and not seen("本机 IP") and seen("头部转动") and not seen("页面出错"), "VMC through the receiver, head card kept")
-- VMC: expression names outside the ARKit 52 are held on the shape key of that name
SKS.call("mocap", { patch = { gain = 1, smoothing = 0, fade_sec = 0, timeout = 5 } })
NAT.extra = { Other = 0.7, Eye_Blink_Left = 0.1 }
nat_frame({ eyeBlinkLeft = 0.6 })
for _ = 1, 20 do wait(0.002); ticks(1) end
local oi = mesh_idx("Other")
check(math.abs((WEIGHTS[oi] or -1) - 0.7) < 1e-3 and st.mocap.extra_n == 1,
    "VMC: a non-ARKit name drives the shape key of the same name")
local shadow = false
for _, h in ipairs(st.external.held) do if h.name == "Eye_Blink_Left" then shadow = true end end
check(not shadow, "VMC: a name that normalises to an ARKit name does not take over that key")
DRAWS = {}; CB.d2d_draw()
check(seen("其他表情名：正在写入 1 个"), "VMC page counts the extra names being written")
NAT.extra = nil
nat_frame({ eyeBlinkLeft = 0.6 })
for _ = 1, 5 do wait(0.002); ticks(1) end
check(st.mocap.extra_n == 0, "extras stop when the sender no longer sends them")
SKS.call("mocap", { patch = { scheme = "ifacialmocap" } }); ticks(1)
Panel.set_open(false)
local stops = NAT.stops
SKS.call("mocap", { patch = { enabled = false } }); ticks(1)
check(NAT.stops == stops + 1, "disabling mocap stops the receiver")
SKS.call("mocap", { patch = { phone_ip = "" } })
sks_mocap_native = nil
SKS.call("mocap", { patch = { enabled = true } }); ticks(2)
check(not st.mocap.native.available, "without the DLL the file path is used again")
SKS.call("mocap", { patch = { scheme = "vmc", timeout = 0.1 } }); ticks(1)
frame_in({ jawOpen = 0.5 }); wait(0.15); ticks(2)   -- a bridge's live.json is not VMC's
check(st.mocap.status == "需要 ShapeKeySystem_Mocap.dll", "VMC without the DLL says it needs the plugin")
SKS.call("mocap", { patch = { scheme = "ifacialmocap" } })
SKS.call("mocap", { patch = { enabled = false, timeout = 0.5 } }); ticks(1)
Panel.ui.page = "basic"

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
check(drawn("基础配置 · RhyLive") and drawn("并启用相应的收发程序") and not drawn("头部转动")
    and drawn("各通道强度") and not drawn("页面出错"), "RhyLive scheme box, head card hidden")
SKS.call("mocap", { patch = { scheme = "ifacialmocap" } })
DRAWS = {}; CB.d2d_draw()
Panel.ui.page_state.mocap.channels_open = true
local h_before = Panel.ui.win.h
Panel.ui.win.h = 2000
DRAWS, CMDS = {}, {}; CB.d2d_draw()
check(drawn("各通道强度") and drawn("browDownLeft") and not drawn("页面出错"), "channel list drawn")
-- the face mirror has its own tab on this page: draw the page with that tab picked
do
    local PageMocap = package.loaded["ShapeKeySystem_UI.PageMocap"]
    DRAWS = {}
    local ok, err = pcall(PageMocap.draw, { st = SKS.state, call = SKS.call, state = {} }, 0, 0, 900)
    check(ok and drawn("面捕总配置") and not drawn("对准定位点"), "mocap page opens on the 面捕 tab")
    DRAWS = {}
    ok, err = pcall(PageMocap.draw, { st = SKS.state, call = SKS.call, state = { tab = "mirror" } }, 0, 0, 900)
    check(ok and drawn("表情镜") and drawn("定位点") and drawn("对准定位点") and not drawn("面捕总配置"), "face mirror tab drawn" .. (ok and "" or (" " .. tostring(err))))
end
-- face mirror settings: values are clamped, unknown joints refused, the current joint's rig reset
do
    local fm = SKS.state.face_mirror
    check(SKS.call("face_mirror", { patch = { size = 5000, rigs = { COG = { dist = 1.2, aim = { y = 0.5 } } } } })
        and fm.cfg.size == 800 and fm.cfg.rigs.COG.dist == 1.2 and fm.cfg.rigs.COG.aim.y == 0.5, "face mirror patch clamps and nests")
    check(not SKS.call("face_mirror", { patch = { bind = "Hip" } }) and fm.cfg.bind == "Head", "face mirror refuses an unknown joint")
    check(not SKS.call("face_mirror", { patch = { size = 300, rigs = { COG = { rot = { w = 1 } } } } }) and fm.cfg.size == 800,
        "face mirror patch writes nothing when one value is bad")
    SKS.call("face_mirror", { patch = { bind = "COG" } })
    check(SKS.call("face_mirror_reset", { what = "rig" }) and fm.cfg.rigs.COG.dist == 0.6 and fm.cfg.rigs.COG.aim.y == 0.45,
        "face mirror reset restores the current joint's camera")
    check(SKS.call("face_mirror_reset", { what = "aim" }) and fm.cfg.rigs.COG.aim.x == 0 and fm.cfg.rigs.COG.aim.y == 0
        and fm.cfg.rigs.COG.aim.z == 0, "face mirror aims at the anchor joint")
    check(SKS.call("face_mirror_reset", { what = "all" }) and fm.cfg.size == 260 and fm.cfg.bind == "Head", "face mirror reset all")
    check(SKS.call("face_mirror", { patch = { hide = { legs = true } } }) and fm.cfg.hide.legs == true
        and not SKS.call("face_mirror", { patch = { hide = { tail = true } } }) and fm.cfg.hide.tail == nil,
        "face mirror hides a known part, refuses an unknown one")
    SKS.call("face_mirror_reset", { what = "all" })
end
SNAP("面捕", function() DRAWS, CMDS = {}, {}; CB.d2d_draw() end)
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
-- the same kind of face under its own profile: the phone reaches it through the game signals
local prof0 = st.expression.profile and st.expression.profile.id
set_channels({ "blendShape1.eye_close_L", "blendShape1.eye_close_R", "blendShape1.eye_look_left",
               "blendShape1.mouth_smile_L" })
check(SKS.call("set_profile", { id = "shinano", discard = true }), "Shinano profile selected")
ticks(3)
SKS.call("mocap", { patch = { enabled = true, timeout = 5, fade_sec = 0, smoothing = 0 } })
frame_in({ eyeBlinkLeft = 0.8, eyeLookOutLeft = 0.5, mouthSmileLeft = 0.6 })
for _ = 1, 40 do wait(0.002); ticks(1) end
local ci, li, si = mesh_idx("eye_close_L"), mesh_idx("eye_look_left"), mesh_idx("mouth_smile_L")
check(st.mocap.resolved == 0 and (st.mocap.signals or 0) > 20, "Shinano: no ARKit keys, game signals counted ("
    .. tostring(st.mocap.signals) .. ")")
check(math.abs((WEIGHTS[ci] or -1) - 0.8) < 0.02, "Shinano: eyeBlinkLeft closes eye_close_L through blink.L ("
    .. tostring(WEIGHTS[ci]) .. ")")
check((WEIGHTS[mesh_idx("eye_close_R")] or 1) < 0.02, "Shinano: the other eye stays open, the game's blink is out")
check(math.abs((WEIGHTS[si] or -1) - 0.6) < 0.02, "Shinano: mouthSmileLeft reaches mouth_smile_L")
check((WEIGHTS[li] or 0) > 0.3, "Shinano: eyeLookOutLeft turns the eyes to the character's left ("
    .. tostring(WEIGHTS[li]) .. ")")
SKS.call("mocap", { patch = { enabled = false, timeout = 0.5, fade_sec = 0.25, smoothing = 0.3 } }); ticks(3)
check((WEIGHTS[li] or 1) < 0.02, "Shinano: mocap off hands the gaze back")
if prof0 then SKS.call("set_profile", { id = prof0, discard = true }) end
set_channels(saved_channels)
print("MOCAP FAILS:", mfails)
