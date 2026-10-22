-- 播放分析使用实际录制帧计数；独立实例避免污染面板正在显示的播放状态。
local Analysis = require("ShapeKeySystem_Core.PlaybackAnalysis")
local Profile = require("ShapeKeySystem_Core.Profile")
local Wilds = require("ShapeKeySystem_Games.Wilds.Adapter")
local Mapping = require("ShapeKeySystem_UI.MappingEditor")
local failures = 0
local function check(ok, label)
    print((ok and "ok   " or "FAIL ") .. "[analysis] " .. label)
    if not ok then failures = failures + 1 end
end
local clip = { track = "raw", duration = 2, map = { [1] = 1, [7] = 2 }, frames = {
    { t = 0, values = { 0.01, 0.0001 } },
    { t = 1, values = { -0.005, 0.002 } },
    { t = 2, values = { 0, 0.003 } },
} }
local a = Analysis.new(clip, 0.01, "test", Wilds.raw.label)
check(a.state.sampled_frames == 1 and a.by_param[1].hits == 1 and a.by_param[7].hits == 0,
    "counts absolute values above threshold; exactly 1% is excluded")
a:advance(1, 0); a:advance(1, 0)
check(a.state.sampled_frames == 2 and a.by_param[1].hits == 2, "repeated ticks do not count a frame twice")
a:advance(0, 2)
check(a.state.sampled_frames == 7 and a.by_param[1].hits == 5 and a.by_param[7].hits == 4,
    "loop wrap counts the remainder and full cycles")
a:seek(2)
check(a.state.sampled_frames == 8 and a.by_param[7].hits == 5, "seek counts only the target frame")
local sig = Profile.load_signals()
local seen, fc = {}, 0
for _, s in ipairs(sig.list) do
    seen[s.key] = true
    if s.key and s.key <= 200 then fc = fc + 1 end   -- bone signals are keyed above the fcParam range
end
local complete = fc == 200
for n = 1, 200 do complete = complete and seen[n] == true end
check(complete, "per-game dictionary retains every parameter from 1 through 200")
local prog = assert(Profile.compile({ id = "analysis", name = "analysis", aliases = {}, channels = {
    { name = "Blink", s = "blink.L" },
    { name = "Combined", sum = { { ref = "Blink" }, { p = 7 } } },
} }, {}))
a:bindings(prog, sig.list, { { present = true }, { present = false } }, 1)
check(#a.by_param[1].mappings == 2 and a.by_param[1].present_count == 1
    and #a.by_param[7].mappings == 1, "bindings follow key, raw nodes and indirect references")
check(a.by_param[1].label == "blink.L · fcParam_001" and a.by_param[1].signal == "blink.L"
    and a.by_param[1].purpose ~= "词典尚未标注用途", "alias, raw label and purpose survive schema /2")
check(a.by_param[7].label == "fcParam_007", "generic aliases do not repeat the raw name")
check(a.state.rows[1].param == 1 and a.state.rows[2].param == 7, "equal hits sort by parameter")
local ctx = { state = {}, st = { mapping = { signals = sig.list, entries = {}, profile_id = "analysis" } } }
Mapping.open(ctx, nil, a.by_param[1].signal)
local draft = ctx.state.mapping_draft
check(draft and draft.entry.s == "blink.L" and draft.entry.group == "eye",
    "quick add opens the shared editor with signal and group prefilled")
local title = Mapping.summary(ctx, { s = "fcParam_007" })
check(title == "fcParam_007", "mapping summary uses adapter label without duplicate aliases")
a:finish(); a:bindings(nil, sig.list, {}, 2)
check(a.clip == nil and a.state.finished and a.by_param[1].hits == 5 and #a.by_param[1].mappings == 0,
    "stopping releases frames while preserving counts and allowing binding refresh")
local generic = Analysis.new(clip, 0.01, "other", function(n) return "bone:" .. n end)
generic:bindings(nil, { { key = 1, name = "blink", note = "close", label = "bone:1" },
    { key = 7, name = "absent", no_signal = true } }, {}, 1)
check(generic.by_param[1].label == "blink · bone:1" and generic.by_param[7].signal ~= "absent",
    "analysis uses injected labels and ignores unavailable signals")
print("PLAYBACK ANALYSIS FAILS:", failures)
assert(failures == 0, "playback analysis regression")
