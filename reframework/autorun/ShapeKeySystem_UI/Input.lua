-- ShapeKeySystem panel: mouse / keyboard state for the immediate-mode widgets.
-- Clicks are sampled every game frame (re.on_frame) and queued, because d2d may call the draw
-- function less often than the game renders (max update rate); one queued click is handed to
-- each draw. Idea from ArmorVariantManager's Component/Runtime.lua (MIT, Copyright (c) 2026 MK).
--
-- Hit testing: I.hit(x, y, w, h) is false outside the current clip rect and under any overlay
-- (open dropdown) registered on the previous draw, unless the caller is drawing that overlay.

local D = require("ShapeKeySystem_UI.Draw")
local Blocker = require("ShapeKeySystem_UI.InputBlocker")

local I = {
    mx = -1, my = -1,          -- logical mouse position this draw
    down = false, clicked = false, released = false,
    device_click = false,      -- this draw's click came from the game device, unseen by ImGui
    wheel = 0,                 -- notches this draw (+ = away from the user)
    active = nil,              -- id of the widget holding the mouse (slider drag, window drag)
    in_overlay = false,        -- set while an overlay draws itself
}

local queue, q_head, q_tail = {}, 1, 0
local was_down = false
local sampled = false
local overlays, next_overlays = {}, {}
local wheel_acc = 0

local function imgui_mouse()
    local ok, m = pcall(imgui.get_mouse)
    if ok and m and type(m.x) == "number" and m.x >= 0 and m.y >= 0 then return m.x, m.y end
    return nil
end

local function imgui_down()
    local ok, v = pcall(imgui.is_mouse_down, 0)
    return ok and v == true
end

-- second value: ImGui saw the button itself (RE4R withholds it while the REF menu is closed)
local function raw_down()
    if imgui_down() then return true, true end
    return Blocker.enabled and Blocker.device_left_down() or false, false
end

-- screen px. While the input blocker runs, the virtual cursor (Blocker.cursor) is used when the
-- OS cursor is pinned to the screen centre, and synced to the OS cursor when it is free.
local pinned_frames = 0
function I.raw_mouse()
    local x, y = imgui_mouse()
    if Blocker.enabled then
        local sw, sh = Blocker.surface()
        -- sticky: the game pulls the cursor back to the centre every frame while it owns the mouse,
        -- so a position off-centre between two pulls does not mean the cursor is free
        if x and math.abs(x - sw / 2) <= 2 and math.abs(y - sh / 2) <= 2 then
            pinned_frames = 30
        elseif x and pinned_frames > 0 then
            pinned_frames = pinned_frames - 1
        end
        Blocker.pinned = (x == nil) or pinned_frames > 0
        local c = Blocker.cursor
        if not Blocker.pinned and x then
            if c then c.x, c.y = x, y else Blocker.cursor = { x = x, y = y } end
            return x, y
        end
        if c then return c.x, c.y end
        return sw / 2, sh / 2
    end
    if x then return x, y end
    return -1, -1
end

-- every game frame
function I.capture()
    local down, seen = raw_down()
    if sampled and down and not was_down then
        local x, y = I.raw_mouse()
        if x >= 0 then q_tail = q_tail + 1; queue[q_tail] = { x, y, seen } end
    end
    if sampled and not down and was_down then
        q_tail = q_tail + 1; queue[q_tail] = false   -- release marker
    end
    sampled, was_down = true, down
    if Blocker.enabled then
        Blocker.poll_wheel()
        wheel_acc = wheel_acc + Blocker.take_wheel()
    end
end

function I.reset()
    queue, q_head, q_tail = {}, 1, 0
    sampled, was_down = false, false
    I.active, I.clicked, I.released, I.device_click = nil, false, false, false
    overlays, next_overlays = {}, {}
    wheel_acc = 0
end

-- start of each draw
function I.begin_frame()
    local x, y = I.raw_mouse()
    I.clicked, I.released, I.device_click = false, false, false
    local ev = queue[q_head]
    if ev ~= nil then
        queue[q_head] = nil
        q_head = q_head + 1
        if q_head > q_tail then q_head, q_tail = 1, 0 end
        if ev then I.clicked, I.device_click = true, not ev[3]; x, y = ev[1], ev[2]
        else I.released = true end
    end
    I.mx, I.my = x / D.S, y / D.S
    I.down = raw_down() or I.clicked
    if I.released and not I.clicked then I.down = false end
    I.wheel = wheel_acc > 0 and 1 or (wheel_acc < 0 and -1 or 0)
    wheel_acc = 0
    overlays, next_overlays = next_overlays, {}
    if not I.down and not I.clicked then I.active = nil end
end

function I.add_overlay(x, y, w, h) next_overlays[#next_overlays + 1] = { x, y, w, h } end

function I.inside(x, y, w, h)
    local mx, my = I.mx, I.my
    return mx >= x and mx < x + w and my >= y and my < y + h
end

function I.over_overlay()
    for _, r in ipairs(overlays) do
        if I.inside(r[1], r[2], r[3], r[4]) then return true end
    end
    return false
end

function I.hit(x, y, w, h)
    if not I.inside(x, y, w, h) then return false end
    local c = D.get_clip()
    if c and (I.mx < c[1] or I.mx >= c[3] or I.my < c[2] or I.my >= c[4]) then return false end
    if not I.in_overlay and I.over_overlay() then return false end
    return true
end

-- a click inside the rect (and nobody else took it). Consumes the click.
function I.click(x, y, w, h)
    if I.clicked and I.hit(x, y, w, h) then
        I.clicked = false
        return true
    end
    return false
end

function I.consume() I.clicked = false end

-- ---------------------------------------------------------------- keyboard (hotkey)
local VK = { Home = 0x24, End = 0x23, Insert = 0x2D, Delete = 0x2E, PageUp = 0x21, PageDown = 0x22,
             Pause = 0x13, ScrollLock = 0x91 }
for i = 1, 12 do VK["F" .. i] = 0x6F + i end
for c = 65, 90 do VK[string.char(c)] = c end
for i = 0, 9 do VK["NumPad" .. i] = 0x60 + i end
I.VK = VK

I.MODIFIERS = { Ctrl = 0x11, Shift = 0x10, Alt = 0x12 }

local function is_down(vk)
    local ok, down = pcall(function() return reframework:is_key_down(vk) end)
    return ok and down == true
end

local key_was = {}
-- The key went down this frame; with `mod` ("Ctrl" / "Shift" / "Alt") that modifier must be held.
function I.key_pressed(name, mod)
    local vk = VK[name or "Delete"] or VK.Delete
    local down = is_down(vk)
    local was = key_was[vk]
    key_was[vk] = down
    if not down or was then return false end
    local m = mod and I.MODIFIERS[mod]
    return not m or is_down(m)
end

return I
