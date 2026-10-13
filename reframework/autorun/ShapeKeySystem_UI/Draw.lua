-- ShapeKeySystem panel: thin drawing layer with two backends.
--   * "d2d":   reframework-d2d (optional plugin), drawn from its own callback
--   * "imgui": REFramework's ImGui background draw list, drawn from re.on_frame. For players
--     without d2d (frame drops, Linux / Proton). No images: the face art on the basic page is
--     decoration only and is left out. Needs a REFramework with ImDrawList in Lua (2025-05) and
--     dynamic font sizes (2025-07); the built-in font (Roboto CJK SC) has the Chinese glyphs.
--   * every coordinate is logical; D.S (ui scale) converts to screen pixels
--   * d2d has no clipping: D.push_clip keeps a clip rect; rectangles are cut to it, text and
--     images that do not fit inside it entirely are skipped (the same on both backends)
--   * fonts are created on first use per (size, bold, mono) and text sizes are cached
--   * D.defer(fn) runs fn after the page (dropdown popups, tooltips) without any clip

local T = require("ShapeKeySystem_UI.Theme")

local D = {}

D.S = 1.0
local floor, max, min = math.floor, math.max, math.min

local clip_stack = {}
local clip = nil          -- { x0, y0, x1, y1 } logical

local fonts = {}
local measure_cache, measure_count = {}, 0
local images = {}
local deferred = {}

-- ---------------------------------------------------------------- backends
D.BACKENDS = { "auto", "d2d", "imgui" }
D.backend = nil           -- "d2d" / "imgui" / nil (nothing to draw with: no panel)

function D.has_d2d()
    return type(d2d) == "table" and type(d2d.register) == "function" and d2d.fill_rect ~= nil
        and type(d2d.Font) == "table"
end

function D.has_imgui()
    return type(imgui) == "table" and imgui.get_background_draw_list ~= nil
        and imgui.calc_text_size ~= nil and imgui.get_display_size ~= nil
end

-- backend for a setting value ("auto" = d2d when installed); the other one when the wanted one is missing
function D.pick(pref)
    local d, g = D.has_d2d(), D.has_imgui()
    if pref == "imgui" then return (g and "imgui") or (d and "d2d") or nil end
    return (d and "d2d") or (g and "imgui") or nil
end

function D.available() return D.backend ~= nil end
function D.images() return D.backend == "d2d" end

local A, A_src = {}, nil
local function noop() end

-- the d2d table in use, with fallbacks for anything missing: ArmorVariantManager's UI DLL ships
-- its own d2d build, which may replace reframework-d2d's global table
local function bind_d2d(g)
    for _, k in ipairs({ "text", "fill_rect", "outline_rect", "line", "fill_circle", "circle", "image" }) do
        A[k] = g[k] or noop
    end
    A.fill_rounded_rect = g.fill_rounded_rect or function(x, y, w, h, _, _, c) A.fill_rect(x, y, w, h, c) end
    A.rounded_rect = g.rounded_rect or function(x, y, w, h, _, _, t, c) A.outline_rect(x, y, w, h, t, c) end
    A.oval = g.oval or function(x, y, rx, ry, t, c) A.circle(x, y, math.max(rx, ry), t, c) end
    A.fill_quad = g.fill_quad or noop
    A.surface_size = g.surface_size or function() return 1920, 1080 end
    A.new_font = function(family, px, bold) return g.Font.new(family, px, bold) end
end

-- ImGui: colours are ABGR (d2d and Theme are ARGB); points are {x, y} tables (a list of plain
-- numbers is accepted without error but draws nothing - ArmorVariantManager's Rise port)
local DL = nil            -- background draw list of the current ImGui frame
local function col(c)
    c = floor(c or 0) % 0x100000000
    return (c & 0xFF00FF00) | ((c >> 16) & 0xFF) | ((c & 0xFF) << 16)
end

-- dynamic font size (ImGui 1.92); older REFramework draws everything at its default size
local function push_px(px) return imgui.push_font_size ~= nil and pcall(imgui.push_font_size, px + 0.0) end

local font_mt = { __index = {} }
function font_mt.__index:measure(s)
    local sized = push_px(self.px)
    local ok, v = pcall(imgui.calc_text_size, s)
    if sized then imgui.pop_font_size() end
    if not ok or not v then return 0, 0 end
    return v.x + (self.bold and 1 or 0), v.y
end

local function bind_imgui()
    A.text = function(f, s, x, y, c)
        if not DL then return end
        local sized = push_px(f.px)
        c = col(c)
        pcall(DL.add_text, DL, { x, y }, c, s)
        if f.bold then pcall(DL.add_text, DL, { x + 0.8, y }, c, s) end   -- no bold face: overstrike
        if sized then imgui.pop_font_size() end
    end
    A.fill_rect = function(x, y, w, h, c)
        if DL then DL:add_rect_filled({ x, y }, { x + w, y + h }, col(c), 0.0, 0) end
    end
    A.fill_rounded_rect = function(x, y, w, h, rx, _, c)
        if DL then DL:add_rect_filled({ x, y }, { x + w, y + h }, col(c), rx + 0.0, 0) end
    end
    A.outline_rect = function(x, y, w, h, t, c)
        if DL then DL:add_rect({ x, y }, { x + w, y + h }, col(c), 0.0, 0, t + 0.0) end
    end
    A.rounded_rect = function(x, y, w, h, rx, _, t, c)
        if DL then DL:add_rect({ x, y }, { x + w, y + h }, col(c), rx + 0.0, 0, t + 0.0) end
    end
    A.line = function(x1, y1, x2, y2, t, c)
        if DL then DL:add_line({ x1, y1 }, { x2, y2 }, col(c), t + 0.0) end
    end
    A.fill_circle = function(x, y, r, c)
        if DL then DL:add_circle_filled({ x, y }, r + 0.0, col(c), 0) end
    end
    A.circle = function(x, y, r, t, c)
        if DL then DL:add_circle({ x, y }, r + 0.0, col(c), 0, t + 0.0) end
    end
    A.oval = function(x, y, rx, ry, t, c)
        if DL then DL:add_ellipse({ x, y }, { rx, ry }, col(c), 0.0, 0, t + 0.0) end
    end
    A.fill_quad = function(x1, y1, x2, y2, x3, y3, x4, y4, c)
        if DL then DL:add_quad_filled({ x1, y1 }, { x2, y2 }, { x3, y3 }, { x4, y4 }, col(c)) end
    end
    A.image = noop
    A.surface_size = function()
        local v = imgui.get_display_size()
        return v.x, v.y
    end
    A.new_font = function(_, px, bold) return setmetatable({ px = px, bold = bold == true }, font_mt) end
end

local function bind_api()
    local src = D.backend == "imgui" and "imgui" or d2d
    if src == A_src then return end
    A_src = src
    if src == "imgui" then bind_imgui() elseif type(src) == "table" then bind_d2d(src) end
end

-- switch backends (fonts, text sizes and images belong to one backend)
function D.set_backend(name)
    if name == D.backend then return end
    D.backend = name
    fonts, measure_cache, measure_count, images = {}, {}, 0, {}
    A_src = nil
    DL = nil
end

function D.reset_frame(scale)
    bind_api()
    if D.backend == "imgui" then
        local ok, dl = pcall(imgui.get_background_draw_list)
        DL = ok and dl or nil
    end
    if scale ~= D.S then
        D.S = scale
        fonts, measure_cache, measure_count = {}, {}, 0
    end
    clip_stack, clip = {}, nil
    deferred = {}
end

-- ---------------------------------------------------------------- fonts / text
function D.font(size, bold, mono)
    size = size or T.font.body
    local key = size * 4 + (bold and 1 or 0) + (mono and 2 or 0)
    local f = fonts[key]
    if f == nil then
        local px = max(6, floor(size * D.S + 0.5))
        local ok, made = pcall(A.new_font, mono and T.font.mono or T.font.family, px, bold == true)
        f = (ok and made) or false
        fonts[key] = f
    end
    return f or nil
end

-- logical width, height of a string
function D.measure(f, s)
    if not f or s == nil or s == "" then return 0, 0 end
    local per = measure_cache[f]
    if not per then per = {}; measure_cache[f] = per end
    local m = per[s]
    if m then return m[1], m[2] end
    local ok, w, h = pcall(f.measure, f, s)
    if not ok then w, h = 0, 0 end
    w, h = (w or 0) / D.S, (h or 0) / D.S
    measure_count = measure_count + 1
    if measure_count > 4000 then measure_cache, measure_count = {}, 0 end
    per[s] = { w, h }
    return w, h
end

local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- s cut to max_w with an ellipsis (cached through D.measure)
function D.fit(f, s, max_w)
    s = tostring(s or "")
    if max_w <= 0 then return "" end
    if D.measure(f, s) <= max_w then return s end
    local chars = {}
    for ch in s:gmatch(UTF8_CHAR) do chars[#chars + 1] = ch end
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = floor((lo + hi + 1) / 2)
        if D.measure(f, table.concat(chars, "", 1, mid) .. "…") <= max_w then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, "", 1, lo) .. "…"
end

local function inside_y(y, h)
    return not clip or (y >= clip[2] - 0.5 and y + h <= clip[4] + 0.5)
end

-- text at (x, y) top-left; max_w cuts it with an ellipsis. Returns the drawn width.
function D.text(s, x, y, color, f, max_w)
    f = f or D.font()
    if not f or s == nil then return 0 end
    s = tostring(s)
    if max_w then s = D.fit(f, s, max_w) end
    local w, h = D.measure(f, s)
    if not inside_y(y, h) then return w end
    if clip and (x > clip[3] or x + w < clip[1]) then return w end
    A.text(f, s, x * D.S, y * D.S, color or T.c.text)
    return w
end

-- text centred in a box
function D.text_center(s, x, y, w, h, color, f)
    f = f or D.font()
    local tw, th = D.measure(f, s)
    if tw > w then return D.text(s, x, y + (h - th) / 2, color, f, w) end
    return D.text(s, x + (w - tw) / 2, y + (h - th) / 2, color, f)
end

-- text vertically centred in a row, left aligned
function D.text_mid(s, x, y, h, color, f, max_w)
    f = f or D.font()
    local _, th = D.measure(f, "Ag国")
    return D.text(s, x, y + (h - th) / 2, color, f, max_w)
end

-- ---------------------------------------------------------------- shapes
local function cut(x, y, w, h)
    if not clip then return x, y, w, h, true end
    local x0, y0 = max(x, clip[1]), max(y, clip[2])
    local x1, y1 = min(x + w, clip[3]), min(y + h, clip[4])
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1 - x0, y1 - y0, (x0 == x and y0 == y and x1 == x + w and y1 == y + h)
end

function D.rect(x, y, w, h, color)
    local cx, cy, cw, ch = cut(x, y, w, h)
    if not cx then return end
    local S = D.S
    A.fill_rect(cx * S, cy * S, cw * S, ch * S, color)
end

function D.rrect(x, y, w, h, r, color)
    local cx, cy, cw, ch, whole = cut(x, y, w, h)
    if not cx then return end
    local S = D.S
    if whole and r and r > 0 then
        A.fill_rounded_rect(x * S, y * S, w * S, h * S, r * S, r * S, color)
    else
        A.fill_rect(cx * S, cy * S, cw * S, ch * S, color)
    end
end

function D.outline(x, y, w, h, r, thickness, color)
    local _, _, _, _, whole = cut(x, y, w, h)
    if not whole then
        -- partly clipped: draw the visible edges as rectangles
        local t = thickness or 1
        D.rect(x, y, w, t, color); D.rect(x, y + h - t, w, t, color)
        D.rect(x, y, t, h, color); D.rect(x + w - t, y, t, h, color)
        return
    end
    local S = D.S
    if r and r > 0 then
        A.rounded_rect(x * S, y * S, w * S, h * S, r * S, r * S, (thickness or 1) * S, color)
    else
        A.outline_rect(x * S, y * S, w * S, h * S, (thickness or 1) * S, color)
    end
end

function D.line(x1, y1, x2, y2, thickness, color)
    if clip and (max(y1, y2) < clip[2] or min(y1, y2) > clip[4]) then return end
    local S = D.S
    A.line(x1 * S, y1 * S, x2 * S, y2 * S, (thickness or 1) * S, color)
end

function D.fill_circle(x, y, r, color)
    if not inside_y(y - r, 2 * r) then return end
    A.fill_circle(x * D.S, y * D.S, r * D.S, color)
end

function D.circle(x, y, r, thickness, color)
    if not inside_y(y - r, 2 * r) then return end
    A.circle(x * D.S, y * D.S, r * D.S, (thickness or 1) * D.S, color)
end

function D.oval(x, y, rx, ry, thickness, color)
    if not inside_y(y - ry, 2 * ry) then return end
    A.oval(x * D.S, y * D.S, rx * D.S, ry * D.S, (thickness or 1) * D.S, color)
end

function D.quad(x1, y1, x2, y2, x3, y3, x4, y4, color)
    local S = D.S
    A.fill_quad(x1 * S, y1 * S, x2 * S, y2 * S, x3 * S, y3 * S, x4 * S, y4 * S, color)
end

-- ---------------------------------------------------------------- icons (drawn, not glyphs:
-- the UI font may not have ✕ ▾ ▸)
function D.icon_x(cx, cy, s, color)
    D.line(cx - s, cy - s, cx + s, cy + s, 1.5, color)
    D.line(cx - s, cy + s, cx + s, cy - s, 1.5, color)
end

-- filled triangle pointing down (open) or right (closed)
function D.icon_tri(cx, cy, s, down, color)
    if not inside_y(cy - s, 2 * s) then return end
    if down then D.quad(cx - s, cy - s * 0.5, cx + s, cy - s * 0.5, cx, cy + s * 0.6, cx, cy + s * 0.6, color)
    else D.quad(cx - s * 0.5, cy - s, cx + s * 0.6, cy, cx + s * 0.6, cy, cx - s * 0.5, cy + s, color) end
end

-- ---------------------------------------------------------------- images
-- path relative to reframework/images; nil when missing or on a backend without images
function D.image_res(path)
    if not D.images() then return nil end
    local img = images[path]
    if img == nil then
        local ok, made = pcall(d2d.Image.new, path)
        img = (ok and made) or false
        images[path] = img
    end
    return img or nil
end

function D.image(img, x, y, w, h, alpha)
    if not img or not inside_y(y, h) then return end
    local S = D.S
    A.image(img, x * S, y * S, w * S, h * S, alpha or 1.0)
end

-- ---------------------------------------------------------------- clip / deferred
function D.push_clip(x, y, w, h)
    clip_stack[#clip_stack + 1] = clip
    local c = { x, y, x + w, y + h }
    if clip then
        c[1], c[2] = max(c[1], clip[1]), max(c[2], clip[2])
        c[3], c[4] = min(c[3], clip[3]), min(c[4], clip[4])
    end
    clip = c
end

function D.pop_clip()
    clip = clip_stack[#clip_stack]
    clip_stack[#clip_stack] = nil
end

function D.get_clip() return clip end

function D.defer(fn) deferred[#deferred + 1] = fn end

function D.flush_deferred()
    local list = deferred
    deferred = {}
    local saved = clip
    clip = nil
    for _, fn in ipairs(list) do pcall(fn) end
    clip = saved
end

-- d2d.surface_size only works inside the d2d draw callback (it throws from re.on_frame, and REF
-- logs that as a script error even under pcall), so the last good raw size is cached for frame code
D.raw_w, D.raw_h = 1920, 1080

function D.surface_size()
    bind_api()
    local ok, w, h = pcall(A.surface_size)
    if ok and w and h then D.raw_w, D.raw_h = w, h end
    return D.raw_w / D.S, D.raw_h / D.S
end

return D
