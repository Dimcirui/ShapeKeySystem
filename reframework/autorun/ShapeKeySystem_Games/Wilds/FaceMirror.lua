-- ShapeKeySystem: MH Wilds face mirror. A second camera renders the hunter's face into
-- GUI/ui_texture/tex_render/rtt_facemirror_00.rtex (shipped in natives/), and a texture element of
-- our own GUI shows it on screen. Settings live in user/face_mirror.json; the panel reads `F.view`.
--
-- Constraints:
-- - Nothing here calls sdk at load: lookups happen in `F.attach`.
-- - The camera's RenderOutput must be Secondary with an .rtex target: a Primary output becomes
--   MainView.PrimaryCamera and flickers. A primary camera that is not "Main Camera" stops the mirror.
-- - The camera and the GUI GameObject are created once and only hidden afterwards: destroying and
--   recreating render cameras left orphaned outputs in the renderer. They are found again by name.
-- - The camera is a child of a player joint with a fixed local pose. A camera written in world space
--   every frame was drawn with a pose from another moment on single frames of sharp turns.
-- - The GUI GameObject is created in UpdateBehavior: changing the GUI tree during PrepareRendering
--   crashed the game. Only components the camera already has get the main camera's settings:
--   creating CustomFilter / SoftBloom / FFTBloom on it and copying into them crashed the game.
-- - Engine references are dropped with the rigs (`F.drop_refs`) and never held across a rebuild.

local U = require("ShapeKeySystem_Core.Util")

local F = {}

local RTEX = "GUI/ui_texture/tex_render/rtt_facemirror_00.rtex"
local CAM_NAME = "FaceMirrorRtexCam"
local GUI_NAME, GUI_ASSET, GUI_ELEM = "FaceMirrorGUI", "GUI/ui000000/ui000200/lib000204.gui", "tex_saleMark"
local CAM_COMPONENTS = { "via.Camera", "via.render.RenderOutput", "via.render.ToneMapping", "via.render.LDRPostProcess" }
local CFG_PATH = U.path("user", "face_mirror.json")
local sin, cos, rad, max = math.sin, math.cos, math.rad, math.max

-- joints the camera can hang from, in the joint's own frame (+Z forward, +Y up for Head and COG).
-- Hip sits on COG, so it is not offered.
F.BINDS = {
    { id = "Head", name = "头部（Head）" },
    { id = "Spine_2", name = "胸部（Spine_2）" },
    { id = "COG", name = "重心（COG）" },
}
local BIND_IDS = {}
for _, b in ipairs(F.BINDS) do BIND_IDS[b.id] = true end

-- per joint: distance from the aim point, aim point in the joint's frame, camera angles (degrees,
-- applied Y, then X, then Z). Head: the joint sits behind the face; Spine_2 / COG: the face is above.
local RIG_DEFAULTS = {
    Head = { dist = 0.6, aim = { x = 0, y = 0.07, z = 0.08 }, rot = { x = -6, y = 0, z = 0 } },
    Spine_2 = { dist = 0.6, aim = { x = 0, y = 0.2, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
    COG = { dist = 0.6, aim = { x = 0, y = 0.45, z = 0.1 }, rot = { x = -6, y = 0, z = 0 } },
}
-- where "对准头部" puts the aim point, in the Head joint's frame (in front of the face)
local FACE_OFFSET = { 0, 0.04, 0.08 }

F.DEFAULTS = {
    enabled = false, bind = "Head",
    size = 260, x = 200, y = 540,           -- window centre in the 1920 x 1080 view, origin top left, Y down
    fov = 30,
    ev = -2,                                -- added to the main camera's exposure; lower is brighter
    follow_meter = true,                    -- fixed exposure at the main camera's meter
    clip_front = 0.2, clip_back = 0.3,      -- slab kept around the aim point; the rest is transparent
    rigs = U.copy(RIG_DEFAULTS),
}
F.LIMITS = {
    size = { 100, 800 }, x = { -200, 2120 }, y = { -200, 1280 }, fov = { 5, 60 }, ev = { -4, 4 },
    clip_front = { 0.05, 1 }, clip_back = { 0.05, 2 },
}
F.RIG_LIMITS = { dist = { 0.2, 2.5 }, aim = { -1, 1 }, rot = { -180, 180 } }

local cfg = U.copy(F.DEFAULTS)
F.cfg = cfg
-- status: what the panel shows next to the toggle
local view = { available = true, cfg = cfg, binds = F.BINDS, status = "未开启" }
F.view = view

-- ---------------------------------------------------------------- settings
local function fill(dst, src, defaults)
    for k, d in pairs(defaults) do
        local v = src[k]
        if type(d) == "table" then
            if type(v) == "table" then fill(dst[k], v, d) end
        elseif type(v) == type(d) then
            dst[k] = v
        end
    end
end

local save_at
function F.load()
    local saved = U.load_json(CFG_PATH)
    if type(saved) == "table" then fill(cfg, saved, F.DEFAULTS) end
    if not BIND_IDS[cfg.bind] then cfg.bind = F.DEFAULTS.bind end
end

function F.save()
    save_at = nil
    return U.save_json(CFG_PATH, cfg)
end

-- slider drags patch every frame: write the file once they settle
function F.save_soon() save_at = os.clock() + 0.5 end
function F.flush() if save_at then F.save() end end
function F.tick_save() if save_at and os.clock() >= save_at then F.save() end end

local function num(v, lim)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return math.min(lim[2], math.max(lim[1], v))
end

-- patch = { enabled, bind, size, x, y, fov, ev, follow_meter, clip_front, clip_back,
--           rigs = { <bind> = { dist, aim = { x, y, z }, rot = { x, y, z } } } }.
-- Everything is checked before anything is written.
function F.patch(p)
    if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
    local writes = {}
    for _, k in ipairs({ "enabled", "follow_meter" }) do
        if p[k] ~= nil then
            if type(p[k]) ~= "boolean" then return false, "E_BAD_ARGS", k .. " must be boolean" end
            writes[#writes + 1] = { cfg, k, p[k] }
        end
    end
    if p.bind ~= nil then
        if not BIND_IDS[p.bind] then return false, "E_BAD_ARGS", "unknown bind " .. tostring(p.bind) end
        writes[#writes + 1] = { cfg, "bind", p.bind }
    end
    for k, lim in pairs(F.LIMITS) do
        if p[k] ~= nil then
            local v = num(p[k], lim)
            if not v then return false, "E_BAD_ARGS", k .. ": number expected" end
            writes[#writes + 1] = { cfg, k, v }
        end
    end
    if p.rigs ~= nil then
        if type(p.rigs) ~= "table" then return false, "E_BAD_ARGS", "rigs must be a table" end
        for id, r in pairs(p.rigs) do
            if not BIND_IDS[id] or type(r) ~= "table" then return false, "E_BAD_ARGS", "rigs: unknown bind " .. tostring(id) end
            local dst = cfg.rigs[id]
            if r.dist ~= nil then
                local v = num(r.dist, F.RIG_LIMITS.dist)
                if not v then return false, "E_BAD_ARGS", "dist: number expected" end
                writes[#writes + 1] = { dst, "dist", v }
            end
            for _, k in ipairs({ "aim", "rot" }) do
                if r[k] ~= nil then
                    if type(r[k]) ~= "table" then return false, "E_BAD_ARGS", k .. " must be a table" end
                    for ax, v in pairs(r[k]) do
                        if ax ~= "x" and ax ~= "y" and ax ~= "z" then return false, "E_BAD_ARGS", k .. ": x / y / z" end
                        local n = num(v, F.RIG_LIMITS[k])
                        if not n then return false, "E_BAD_ARGS", k .. "." .. ax .. ": number expected" end
                        writes[#writes + 1] = { dst[k], ax, n }
                    end
                end
            end
        end
    end
    for _, w in ipairs(writes) do w[1][w[2]] = w[3] end
    return true
end

-- what = "rig": the current joint's distance, aim and angles; "all": every setting except enabled
function F.reset(what)
    if what == "rig" then
        cfg.rigs[cfg.bind] = U.copy(RIG_DEFAULTS[cfg.bind])
    elseif what == "all" then
        local on = cfg.enabled
        for k in pairs(cfg) do cfg[k] = nil end
        for k, v in pairs(U.copy(F.DEFAULTS)) do cfg[k] = v end
        cfg.enabled = on
    else
        return false, "E_BAD_ARGS", "what: rig / all"
    end
    return true
end

-- the aim point moves to the face on the next rendered frame (it needs the current pose)
local aim_pending = false
function F.request_aim() aim_pending = true end

-- ---------------------------------------------------------------- engine
local T, M = {}, {}            -- type definitions and methods, filled by attach
local E = {}                   -- enum values
local opts                     -- attach options: stable(), root(), log(fmt, ...)
-- Engine references. Resources outlive the drops (they are not scene objects); everything else is
-- found again by name after a drop.
local res = {}
local R = {}
local frame, stopped = 0, false

local function scene()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), T.SceneManager, "get_CurrentScene")
end

local function main_camera_go()
    local mv = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), T.SceneManager, "get_MainView")
    local cam = mv and mv:call("get_PrimaryCamera")
    return cam and cam:call("get_GameObject")
end

local function component(go, name) return go:call("getComponent(System.Type)", sdk.typeof(name)) end

local function set_draw(go, v) if go then pcall(go.call, go, "set_DrawSelf", v) end end

local function hide()
    if R.shown then set_draw(R.cam_go, false); set_draw(R.gui_go, false); R.shown = false end
end

local function show()
    if not R.shown then set_draw(R.cam_go, true); set_draw(R.gui_go, true); R.shown = true end
end

function F.drop_refs()
    pcall(hide)
    R = {}
end

local function load_resources()
    if res.rt_holder then return true end
    local r = sdk.create_resource("via.render.RenderTargetTextureResource", RTEX)
    if not r then return false end
    r = r:add_ref()
    res.rt = r
    res.rt_holder = r:create_holder("via.render.RenderTargetTextureResourceHolder"):add_ref()
    -- GUI texture elements take a plain TextureResourceHolder of the same render target
    res.tex_holder = r:create_holder("via.render.TextureResourceHolder"):add_ref()
    return res.rt_holder ~= nil and res.tex_holder ~= nil
end

-- the camera GameObject: found by name, created once
local function find_camera()
    local sc = scene()
    local go = sc and sc:call("findGameObject(System.String)", CAM_NAME)
    if not go then
        go = M.go_create:call(nil, CAM_NAME)
        if not go then return false end
        go:call("set_DrawSelf", false)
        for _, t in ipairs(CAM_COMPONENTS) do go:call("createComponent(System.Type)", sdk.typeof(t)) end
        opts.log("face mirror: camera created")
    end
    go:call("set_DrawSelf", false)
    R.shown = false
    R.cam_go, R.tr = go, go:call("get_Transform")
    R.cam = component(go, "via.Camera")
    R.out = component(go, "via.render.RenderOutput")
    R.tm = component(go, "via.render.ToneMapping")
    R.ldr = component(go, "via.render.LDRPostProcess")
    if not (R.tr and R.cam and R.out and R.tm) then return false end
    R.out:call("set_RenderOutputID", E.secondary)   -- before the target, so it is never a primary output
    R.out:call("set_RenderTarget", res.rt_holder)
    local main = main_camera_go()
    R.main_go = main
    R.main_tm = main and component(main, "via.render.ToneMapping")
    if not R.main_tm then return false end
    R.main_ldr = component(main, "via.render.LDRPostProcess")
    R.tm:call("setTemporalAA", E.taa_off)   -- TAA history left ghost faces
    R.auto_mode = nil
    R.attached, R.pose_key, R.copied_at = nil, nil, nil
    return true
end

-- ---------------------------------------------------------------- own GUI
local gui_res
local function create_gui()
    local sc = scene()
    if not sc then return end
    local go = sc:call("findGameObject(System.String)", GUI_NAME)
    if go then R.gui_go = go; return end
    local folder = sc:call("findFolder(System.String)", "GUIHud")
    go = folder and M.go_create_in:call(nil, GUI_NAME, folder) or M.go_create:call(nil, GUI_NAME)
    if not go then return end
    if not gui_res then
        local r = sdk.create_resource("via.gui.GUIResource", GUI_ASSET)
        if not r then return end
        gui_res = { res = r:add_ref() }
        gui_res.holder = gui_res.res:create_holder("via.gui.GUIResourceHolder"):add_ref()
    end
    local gui = go:call("createComponent(System.Type)", sdk.typeof("via.gui.GUI"))
    if gui then gui:call("set_Asset", gui_res.holder) end
    R.gui_go = go
    opts.log("face mirror: GUI created")
end

local function find_element(node, depth)
    for _ = 1, 200 do
        if not node then return nil end
        if node:call("get_Name") == GUI_ELEM then return node end
        if depth < 20 then
            local e = find_element(node:call("get_Child"), depth + 1)
            if e then return e end
        end
        node = node:call("get_Next")
    end
    return nil
end

local function apply_element()
    local el = R.el
    local sz = ValueType.new(T.Size)
    sz:set_field("w", cfg.size + 0.0); sz:set_field("h", cfg.size + 0.0)
    el:call("set_AssetType", E.tex_asset)
    el:call("setTexture", res.tex_holder)
    el:call("set_Size", sz)
    -- the library element took its UV range from a UV sequence; without a full range one texel shows
    el:call("set_UVType", E.uv)
    el:call("set_UVU", 0.0); el:call("set_UVV", 0.0); el:call("set_UVW", 1.0); el:call("set_UVH", 1.0)
    el:call("set_Degamma", false)       -- with the main camera's grading copied, Degamma washes the image out
    el:call("set_IgnoreAlpha", false)   -- the clipped background stays transparent
    el:call("set_Position", Vector3f.new(cfg.x + 0.0, cfg.y + 0.0, 0.0))
    R.el_key = string.format("%g|%g|%g", cfg.size, cfg.x, cfg.y)
end

-- the element of the loaded GUI asset; nil until the asset has loaded
local function take_element()
    local go = R.gui_go
    local gui = go and component(go, "via.gui.GUI")
    local v = gui and gui:call("get_View")
    if not v then return false end
    local el = find_element(v, 0)
    if not el then return false end
    -- the library GUI plays a state animation that rewrote the element's position and size every
    -- frame: stop it on the view and on every control above the element
    v:call("set_Play", false)
    local p = el:call("get_Parent")
    while p do p:call("set_Play", false); p = p:call("get_Parent") end
    R.el = el
    apply_element()
    return true
end

-- the game re-initialises GUI elements at times (after resting in camp the mirror turned white)
local function keep_element()
    local el = R.el
    local t = el:call("getTexture")
    local ok = t and t:call("get_ResourcePath") == RTEX and el:call("get_UVW") == 1.0
        and R.el_key == string.format("%g|%g|%g", cfg.size, cfg.x, cfg.y)
    if not ok then apply_element() end
end

-- ---------------------------------------------------------------- camera pose
local function qaxis(ax, deg)
    local h = rad(deg) * 0.5
    local s = sin(h)
    if ax == "x" then return { s, 0, 0, cos(h) } elseif ax == "y" then return { 0, s, 0, cos(h) } end
    return { 0, 0, s, cos(h) }
end

local function qmul(a, b)   -- (x, y, z, w)
    return { a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
             a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
             a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
             a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3] }
end

local function qrot(q, v)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local tx, ty, tz = 2 * (y * v[3] - z * v[2]), 2 * (z * v[1] - x * v[3]), 2 * (x * v[2] - y * v[1])
    return { v[1] + w * tx + (y * tz - z * ty), v[2] + w * ty + (z * tx - x * tz), v[3] + w * tz + (x * ty - y * tx) }
end

-- local position and rotation of the camera in its joint's frame. The camera looks down its -Z,
-- so its +Z points from the aim point to the camera; with no angles it sits in front of the joint.
function F.local_pose(rig)
    local q = qmul(qmul(qaxis("y", rig.rot.y), qaxis("x", rig.rot.x)), qaxis("z", rig.rot.z))
    local back = qrot(q, { 0, 0, rig.dist })
    return { rig.aim.x + back[1], rig.aim.y + back[2], rig.aim.z + back[3] }, q
end

local function rig_key(rig)
    return string.format("%s|%g|%g|%g|%g|%g|%g|%g", cfg.bind, rig.dist, rig.aim.x, rig.aim.y, rig.aim.z, rig.rot.x, rig.rot.y, rig.rot.z)
end

-- the aim point in the bound joint's frame, in front of the face
local function aim_at_face(root)
    local j = M.jbn:call(root, cfg.bind)
    local head = M.jbn:call(root, "Head")
    if not (j and head) then return end
    local jp, jq, hp, hq = j:call("get_Position"), j:call("get_Rotation"), head:call("get_Position"), head:call("get_Rotation")
    local f = qrot({ hq.x, hq.y, hq.z, hq.w }, FACE_OFFSET)
    local d = { hp.x + f[1] - jp.x, hp.y + f[2] - jp.y, hp.z + f[3] - jp.z }
    local l = qrot({ -jq.x, -jq.y, -jq.z, jq.w }, d)
    local a = cfg.rigs[cfg.bind].aim
    a.x, a.y, a.z = l[1], l[2], l[3]
    F.save_soon()
end

local function place_camera(root)
    local addr = root:get_address()
    if R.attached ~= addr or R.bound ~= cfg.bind then
        R.tr:call("set_Parent", root)
        R.tr:call("set_ParentJoint", cfg.bind)
        R.attached, R.bound, R.pose_key = addr, cfg.bind, nil
    end
    if aim_pending then aim_pending = false; aim_at_face(root) end
    local rig = cfg.rigs[cfg.bind]
    local key = rig_key(rig)
    if R.pose_key ~= key then
        local p, q = F.local_pose(rig)
        R.tr:call("set_LocalPosition", Vector3f.new(p[1], p[2], p[3]))
        R.tr:call("set_LocalRotation", Quaternion.new(q[4], q[1], q[2], q[3]))
        R.pose_key = key
    end
    R.cam:call("set_FOV", cfg.fov + 0.0)
    R.cam:call("set_NearClipPlane", max(0.02, rig.dist - cfg.clip_front) + 0.0)
    R.cam:call("set_FarClipPlane", rig.dist + cfg.clip_back + 0.0)
end

-- ---------------------------------------------------------------- image
-- every zero-argument getter with a setter (get_X / set_X, getX / setX), per type; resource
-- holders are shared, other objects (curves, sub-objects) are left alone
local COMMON_SKIP = { Enabled = true, GameObject = true, InjectingGameObject = true, Valid = true, UpdateTiming = true, DrawTiming = true }
local TM_SKIP = { EV = true, AutoExposure = true, UseAutoExposure = true, MultiZoneMeteringTexture = true,
                  OffsetEVCurve = true, ClearHistogram = true, TemporalAA = true }
for k in pairs(COMMON_SKIP) do TM_SKIP[k] = true end
local prop_cache = {}

local function props_of(obj, skip)
    local td = obj:get_type_definition()
    local name = td:get_full_name()
    if prop_cache[name] then return prop_cache[name] end
    local list = {}
    local t = td
    while t and t:get_full_name() ~= "via.Component" do
        for _, m in ipairs(t:get_methods()) do
            local g = m:get_name()
            if m:get_num_params() == 0 and not m:is_static() then
                local prop, setter
                if g:sub(1, 4) == "get_" then prop = g:sub(5); setter = "set_" .. prop
                elseif g:match("^get%u") then prop = g:sub(4); setter = "set" .. prop end
                if prop and not skip[prop] and t:get_method(setter) then list[#list + 1] = { g, setter } end
            end
        end
        t = t:get_parent_type()
    end
    prop_cache[name] = list
    return list
end

local function copy_props(src, dst, skip)
    for _, p in ipairs(props_of(src, skip)) do
        pcall(function()
            local v = src:call(p[1])
            if v == nil or type(v) == "string" then return end
            if sdk.is_managed_object(v) and not v:get_type_definition():get_full_name():find("Holder$") then return end
            dst:call(p[2], v)
        end)
    end
end

-- the stage LUT and the linear grading live in LDRPostProcess.ColorCorrect, a sub-object; without
-- it the mirror looked warmer than the main view
local CC_PROPS = { "Enabled", "BlendRate", "BlendTargetIndex", "ColorCubeBlendRate", "ColorCube2BlendRate", "ColorCube0", "ColorCube1", "ColorCube2" }
local function copy_color_correct(src, dst)
    if not (src and dst) then return end
    for _, p in ipairs(CC_PROPS) do
        pcall(function()
            local v = src:call("get_" .. p)
            if v ~= nil and type(v) ~= "string" then dst:call("set_" .. p, v) end
        end)
    end
    local n = src:call("get_LinearParamsCount")
    if not n then return end
    dst:call("set_LinearParamsCount", n)
    for i = 0, n - 1 do
        local lp = src:call("getLinearParamsAt", i)
        if lp then dst:call("setLinearParamsAt", i, lp) end
    end
end

local function update_image()
    -- grading changes with the time of day and the area
    if not R.copied_at or frame - R.copied_at >= 120 then
        R.copied_at = frame
        copy_props(R.main_tm, R.tm, TM_SKIP)
        R.tm:call("set_Enabled", R.main_tm:call("get_Enabled") == true)
        if R.main_ldr and R.ldr then
            copy_props(R.main_ldr, R.ldr, COMMON_SKIP)
            R.ldr:call("set_Enabled", R.main_ldr:call("get_Enabled") == true)
            pcall(copy_color_correct, R.main_ldr:call("get_ColorCorrect"), R.ldr:call("get_ColorCorrect"))
        end
    end
    -- main EV = the per-scene compensation ace.DynamicExposure writes (0 in camp, ~1.5-2 outdoors).
    -- Fixed exposure at the main meter: the mirror's own auto exposure turned the hunter in the
    -- main view white.
    local comp = R.main_tm:call("get_EV") or 0
    if cfg.follow_meter then
        if R.auto_mode ~= 2 then R.tm:call("setAutoExposure", 2); R.auto_mode = 2 end
        local real = R.main_tm:call("get_SnappedRealEV")
        if real and real > 0 then R.tm:call("set_EV", real + comp + cfg.ev + 0.0) end
    else
        if R.auto_mode ~= 0 then R.tm:call("setAutoExposure", R.main_tm:call("getAutoExposure")); R.auto_mode = 0 end
        R.tm:call("set_EV", comp + cfg.ev + 0.0)
    end
end

-- ---------------------------------------------------------------- per frame
local function prepare()
    frame = frame + 1
    if stopped then return end
    if not cfg.enabled then hide(); view.status = "未开启"; return end
    if not opts.stable() then hide(); view.status = "过场或读取中，暂时隐藏"; return end
    local root = opts.root()
    if not root then hide(); return end
    if not R.tr then
        if frame % 60 ~= 0 then return end
        if not load_resources() then view.status = "找不到镜子的渲染贴图（natives 文件没有安装？）"; return end
        if not find_camera() then R = {}; return end
    end
    -- a mirror camera that became the primary camera would drive the HUD, culling and sound
    if frame % 30 == 0 then
        local main = main_camera_go()
        if not main or main:call("get_Name") ~= "Main Camera" then
            hide(); stopped = true; view.status = "主相机异常，表情镜已停止（重置脚本后重试）"
            opts.log("face mirror stopped: primary camera is %s", tostring(main and main:call("get_Name")))
            return
        end
    end
    if not R.el then
        if not R.gui_go then R.want_gui = true; view.status = "正在加载界面"; return end
        if frame % 30 ~= 0 or not take_element() then view.status = "正在加载界面"; return end
    end
    if frame % 30 == 0 then keep_element() end
    place_camera(root)
    update_image()
    show()
    view.status = "显示中"
end

-- the GUI GameObject is created here, outside rendering
local function update_behavior()
    if R.want_gui and not R.gui_go then create_gui() end
    R.want_gui = nil
    F.tick_save()
end

-- opts = { stable = fn -> bool (characters settled, no cutscene), root = fn -> player transform or nil,
-- log = fn(fmt, ...) }. Registers the callbacks once.
local attached = false
function F.attach(o)
    opts = o
    F.load()
    if attached then return end
    attached = true
    -- a type that is gone after a game update leaves the mirror off, the rest of SKS runs
    local ok = pcall(function()
        T.SceneManager = sdk.find_type_definition("via.SceneManager")
        T.Size = sdk.find_type_definition("via.Size")
        local go_t = sdk.find_type_definition("via.GameObject")
        M.go_create = go_t:get_method("create(System.String)")
        M.go_create_in = go_t:get_method("create(System.String, via.Folder)")
        M.jbn = sdk.find_type_definition("via.Transform"):get_method("getJointByName(System.String)")
        local function enum(t, name) return sdk.find_type_definition(t):get_field(name):get_data(nil) end
        E.secondary = enum("via.render.RenderOutputID", "Secondary")
        E.taa_off = enum("via.render.ToneMapping.TemporalAA", "Disable")
        E.tex_asset = enum("via.gui.TextureAssetType", "Texture")
        E.uv = enum("via.gui.UVValueType", "UV")
        assert(T.SceneManager and T.Size and M.go_create and M.go_create_in and M.jbn)
    end)
    if not ok then
        stopped = true
        view.status = "游戏类型缺失，表情镜不可用"
        return
    end
    re.on_application_entry("PrepareRendering", function()
        -- after PrepareRendering: joint world positions are still last frame's before it
        local ok, err = pcall(prepare)
        if not ok then
            view.status = "表情镜出错，详见日志"
            if frame % 300 == 0 then opts.log("face mirror error: %s", tostring(err)) end
        end
    end)
    re.on_pre_application_entry("UpdateBehavior", function()
        local ok, err = pcall(update_behavior)
        if not ok then opts.log("face mirror GUI error: %s", tostring(err)) end
    end)
end

function F.shutdown()
    pcall(hide)
    F.flush()
end

return F
