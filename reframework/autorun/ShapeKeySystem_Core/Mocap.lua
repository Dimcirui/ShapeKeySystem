-- ShapeKeySystem: face mocap from iFacialMocap (iPhone ARKit tracking).
--
-- Input, once per tick: the native plugin ShapeKeySystem_Mocap.dll (global sks_mocap_native)
-- receives the phone's UDP stream inside the game; without it, builtin/mocap/ifm_bridge.py writes
-- the latest frame to mocap/live.json and this module reads that file. The 52 ARKit
-- values go in as External leases (owner "mocap"), so they override expression and sculpt for
-- those keys and pass the same warm-up / cutscene / rebuild guards as every other write. While
-- the stream fades in or out the lease value is mixed with the pure expression weight, so the
-- face hands back without a jump.
--
-- Constraints:
-- - The head turn is the only engine access here. It runs after UpdateMotion and only when the
--   previous tick drove the master player (API passes that in); the joint chain is dropped
--   whenever API drops its rigs, never held across a rebuild or cutscene teardown.
-- - Settings live in user/mocap.json, not settings.json: per-channel gains and the calibrated
--   neutral pose are personal to one phone and one face.

local U     = require("ShapeKeySystem_Core.Util")
local Names = require("ShapeKeySystem_Core.Names")
local Ext   = require("ShapeKeySystem_Core.External")
local Derived = require("ShapeKeySystem_Core.MocapDerived")

local M = {}
M.OWNER = "mocap"

local clock, max, min, abs = os.clock, math.max, math.min, math.abs
local ARKIT = Names.ARKIT52
local N = #ARKIT
local LIVE_PATH = U.path("mocap", "live.json")
local CFG_PATH = U.path("user", "mocap.json")
-- share of the head turn each joint takes, root -> tip (MH Wilds hunter skeleton)
local HEAD_JOINTS = { { "Neck_0", 0.25 }, { "Neck_1", 0.25 }, { "Head", 0.5 } }
local AXES = { "pitch", "yaw", "roll" }

-- input schemes the 面捕方案 select offers; each one reads its own transport into view.raw /
-- view.head_raw.
-- bridge = the script that writes live.json when the native receiver is missing (nil: the scheme
-- only works through ShapeKeySystem_Mocap.dll); head = false:
-- the app sends no head rotation, so the head turn is off altogether (the page hides its card,
-- and a head neutral or test pose left from another scheme must not turn the head).
M.SCHEMES = {
    { id = "ifacialmocap", name = "iFacialMocap", bridge = "ifm_bridge.py", head = true },
    { id = "rhylive", name = "RhyLive", bridge = "rhylive_bridge.py", head = false },
    -- any VMC protocol sender: ARKit (Perfect Sync) names drive the profile like the phone apps,
    -- other expression names are held on the shape key of the same name (extra = true)
    { id = "vmc", name = "VMC（通用）", head = true, extra = true },
}
local SCHEME_BY_ID = {}
for _, sc in ipairs(M.SCHEMES) do SCHEME_BY_ID[sc.id] = sc end

M.DEFAULTS = {
    enabled = false, scheme = "ifacialmocap", mirror = false, gain = 1.0, smoothing = 0.3,
    phone_ip = "",       -- iFacialMocap only streams after a trigger sent to the phone
    port = 0,            -- 0 = the scheme's default port
    timeout = 0.5, fade_sec = 0.25,
    neutral = {},        -- ARKit name -> resting value subtracted before gain
    channel_gains = {},  -- ARKit name -> extra gain
    -- order = which iFacialMocap head# value feeds each axis
    head = { enabled = false, gain = 1.0, max_deg = 45, smoothing = 0.6,
             order = { pitch = 1, yaw = 2, roll = 3 },
             invert = { pitch = false, yaw = false, roll = false },
             neutral = { 0, 0, 0 } },
}
M.LIMITS = { gain = { 0, 3 }, smoothing = { 0, 1 }, fade_sec = { 0, 2 }, timeout = { 0.1, 5 } }
M.HEAD_LIMITS = { gain = { 0, 2 }, max_deg = { 5, 90 }, smoothing = { 0, 1 } }

local cfg = U.copy(M.DEFAULTS)
M.cfg = cfg
local st = { seq = nil, last_rx = -1, rx_n = 0, rx_t0 = clock(), holding = false, save_at = nil,
             slots = nil, slots_for = nil, chain = nil, body = nil }

local MIRROR = {}   -- slot -> slot of the opposite side (jawLeft / mouthLeft swap too)
do
    local slot = {}
    for i, n in ipairs(ARKIT) do slot[n] = i end
    for i, n in ipairs(ARKIT) do
        local o = n:match("Left$") and n:sub(1, -5) .. "Right" or n:match("Right$") and n:sub(1, -6) .. "Left" or n
        MIRROR[i] = slot[o] or i
    end
end

-- what the panel reads (state.mocap)
local view = {
    -- pre = out before the gains: what the profile's ref nodes read (MocapDerived)
    names = ARKIT, raw = {}, out = {}, pre = {}, head_raw = { 0, 0, 0 },
    head_out = { pitch = 0, yaw = 0, roll = 0 },
    live = false, age = nil, rx_hz = 0, fade = 0, held = 0, derived = 0, resolved = 0,
    status = "未开启", head_status = "-", read_ms = 0,
    test = { on = false, pitch = 0, yaw = 0, roll = 0 },
    schemes = M.SCHEMES,
    cfg = cfg,
}
M.view = view
for i = 1, N do view.raw[i], view.out[i], view.pre[i] = 0, 0, 0 end
-- VMC expressions outside the ARKit 52, by the sender's name; held like ShapeKeySystemAPI.set
-- on the key of that name (case-insensitive). A name that normalises to an ARKit name is skipped.
view.extra_raw, view.extra_out, view.extra_n = {}, {}, 0
local ARKIT_NORM = {}
for _, n in ipairs(ARKIT) do ARKIT_NORM[Ext.norm(n)] = true end


local function fill(dst, src, defaults)
    for k, d in pairs(defaults) do
        local v = src[k]
        if type(d) == "table" then
            if type(v) == "table" then
                if next(d) == nil then dst[k] = U.copy(v) else fill(dst[k], v, d) end
            end
        elseif type(v) == type(d) then
            dst[k] = v
        end
    end
end

function M.load()
    local saved = U.load_json(CFG_PATH)
    if type(saved) == "table" then fill(cfg, saved, M.DEFAULTS) end
    if not SCHEME_BY_ID[cfg.scheme] then cfg.scheme = M.DEFAULTS.scheme end
end

function M.scheme() return SCHEME_BY_ID[cfg.scheme] or M.SCHEMES[1] end

function M.save()
    st.save_at = nil
    return U.save_json(CFG_PATH, cfg)
end

-- slider drags patch every frame: write the file once they settle
function M.save_soon() st.save_at = clock() + 0.5 end

function M.flush() if st.save_at then M.save() end end

-- ---------------------------------------------------------------- input
local function read_live()
    local data = U.load_json(LIVE_PATH)
    if not data or type(data.w) ~= "table" or data.seq == st.seq then return end
    local first = st.seq == nil
    st.seq = data.seq
    if first then return end   -- a live.json left over from an earlier session is not live
    local w, raw = data.w, view.raw
    for i = 1, N do raw[i] = tonumber(w[i]) or 0 end
    if type(data.head) == "table" then
        for i = 1, 3 do view.head_raw[i] = tonumber(data.head[i]) or 0 end
    end
    st.last_rx = clock()
    st.rx_n = st.rx_n + 1
end

-- in-game receiver (native plugin); nil when the DLL is not installed or refused this Lua release
local function native_api()
    local n = rawget(_G, "sks_mocap_native")
    return type(n) == "table" and type(n.poll) == "function" and n or nil
end

-- ips_due: look up this PC's IPs on the next tick (once after load, then on the page's 刷新 button);
-- the page shows them before mocap is switched on
local nat = { key = nil, buf = {}, seq = 0, ips_due = true }

function M.refresh_ips() nat.ips_due = true end
-- ips = this PC's LAN IPv4 addresses (RhyLive is told where to send)
view.native = { available = false, running = false, error = 0, sender = "", packets = 0, rejected = 0, port = 0, ips = {} }

local function native_stop()
    local n = native_api()
    if n and nat.key then pcall(n.stop) end
    nat.key = nil
    view.native.running = false
end

-- (re)starts the socket when the scheme, port or phone IP changed; returns true when it polled
local function read_native(n)
    local key = cfg.scheme .. ":" .. cfg.port .. ":" .. cfg.phone_ip
    local vn = view.native
    if nat.key ~= key then
        nat.key, nat.seq = key, 0
        view.extra_raw, view.extra_out = {}, {}
        local port = cfg.port > 0 and math.floor(cfg.port) or nil
        local ip = cfg.phone_ip ~= "" and cfg.phone_ip or nil
        local ok, res, err = pcall(n.start, cfg.scheme, port, ip)
        vn.error = (ok and res) and 0 or (ok and tonumber(err) or -1)
    end
    local ok, t = pcall(n.poll, nat.buf)
    if not ok or type(t) ~= "table" then vn.running = false; return false end
    vn.running, vn.error = t.running == true, t.error or vn.error
    vn.sender, vn.packets, vn.rejected, vn.port = t.sender or "", t.packets or 0, t.rejected or 0, t.port or 0
    if (t.seq or 0) == nat.seq then return true end
    nat.seq = t.seq
    local w, raw = t.w, view.raw
    for i = 1, N do raw[i] = w[i] or 0 end
    if type(t.head) == "table" then
        for i = 1, 3 do view.head_raw[i] = t.head[i] or 0 end
    end
    local xr = view.extra_raw
    for k in pairs(xr) do xr[k] = nil end
    if M.scheme().extra and type(t.extra) == "table" then
        for name, v in pairs(t.extra) do
            if type(name) == "string" and not ARKIT_NORM[Ext.norm(name)] then xr[name] = tonumber(v) or 0 end
        end
    end
    st.last_rx = clock()
    st.rx_n = st.rx_n + 1
    return true
end

local function compute(dt)
    local now = clock()
    view.age = st.last_rx >= 0 and (now - st.last_rx) or nil
    view.live = view.age ~= nil and view.age < cfg.timeout
    local step = dt / max(cfg.fade_sec, 0.01)
    view.fade = view.live and min(1, view.fade + step) or max(0, view.fade - step)
    local alpha = 1 - min(cfg.smoothing, 1) * 0.9
    local raw, out, pre = view.raw, view.out, view.pre
    local neutral, cg, g = cfg.neutral, cfg.channel_gains, cfg.gain
    for i = 1, N do
        local src = cfg.mirror and MIRROR[i] or i
        local n0 = tonumber(neutral[ARKIT[src]]) or 0
        local v = (n0 < 0.99) and (raw[src] - n0) / (1 - n0) or 0
        pre[i] = pre[i] + (U.clamp(v, 0, 1) - pre[i]) * alpha
        v = U.clamp(v * g * (tonumber(cg[ARKIT[i]]) or 1), 0, 1)
        out[i] = out[i] + (v - out[i]) * alpha
    end
    -- extra expressions: master gain and smoothing only (no neutral, per-channel gain or mirror)
    local xo = view.extra_out
    for name in pairs(xo) do if view.extra_raw[name] == nil then xo[name] = nil end end
    for name, r in pairs(view.extra_raw) do
        local v = U.clamp(r * g, 0, 1)
        xo[name] = (xo[name] or 0) + (v - (xo[name] or 0)) * alpha
    end
    -- head input arrives in ~25 Hz steps, which shows far more on a turning head than on the
    -- face: its own time-based smoothing, 0..1 -> time constant 0..0.2 s
    local h, ho = cfg.head, view.head_out
    local tau = h.smoothing * 0.2
    local ha = tau > 0 and (1 - math.exp(-dt / tau)) or 1
    for _, ax in ipairs(AXES) do
        local k = h.order[ax]
        local v = ((view.head_raw[k] or 0) - (tonumber(h.neutral[k]) or 0)) * h.gain
        if h.invert[ax] then v = -v end
        v = U.clamp(v, -h.max_deg, h.max_deg)
        ho[ax] = ho[ax] + (v - ho[ax]) * ha
    end
    if now - st.rx_t0 >= 1 then
        view.rx_hz = st.rx_n / (now - st.rx_t0); st.rx_n = 0; st.rx_t0 = now
    end
end

-- expression slot per ARKit channel (false = not an expression channel), recounted when the
-- profile or the scan changes; view.resolved = channels that reach a mesh key.
local function slots_for(ctx)
    local key = tostring(ctx.prog) .. ":" .. tostring(ctx.gen)
    if st.slots_for ~= key then
        st.slots, st.slots_for = {}, key
        local n = 0
        for i = 1, N do
            local s = ctx.prog and ctx.resolve(ARKIT[i]) or false
            st.slots[i] = s
            if ctx.reaches(ARKIT[i], s) then n = n + 1 end
        end
        view.resolved = n
    end
    return st.slots
end

local function release()
    view.held, view.derived, view.extra_n = 0, 0, 0
    if not st.holding then return false end
    st.holding = false
    Derived.reset()
    return Ext.release_all(M.OWNER) > 0
end

-- Once per API tick, before the rigs are driven. ctx = { prog, gen (scan revision), resolve(name)
-- -> slot, reaches(name, slot) -> a mesh key takes it, expr = pure expression weights by slot }.
-- Returns true when the held values changed (API marks the sculpt layer dirty).
function M.tick(dt, ctx)
    if st.save_at and clock() >= st.save_at then M.save() end
    local n = native_api()
    view.native.available = n ~= nil
    if n and n.local_ips and nat.ips_due then
        nat.ips_due = false
        local ok, ips = pcall(n.local_ips)
        view.native.ips = (ok and type(ips) == "table") and ips or {}
    end
    if not cfg.enabled then
        native_stop()
        view.status = "未开启"
        view.fade, view.live = 0, false
        return release()
    end
    local t0 = clock()
    -- live.json belongs to the bridge scripts: a scheme without one must not pick up their frames
    if not (n and read_native(n)) and M.scheme().bridge then read_live() end
    view.read_ms = view.read_ms * 0.95 + (clock() - t0) * 1000 * 0.05
    compute(dt)
    local f = view.fade
    if f <= 0 then
        local sc = M.scheme()
        if not n and not sc.bridge then view.status = "需要 ShapeKeySystem_Mocap.dll"
        elseif st.last_rx >= 0 then view.status = "数据中断"
        else view.status = "等待 " .. (n and sc.name or sc.bridge) .. " 的数据" end
        return release()
    end
    view.status = f < 1 and "淡入淡出中" or "面捕驱动中"
    local slots, expr = slots_for(ctx), ctx.expr
    local out, held = view.out, 0
    for i = 1, N do
        local s = slots[i]
        local e = s and expr[s] or 0
        local v = out[i] * f + e * (1 - f)
        Ext.set(M.OWNER, ARKIT[i], v + 0.0, Ext.DEFAULT_TTL)
        held = held + 1
    end
    -- profile channels made from ARKit refs (combination correctives) follow the phone too
    view.derived = Derived.hold(M.OWNER, ctx.prog, st.slots_for, slots, view.pre, cfg.gain, f, expr)
    local xn = 0
    for name, v in pairs(view.extra_out) do
        local s = ctx.prog and ctx.resolve(name)
        local e = s and expr[s] or 0
        Ext.set(M.OWNER, name, (v * f + e * (1 - f)) + 0.0, Ext.DEFAULT_TTL)
        xn = xn + 1
    end
    view.extra_n = xn
    view.held = held + view.derived + xn
    st.holding = true
    return true
end

-- ---------------------------------------------------------------- calibration / commands
function M.calibrate_face()
    cfg.neutral = {}
    for i = 1, N do if view.raw[i] > 0.01 then cfg.neutral[ARKIT[i]] = view.raw[i] end end
end

function M.calibrate_head()
    cfg.head.neutral = { view.head_raw[1], view.head_raw[2], view.head_raw[3] }
end

local function num(v, lim)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return U.clamp(v, lim[1], lim[2]) + 0.0
end

-- patch: enabled, scheme (an M.SCHEMES id), phone_ip, port, mirror, gain, smoothing, fade_sec, timeout, channel_gains = {name = gain|false},
-- head = {enabled, gain, max_deg, smoothing, invert = {axis = bool}, order = {axis = 1..3}},
-- test = {on, pitch, yaw, roll} (not saved). Validates everything before changing anything;
-- returns ok, err, msg.
function M.patch(p)
    if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
    local writes = {}
    local function bool(dst, k, v)
        if v == nil then return true end
        if type(v) ~= "boolean" then return false end
        writes[#writes + 1] = { dst, k, v }
        return true
    end
    for _, k in ipairs({ "enabled", "mirror" }) do
        if not bool(cfg, k, p[k]) then return false, "E_BAD_ARGS", k .. " must be boolean" end
    end
    if p.phone_ip ~= nil then
        local ip = p.phone_ip
        local ok = type(ip) == "string" and (ip == "" or ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil)
        if ok and ip ~= "" then
            for part in ip:gmatch("%d+") do if #part > 3 or tonumber(part) > 255 then ok = false end end
        end
        if not ok then return false, "E_BAD_ARGS", "phone_ip: IPv4 address or empty" end
        writes[#writes + 1] = { cfg, "phone_ip", ip }
    end
    if p.port ~= nil then
        local v = tonumber(p.port)
        if not v or v % 1 ~= 0 or v < 0 or v > 65535 then return false, "E_BAD_ARGS", "port: 0 (default) or 1..65535" end
        writes[#writes + 1] = { cfg, "port", math.floor(v) }
    end
    if p.scheme ~= nil then
        if not SCHEME_BY_ID[p.scheme] then return false, "E_BAD_ARGS", "unknown scheme " .. tostring(p.scheme) end
        writes[#writes + 1] = { cfg, "scheme", p.scheme }
    end
    for k, lim in pairs(M.LIMITS) do
        if p[k] ~= nil then
            local v = num(p[k], lim)
            if not v then return false, "E_BAD_ARGS", k .. ": number expected" end
            writes[#writes + 1] = { cfg, k, v }
        end
    end
    if p.channel_gains ~= nil then
        if type(p.channel_gains) ~= "table" then return false, "E_BAD_ARGS", "channel_gains must be a table" end
        for name, g in pairs(p.channel_gains) do
            if not Names.ARKIT_BY_NORM[U.norm(tostring(name))] then return false, "E_BAD_ARGS", "unknown channel " .. tostring(name) end
            local v = g ~= false and num(g, { 0, 3 }) or nil
            if g ~= false and not v then return false, "E_BAD_ARGS", "channel gain: number expected" end
            if v and abs(v - 1) < 0.001 then v = nil end
            writes[#writes + 1] = { cfg.channel_gains, name, v }
        end
    end
    local h = p.head
    if h ~= nil then
        if type(h) ~= "table" then return false, "E_BAD_ARGS", "head must be a table" end
        if not bool(cfg.head, "enabled", h.enabled) then return false, "E_BAD_ARGS", "head.enabled must be boolean" end
        for k, lim in pairs(M.HEAD_LIMITS) do
            if h[k] ~= nil then
                local v = num(h[k], lim)
                if not v then return false, "E_BAD_ARGS", "head." .. k .. ": number expected" end
                writes[#writes + 1] = { cfg.head, k, v }
            end
        end
        for _, ax in ipairs(AXES) do
            if type(h.invert) == "table" and not bool(cfg.head.invert, ax, h.invert[ax]) then
                return false, "E_BAD_ARGS", "head.invert." .. ax .. " must be boolean"
            end
            local o = type(h.order) == "table" and h.order[ax]
            if o ~= nil and o ~= false then
                o = tonumber(o)
                if o ~= 1 and o ~= 2 and o ~= 3 then return false, "E_BAD_ARGS", "head.order." .. ax .. ": 1..3" end
                writes[#writes + 1] = { cfg.head.order, ax, math.floor(o) }
            end
        end
    end
    local t = p.test
    if t ~= nil then
        if type(t) ~= "table" then return false, "E_BAD_ARGS", "test must be a table" end
        if not bool(view.test, "on", t.on) then return false, "E_BAD_ARGS", "test.on must be boolean" end
        for _, ax in ipairs(AXES) do
            if t[ax] ~= nil then
                local v = num(t[ax], { -60, 60 })
                if not v then return false, "E_BAD_ARGS", "test." .. ax .. ": number expected" end
                writes[#writes + 1] = { view.test, ax, v }
            end
        end
    end
    for _, w in ipairs(writes) do w[1][w[2]] = w[3] end
    return true
end

-- ---------------------------------------------------------------- head turn
local sin, cos, rad = math.sin, math.cos, math.rad

-- character space: yaw about +Y, pitch about +X, roll about +Z (degrees)
local function euler_q(pitch, yaw, roll)
    local p, y, r = rad(pitch) * 0.5, rad(yaw) * 0.5, rad(roll) * 0.5
    return Quaternion.new(cos(y), 0, sin(y), 0)
         * Quaternion.new(cos(p), sin(p), 0, 0)
         * Quaternion.new(cos(r), 0, 0, sin(r))
end

-- joint path from the skeleton root down to Head, with the driven joints' shares
local function build_chain(body, jbn)
    local head = jbn:call(body, "Head")
    if not head then return nil end
    local share = {}
    for _, e in ipairs(HEAD_JOINTS) do share[e[1]] = e[2] end
    local path, j = {}, head
    while j and #path < 64 do table.insert(path, 1, j); j = j:call("get_Parent") end
    local chain = {}
    for i, jt in ipairs(path) do chain[i] = { joint = jt, share = share[jt:call("get_Name")] } end
    return chain
end

-- API calls this whenever it lets go of its rigs: the joints belong to the old hunter object
function M.drop_refs()
    if st.chain or st.body then
        st.chain, st.body = nil, nil
        return true
    end
    return false
end

function M.wants_head()
    return cfg.enabled and cfg.head.enabled and M.scheme().head and (view.fade > 0 or view.test.on)
end

-- After UpdateMotion: the animation has written this frame's local rotations and constraints
-- still follow ours. The extra turn D (character space) is split over the head joints: each
-- joint's local rotation L becomes L * (W^-1 * D_share * W), W = its world rotation from the
-- chain. root = the master player's transform, only passed while the previous tick drove it.
function M.update_motion(root, jbn)
    if not root then return end
    if st.body and st.body:get_address() ~= root:get_address() then M.drop_refs() end
    if not st.chain then
        st.body = root
        st.chain = build_chain(root, jbn)
        view.head_status = st.chain and string.format("头部骨骼链：%d 节", #st.chain) or "找不到 Head 骨骼"
        if not st.chain then return end
    end
    local ho, f = view.head_out, view.fade
    if view.test.on then ho, f = view.test, 1 end
    if f <= 0 then return end
    local C = root:call("get_Rotation")
    local Ci = C:inverse()
    local q = C
    for _, e in ipairs(st.chain) do
        local L = e.joint:call("get_LocalRotation")
        if e.share then
            -- nothing re-posed the joint since our last write: start from the pose seen then
            -- instead of stacking the turn again
            if e.wrote and abs(L:dot(e.wrote)) > 0.9999999 then L = e.base else e.base = L end
            local s = e.share * f
            local D = C * euler_q(ho.pitch * s, ho.yaw * s, ho.roll * s) * Ci
            local Wq = q * L
            L = (L * (Wq:inverse() * D * Wq)):normalized()
            e.joint:call("set_LocalRotation", L)
            e.wrote = L
        end
        q = q * L
    end
end

return M
