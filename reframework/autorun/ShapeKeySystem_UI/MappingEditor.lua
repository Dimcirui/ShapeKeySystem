-- 编辑表情映射草稿并提交后端命令。
--
-- 页面独立持有草稿，取消不改变已应用配置；d2d / ImGui 共用控件，后端负责验证和保存。
local D = require("ShapeKeySystem_UI.Draw")
local T = require("ShapeKeySystem_UI.Theme")
local W = require("ShapeKeySystem_UI.Widgets")
local I = require("ShapeKeySystem_UI.Input")
local U = require("ShapeKeySystem_Core.Util")
local Profile = require("ShapeKeySystem_Core.Profile")
local Expression = require("ShapeKeySystem_Core.Expression")
local E = {}
local C = T.c
local min, max = math.min, math.max
local TYPES = { "none", "s", "sum", "max", "min", "mul", "sub", "ref", "p", "const", "eye" }
local LABELS = { "无自动信号（手动）", "面部信号", "求和（sum）", "取最大值（max）", "取最小值（min）",
    "相乘（mul）", "相减（sub）", "引用映射", "原始通道", "常量", "眼球旋转" }
local HELP = { none = "不读取自动信号，可由捏脸、条件规则或外部插件控制。",
    s = "读取游戏面部动画信号，按 SKS 信号词典归一化。",
    sum = "将所有输入相加；可以超过 1，最终是否截断由全局设置决定。",
    max = "取所有输入中的最大值，常用于左右信号任一生效时驱动。",
    min = "取所有输入中的最小值，所有输入都较强时结果才较强。",
    mul = "将所有输入相乘，适合组合修正，例如张嘴 × 微笑。",
    sub = "第一个输入减去第二个输入；负值是否截断由全局设置决定。",
    ref = "引用另一映射在增益之前的值；不允许循环引用。",
    p = "直接读取游戏的原始通道；用途不明确时请先实测。优先使用有语义的面部信号。",
    const = "输出固定数值，不随面部动画变化。",
    eye = "读取眼球骨骼角度，除以满权重角度并截到 0～1；不属于面部信号。" }
local OPS = { sum = true, max = true, min = true, mul = true, sub = true }
local GROUP_KEYS, GROUP_LABELS = {}, {}
for i, g in ipairs(Expression.GROUPS) do GROUP_KEYS[i], GROUP_LABELS[i] = g.key, g.name end

-- 从语义名推断新映射的初始部位；原始通道名归入扩展，仍可手动修改。
local function group_for_signal(signal)
    local n = (signal or ""):lower()
    if n:find("brow", 1, true) then return "brow" end
    if n:find("eye", 1, true) or n:find("blink", 1, true) then return "eye" end
    if n:find("nose", 1, true) or n:find("cheek", 1, true) or n:find("puff", 1, true) then return "nose_cheek" end
    if n:find("tongue", 1, true) then return "tongue" end
    if n:find("jaw", 1, true) or n:find("chin", 1, true) or n:find("_jo", 1, true) then return "jaw" end
    if n:find("mouth", 1, true) or n:find("lip", 1, true) or n:find("smile", 1, true)
        or n:find("funnel", 1, true) or n:find("press", 1, true) or n:find("sneer", 1, true)
        or n:find("frown", 1, true) or n:find("dimple", 1, true) or n:find("stretch", 1, true) then
        return "mouth"
    end
    return "extra"
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end
function E.node_type(node)
    for _, kind in ipairs(TYPES) do if node[kind] ~= nil then return kind end end
    return "none"
end

-- 改变运算保留已有输入，避免 sum/max 切换时丢失绑定；切到叶节点时保留系数和曲线。
function E.change_type(node, kind)
    local old = E.node_type(node)
    local children = OPS[old] and node[old] or nil
    local leaf = Profile.node_of(node)
    leaf.k, leaf.curve = nil, nil -- 外层保留修饰器，包装输入时不能再乘一次系数或曲线。
    for _, key in ipairs(TYPES) do node[key] = nil end
    node.axis, node.sign, node.full_deg = nil, nil, nil
    if OPS[kind] then
        children = children or { old ~= "none" and leaf or { s = "blink.L" } }
        if kind == "sub" then
            children = { children[1] or { const = 0 }, children[2] or { const = 0 } }
        end
        node[kind] = children
    elseif kind == "s" then node.s = "blink.L"
    elseif kind == "ref" then node.ref = ""
    elseif kind == "p" then node.p = 1
    elseif kind == "const" then node.const = 0
    elseif kind == "eye" then node.eye, node.axis, node.sign = "L", "yaw", 1
    end
end

local function mark(draft) draft.dirty = true end

local function signal_title(sd)
    local label = sd.no_signal and "本游戏没有" or sd.label
    return sd.name == label and label or (sd.name .. " · " .. label)
end

-- 生成摘要，不修改节点或后端快照。
function E.summary(ctx, node)
    local kind = E.node_type(node)
    local label = LABELS[index_of(TYPES, kind)]
    local detail = ""
    if kind == "s" then
        for _, sd in ipairs(ctx.st.mapping.signals or {}) do
            if sd.name == node.s then
                label = signal_title(sd)
                detail = sd.note .. (sd.guessed and "（推测）" or "")
                break
            end
        end
        if label == LABELS[2] then label = tostring(node.s) end
    elseif OPS[kind] then
        label = label .. " · " .. #(node[kind] or {}) .. " 个输入"
        local parts = {}
        for _, child in ipairs(node[kind] or {}) do
            local ck = E.node_type(child)
            local value = child.s or child.ref or (child.const ~= nil and tostring(child.const)) or LABELS[index_of(TYPES, ck)]
            parts[#parts + 1] = value .. ((child.k and child.k ~= 1) and string.format(" ×%g", child.k) or "")
        end
        detail = table.concat(parts, kind == "sum" and " + " or " / ")
    elseif kind == "ref" then detail = "引用：" .. (node.ref or "未选择")
    elseif kind == "p" then label = (ctx.SKS and ctx.SKS.raw_label(node.p)) or ("原始通道 · " .. tostring(node.p))
    elseif kind == "const" then label = "常量 · " .. tostring(node.const)
    elseif kind == "eye" then
        label = (node.eye == "R" and "右眼" or "左眼") .. (node.axis == "pitch" and " · 垂直" or " · 水平")
        detail = (node.sign or 1) < 0 and "负方向" or "正方向"
    end
    if node.k and node.k ~= 1 then label = label .. string.format(" ×%g", node.k) end
    if node.curve then label = label .. " · 曲线" end
    return label, detail
end

-- 草稿以节点对象定位选中项，插入/移除相邻输入时不会把编辑状态移到另一条信号。
function E.tree(ctx, draft)
    local rows = {}
    local rootid = "map:" .. (draft.original_name or "new") .. ":root"
    local function visit(node, id, depth, parent, at, path)
        rows[#rows + 1] = { node = node, id = id, depth = depth, parent = parent, at = at, path = path }
        local kind = E.node_type(node)
        if OPS[kind] then
            for i, child in ipairs(node[kind]) do visit(child, id .. ":" .. i, depth + 1, node, i, path .. " / 输入 " .. i) end
        end
    end
    visit(draft.entry, rootid, 0, nil, nil, "输出")
    local selected = rows[1]
    for _, row in ipairs(rows) do if row.node == draft.selected then selected = row end end
    draft.selected = selected.node
    return rows, selected
end

local function draw_tree(ctx, draft, x, y, w, compact)
    local rows = E.tree(ctx, draft)
    local cy = y
    W.h2("映射结构", x, cy, w); cy = cy + 30
    D.text_mid("点击节点编辑参数", x, cy, 22, C.faint, W.small(), w); cy = cy + 28
    local hidden_depth
    local row_h = compact and 30 or 46
    for _, row in ipairs(rows) do
        if hidden_depth and row.depth <= hidden_depth then hidden_depth = nil end
        if not hidden_depth then
            local indent = min(row.depth * 14, w * 0.2)
            local rx, rw = x + indent, w - indent
            local kind = E.node_type(row.node)
            local branch = OPS[kind]
            local selected = draft.selected == row.node
            local label, detail = E.summary(ctx, row.node)
            local is_closed = draft.closed[row.id] == true
            D.rrect(rx, cy, rw, row_h, 4, selected and C.panel3 or C.ink)
            D.outline(rx, cy, rw, row_h, 4, 1, selected and C.brass or C.line)
            if row.depth > 0 then D.line(rx - 7, cy - 6, rx - 7, cy + row_h / 2, 1, C.line); D.line(rx - 7, cy + row_h / 2, rx, cy + row_h / 2, 1, C.line) end
            if branch then
                D.icon_tri(rx + 12, cy + 15, 4, not is_closed, C.brass)
                if I.click(rx, cy, 24, row_h) then
                    draft.closed[row.id] = not is_closed; is_closed = not is_closed
                    if is_closed then draft.selected = row.node; draft.picker = nil; W.open_search = nil end
                end
            end
            D.text_mid(label, rx + 26, cy + 2, compact and 26 or 22, selected and C.text or C.muted, W.small(), rw - 34)
            if not compact then D.text_mid(detail ~= "" and detail or HELP[kind], rx + 26, cy + 23, 20, C.faint, W.small(), rw - 34) end
            W.tooltip(label .. "\n" .. detail, rx, cy, rw, row_h)
            if I.click(rx + (branch and 24 or 0), cy, rw - (branch and 24 or 0), row_h) then
                draft.selected, draft.picker = row.node, nil
                W.open_search = nil
            end
            cy = cy + row_h + 6
            if branch and is_closed then hidden_depth = row.depth end
        end
    end
    return cy - y
end
local function line(text, x, y, w, color)
    D.text_mid(text, x, y, 24, color or C.muted, W.small(), w)
    W.tooltip(text, x, y, w, 24)
    return y + 26
end
local function slider(draft, id, label, x, y, w, value, lo, hi, step, fmt)
    D.text_mid(label, x, y, 28, C.muted, W.small(), 90)
    local changed, v = W.slider(id, x + 96, y, max(100, w - 96), 28, value, lo, hi,
        { step = step, fmt = fmt or "%.2f", value_w = 58 })
    if changed then mark(draft) end
    return v, y + 34
end

local function signal_picker(ctx, draft, node, id, x, y, w)
    local signals = ctx.st.mapping.signals or {}
    local selected
    for _, sd in ipairs(signals) do if sd.name == node.s then selected = sd end end
    local title = selected and signal_title(selected) or (node.s or "选择信号")
    local items = {}
    for _, sd in ipairs(signals) do
        items[#items + 1] = { value = sd.name,
            label = string.format("%s · %s%s", signal_title(sd), sd.note, sd.guessed and "（推测）" or "") }
    end
    draft.search = draft.search or {}
    local changed, value, height = W.search_select(draft.search, "map_signal_search:" .. id, x, y, w,
        items, title, { selected = node.s, placeholder = "搜索别名、通道名或用途…" })
    if changed then
        node.s = value; mark(draft)
        for _, sd in ipairs(signals) do if sd.name == value then selected = sd; break end end
    end
    y = y + height
    if selected then
        local side = selected.name:match("%.([LR])$")
        local purpose = "用途：" .. (selected.note ~= "" and selected.note or "用途尚未整理")
        if side then purpose = purpose .. (side == "L" and " · 角色左侧" or " · 角色右侧") end
        if selected.guessed then purpose = purpose .. " · 推测，需实测确认" end
        if selected.no_signal then purpose = purpose .. " · 本游戏没有这个信号，值恒为 0" end
        y = line(purpose, x, y, w, (selected.guessed or selected.no_signal) and C.warn or C.muted)
        local value = ctx.live.signal[selected.slot] or 0
        D.text_mid("实时信号：", x, y, 22, C.signal, W.small(), 72)
        D.text_mid(string.format("%.3f", value), x + 76, y, 22, C.signal, W.mono(), w - 76)
        y = y + 26
    end
    return y
end

local function draw_node(ctx, draft, node, id, x, y, w, depth, root)
    local cy = y
    local kind = E.node_type(node)
    local types, labels = TYPES, LABELS
    if not root then
        types, labels = {}, {}
        for i = 2, #TYPES do types[#types + 1], labels[#labels + 1] = TYPES[i], LABELS[i] end
    end
    local changed, selected = W.select("map_type:" .. id, x, cy, min(250, w), 28, labels, index_of(types, kind))
    if changed then
        if OPS[types[selected]] and depth >= 16 then ctx.toast("warn", "节点嵌套最多 16 层，此处请选择信号或其他叶节点")
        else E.change_type(node, types[selected]); kind = types[selected]; draft.picker = nil; mark(draft) end
    end
    cy = cy + 34
    cy = line(HELP[kind], x, cy, w)
    if kind == "s" then
        cy = signal_picker(ctx, draft, node, id, x, cy, w)
    elseif kind == "p" then
        local raw = ctx.st.mapping.raw
        local sl = raw and raw.slider
        if sl then
            node.p, cy = slider(draft, "map_param:" .. id, raw.term .. " 编号", x, cy, w, tonumber(node.p) or sl.min, sl.min, sl.max, 1, sl.fmt)
        else
            cy = line(raw and ("原始通道：" .. tostring(node.p)) or "本游戏没有原始通道", x, cy, w, raw and C.muted or C.warn)
        end
    elseif kind == "const" then
        node.const, cy = slider(draft, "map_const:" .. id, "固定数值", x, cy, w, node.const or 0, -5, 5, 0.01)
    elseif kind == "ref" then
        local names = {}
        for _, c in ipairs(ctx.st.expression.channels or {}) do if c.canonical ~= draft.entry.name then names[#names + 1] = c.canonical end end
        local selected_ref
        for i, name in ipairs(names) do if name == node.ref then selected_ref = i end end
        local ch, i = W.select("map_ref:" .. id, x, cy, w, 28, names, selected_ref, { placeholder = "选择其他映射" })
        if ch then node.ref = names[i]; mark(draft) end
        if node.ref == "" then cy = line("尚未选择引用目标", x, cy + 32, w, C.warn) else cy = cy + 34 end
    elseif kind == "eye" then
        local ch, i = W.select("map_eye:" .. id, x, cy, 110, 28, { "左眼", "右眼" }, node.eye == "R" and 2 or 1)
        if ch then node.eye = i == 2 and "R" or "L"; mark(draft) end
        ch, i = W.select("map_axis:" .. id, x + 118, cy, min(140, w - 118), 28,
            { "水平（yaw）", "垂直（pitch）" }, node.axis == "pitch" and 2 or 1)
        if ch then node.axis = i == 2 and "pitch" or "yaw"; mark(draft) end
        cy = cy + 34
        ch, i = W.select("map_sign:" .. id, x, cy, min(230, w), 28, { "正方向（+1）", "负方向（-1）" }, (node.sign or 1) < 0 and 2 or 1)
        if ch then node.sign = i == 2 and -1 or 1; mark(draft) end
        cy = cy + 34
        local override
        ch, override = W.toggle("单独设置满权重角度", x, cy, node.full_deg ~= nil)
        if ch then node.full_deg = override and 25 or nil; mark(draft) end
        cy = cy + 32
        if node.full_deg then node.full_deg, cy = slider(draft, "map_full:" .. id, "满权重角度", x, cy, w, node.full_deg, 1, 90, 1, "%d°") end
    elseif OPS[kind] then
        local list = node[kind]
        cy = line("包含 " .. #list .. " 个输入，点击映射树中的输入节点分别编辑。", x, cy, w)
        if kind ~= "sub" and depth < 16 then
            if W.button("＋ 添加输入", x, cy, 116, 26, { font = W.small() }) then
                local child = { s = "blink.L" }
                list[#list + 1], draft.selected, draft.picker = child, child, nil
                mark(draft)
            end
            cy = cy + 34
        end
    end
    if kind ~= "none" then
        local coefficient
        coefficient, cy = slider(draft, "map_k:" .. id, root and "输出系数" or "输入系数", x, cy, w, node.k or 1, -5, 5, 0.01, "×%.2f")
        if node.k ~= nil or coefficient ~= 1 then node.k = coefficient end
        local ch, on = W.toggle("响应曲线", x, cy, node.curve ~= nil)
        if ch then node.curve = on and { deadzone = 0, gamma = 1, gain = 1 } or nil; mark(draft) end
        cy = cy + 32
        if node.curve then
            cy = line("处理顺序：输入 × 系数 → 死区 → 幂指数 → 曲线增益", x, cy, w)
            node.curve.deadzone, cy = slider(draft, "map_dz:" .. id, "死区", x, cy, w, node.curve.deadzone or 0, 0, 0.95, 0.01)
            node.curve.gamma, cy = slider(draft, "map_gamma:" .. id, "幂指数", x, cy, w, node.curve.gamma or 1, 0.05, 5, 0.05)
            node.curve.gain, cy = slider(draft, "map_curve_gain:" .. id, "曲线增益", x, cy, w, node.curve.gain or 1, 0, 5, 0.01)
        end
    end
    return cy - y
end

-- 读取状态快照，草稿独立持有，取消不会改变已应用的映射。
function E.open(ctx, name, signal)
    local entry = name and ctx.st.mapping.entries[name] or {
        name = "", group = group_for_signal(signal), s = signal or "blink.L" }
    if not entry then return end
    W.open_search = nil
    ctx.state.name_form = nil
    ctx.state.mapping_draft = { entry = U.copy(entry), original_name = name,
        profile_id = ctx.st.mapping.profile_id, closed = {}, dirty = false, confirm_delete = false, selected = nil }
    W.reset_scroll("page:expr")
end

local function names_text(list) return table.concat(list or {}, "; ") end
local function parse_names(text)
    local list = {}
    for name in text:gsub("；", ";"):gmatch("[^;\r\n]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then list[#list + 1] = name end
    end
    return #list > 0 and list or nil
end

function E.draw_draft(ctx, x, y, w)
    local draft = ctx.state.mapping_draft
    if not draft then return 0 end
    local e, cy = draft.entry, y
    local id = "map:" .. (draft.original_name or "new")
    local title = draft.original_name and ("编辑映射：" .. draft.original_name) or "新建形态键映射"
    W.h2(title, x + 10, cy, w - 20)
    cy = cy + 32
    if W.button("应用映射", x + 10, cy, 100, 28, { kind = "primary", text_color = 0xFFFFFFFF, disabled = e.name == "" }) then
        if ctx.call("set_mapping", { entry = e, create = draft.original_name == nil }) then
            ctx.state.mapping_draft = nil
            ctx.toast("info", "映射已应用，保存配置后可保留")
            W.reset_scroll("page:expr")
            return 72
        end
    end
    if W.button("取消编辑", x + 118, cy, 100, 28) then
        ctx.state.mapping_draft = nil; W.reset_scroll("page:expr"); return 72
    end
    if draft.original_name and W.button("删除映射", x + 226, cy, 100, 28, { kind = "danger" }) then draft.confirm_delete = true end
    if draft.dirty then D.text_mid("草稿未应用", x + 342, cy, 28, C.warn, W.small(), w - 352) end
    cy = cy + 38
    if draft.confirm_delete then
        cy = line("删除此映射？仍被其他映射引用时无法删除。", x + 10, cy, w - 20, C.warn)
        if W.button("确认删除", x + 10, cy, 100, 28, { kind = "danger" }) then
            if ctx.call("remove_mapping", { name = draft.original_name }) then
                ctx.state.mapping_draft = nil; W.reset_scroll("page:expr"); return cy - y + 36
            end
        end
        if W.button("保留映射", x + 118, cy, 100, 28) then draft.confirm_delete = false end
        cy = cy + 36
    end
    if not draft.original_name then
        local names, seen = {}, {}
        for _, k in ipairs(ctx.st.sculpt.keys or {}) do
            if not ctx.st.mapping.entries[k.name] and not seen[k.name] then
                names[#names + 1] = { value = k.name, label = k.name }; seen[k.name] = true
            end
        end
        draft.search = draft.search or {}
        local ch, name, height = W.search_select(draft.search, "map_new_name", x + 10, cy, w - 20,
            names, e.name, { selected = e.name, placeholder = "输入形态键名称，或从已扫描的形态键选择…",
                empty = "没有匹配的已扫描形态键，可保留输入的名称",
                on_query = function(t) e.name = t; mark(draft) end })
        if ch then e.name = name; mark(draft) end
        cy = cy + height

    end
    D.text_mid("部位类型", x + 10, cy, 28, C.muted, W.small())
    local groups, labels = U.copy(GROUP_KEYS), U.copy(GROUP_LABELS)
    if e.group and index_of(groups, e.group) == 1 and e.group ~= groups[1] then groups[#groups + 1], labels[#labels + 1] = e.group, e.group end
    local ch, i = W.select("map_group:" .. id, x + 88, cy, 160, 28, labels, index_of(groups, e.group))
    if ch then e.group = groups[i]; mark(draft) end
    if e.guessed then W.chip("推测", x + 262, cy + 5, C.warn) end
    if e.extension then W.chip("扩展", x + 318, cy + 5, C.faint) end
    cy = cy + 40
    if e.group == "gaze" then
        D.text_mid("视线组", x + 10, cy, 28, C.muted, W.small())
        ch, i = W.select("map_gaze:" .. id, x + 88, cy, min(260, w - 100), 28,
            { "不分组", "眼睑跟随（eye_look）", "虹膜移动（look）" }, e.gaze_set == "eye_look" and 2 or e.gaze_set == "look" and 3 or 1)
        if ch then e.gaze_set = ({ false, "eye_look", "look" })[i] or nil; mark(draft) end
        cy = cy + 34
    end
    local wide = w >= 680
    local tree_w = wide and min(340, math.floor((w - 44) * 0.42)) or w - 20
    local tree_h = draw_tree(ctx, draft, x + 10, cy, tree_w, not wide)
    local _, selected = E.tree(ctx, draft)
    local sx = wide and x + tree_w + 34 or x + 10
    local sy = wide and cy or cy + tree_h + 16
    local sw = wide and w - tree_w - 44 or w - 20
    local iy = sy
    W.h2("当前节点设置", sx, iy, sw); iy = iy + 30
    iy = line(selected.path, sx, iy, sw, C.brass)
    if selected.parent then
        local kind = E.node_type(selected.parent)
        local list = selected.parent[kind]
        if W.button("移除当前输入", sx, iy, 128, 26, { kind = "danger", font = W.small(), disabled = kind == "sub" or #list <= 1 }) then
            table.remove(list, selected.at)
            draft.selected, draft.picker, draft.closed = selected.parent, nil, {}
            mark(draft)
            _, selected = E.tree(ctx, draft)
        end
        iy = iy + 34
    end
    iy = iy + draw_node(ctx, draft, selected.node, selected.id, sx, iy, sw, selected.depth, selected.parent == nil)
    if wide then D.line(sx - 12, cy, sx - 12, max(cy + tree_h, iy), 1, C.line) end
    cy = max(cy + tree_h, iy) + 18
    local metadata = draft.metadata == true
    if W.header("映射说明与标记", x + 10, cy, w - 20, metadata) then draft.metadata = not metadata end
    cy = cy + 32
    if metadata then
        W.text_box("map_note:" .. id, x + 10, cy, w - 20, 28, e.note, "映射说明…", function(t) e.note = t; mark(draft) end)
        cy = cy + 34
        local v
        ch, v = W.toggle("推测映射", x + 10, cy, e.guessed == true)
        if ch then e.guessed = v; mark(draft) end
        ch, v = W.toggle("扩展通道", x + 174, cy, e.extension == true)
        if ch then e.extension = v; mark(draft) end
        cy = cy + 34
    end
    local adv = draft.advanced == true
    if W.header("网格名称与排除规则", x + 10, cy, w - 20, adv) then draft.advanced = not adv end
    cy = cy + 32
    if adv then
        cy = line("其他网格名称（any），用分号分隔，前面的名称优先。", x + 10, cy, w - 20)
        if draft.any_text == nil then draft.any_text = names_text(e.any) end
        W.text_box("map_any:" .. id, x + 10, cy, w - 20, 28, draft.any_text, "名称1; 名称2…", function(t)
            draft.any_text, e.any = t, parse_names(t); mark(draft)
        end)
        cy = cy + 34
        cy = line("排除映射（unless）：这些映射在同一部件匹配时，本映射不驱动。", x + 10, cy, w - 20)
        if draft.unless_text == nil then draft.unless_text = names_text(e.unless) end
        W.text_box("map_unless:" .. id, x + 10, cy, w - 20, 28, draft.unless_text, "映射名1; 映射名2…", function(t)
            draft.unless_text, e.unless = t, parse_names(t); mark(draft)
        end)
        cy = cy + 34
    end
    return cy - y + 8
end

-- 配置级操作；浏览中的其他配置保持只读，先应用配置再编辑。
function E.toolbar(ctx, x, y, w)
    local s, m, profile = ctx.state, ctx.st.mapping, ctx.st.expression.profile
    local draft = s.mapping_draft
    if draft and draft.profile_id ~= m.profile_id then s.mapping_draft, draft = nil, nil end
    if not profile or s.browsing then return 0 end
    local cy = y
    W.panel_box(x, cy, w, 44)
    if W.button("＋ 新建映射", x + 10, cy + 8, 116, 28) then E.open(ctx) end
    local function save_as()
        W.start_text(s, "name_form", { title = "保存表情映射配置", text = profile.name .. " 自定义",
            on_submit = function(name) if ctx.call("save_profile", { as_name = name }) then s.mapping_draft = nil end end })
    end
    if W.button("保存配置", x + 134, cy + 8, 100, 28, { kind = m.dirty and "primary" or nil }) then
        if s.mapping_draft then ctx.toast("warn", "请先应用或取消当前映射草稿，再保存配置")
        elseif profile.source == "user" then ctx.call("save_profile", {}) else save_as() end
    end
    if W.button("另存配置", x + 242, cy + 8, 100, 28) then
        if s.mapping_draft then ctx.toast("warn", "请先应用或取消当前映射草稿，再保存配置") else save_as() end
    end
    if W.button("恢复配置", x + 350, cy + 8, 100, 28, { disabled = not m.dirty }) then s.confirm_restore = true end
    cy = cy + 50
    if m.dirty then cy = line("映射修改未保存 · 保存为用户配置后，可设为装备默认", x + 10, cy, w - 20, C.warn) end
    if s.confirm_restore then
        cy = line("恢复加载时的映射，放弃所有未保存修改？", x + 10, cy, w - 20, C.warn)
        if W.button("确认恢复", x + 10, cy, 100, 28, { kind = "danger" }) then
            if ctx.call("revert_mappings", {}) then s.confirm_restore, s.mapping_draft = nil, nil end
        end
        if W.button("继续编辑", x + 118, cy, 100, 28) then s.confirm_restore = nil end
        cy = cy + 36
    end
    cy = cy + W.text_form(s, "name_form", "mapping_profile_name", x, cy, w)
    return cy - y
end
return E
