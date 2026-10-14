-- 校验录制数据并按时间采样。
--
-- 解码结果拥有只读快照；未变化的差分帧共享快照，源数据保持不变，不持有引擎对象。
-- 差分列是 `params` 的一基下标，值为绝对值，空差分保留前帧；格式见 docs/plans/shape-key-system-api.md。
local R = {}
local abs, min, max = math.abs, math.min, math.max

function R.finite(v, bound, integer)
    return type(v) == "number" and v == v and abs(v) <= bound and (not integer or v % 1 == 0)
end

-- 拒绝对象键和缺号数组；调用方另行检查是否允许空数组。
local function array(t, limit, label, checkpoint)
    assert(type(t) == "table", label .. " 必须是数组")
    local n = #t
    assert(n <= limit, label .. " 超过数量上限")
    local count = 0
    for k in pairs(t) do
        assert(R.finite(k, n, true) and k >= 1, label .. " 包含无效下标或对象键")
        count = count + 1
        if checkpoint and count % 128 == 0 then checkpoint(128) end
    end
    assert(count == n, label .. " 包含缺号")
    return n
end

-- 同时校验已声明的两条轨道，拒绝错误后不得得到可播放的部分结果。
function R.decode(data, track, catalog, game, checkpoint)
    assert(type(data) == "table", "录制文件无法读取")
    assert(track == "raw" or track == "final", "未知播放模式")
    local compact = data.schema == "fcparam.recording/2"
    assert(compact or data.schema == "fcparam.recording/1", "不支持的录制 schema")
    assert(data.game == nil or data.game == game, "录制所属游戏不匹配")
    assert(R.finite(data.duration, 300) and data.duration > 0, "录制时长必须在 0～300 秒之间")
    if compact then
        assert(data.encoding == "quantized-delta" and data.raw_scale == 10000000, "原始轨编码或量化比例无效")
        assert(data.final_scale == nil or data.final_scale == 100000, "最终轨量化比例无效")
    end
    local n = array(data.params, 200, "params")
    assert(n >= 1, "录制没有参数")
    local map, hashes = {}, {}
    for i, row in ipairs(data.params) do
        assert(type(row) == "table" and R.finite(row.param, 200, true) and row.param >= 1 and not map[row.param],
            "录制包含无效或重复参数编号")
        assert(R.finite(row.hash, 4294967295, true) and row.hash >= 0, "录制参数哈希无效")
        assert(catalog and catalog[row.param] == row.hash, string.format("参数 %03d 名称哈希与当前游戏不匹配", row.param))
        map[row.param], hashes[i] = i, row.hash
    end
    local count = array(data.frames, 9001, "frames", checkpoint)
    assert(count >= 2, "录制至少需要两帧")
    local has_final = compact and data.final_scale ~= nil or (not compact and data.frames[1].final ~= nil)
    assert(track ~= "final" or has_final, "此录制没有 final 最终信号，请选择原版输入重播")
    local previous, frames, prev_time = {}, {}, -1
    local tracks = has_final and { "raw", "final" } or { "raw" }
    for i, row in ipairs(data.frames) do
        assert(type(row) == "table" and R.finite(row.t, 300) and row.t >= 0 and row.t > prev_time,
            "帧时间必须有限、非负且严格递增")
        prev_time = row.t
        assert(has_final or (row.final == nil and row.df == nil), "最终轨数据缺少 final_scale")
        for _, key in ipairs(tracks) do
            local scale = compact and data[key .. "_scale"] or 1
            local limit = (key == "raw" and 1000 or 100000) * scale
            local values
            if not compact or i == 1 then
                assert(array(row[key], n, "完整 " .. key .. " 帧", checkpoint) == n, "完整帧长度与 params 不一致")
                if key == track then values = {} end
                for column = 1, n do
                    local v = row[key][column]
                    assert(R.finite(v, limit, compact), "完整帧数值无效")
                    if values then values[column] = v / scale end
                    if checkpoint and column % 128 == 0 then checkpoint(128) end
                end
            else
                assert(row[key] == nil, "差分帧不能同时带完整轨道")
                local delta = row[key == "raw" and "d" or "df"]
                local dn = delta ~= nil and array(delta, n * 2, key .. " 差分", checkpoint) or 0
                assert(dn % 2 == 0, "差分必须是列号与数值对")
                if key == track then
                    values = previous[key]
                    if dn > 0 then
                        -- 快照发布后只读；变更帧先复制，不能修改共享的前帧值。
                        values = {}
                        for column = 1, n do values[column] = previous[key][column] end
                        if checkpoint then checkpoint(n) end
                    end
                end
                local last = 0
                for k = 1, dn, 2 do
                    local col, value = delta[k], delta[k + 1]
                    assert(R.finite(col, n, true) and col > last, "差分列号越界、重复或乱序")
                    assert(R.finite(value, limit, true), "差分数值无效")
                    if values then values[col] = value / scale end
                    last = col
                    if checkpoint and k % 128 == 127 then checkpoint(128) end
                end
            end
            if key == track then previous[key] = values end
        end
        if checkpoint then checkpoint(1, i, count) end
        frames[i] = { t = row.t, values = previous[track] }
    end
    assert(prev_time == data.duration, "最后一帧时间与 duration 不一致")
    return { frames = frames, duration = data.duration, map = map, hashes = hashes, n = n,
        track = track, has_final = has_final }
end

-- 更新回调逐次推进准备任务；全量校验和附加统计完成前不返回可播放结果。
-- 每片预算为 1.5 ms 或 4096 工作单位，在检查点让出；文件读取和 JSON 解析由调用方完成。
function R.prepare(data, track, catalog, game, complete)
    local job = { stage = "decode", progress = 0 }
    local deadline, remaining
    local function checkpoint(work, frame, count)
        if frame then job.progress = frame / count end
        remaining = remaining - work
        if remaining <= 0 or os.clock() >= deadline then coroutine.yield() end
    end
    job.thread = coroutine.create(function()
        local decoded = R.decode(data, track, catalog, game, checkpoint)
        if complete then
            job.stage, job.progress = "analysis", 0
            return decoded, complete(decoded, checkpoint)
        end
        return decoded
    end)
    -- 每次恢复都会重置预算；错误向调用方传播，由播放模块负责取消和恢复。
    function job:step()
        deadline, remaining = os.clock() + 0.0015, 4096
        local ok, decoded, extra = coroutine.resume(self.thread)
        assert(ok, decoded)
        self.done = coroutine.status(self.thread) == "dead"
        return self.done, decoded, extra
    end
    return job
end

-- 在相邻录制帧之间插值；`out` 可复用，调用方拥有采样结果。
function R.sample(clip, elapsed, out)
    assert(R.finite(elapsed, 1e9), "播放时间无效")
    local frames, lo, hi = clip.frames, 1, #clip.frames
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if frames[mid].t <= elapsed then lo = mid else hi = mid - 1 end
    end
    local a, b = frames[lo], frames[min(lo + 1, #frames)]
    local u = a == b and 0 or max(0, min(1, (elapsed - a.t) / (b.t - a.t)))
    out = out or {}
    for col = 1, clip.n do out[col] = a.values[col] + (b.values[col] - a.values[col]) * u end
    return out
end
return R
