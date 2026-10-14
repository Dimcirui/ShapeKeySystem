-- 用内存适配器验证播放时钟与解码契约，测试不持有或写入真实游戏对象。
local R = require("ShapeKeySystem_Core.Playback")
local Recording = require("ShapeKeySystem_Core.Recording")
local Wilds = require("ShapeKeySystem_Games.Wilds.Adapter")
local Profile = require("ShapeKeySystem_Core.Profile")
local U = require("ShapeKeySystem_Core.Util")
local failures = 0
local function check(ok, label)
    print((ok and "ok   " or "FAIL ") .. "[playback] " .. label)
    if not ok then failures = failures + 1 end
end
local catalog = Wilds.playback.catalog()
for _, name in ipairs({ "Speak", "CampMeals" }) do
    local data = U.load_json(U.path("builtin", "mhwilds", "recordings", name .. ".json"))
    local has_final = data.final_scale ~= nil or data.frames[1].final ~= nil
    for _, mode in ipairs(has_final and { "raw", "final" } or { "raw" }) do
        local clip = Recording.decode(data, mode, catalog, "mhwilds")
        check(clip.n == #data.params and #clip.frames > 2 and clip.frames[#clip.frames].t == clip.duration,
            name .. " " .. mode .. " decodes all parameters and timestamps")
        local last = Recording.sample(clip, clip.duration)
        check(last[1] == clip.frames[#clip.frames].values[1], name .. " " .. mode .. " samples the final frame")
    end
end
local raw = { schema = "fcparam.recording/2", game = "mhwilds", duration = 2,
    encoding = "quantized-delta", raw_scale = 10000000, final_scale = 100000,
    params = { { param = 1, hash = catalog[1] } }, frames = {
        { t = 0, raw = { 100000 }, final = { 50000 } },
        { t = 1, d = {}, df = { 1, 100000 } },
        { t = 2, d = { 1, 0 } },
    } }
local c = Recording.decode(raw, "raw", catalog, "mhwilds")
check(c.frames[2].values[1] == 0.01 and math.abs(Recording.sample(c, 1.5)[1] - 0.005) < 1e-9,
    "empty deltas retain absolute values; interpolation keeps raw engine units")
raw.params[1].hash = 0
check(not pcall(Recording.decode, raw, "raw", catalog, "mhwilds"), "wrong hash is rejected before playback")
raw.params[1].hash = catalog[1]
check(not pcall(Recording.decode, raw, "raw", catalog, "other"), "recordings from another game are rejected")
raw.frames[2].d = { 1, 1, 1, 2 }
check(not pcall(Recording.decode, raw, "raw", catalog, "mhwilds"), "duplicate delta columns are rejected")
raw.frames[2].d = {}
U.save_json(U.path("user", "recordings", "ClockTest.json"), raw)
U.save_json(U.path("user", "games", "mhwilds", "recordings", "ClockTest.json"), { duration = 99 })
U.save_json(U.path("user", "games", "mhwilds", "recordings", "LegacyTest.json"), raw)
U.save_json(U.path("user", "games", "other", "recordings", "OtherGame.json"), raw)
U.save_json(U.path("games", "mhwilds", "recordings", "OldBuiltin.json"), raw)
local now, restored, injected, stale, connects = 0, 0, nil, false, 0
local adapter = { raw_unit = 0.01, final_unit = 0.01, catalog = function() return catalog end,
    attach = function() end, now = function() return now end,
    connect = function() stale = false; connects = connects + 1 end,
    healthy = function() assert(not stale, "replaced face") end,
    inject = function(v) injected = v[1] end,
    stop = function(restore) if restore then restored = restored + 1 end end,
    matches = function(rig) return rig.primary end }
R.init({ id = "mhwilds", name = "test", raw = Wilds.raw, playback = adapter }, nil,
    function() return { 1 } end, function() return nil, Profile.signals.list, {}, 1 end)
check(R.state.supported and #R.state.files == 4, "lists builtin, user and legacy recordings without duplicates or other games")
local clock, legacy
for _, file in ipairs(R.state.files) do
    if file.id == "user:ClockTest.json" then clock = file end
    if file.id == "user:LegacyTest.json" then legacy = file end
end
check(clock and clock.path == U.path("user", "recordings", "ClockTest.json") and clock.duration == 2,
    "canonical user directory wins over the legacy path while retaining the playback ID")
check(legacy and legacy.path == U.path("user", "games", "mhwilds", "recordings", "LegacyTest.json"),
    "old user recordings remain readable without moving or rewriting them")
check(R.request("play", { id = "user:ClockTest.json", mode = "raw" }), "play accepts a registered file ID")
R.tick(true)
check(R.state.status == "playing" and injected == 0.01, "raw injection preserves engine units")
now = 0.5; R.request("pause"); R.tick(true)
local samples = R.state.analysis.sampled_frames
now = 1.5; R.tick(true)
check(R.state.status == "paused" and R.state.elapsed == 0.5 and R.state.analysis.sampled_frames == samples,
    "paused time and analysis do not advance")
R.request("seek", { time = 1 }); R.tick(true)
check(R.state.elapsed == 1 and R.state.analysis.sampled_frames == samples + 1, "paused seek counts the displayed frame once")
R.request("options", { speed = 2, loop = true }); R.request("resume"); R.tick(true)
now = 2.5; R.tick(true)
check(R.state.status == "playing" and R.state.elapsed == 1 and R.state.analysis.sampled_frames > samples + 1,
    "speed and looping use the adapter clock")
stale = true; R.tick(true)
check(R.state.status == "stopped" and R.state.message:find("replaced face", 1, true) and restored > 0,
    "invalid engine session stops playback and requests restoration")
R.request("play", { id = "user:ClockTest.json", mode = "final" }); R.tick()
local P = { [2] = 99 }
local rig = { primary = true, angles = { L = { 1, 2 }, R = { 3, 4 } } }
check(R.apply(rig, P, 100) and P[1] == 0.5 and P[2] == nil and rig.angles.L[1] == 0,
    "final playback normalizes once, zeros missing signals and gaze")
check(not R.apply({ primary = false }, {}, 100), "final playback does not affect other characters")
R.request("options", { loop = false }); R.tick(); now = 5; R.tick()
check(R.state.status == "stopped" and R.state.elapsed == 2 and R.state.analysis.finished,
    "natural completion preserves end progress and releases decoded frames")
-- 准备期间不连接引擎；取消、重播和末帧错误都必须放掉尚未发布的结果。
local stress = { schema = "fcparam.recording/2", game = "mhwilds", duration = 5,
    encoding = "quantized-delta", raw_scale = 10000000, final_scale = 100000, params = {}, frames = {} }
local first_raw, first_final = {}, {}
for i = 1, 200 do
    stress.params[i] = { param = i, hash = catalog[i] }
    first_raw[i], first_final[i] = 10000, 50000
end
stress.frames[1] = { t = 0, raw = first_raw, final = first_final }
for i = 2, 151 do stress.frames[i] = { t = (i - 1) / 30, d = {}, df = {} } end
local static = Recording.decode(stress, "raw", catalog, "mhwilds")
check(static.frames[1].values == static.frames[151].values and static.frames[151].values[1] == 0.001,
    "unchanged deltas share read-only snapshots")
stress.frames[151].d = { 1, 20000 }
local changed = Recording.decode(stress, "raw", catalog, "mhwilds")
check(changed.frames[150].values[1] == 0.001 and changed.frames[151].values[1] == 0.002
    and first_raw[1] == 10000, "copy-on-write leaves earlier snapshots and source arrays unchanged")
for i = 2, 151 do
    local d, df = {}, {}
    for col = 1, 200 do
        d[#d + 1], d[#d + 2] = col, col == 1 and i == 151 and 20000 or 10000
        df[#df + 1], df[#df + 2] = col, 50000
    end
    stress.frames[i].d, stress.frames[i].df = d, df
end
U.save_json(U.path("user", "recordings", "BudgetTest.json"), stress); R.refresh()
local connected_before = connects
injected = nil
R.request("play", { id = "user:BudgetTest.json" }); R.tick(true)
check(R.state.status == "preparing" and connects == connected_before and injected == nil,
    "large recordings yield before connecting or injecting")
local seek_ok = R.request("seek", { time = 1 })
check(not seek_ok, "seek is rejected until all recording data is validated")
R.request("stop"); R.tick(true)
for _ = 1, 20 do R.tick(true) end
check(R.state.status == "stopped" and connects == connected_before,
    "stop cancels preparation and no delayed session appears")
R.request("play", { id = "user:BudgetTest.json" }); R.request("pause")
R.request("options", { speed = 1.25 }); R.tick(true)
for _ = 1, 1000 do if R.state.status ~= "preparing" then break end; R.tick(true) end
check(R.state.status == "paused" and R.state.elapsed == 0 and R.state.speed == 1.25
    and R.state.analysis.sampled_frames == 1 and injected == 0.001,
    "budgeted preparation completes and preserves ordered pause/options commands")
R.stop(true)
R.request("play", { id = "user:BudgetTest.json" }); R.tick(true)
R.request("play", { id = "user:ClockTest.json" }); R.tick(true)
check(R.state.status == "playing" and R.state.file == "ClockTest", "new play replaces an unfinished preparation")
R.stop(true)
local bad = U.copy(stress); bad.frames[151].df = { 1, 1, 1, 2 }
U.save_json(U.path("user", "recordings", "LateBad.json"), bad); R.refresh()
connected_before = connects; injected = nil
R.request("play", { id = "user:LateBad.json", mode = "raw" }); R.tick(true)
for _ = 1, 1000 do if R.state.status ~= "preparing" then break end; R.tick(true) end
check(R.state.status == "stopped" and R.state.message:find("差分列号", 1, true)
    and connects == connected_before and injected == nil,
    "a late error on the unselected track never produces engine writes or a partial clip")
R.request("play", { id = "user:ClockTest.json" }); R.tick(true)
check(R.state.status == "playing", "a valid recording still plays after a preparation error")
R.stop(true)
local synchronous = Recording.decode(stress, "final", catalog, "mhwilds")
local job = Recording.prepare(stress, "final", catalog, "mhwilds")
local done, sliced, steps = false, nil, 0
repeat done, sliced = job:step(); steps = steps + 1 until done
local equal = steps > 1 and #sliced.frames == #synchronous.frames
for _, time in ipairs({ -1, 0, 0.37, 2.5, 5, 6 }) do
    local a, b = Recording.sample(sliced, time), Recording.sample(synchronous, time)
    for col = 1, 200 do equal = equal and a[col] == b[col] end
end
check(equal, "sliced and synchronous decoders have identical seek/interpolation results")

local ok, code = R.request("play", { id = "../../outside.json" })
check(not ok and code == "E_NOT_FOUND", "arbitrary paths are refused")
R.init({ id = "other", name = "other" })
ok, code = R.request("play", { id = "builtin:Speak.json" })
check(not R.state.supported and not ok and code == "E_UNSUPPORTED",
    "an adapter without playback does not enable Wilds playback")
print("PLAYBACK FAILS:", failures)
assert(failures == 0, "playback regression")
