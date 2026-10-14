-- 统计录制信号命中次数及当前配置的形态键绑定。
--
-- 实例拥有录制帧游标和累计计数，不持有引擎对象。每次经过幅值超过 1% 的录制帧计一次命中，
-- 相同时间的重复调用不计数，循环累计，跳转只计目标帧。
local Profile = require("ShapeKeySystem_Core.Profile")
local A = {}
A.__index = A
local THRESHOLD = 0.01

function A:publish()
    local s, rows, bound = self.state, {}, 0
    for _, row in pairs(self.by_param) do
        if row.hits > 0 then
            rows[#rows + 1] = row
            if #row.mappings > 0 then bound = bound + 1 end
        end
    end
    table.sort(rows, function(a, b) return a.hits > b.hits or (a.hits == b.hits and a.param < b.param) end)
    s.rows, s.active_signals, s.bound_signals, s.unbound_signals = rows, #rows, bound, #rows - bound
    s.rev = s.rev + 1
end

local function hit(value, unit) return math.abs(value / unit) > THRESHOLD end

function A:count(frame)
    self.state.sampled_frames = self.state.sampled_frames + 1
    for param, column in pairs(self.clip.map) do
        if hit(frame.values[column], self.unit) then self.by_param[param].hits = self.by_param[param].hits + 1 end
    end
end

function A:range(elapsed)
    local frames, cursor = self.clip.frames, self.cursor
    while cursor <= #frames and frames[cursor].t <= elapsed do self:count(frames[cursor]); cursor = cursor + 1 end
    local changed = cursor ~= self.cursor
    self.cursor = cursor
    return changed
end

-- 完整循环使用预计算总量，避免逐循环遍历录制帧。
function A:advance(elapsed, loops)
    local changed = false
    if loops > 0 then
        self:range(self.clip.duration)
        if loops > 1 then
            self.state.sampled_frames = self.state.sampled_frames + (loops - 1) * #self.clip.frames
            for param, total in pairs(self.totals) do
                self.by_param[param].hits = self.by_param[param].hits + (loops - 1) * total
            end
        end
        self:count(self.clip.frames[1]); self.cursor = 2
        changed = true
    end
    if self:range(elapsed) then changed = true end
    if changed then self:publish() end
end

-- 只统计目标显示帧，不补计跳过的帧。
function A:seek(elapsed)
    local frames, lo, hi = self.clip.frames, 1, #self.clip.frames
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if frames[mid].t <= elapsed then lo = mid else hi = mid - 1 end
    end
    self:count(frames[lo]); self.cursor = lo + 1
    self:publish()
end

-- 修订变化时重建绑定依赖，保留累计命中次数；`Profile.needs` 包含间接引用。
function A:bindings(prog, signals, channels, revision)
    if revision ~= nil and self.binding_revision == revision then return end
    self.binding_revision = revision
    for param, row in pairs(self.by_param) do
        local aliases, notes, guessed = {}, {}, false
        for _, sig in ipairs(signals or {}) do
            if not sig.no_signal and sig.key == param then
                aliases[#aliases + 1] = sig.name
                if sig.note and sig.note ~= "" then notes[#notes + 1] = sig.note end
                guessed = guessed or sig.guessed == true
            end
        end
        local param_name = self.label(param)
        -- 字典别名与原始通道名相同时，只显示一次。
        local semantic = {}
        for _, alias in ipairs(aliases) do if alias ~= param_name then semantic[#semantic + 1] = alias end end
        row.label = #semantic > 0 and (table.concat(semantic, " / ") .. " · " .. param_name) or param_name
        row.signal = #semantic > 0 and semantic[1] or param_name
        row.purpose = #notes > 0 and table.concat(notes, "；") or "词典尚未标注用途"
        row.guessed, row.mappings, row.present_count = guessed, {}, 0
    end
    if prog then
        for slot, c in ipairs(prog.channels) do
            local params = Profile.needs(prog, { [slot] = true })
            for _, param in ipairs(params) do
                local row = self.by_param[param]
                if row then
                    local current = channels and channels[slot]
                    local present = current and current.present == true or false
                    row.mappings[#row.mappings + 1] = { name = c.name, present = present }
                    if present then row.present_count = row.present_count + 1 end
                end
            end
        end
    end
    self.state.profile = prog and prog.name or "无表情配置"
    self:publish()
end

-- 释放解码帧，保留排名供停止后查看和更新绑定。
function A:finish()
    self.clip, self.totals = nil, nil
    self.state.finished = true
end

-- `unit` 只用于活跃判定，不将原版输入转换为游戏求值后的最终信号。
function A.new(clip, unit, file, label, checkpoint)
    assert(type(unit) == "number" and unit > 0 and unit < math.huge, "播放分析缺少游戏信号幅值单位")
    local self = setmetatable({ clip = clip, unit = unit, label = label or tostring, cursor = 2, by_param = {}, totals = {},
        state = { rev = 0, file = file, mode = clip.track, sampled_frames = 0, threshold = THRESHOLD,
            rows = {}, active_signals = 0, bound_signals = 0, unbound_signals = 0 } }, A)
    for param, column in pairs(clip.map) do
        self.by_param[param] = { param = param, hits = 0, mappings = {}, present_count = 0,
            label = self.label(param), purpose = "词典尚未标注用途" }
        self.totals[param] = 0
    end
    -- 连续共享快照一次判定幅值，按帧数累计，空差分不重复扫描全部参数。
    local frames, first = clip.frames, 1
    while first <= #frames do
        local values, last = frames[first].values, first
        while last < #frames and frames[last + 1].values == values do
            last = last + 1
            if checkpoint and last % 128 == 0 then checkpoint(128, last, #frames) end
        end
        for param, column in pairs(clip.map) do
            if hit(values[column], unit) then self.totals[param] = self.totals[param] + last - first + 1 end
        end
        if checkpoint then checkpoint(clip.n or #values, last, #frames) end
        first = last + 1
    end
    self:count(clip.frames[1]); self:publish()
    return self
end
return A
