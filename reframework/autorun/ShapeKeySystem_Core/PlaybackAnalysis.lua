-- 本次播放分析：纯 Lua，实例拥有帧游标和计数，公开状态只含普通数据，不持有引擎对象。
-- 按实际经过的录制帧统计绝对幅值 > 1% 的命中，暂停不计，循环累计，跳转只计目标帧。
local Profile = require("ShapeKeySystem_Core.Profile")
local A = {}
A.__index = A
local THRESHOLD = 0.01

-- 重建有命中的排名；同次数按参数编号排序，绑定信息变化不改变已经累积的计数。
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

-- 单帧计数，不使用渲染帧数或钩子次数；每次经过静止录制帧也正常计入一次。
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

-- 跨循环时完整周期用预计算总量相乘，避免高倍速或短录制造成逐循环遍历。
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

-- 跳转后统计目标所显示的录制帧，不补记跳过的帧；再次经过旧帧视为一次新播放。
function A:seek(elapsed)
    local frames, lo, hi = self.clip.frames, 1, #self.clip.frames
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if frames[mid].t <= elapsed then lo = mid else hi = mid - 1 end
    end
    self:count(frames[lo]); self.cursor = lo + 1
    self:publish()
end

-- 当前编译配置的信号依赖包括嵌套运算、原始 p 节点和 ref 间接引用；仅修订变化时重建。
function A:bindings(prog, signals, channels, revision)
    if revision ~= nil and self.binding_revision == revision then return end
    self.binding_revision = revision
    for param, row in pairs(self.by_param) do
        local aliases, notes, guessed = {}, {}, false
        for _, sig in ipairs(signals or {}) do
            if sig.param == param then
                aliases[#aliases + 1] = sig.name
                if sig.note and sig.note ~= "" then notes[#notes + 1] = sig.note end
                guessed = guessed or sig.guessed == true
            end
        end
        local param_name = string.format("fcParam_%03d", param)
        -- 通用 fcParam 名称只是补全编号，不重复显示为“fcParam · fcParam”。
        local semantic = {}
        for _, alias in ipairs(aliases) do if alias ~= param_name then semantic[#semantic + 1] = alias end end
        row.label = #semantic > 0 and (table.concat(semantic, " / ") .. " · " .. param_name) or param_name
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

-- 停止后释放大体积解码帧，仅保留排名和参数元数据；绑定仍可跟随当前已应用配置刷新。
function A:finish()
    self.clip, self.totals = nil, nil
    self.state.finished = true
end

-- raw 的幅值单位由游戏适配器给出，仅用于活跃判定；这一步不把 raw 当成 final 信号。
function A.new(clip, unit, file)
    assert(type(unit) == "number" and unit > 0 and unit < math.huge, "播放分析缺少游戏信号幅值单位")
    local self = setmetatable({ clip = clip, unit = unit, cursor = 2, by_param = {}, totals = {},
        state = { rev = 0, file = file, mode = clip.track, sampled_frames = 0, threshold = THRESHOLD,
            rows = {}, active_signals = 0, bound_signals = 0, unbound_signals = 0 } }, A)
    for param, column in pairs(clip.map) do
        self.by_param[param] = { param = param, hits = 0, mappings = {}, present_count = 0,
            label = string.format("fcParam_%03d", param), purpose = "词典尚未标注用途" }
        local total = 0
        for _, frame in ipairs(clip.frames) do if hit(frame.values[column], unit) then total = total + 1 end end
        self.totals[param] = total
    end
    self:count(clip.frames[1]); self:publish()
    return self
end
return A
