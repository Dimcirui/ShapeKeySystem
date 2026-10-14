-- 用确定时钟验证目标索引的混合顺序和配置失效；结束后恢复模块配置。
local Cond = require("ShapeKeySystem_Core.CondExpr")
local Touch = require("ShapeKeySystem_Core.Touch")
local Perf = require("ShapeKeySystem_Core.Perf")
local failures = 0
local function check(ok, label)
    print((ok and "ok   " or "FAIL ") .. "[target lookup] " .. label)
    if not ok then failures = failures + 1 end
end
local function near(a, b) return math.abs(a - b) < 1e-12 end
local keep_current, keep_preview, keep_map, keep_clock = Cond.current, Cond.preview, Touch.map, os.clock
local now = 0
os.clock = function() return now end
Cond.reset(); Touch.reset()
local data = { auto = false, states = {}, clips = {
    first = { values = { Jaw_Open = 0.2, ["jaw.open"] = 0.8 }, fade_in = 0, fade_out = 0.4 },
    second = { values = { ["JAW-OPEN"] = 0.4 }, fade_in = 0, fade_out = 0.4 },
} }
Cond.current = { data = data }; Cond.preview = "first"; Cond.update(false)
local function original(set, value, alpha)
    for key, target in pairs(set) do
        if Touch.norm(key) == "jawopen" then value = value * (1 - alpha) + target * alpha end
    end
    return value
end
local expected = original(data.clips.first.values, 0.1, Cond.alpha("first"))
check(near(Cond.for_key("jaw open", 0.1), expected), "normalized collisions keep all targets in source order")
Cond.preview = "second"; now = 0.1; Cond.update(false)
expected = original(data.clips.first.values, 0.1, Cond.alpha("first"))
expected = original(data.clips.second.values, expected, Cond.alpha("second"))
local W = { 0.1 }; Cond.apply({}, function() return 1 end, W)
check(near(Cond.for_key("jaw_open", 0.1), expected) and near(W[1], expected),
    "fading clip precedes current clip; indexed lookup matches expression layering")
local replacement = { auto = false, states = {}, clips = {
    second = { values = { JawOpen = 0.9 }, fade_in = 0, fade_out = 0 },
} }
check(Cond.edit(replacement) and near(Cond.for_key("jaw-open", 0.1), 0.9),
    "editing active values invalidates indexes before the next update")
Cond.reset()
check(Cond.for_key("JawOpen", 0.3) == 0.3, "reset removes cached active clips")
Cond.current = nil
check(Cond.for_key("JawOpen", 0.3) == 0.3, "deselecting a set releases active targets")

local m = { eye = { values = { Jaw_Open = 0.3, ["jaw.open"] = 0.7 }, hold = 1 },
    mouth = { left = { JawOpen = 0.8 }, right = { JawOpen = 0.1 } } }
Touch.set_map(m); Touch.update(); Touch.poke("eye"); now = 0.2; Touch.update()
Touch.drag(0.5, 0); Touch.update()
W = { 0.2 }; Touch.apply({}, function() return 1 end, W)
check(near(Touch.for_key("jaw open", 0.2), W[1]) and near(W[1], 0.4),
    "touch alias collisions and mouth-last priority match expression output")
Touch.drag(-0.5, 0)
check(near(Touch.for_key("JawOpen", 0.2), 0.05), "drag invalidates its mutable index immediately")
Touch.reset(); Touch.update(); Touch.poke("eye"); now = 0.3; Touch.update()
Touch.for_key("JawOpen", 0)
m.eye.values = { JawOpen = 0.95 }; Touch.set_map(m)
check(near(Touch.for_key("JawOpen", 0), 0.95), "set_map invalidates targets when the same map object is reused")
Touch.release(); now = 0.5; Touch.update(); Touch.reset()
check(Touch.for_key("JawOpen", 0.2) == 0.2, "touch reset clears cached layers")
Cond.current, Cond.preview = keep_current, keep_preview; Cond.reset()
Touch.set_map(keep_map); os.clock = keep_clock

for i = 1, 60 do Perf.record("test_window", i / 1000) end
local metric = Perf.metrics.test_window
check(near(metric.avg, 30.5) and metric.max == 60 and metric.p95 == 57,
    "bounded timing window reports average, maximum and P95")
for _ = 1, 60 do Perf.record("test_window", 0.001) end
check(near(metric.avg, 1) and metric.max == 1 and metric.p95 == 1 and metric.count == 60,
    "old spikes leave the timing window without retaining unbounded samples")
print("TARGET LOOKUP FAILS:", failures)
assert(failures == 0, "target lookup regression")
