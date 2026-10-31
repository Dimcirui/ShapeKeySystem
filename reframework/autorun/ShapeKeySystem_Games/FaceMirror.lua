-- ShapeKeySystem: face mirror, shared by the games whose adapter has `face_mirror`. A second camera
-- renders the player's face into a render target texture shipped in natives/, and a texture element
-- of our own GUI shows it on screen. Settings live in user/face_mirror.json; the panel reads `view`.
-- Each adapter passes its game's resources and joints to `M.new`.
--
-- Constraints:
-- - Nothing here calls sdk at load: lookups happen in `attach`.
-- - The camera's RenderOutput must be Secondary with an .rtex target: a Primary output becomes
--   MainView.PrimaryCamera and flickers. A primary camera with another name than the game's main
--   camera stops the mirror.
-- - The camera and the GUI GameObject are created once and only hidden afterwards: destroying and
--   recreating render cameras left orphaned outputs in the renderer. They are found again by name.
-- - The camera is a child of a player joint with a fixed local pose. A camera written in world space
--   every frame was drawn with a pose from another moment on single frames of sharp turns.
-- - The GUI GameObject is created in UpdateBehavior: changing the GUI tree during PrepareRendering
--   crashed the game. Only components the camera already has get the main camera's settings:
--   creating CustomFilter / SoftBloom / FFTBloom on it and copying into them crashed the game.
-- - Engine references are dropped with the rigs (`drop_refs`) and never held across a rebuild.
-- - The camera draws into the Tertiary output, which the player's meshes leave out by default
--   in RE4R (their RenderOutputID mask is Primary | Secondary). Only the Tertiary bit is changed:
--   set on the player parts the mirror shows, cleared on the other player parts and, with
--   `isolate`, on every other mesh in the scene that has it (props carry it by default), and put
--   back as it was when the mirror hides. Isolated, the mirror shows the player alone and the clip
--   range can stay wide. MH Wilds is not isolated: all of its ~6000 meshes carry every output bit and
--   stream in all the time, so its background is cut by the clip range alone.

local U = require("ShapeKeySystem_Core.Util")

local M = {}

local CAM_NAME, GUI_NAME = "FaceMirrorRtexCam", "FaceMirrorGUI"
local CAM_COMPONENTS = { "via.Camera", "via.render.RenderOutput", "via.render.ToneMapping", "via.render.LDRPostProcess" }
local CFG_PATH = U.path("user", "face_mirror.json")
local sin, cos, rad, max = math.sin, math.cos, math.rad, math.max

-- G = { rtex, gui_asset, gui_elem (a via.gui.Texture in that GUI), gui_folder (scene folder of the
-- HUD GUIs), main_camera (name of the main camera's GameObject), binds = { {id, name}, ... } (body
-- joints, first is the default; their local axes: +Z forward, +Y up), rigs = { <id> = {dist, aim,
-- rot} } (defaults per joint: distance from the aim point, aim point in the joint's frame, camera
-- angles in degrees applied Y, then X, then Z), parts = { {id, name, hide}, ... } (player parts the
-- panel can hide; hide = the default), part = fn(top_name, mesh_path) -> "head" (always shown), a
-- parts id, or "other" (never shown) (top_name: the player root's child the mesh hangs under;
-- mesh_path lower case), isolate = clear the mirror's output bit on every other mesh in the scene, clip = { front,
-- back } default clip range, exposure = { follow_meter, ev, main_ev } defaults (optional: true, -2,
-- "add"; main_ev "add" when the main camera's EV is a compensation to add, "skip" when it is the
-- meter itself) }. Returns the face mirror of that game.
function M.new(G)
    local F = {}

    local RTEX = G.rtex
    local GUI_ASSET, GUI_ELEM = G.gui_asset, G.gui_elem
    F.BINDS = G.binds
    F.part = G.part
    local PART_IDS, HIDE_DEFAULTS = {}, {}
    for _, p in ipairs(G.parts) do PART_IDS[p.id] = true; HIDE_DEFAULTS[p.id] = p.hide == true end
    local BIND_IDS = {}
    for _, b in ipairs(F.BINDS) do BIND_IDS[b.id] = true end
    local RIG_DEFAULTS = G.rigs
    local EXPO = G.exposure or {}
    local ADD_MAIN_EV = EXPO.main_ev ~= "skip"

    F.DEFAULTS = {
        enabled = false, bind = F.BINDS[1].id,
        size = 260, x = 200, y = 540,           -- window centre in the 1920 x 1080 view, origin top left, Y down
        fov = 30,
        ev = EXPO.ev or -2,                     -- added to the main camera's exposure; lower is brighter
        follow_meter = EXPO.follow_meter ~= false,   -- fixed exposure at the main camera's meter
        hide = HIDE_DEFAULTS,                   -- parts id -> left out of the mirror (the head always shows)
        clip_front = G.clip[1], clip_back = G.clip[2],   -- slab kept around the aim point; the rest is transparent
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
    local view = { available = true, cfg = cfg, binds = F.BINDS, parts = G.parts, status = "未开启" }
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
        if p.hide ~= nil then
            if type(p.hide) ~= "table" then return false, "E_BAD_ARGS", "hide must be a table" end
            for id, v in pairs(p.hide) do
                if not PART_IDS[id] or type(v) ~= "boolean" then return false, "E_BAD_ARGS", "hide: unknown part " .. tostring(id) end
                writes[#writes + 1] = { cfg.hide, id, v }
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

    -- what = "aim": aim at the anchor joint itself (aim point 0, 0, 0); "rig": the current joint's
    -- distance, aim and angles; "all": every setting except enabled
    function F.reset(what)
        if what == "aim" then
            local a = cfg.rigs[cfg.bind].aim
            a.x, a.y, a.z = 0, 0, 0
        elseif what == "rig" then
            cfg.rigs[cfg.bind] = U.copy(RIG_DEFAULTS[cfg.bind])
        elseif what == "all" then
            local on = cfg.enabled
            for k in pairs(cfg) do cfg[k] = nil end
            for k, v in pairs(U.copy(F.DEFAULTS)) do cfg[k] = v end
            cfg.enabled = on
        else
            return false, "E_BAD_ARGS", "what: aim / rig / all"
        end
        return true
    end

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

    -- ---------------------------------------------------------------- which parts the mirror draws
    -- R.masks: mesh address -> { mesh, original mask }; the Tertiary bit is set or cleared per part
    local function restore_masks()
        for _, m in pairs(R.masks or {}) do pcall(m[1].call, m[1], "set_RenderOutputID", m[2]) end
        R.masks, R.parts_key, R.scan, R.scanned_at = nil, nil, nil, nil
    end

    local function hide_key()
        local out = {}
        for _, p in ipairs(G.parts) do out[#out + 1] = cfg.hide[p.id] and "1" or "0" end
        return table.concat(out)
    end

    local function mark_parts(root)
        R.masks = R.masks or {}
        local bit, hide = E.out_bit, cfg.hide
        local function visit(tr, top, depth)
            for _ = 1, 64 do
                if not tr then return end
                local go = tr:call("get_GameObject")
                local name = top or (go and go:call("get_Name")) or ""
                local mesh = go and component(go, "via.render.Mesh")
                if mesh then
                    local res_h = mesh:call("getMesh")
                    local path = res_h and res_h:call("get_ResourcePath") or ""
                    local addr = mesh:get_address()
                    local m = R.masks[addr]
                    if not m then m = { mesh, mesh:call("get_RenderOutputID") or 3 }; R.masks[addr] = m end
                    local part = G.part(name, path:lower())
                    local show = part == "head" or (PART_IDS[part] and not hide[part])
                    local mask = show and (m[2] | bit) or (m[2] & ~bit)
                    if mesh:call("get_RenderOutputID") ~= mask then mesh:call("set_RenderOutputID", mask) end
                end
                if depth < 4 then visit(tr:call("get_Child"), name, depth + 1) end
                tr = tr:call("get_Next")
            end
        end
        visit(root:call("get_Child"), nil, 0)
        R.parts_key = hide_key()
    end

    -- Every other mesh in the scene loses the Tertiary bit; meshes seen before are skipped by address.
    -- The list is taken at once and worked through SCAN_STEP meshes per frame: reading all of them in
    -- one frame (about 1600 in a RE4R area) stalled the first frame.
    local SCAN_STEP = 200
    local function start_scan(sc)
        local arr = sc and sc:call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
        if arr then R.scan = { list = arr:get_elements(), i = 1, ms = 0 } end
    end

    -- returns true when the scan has finished
    local function step_scan()
        local s = R.scan
        local bit, masks, list = E.out_bit, R.masks, s.list
        local t0 = os.clock()
        local last = math.min(#list, s.i + SCAN_STEP - 1)
        for k = s.i, last do
            local mesh = list[k]
            local addr = mesh:get_address()
            if not masks[addr] then
                local mask = mesh:call("get_RenderOutputID") or 0
                masks[addr] = { mesh, mask }
                if mask & bit ~= 0 then mesh:call("set_RenderOutputID", mask & ~bit) end
            end
        end
        s.i, s.ms = last + 1, max(s.ms, (os.clock() - t0) * 1000)
        if s.i <= #list then return false end
        R.scan, R.scanned_at = nil, frame
        return true, s
    end

    local function hide()
        if R.masks then pcall(restore_masks) end
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
        R.out:call("set_RenderOutputID", E.output)   -- before the target, so it is never a primary output
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
    local function gui_holder()
        if not gui_res then
            local r = sdk.create_resource("via.gui.GUIResource", GUI_ASSET)
            if not r then return nil end
            gui_res = { res = r:add_ref() }
            gui_res.holder = gui_res.res:create_holder("via.gui.GUIResourceHolder"):add_ref()
        end
        return gui_res.holder
    end

    local function create_gui()
        local sc = scene()
        if not sc then return end
        local go = sc:call("findGameObject(System.String)", GUI_NAME)
        if go then
            -- found again after a script reset: an earlier version may have left another GUI asset on it
            local gui = component(go, "via.gui.GUI")
            local cur = gui and gui:call("get_Asset")
            local path = cur and cur:call("get_ResourcePath")
            if gui and (type(path) ~= "string" or path:lower() ~= GUI_ASSET:lower()) then
                local holder = gui_holder()
                if holder then gui:call("set_Asset", holder); opts.log("face mirror: GUI asset replaced (was %s)", tostring(path)) end
            end
            R.gui_go = go
            return
        end
        local folder = sc:call("findFolder(System.String)", G.gui_folder)
        go = folder and M.go_create_in:call(nil, GUI_NAME, folder) or M.go_create:call(nil, GUI_NAME)
        if not go then return end
        local holder = gui_holder()
        if not holder then return end
        local gui = go:call("createComponent(System.Type)", sdk.typeof("via.gui.GUI"))
        if gui then gui:call("set_Asset", holder) end
        R.gui_go = go
        opts.log("face mirror: GUI created")
    end

    -- a new holder of the same resource on the GUI that has no view yet
    local function reasset_gui()
        local gui = component(R.gui_go, "via.gui.GUI")
        if not gui or gui:call("get_View") or not gui_holder() then return end
        R.reassets = (R.reassets or 0) + 1
        gui:call("set_Asset", gui_res.res:create_holder("via.gui.GUIResourceHolder"):add_ref())
        opts.log("face mirror: GUI asset set again (%d)", R.reassets)
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
        -- opaque white: RE4R's image plane starts fully transparent (it is a fade plane)
        local col = ValueType.new(T.Color)
        col:set_field("rgba", 0xFFFFFFFF)
        el:call("set_Color", col)
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
        local path = t and t:call("get_ResourcePath")
        local ok = type(path) == "string" and path:lower() == RTEX:lower() and el:call("get_UVW") == 1.0
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

    local function place_camera(root)
        local addr = root:get_address()
        if R.attached ~= addr or R.bound ~= cfg.bind then
            R.tr:call("set_Parent", root)
            R.tr:call("set_ParentJoint", cfg.bind)
            R.attached, R.bound, R.pose_key = addr, cfg.bind, nil
        end
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
        -- main view white. In Onimusha the main EV is the meter itself (EV = SnappedRealEV), the fixed
        -- exposure stayed far brighter than the main view, and the mirror's own auto exposure with
        -- `ev` as the compensation matched it (main_ev = "skip", follow_meter off).
        local comp = ADD_MAIN_EV and (R.main_tm:call("get_EV") or 0) or 0
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
            if not main or main:call("get_Name") ~= G.main_camera then
                hide(); stopped = true; view.status = "主相机异常，表情镜已停止（重置脚本后重试）"
                opts.log("face mirror stopped: primary camera is %s", tostring(main and main:call("get_Name")))
                return
            end
        end
        if not R.el then
            if not R.gui_go then R.want_gui = true; view.status = "正在加载界面"; return end
            if frame % 30 ~= 0 or not take_element() then
                -- Onimusha: the GUI set when the GameObject was created or found again sometimes
                -- never built a view; the same asset put on again a moment later did
                if frame % 60 == 0 and (R.reassets or 0) < 3 then R.want_reasset = true end
                view.status = "正在加载界面"
                return
            end
        end
        if frame % 30 == 0 then keep_element() end
        if frame % 60 == 0 or R.parts_key ~= hide_key() then
            mark_parts(root)
        end
        -- after the player's parts, which therefore count as seen; again every 3 s for new meshes
        if G.isolate and not R.scan and (not R.scanned_at or frame - R.scanned_at >= 180) and R.masks then
            start_scan(scene())
        end
        if R.scan then
            local done, s = step_scan()
            if done and (R.scans or 0) < 2 then
                R.scans = (R.scans or 0) + 1
                opts.log("face mirror: scene scan %d meshes, at most %.1f ms per frame", #s.list, s.ms)
            end
        end
        place_camera(root)
        update_image()
        show()
        view.status = "显示中"
    end

    -- the GUI GameObject is created here, outside rendering
    local function update_behavior()
        if R.want_gui and not R.gui_go then create_gui() end
        if R.want_reasset and R.gui_go and not R.el then reasset_gui() end
        R.want_gui, R.want_reasset = nil, nil
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
            T.Color = sdk.find_type_definition("via.Color")
            local go_t = sdk.find_type_definition("via.GameObject")
            M.go_create = go_t:get_method("create(System.String)")
            M.go_create_in = go_t:get_method("create(System.String, via.Folder)")
            local function enum(t, name) return sdk.find_type_definition(t):get_field(name):get_data(nil) end
            E.output = enum("via.render.RenderOutputID", "Tertiary")
            E.out_bit = math.tointeger(E.output) or 4
            E.taa_off = enum("via.render.ToneMapping.TemporalAA", "Disable")
            E.tex_asset = enum("via.gui.TextureAssetType", "Texture")
            E.uv = enum("via.gui.UVValueType", "UV")
            assert(T.SceneManager and T.Size and T.Color and M.go_create and M.go_create_in)
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
end

return M
