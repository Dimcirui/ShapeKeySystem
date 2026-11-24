-- 页面内文本输入：布局回调只登记物理像素矩形；ImGui 控件仅在 re.on_frame 中创建。
-- REF-IME 接管标准 InputText 的输入法。窗口和控件 ID 固定，不逐帧抢焦点或调用游戏输入框。
local T = require("ShapeKeySystem_UI.Theme")
local D = require("ShapeKeySystem_UI.Draw")
local X = { fields = {}, active = nil }
-- ImGui 收不到鼠标按键时（RE4R 未开 REF 菜单），由面板的点击代为激活或释放输入框。
local focus_id, drop_id, claimed = nil, nil, false
local max, floor = math.max, math.floor
local FLAGS = 1 | 2 | 4 | 8 | 16 | 32 | 128 | 256 | 4096 -- NoFocusOnAppearing

local function color(c)
    return Vector4f.new(((c >> 16) & 255) / 255, ((c >> 8) & 255) / 255,
        (c & 255) / 255, ((c >> 24) & 255) / 255)
end

-- 每次布局重建可见控件；关闭面板、切页和渲染器重置时丢弃旧矩形。
function X.clear() X.fields, X.active, focus_id, drop_id = {}, nil, nil, nil end
function X.begin_layout() X.fields, claimed = {}, false end
function X.focus(id)
    claimed = true
    if X.active ~= id then focus_id = id end
end
-- 点在输入框以外：下一帧不提交当前激活的输入框，ImGui 随之清掉它的激活状态。
function X.blur()
    if not claimed and X.active then drop_id = X.active end
end
function X.remove(id)
    for i = #X.fields, 1, -1 do if X.fields[i].id == id then table.remove(X.fields, i) end end
    if X.active == id then X.active = nil end
end
function X.register(id, x, y, w, h, value, on_change, flags)
    local c = D.get_clip()
    -- 与自绘文字一致：被滚动区部分裁剪的输入框不创建可点击的 ImGui 窗口。
    if c and (x < c[1] or y < c[2] or x + w > c[3] or y + h > c[4]) then return false end
    if w <= 16 or h <= 0 then return false end
    local s = D.S
    X.fields[#X.fields + 1] = { id = id, lx = x, ly = y, lw = w, lh = h, x = (x + 8) * s, y = y * s,
        w = (w - 16) * s, h = h * s, px = max(6, floor(T.font.body * s + 0.5)),
        text = value or "", on_change = on_change, flags = flags or 0 }
    return true
end

-- 单个透明窗口只覆盖原输入框内部；即使 InputText 抛错也归还所有 ImGui 栈资源。
local function draw_field(f)
    local focus = focus_id == f.id
    if focus then focus_id = nil end
    local nv, nc, window, width, font = 0, 0, false, false, false
    local text, active, ret
    local ok, err = pcall(function()
        local function var(i, v) imgui.push_style_var(i, v); nv = nv + 1 end
        local function col(i, v) imgui.push_style_color(i, color(v)); nc = nc + 1 end
        var(2, Vector2f.new(0, 0)); var(4, 0.0); var(5, Vector2f.new(1, 1))
        var(13, 0.0); var(11, Vector2f.new(0, max(0, (f.h - f.px) / 2)))
        col(0, T.c.text); col(7, 0); col(8, 0); col(9, 0)
        imgui.set_next_window_pos(Vector2f.new(f.x, f.y), 1)
        imgui.set_next_window_size(Vector2f.new(f.w, f.h), 1)
        if focus and imgui.set_next_window_focus then imgui.set_next_window_focus() end
        local visible = imgui.begin_window("##sks_inline_" .. f.id, nil, FLAGS)
        window = true
        if visible == false then return end
        if imgui.push_font_size then imgui.push_font_size(f.px + 0.0); font = true end
        imgui.push_item_width(f.w + 0.0); width = true
        if focus and imgui.set_keyboard_focus_here then imgui.set_keyboard_focus_here(0) end
        local _
        ret, text = imgui.input_text("##sks_text_" .. f.id, f.text, f.flags or 0)
        active = imgui.is_item_active()
    end)
    if width then imgui.pop_item_width() end
    if font then imgui.pop_font_size() end
    if window then imgui.end_window() end
    if nc > 0 then imgui.pop_style_color(nc) end
    if nv > 0 then imgui.pop_style_var(nv) end
    if not ok then error(err, 0) end
    if active then X.active = f.id end
    if type(text) == "string" and text ~= f.text then
        f.text = text
        if f.on_change then f.on_change(text) end
    end
    local is_enter = (ret == true and ((f.flags or 0) & 32) ~= 0)
    if not is_enter and active then
        local ok_k, k_down = pcall(function() return reframework:is_key_down(0x0D) end)
        if ok_k and k_down then is_enter = true end
    end
    if is_enter then
        if f.on_change and type(text) == "string" then f.on_change(text) end
        X.active = nil
    end
end

-- 下拉浮层打开时 ImGui 输入窗口会被移除（否则盖住浮层）：在浮层之前自绘各框的文字。
function X.draw_static()
    local f = D.font(T.font.body)
    for _, fd in ipairs(X.fields) do
        if fd.text ~= "" then D.text_mid(fd.text, fd.lx + 8, fd.ly, fd.lh, T.c.text, f, fd.lw - 16) end
    end
end

-- 输入回调更新页面状态；Enter/Esc 留给 ImGui/输入法，不把选字按键当成保存或取消。
function X.draw()
    X.active = nil
    local drop = drop_id
    drop_id = nil
    for _, f in ipairs(X.fields) do
        if f.id ~= drop then draw_field(f) end
    end
end
return X
