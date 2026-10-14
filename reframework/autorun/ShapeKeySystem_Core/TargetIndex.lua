-- 索引条件表情和互动目标的归一化名称。
--
-- 索引归调用模块所有，配置或拖拽值变化时必须重建；同名目标保留源表遍历顺序，逐项参与混合。
local I = {}

function I.norm(name) return (tostring(name):gsub("[%s_%-%.]", ""):lower()) end

-- 源目标表保持不变；桶内数值只供读取，不得作为可编辑配置返回。
function I.build(values)
    local index = {}
    for name, value in pairs(values) do
        local key = I.norm(name)
        local bucket = index[key]
        if not bucket then bucket = {}; index[key] = bucket end
        bucket[#bucket + 1] = value
    end
    return index
end

function I.blend(index, key, value, alpha)
    local bucket = index[key]
    if bucket then
        for _, target in ipairs(bucket) do value = value * (1 - alpha) + target * alpha end
    end
    return value
end
return I
