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
    local data = U.load_json(U.path("games", "mhwilds", "recordings", name .. ".json"))
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
U.save_json(U.path("user", "games", "mhwilds", "recordings", "ClockTest.json"), raw)
local now, restored, injected, stale = 0, 0, nil, false
local adapter = { raw_unit = 0.01, final_unit = 0.01, catalog = function() return catalog end,
    attach = function() end, now = function() return now end,
    connect = function() stale = false end,
    healthy = function() assert(not stale, "replaced face") end,
    inject = function(v) injected = v[1] end,
    stop = function(restore) if restore then restored = restored + 1 end end,
    matches = function(rig) return rig.primary end }
R.init({ id = "mhwilds", name = "test", raw = Wilds.raw, playback = adapter }, nil,
    function() return { 1 } end, function() return nil, Profile.signals.list, {}, 1 end)
check(R.state.supported and #R.state.files >= 3, "catalog includes builtin and this game's user recordings")
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
local ok, code = R.request("play", { id = "../../outside.json" })
check(not ok and code == "E_NOT_FOUND", "arbitrary paths are refused")
R.init({ id = "other", name = "other" })
ok, code = R.request("play", { id = "builtin:Speak.json" })
check(not R.state.supported and not ok and code == "E_UNSUPPORTED",
    "an adapter without playback does not enable Wilds playback")
print("PLAYBACK FAILS:", failures)
assert(failures == 0, "playback regression")
