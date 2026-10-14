-- 记录更新、绘制和录制播放的独立耗时窗口。
--
-- 由 Lua 回调调用，仅持有最多 60 个样本；分类可能重叠，不得相加作为总耗时。
local P = { metrics = {} }
local windows = {}
local SIZE = 60

-- 输入为秒，公开指标为毫秒；P95 每满一窗更新，平均值和峰值随调用更新。
function P.record(name, elapsed)
    local window = windows[name]
    if not window then
        window = { values = {}, next = 1, sum = 0, max = 0, calls = 0 }
        windows[name] = window
        P.metrics[name] = { avg = 0, max = 0, p95 = 0, last = 0, count = 0 }
    end
    local ms = elapsed * 1000
    local values, slot = window.values, window.next
    local old = values[slot] or 0
    values[slot], window.sum = ms, window.sum - old + ms
    if ms >= window.max then window.max = ms
    elseif old == window.max then
        window.max = 0
        for _, v in ipairs(values) do window.max = math.max(window.max, v) end
    end
    window.next, window.calls = slot % SIZE + 1, window.calls + 1
    local metric = P.metrics[name]
    metric.avg, metric.max, metric.last, metric.count = window.sum / #values, window.max, ms, #values
    if window.calls == 1 or window.calls % SIZE == 0 then
        local sorted = {}
        for i, v in ipairs(values) do sorted[i] = v end
        table.sort(sorted)
        metric.p95 = sorted[math.ceil(#sorted * 0.95)]
    end
end
return P
