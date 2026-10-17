-- REFramework mock for ShapeKeySystem offline tests (json / fs provided from Python).
writes = {}
local function method(name)
    return { call = function(self, obj, ...) return obj[name](obj, ...) end, name = name }
end
local function vec(z) return { x = 0, y = 0, z = z } end
T = 0
local function joint(z, rot)
    local j = {}
    j.get_LocalPosition = function() return vec(z()) end
    j.get_LocalRotation = function() return rot and rot() or { w = 1, x = 0, y = 0, z = 0 } end
    return j
end
FC = {}   -- fcParam number -> value (set by tests)
local face_joints = {}
for n = 0, 200 do
    local nn = n
    face_joints[string.format("fcParam_%03d", n)] = joint(function() return FC[nn] or 0 end)
end
EYE_Q = { w = 0.9962, x = 0, y = 0.0872, z = 0 }   -- ~10 deg yaw
face_joints["L_EyeJ_LOD02"] = joint(function() return 0 end, function() return EYE_Q end)
face_joints["R_EyeJ_LOD02"] = joint(function() return 0 end, function() return EYE_Q end)

CHANNELS = { "blendShape1.EyeBlinkLeft", "blendShape1.JawOpen", "blendShape1_LOD1.JawOpen_LOD1",
             "blendShape1.LookInLeft", "blendShape1.Other", "blendShape1.Mouth_Smile_Left",
             "blendShape1.browInnerUp", "blendShape1.mouthPucker", "blendShape1.EyeLookInLeft",
             "blendShape1.tongueOut", "blendShape1.Waist_thin" }
WEIGHTS = {}
MESH_STATE = { ready = true, released = false }
local mesh = {
    get_MeshReady = function() return MESH_STATE.ready end,
    get_BlendShapeEnable = function() return true end,
    get_BlendShapeReleasedBuffers = function() return MESH_STATE.released end,
    get_address = function() return 0x1000 end,
    get_BlendShapeChannelNum = function() return #CHANNELS end,
    get_BlendShapeChannelWeightCount = function() return #CHANNELS end,
    getBlendShapeChannelName = function(_, i) return CHANNELS[i + 1] end,
    -- murmur3 of each name (an engine without getBlendShapeChannelName); HASH set by the tests
    get_ChannelNameHash = function()
        local e = {}
        for i, n in ipairs(CHANNELS) do e[i] = HASH(n) end
        return { get_elements = function() return e end }
    end,
    call = function(self, m, ...) return self[m](self, ...) end,
    setBlendShapeChannelWeightParam = function(_, i, w)
        if math.type(w) ~= "float" then INT_WRITES = (INT_WRITES or 0) + 1 end   -- System.Single needs a float
        writes[#writes + 1] = { i, w }; WEIGHTS[i] = w
    end,
    getBlendShapeChannelWeightParam = function(_, i) return WEIGHTS[i] or 0 end,
}

local function mk_tr(name, joints, m)
    local tr = { _name = name, _joints = joints or {}, _mesh = m }
    tr.getJointByName = function(self, n) return self._joints[n] end
    tr.get_GameObject = function(self)
        return { call = function(go, meth, ...)
            if meth == "get_Name" then return self._name end
            if meth == "get_Transform" then return self end
            if meth:find("getComponent") then return self._mesh end
        end }
    end
    tr.call = function(self, meth, ...)
        if meth == "get_GameObject" then return self:get_GameObject() end
        return self[meth](self, ...)
    end
    return tr
end
local root = mk_tr("MasterPlayer")
ROOT = root
local face = mk_tr("Player_Face", face_joints)
local armor = mk_tr("ch03_012_0012", nil, mesh)
ARMOR = armor
local npc = mk_tr("ch00_502_0000", nil, mesh)
face.get_Parent = function() return root end
face.get_Next = function() return armor end
armor.get_Next = function() return npc end
npc.get_Next = function() return nil end
root.get_Child = function() return face end

-- cutscene copy of the hunter (found only by a whole-scene search)
WEIGHTS2 = {}
local mesh2 = {}
for k, v in pairs(mesh) do mesh2[k] = v end
mesh2.get_address = function() return 0x5000 end
mesh2.setBlendShapeChannelWeightParam = function(_, i, w)
    if math.type(w) ~= "float" then INT_WRITES = (INT_WRITES or 0) + 1 end
    writes[#writes + 1] = { i, w }; WEIGHTS2[i] = w
end
local croot = mk_tr("Pl000_00")
local cface = mk_tr("Player_Face", face_joints)
local carmor = mk_tr("ch03_012_0012", nil, mesh2)
cface.get_Parent = function() return croot end
cface.get_Next = function() return carmor end
carmor.get_Next = function() return nil end
croot.get_Child = function() return cface end
COPY_ON = false
local copy_comp = { call = function(_, m) if m == "get_GameObject" then return { call = function() return cface end } end end }
HOOKS = {}

local typedefs = setmetatable({}, { __index = function()
    return { get_method = function(_, sig) return method(sig:match("^([%w_]+)")) end } end })
sdk = {
    find_type_definition = function(n) return typedefs[n] end,
    typeof = function(n) return n end,
    get_managed_singleton = function(name)
        if name == "app.DemoMediator" then return DEMO end
        local player = { call = function(_, m)
                             if m == "get_Character" then return HUNTER end
                             return { call = function() return root end }
                         end,
                         get_field = function() return { call = function() return SETUP end } end }
        return { call = function() return player end }
    end,
    get_native_singleton = function() return {} end,
    call_native_func = function() return SCENE end,
    hook = function(m, pre, post) HOOKS[m.name] = pre or post end,
    to_int64 = function(x) return x end,
}
TL = { frame = 10, endf = 1000 }
TL.get_Frame = function(self) return self.frame end
TL.get_EndFrame = function(self) return self.endf end
TL.get_address = function() return 0x2000 end
TL2 = { frame = 5, endf = 800 }
TL2.get_Frame, TL2.get_EndFrame = TL.get_Frame, TL.get_EndFrame
TL2.get_address = function() return 0x3000 end
CUR_TL = TL
TL_ON = false
local function arr(list)
    return { call = function(_, m, i)
        if m == "get_Length" then return #list end
        return list[i + 1]
    end }
end
SCENE = { call = function(_, m, ty)
    if ty == "via.timeline.Timeline" and TL_ON then return arr({ CUR_TL }) end
    if ty == "via.motion.Motion" and COPY_ON then return arr({ copy_comp }) end
    return arr({})
end }
CB = {}
SETUP = true
DEMO = { busy = false, load = false }
DEMO.get_IsBusy = function(self) return self.busy end
DEMO.get_IsBusyLoad = function(self) return self.load end
re = { on_application_entry = function(name, f) if name == "LateUpdateBehavior" then CB.tick = f elseif name == "UpdateMotion" then CB.motion = f end end, on_draw_ui = function(f) CB.ui = f end,
       on_frame = function(f) CB.frame = f end, on_script_reset = function(f) CB.reset = f end }
TEXTS = {}
imgui = {
    tree_node = function() return true end, tree_pop = function() end,
    text = function(s) TEXTS[#TEXTS + 1] = s end, text_colored = function(s) TEXTS[#TEXTS + 1] = s end,
    checkbox = function(_, v) return false, v end, slider_float = function(_, v) return false, v end,
    slider_int = function(_, v) return false, v end, button = function() return false end,
    same_line = function() end, combo = function(_, v) return false, v end,
    input_text = function(_, v) return false, v end, is_item_hovered = function() return false end,
    set_tooltip = function() end,
}

-- ---------------------------------------------------------------- UI mocks (d2d panel, M3)
MOUSE = { x = -1, y = -1, down = false }
KEYS = {}
DRAWS = {}          -- text draws of the last d2d frame: { s, x, y }
DRAWN_IMAGES = {}
INPUT_EDITS, INPUT_RECTS, INPUT_WINDOWS, INPUT_BUFFERS = {}, {}, {}, {}
INPUT_ACTIVE = nil
local input_id, input_rect, input_window
imgui.get_mouse = function() return { x = MOUSE.x, y = MOUSE.y } end
imgui.is_mouse_down = function() return MOUSE.down end
imgui.is_mouse_clicked = function() return false end
imgui.begin_window = function(name)
    input_window = name
    IMGUI_STACK.window = IMGUI_STACK.window + 1
    return true
end
imgui.end_window = function() IMGUI_STACK.window = IMGUI_STACK.window - 1 end
imgui.input_text = function(label, v)
    input_id = label:match("^##sks_text_(.+)$")
    if not input_id then return false, v end
    INPUT_RECTS[input_id], INPUT_WINDOWS[input_id], INPUT_BUFFERS[input_id] = input_rect, input_window, v
    local t = INPUT_EDITS[input_id]
    INPUT_EDITS[input_id] = nil
    return t ~= nil, t or v
end
imgui.is_item_active = function() return input_id ~= nil and INPUT_ACTIVE == input_id end
Vector2f = { new = function(x, y) return { x = x, y = y } end }
GAME_NAME = "mhwilds"
reframework = { is_key_down = function(_, vk) return KEYS[vk] == true end,
                get_game_name = function() return GAME_NAME end }
re.on_pre_application_entry = function() end
local font_mt = { __index = { measure = function(self, s)
    if py_measure then return py_measure(self.family, self.size, tostring(s)) end
    local n = 0
    for _ in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n * self.size * 0.6, self.size * 1.3
end } }
d2d = {
    register = function(init, draw) CB.d2d_init = init; CB.d2d_draw = draw end,
    Font = { new = function(family, size, bold) return setmetatable({ size = size, family = family }, font_mt) end },
    Image = { new = function(path) return { path = path, size = function() return 403, 650 end } end },
    text = function(f, s, x, y) DRAWS[#DRAWS + 1] = { s = s, x = x, y = y } end,
    fill_rect = function() end, outline_rect = function() end, rounded_rect = function() end,
    fill_rounded_rect = function() end, line = function() end, fill_circle = function() end,
    circle = function() end, oval = function() end, fill_quad = function() end,
    image = function(img) DRAWN_IMAGES[#DRAWN_IMAGES + 1] = img.path end,
    surface_size = function() return 1920, 1080 end,
}

-- REFramework ImGui draw list (Draw.lua "imgui" backend): text lands in DRAWS like d2d text;
-- points must be {x, y} pairs and colours integers, anything else is noted in IMGUI_ERR
IMGUI_ERR = {}
local font_px = {}
imgui.push_font_size = function(px) font_px[#font_px + 1] = px; IMGUI_STACK.font = IMGUI_STACK.font + 1 end
imgui.pop_font_size = function() font_px[#font_px] = nil; IMGUI_STACK.font = IMGUI_STACK.font - 1 end
imgui.calc_text_size = function(s)
    local px = font_px[#font_px] or 18
    local w, h = font_mt.__index.measure({ size = px, family = "Microsoft YaHei UI" }, s)
    return { x = w, y = h }
end
imgui.get_display_size = function() return { x = 1920, y = 1080 } end
-- style stacks must balance (the prompt's field window pushes and pops them every frame)
IMGUI_STACK = { var = 0, color = 0, width = 0, window = 0, font = 0 }
imgui.push_style_var = function() IMGUI_STACK.var = IMGUI_STACK.var + 1 end
imgui.pop_style_var = function(n) IMGUI_STACK.var = IMGUI_STACK.var - (n or 1) end
imgui.push_style_color = function() IMGUI_STACK.color = IMGUI_STACK.color + 1 end
imgui.pop_style_color = function(n) IMGUI_STACK.color = IMGUI_STACK.color - (n or 1) end
imgui.push_item_width = function() IMGUI_STACK.width = IMGUI_STACK.width + 1 end
imgui.pop_item_width = function() IMGUI_STACK.width = IMGUI_STACK.width - 1 end
imgui.set_next_window_pos = function(v) input_rect = { x = v.x, y = v.y } end
imgui.set_next_window_size = function(v) if input_rect then input_rect.w, input_rect.h = v.x, v.y end end
Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
CLIPBOARD = ""
imgui.get_clipboard = function() return CLIPBOARD end
local function ipt(...)
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if type(p) ~= "table" or #p ~= 2 or type(p[1]) ~= "number" or type(p[2]) ~= "number" then
            IMGUI_ERR[#IMGUI_ERR + 1] = "point " .. tostring(p)
        end
    end
end
local function icol(c)
    if math.type(c) ~= "integer" or c < 0 or c > 0xFFFFFFFF then IMGUI_ERR[#IMGUI_ERR + 1] = "colour " .. tostring(c) end
end
local IMGUI_DL = {
    add_text = function(_, p, c, s) ipt(p); icol(c); DRAWS[#DRAWS + 1] = { s = s, x = p[1], y = p[2], c = c } end,
    add_rect_filled = function(_, a, b, c) ipt(a, b); icol(c) end,
    add_rect = function(_, a, b, c) ipt(a, b); icol(c) end,
    add_line = function(_, a, b, c) ipt(a, b); icol(c) end,
    add_circle_filled = function(_, p, _, c) ipt(p); icol(c) end,
    add_circle = function(_, p, _, c) ipt(p); icol(c) end,
    add_ellipse = function(_, p, r, c) ipt(p, r); icol(c) end,
    add_quad_filled = function(_, a, b, c3, d, c) ipt(a, b, c3, d); icol(c) end,
}
imgui.get_background_draw_list = function() return IMGUI_DL end

-- command recorder for offline screenshots (render_ui.py)
CMDS = {}
local function rec(...) CMDS[#CMDS + 1] = table.pack(...) end
local _d = d2d
_d.text = function(f, s, x, y, c) DRAWS[#DRAWS + 1] = { s = s, x = x, y = y }; rec("text", s, x, y, c, f.size, f.family) end
_d.fill_rect = function(x, y, w, h, c) rec("rect", x, y, w, h, c) end
_d.fill_rounded_rect = function(x, y, w, h, rx, ry, c) rec("rrect", x, y, w, h, rx, c) end
_d.outline_rect = function(x, y, w, h, t, c) rec("orect", x, y, w, h, 0, t, c) end
_d.rounded_rect = function(x, y, w, h, rx, ry, t, c) rec("orect", x, y, w, h, rx, t, c) end
_d.line = function(x1, y1, x2, y2, t, c) rec("line", x1, y1, x2, y2, t, c) end
_d.fill_circle = function(x, y, r, c) rec("fcircle", x, y, r, c) end
_d.circle = function(x, y, r, t, c) rec("circle", x, y, r, t, c) end
_d.fill_quad = function(x1, y1, x2, y2, x3, y3, x4, y4, c) rec("quad", x1, y1, x2, y2, x3, y3, x4, y4, c) end
_d.image = function(img, x, y, w, h, a) DRAWN_IMAGES[#DRAWN_IMAGES + 1] = img.path; rec("image", img.path, x, y, w, h, a or 1) end
SNAPS = {}


-- mock app.HunterCharacter for the condition layer (Conditions.lua)
HSTATE = { get_IsCombat = false, get_WeaponType = 9, get_EnemyFeelRateType = 0 }
HEALTH = { hp = 150, max = 150, red = 150, dead = false }
local health_mgr = { call = function(_, m)
    if m == "get_Health" then return HEALTH.hp elseif m == "get_MaxHealth" then return HEALTH.max end
end }
local hunter_health = { call = function(_, m)
    if m == "get_IsDead" then return HEALTH.dead elseif m == "get_RedHealth" then return HEALTH.red end
end, get_field = function(_, f) if f == "<HealthMgr>k__BackingField" then return health_mgr end end }
local stamina = { call = function(_, m) if m == "get_Stamina" then return 100 elseif m == "get_MaxStamina" then return 150 end end }
local handling = { call = function(_, m) return HSTATE["wh." .. m] end }
HUNTER = {
    call = function(_, m)
        if m == "get_HunterHealth" then return hunter_health end
        if m == "get_HunterStamina" then return stamina end
        if m == "get_WeaponHandling" then return handling end
        return HSTATE[m]
    end,
    get_field = function(_, f) if f == "_IsWeaponOn" then return HSTATE._IsWeaponOn == true end end,
}
