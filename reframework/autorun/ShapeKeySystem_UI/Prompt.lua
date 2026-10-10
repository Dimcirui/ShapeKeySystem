-- ShapeKeySystem panel: text input. Every text field of the panel goes through P.open, so the
-- backend can be swapped later (planned: our own d2d build with native IME input, like
-- ArmorVariantManager's bridge). Current backend: a small imgui window drawn in re.on_frame,
-- which gets REFramework's own IME support.
--
-- P.open{ title, text, hint, live = bool, on_change(text), on_submit(text), extra = {label, value} }
--   live: on_change is called on every edit (search boxes)
--   extra: one optional checkbox shown under the field (e.g. "save as general preset")

local P = { req = nil }

function P.open(req)
    req.text = req.text or ""
    req.original = req.text
    req.first = true
    req.first_frame = true
    P.req = req
end

function P.close() P.req = nil end
function P.is_open() return P.req ~= nil end

local function submit(r)
    P.req = nil
    if r.on_submit then pcall(r.on_submit, r.text, r.extra and r.extra.value) end
end

-- re.on_frame
function P.draw(screen_w, screen_h)
    local r = P.req
    if not r then return end
    if r.first then
        pcall(imgui.set_next_window_pos, Vector2f.new((screen_w or 1920) / 2 - 200, (screen_h or 1080) / 3), 1 << 3)
        pcall(imgui.set_next_window_size, Vector2f.new(400, 0), 1 << 3)
    end
    local open = imgui.begin_window((r.title or "输入") .. "##sks_prompt", true, 1 << 5 | 1 << 1)  -- NoCollapse | NoResize
    if open == false then imgui.end_window(); P.req = nil; return end
    if r.first then pcall(imgui.set_keyboard_focus_here, 0); r.first = false end
    local _, text = imgui.input_text("##sks_prompt_text", r.text)
    -- REFramework's input_text returns true on every edit, not only on Enter: Enter is read from
    -- the keyboard instead (edge, so a held Enter from an earlier dialog does not submit)
    local enter_down = false
    pcall(function() enter_down = reframework:is_key_down(0x0D) end)
    local changed = enter_down and not r.enter_was and not r.first_frame
    r.enter_was = enter_down
    r.first_frame = false
    if text ~= nil and text ~= r.text then
        r.text = text
        if r.live and r.on_change then pcall(r.on_change, text) end
    end
    if r.hint then imgui.text(r.hint) end
    if r.extra then
        local c, v = imgui.checkbox(r.extra.label, r.extra.value)
        if c then r.extra.value = v end
    end
    local ok_clicked = imgui.button(r.live and "完成" or "确定")
    imgui.same_line()
    local cancel = imgui.button("取消")
    imgui.end_window()
    if (changed and P.req == r) or ok_clicked then
        submit(r)
    elseif cancel then
        if r.live and r.on_change and r.original ~= nil then pcall(r.on_change, r.original) end
        P.req = nil
    end
end

return P
