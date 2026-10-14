-- Onimusha: Way of the Sword world for the offline tests (run.py --game onimusha), loaded after
-- mock_sks.lua so the UI / d2d / json mocks stay. What differs from MH Wilds (Altina's
-- OnimushaEyeMovementIntensity.lua and kevin's Maya rev 2 build, 2026-10-12):
--   * the player: app.PlayerManager:getControllingPlayerInfo():get_Object() (no getMasterPlayer)
--   * the face is the child "Head" of the player (in Oni form also "OniHead"); its transform holds
--     the vanilla face skeleton (face_joint*, eye_Lt / eye_Rt, the core Head bone) AND its own
--     mesh carries the shape keys: the face is its own part
--   * no fcParam joints, no app.DemoMediator, none of Wilds' GUI / input / hunter types
reframework.get_game_name = function() return "onimusha_wots" end

-- via.render.Mesh has no getBlendShapeChannelName here (probe v2's method list)
local base_find_type = sdk.find_type_definition
sdk.find_type_definition = function(name)
    local td = base_find_type(name)
    if name ~= "via.render.Mesh" then return td end
    return { get_method = function(_, sig)
        if sig:find("getBlendShapeChannelName", 1, true) then return nil end
        return td:get_method(sig)
    end }
end

ONI = { player_on = true, eye_q = { x = 0, y = 0.0872, z = 0, w = 0.9962 }, lpos = {}, lrot = {} }

local IDENT = { x = 0, y = 0, z = 0, w = 1 }
local ONE = { x = 1, y = 1, z = 1 }
local HEAD_POS = { x = 0, y = 1.5, z = 0 }

-- A face skeleton: the core Head bone and face joints under it, each with a base (bind) local pose.
-- ONI.lpos[name] = {x, y, z} metres off its base position (local = head frame here, the mock
-- faces never turn); ONI.lrot[name] = local rotation.
local function face_joints(prefix)
    local joints = {}
    local head = { _name = "Head", _valid = true }
    head.get_Name = function(self) return self._name end
    head.get_Valid = function(self) return self._valid end
    head.get_Position = function() return HEAD_POS end
    head.get_Rotation = function() return IDENT end
    head.get_LocalRotation = function() return IDENT end
    head.get_LocalPosition = function() return { x = 0, y = 0, z = 0 } end
    joints.Head = head
    local function bone(name, base)
        local b = { _name = name, _valid = true }
        local key = prefix .. name
        b.get_Name = function(self) return self._name end
        b.get_Valid = function(self) return self._valid end
        b.get_Parent = function() return head end
        b.get_BaseLocalPosition = function() return { x = base[1], y = base[2], z = base[3] } end
        b.get_BaseLocalRotation = function() return IDENT end
        b.get_BaseLocalScale = function() return ONE end
        local function lp()
            local o = ONI.lpos[key] or { 0, 0, 0 }
            return { x = base[1] + o[1], y = base[2] + o[2], z = base[3] + o[3] }
        end
        b.get_LocalPosition = lp
        b.get_Position = function()
            local p = lp()
            return { x = HEAD_POS.x + p.x, y = HEAD_POS.y + p.y, z = HEAD_POS.z + p.z }
        end
        b.get_LocalRotation = function() return ONI.lrot[key] or IDENT end
        b.get_Rotation = b.get_LocalRotation
        joints[name] = b
        return b
    end
    bone("Face", { 0, 0.02, 0.05 })
    bone("face_joint340", { 0.03, 0.035, 0.08 })    -- upper lid L (Altina's eye script)
    bone("face_joint184", { -0.03, 0.035, 0.08 })   -- upper lid R
    bone("face_joint34", { 0.03, 0.02, 0.08 })      -- lower lid L
    bone("face_joint175", { -0.03, 0.02, 0.08 })    -- lower lid R
    bone("face_joint12", { 0, -0.05, 0.085 })
    -- the joints signals_onimusha.json reads (bind positions in the Head's frame, metres)
    for name, p in pairs({ face_joint343 = { 0.033, 0.080, 0.019 }, face_joint342 = { -0.034, 0.081, 0.020 },
                           face_joint278 = { 0.033, 0.070, 0.016 }, face_joint179 = { -0.035, 0.071, 0.017 },
                           face_joint64 = { 0.034, 0.031, 0.022 }, face_joint196 = { -0.040, 0.035, 0.022 },
                           face_joint276 = { 0.027, 0.092, 0.024 }, face_joint324 = { -0.024, 0.089, 0.027 },
                           face_joint7 = { 0.005, 0.087, 0.029 }, face_joint160 = { -0.009, 0.088, 0.029 },
                           face_joint80 = { -0.003, -0.048, -0.001 }, face_joint101 = { -0.001, 0.003, 0.036 },
                           face_joint82 = { 0.020, 0.001, 0.026 }, face_joint232 = { -0.025, 0.001, 0.027 } }) do
        bone(name, p)
    end
    local eL, eR = bone("eye_Lt", { 0.03, 0.03, 0.07 }), bone("eye_Rt", { -0.03, 0.03, 0.07 })
    eL.get_LocalRotation = function() return ONI.eye_q end
    eR.get_LocalRotation = function() return ONI.eye_q end
    return joints
end

-- A mesh with its own weights; ready = weight buffer allocated.
local next_addr = 0x9000
function ONI.mesh(names)
    next_addr = next_addr + 0x100
    local m = { names = names, w = {}, writes = {}, ready = true, released = false, addr = next_addr }
    m.get_MeshReady = function() return m.ready end
    m.get_BlendShapeEnable = function() return true end
    m.get_BlendShapeReleasedBuffers = function() return m.released end
    m.get_address = function() return m.addr end
    m.get_BlendShapeChannelNum = function() return #m.names end
    m.get_BlendShapeChannelWeightCount = function() return m.ready and #m.names or 0 end
    -- no getBlendShapeChannelName in Onimusha (kevin's game, probe v2): the channels are known by
    -- their name hashes, a System.UInt32[] whose elements read as numbers only through ToString
    m.get_ChannelNameHash = function()
        local list = {}
        for i, n in ipairs(m.names) do
            local h = py_mm3(n)
            list[i] = { call = function(_, meth) if meth == "ToString" or meth == "ToString()" then return tostring(h) end end }
        end
        return { get_elements = function() return list end,
                 call = function(_, meth, k) if meth == "get_Length" then return #list end return list[k + 1] end }
    end
    m.setBlendShapeChannelWeightParam = function(_, i, wt)
        if math.type(wt) ~= "float" then INT_WRITES = (INT_WRITES or 0) + 1 end
        m.writes[#m.writes + 1] = { i, wt }; m.w[i] = wt
    end
    m.getBlendShapeChannelWeightParam = function(_, i) return m.w[i] or 0 end
    m.call = function(self, meth, ...) return self[meth](self, ...) end
    return m
end

-- weight of a named channel on a mesh
function ONI.weight(m, name)
    for i, n in ipairs(m.names) do if n == name then return m.w[i - 1] or 0 end end
    return nil
end

function ONI.tr(name, joints, mesh)
    next_addr = next_addr + 0x100
    local tr = { _name = name, _joints = joints or {}, _mesh = mesh, children = {}, addr = next_addr }
    tr.getJointByName = function(self, n) return self._joints[n] end
    tr.get_address = function(self) return self.addr end
    tr.get_GameObject = function(self)
        return { call = function(_, meth, ...)
            if meth == "get_Name" then return self._name end
            if meth == "get_Transform" then return self end
            if meth:find("getComponent") then return self._mesh end
        end }
    end
    tr.get_Child = function(self) return self.children[1] end
    tr.get_Next = function(self)
        local p = self.parent
        if not p then return nil end
        for i, c in ipairs(p.children) do if c == self then return p.children[i + 1] end end
    end
    tr.get_Parent = function(self) return self.parent end
    tr.call = function(self, meth, ...)
        local f = self[meth] or self[meth:match("^([%w_]+)")]
        return f(self, ...)
    end
    return tr
end

function ONI.attach(parent, child)
    child.parent = parent
    parent.children[#parent.children + 1] = child
end

function ONI.detach(child)
    local p = child.parent
    if not p then return end
    for i, c in ipairs(p.children) do if c == child then table.remove(p.children, i); break end end
    child.parent = nil
end

-- Maya's face keys (the builtin maya profile's channel names) on her face mesh
ONI.MAYA_KEYS = { "あ", "口角上げL", "口角上げR", "ウィンク２", "ｳｨﾝｸ２右", "びっくり_L", "びっくり_R",
                  "瞳上", "瞳下", "瞳左", "瞳右", "眉_上", "怒り" }

-- (re)build the player: Player_00 with Body, Head (face skeleton + Maya's face mesh) and Hair
function ONI.build_player()
    ONI.root = ONI.tr("Player_00")
    ONI.body = ONI.tr("Body", nil, ONI.mesh({}))
    ONI.head_mesh = ONI.mesh(ONI.MAYA_KEYS)
    ONI.head = ONI.tr("Head", face_joints("Head:"), ONI.head_mesh)
    ONI.hair = ONI.tr("Hair", nil, ONI.mesh({}))
    ONI.attach(ONI.root, ONI.body)
    ONI.attach(ONI.root, ONI.head)
    ONI.attach(ONI.root, ONI.hair)
end
ONI.build_player()

-- Oni form: OniHead (its own face skeleton and a copy of the face mesh) next to Head
function ONI.oni_form(on)
    if on then
        ONI.oni_mesh = ONI.mesh(ONI.MAYA_KEYS)
        ONI.oni_head = ONI.tr("OniHead", face_joints("OniHead:"), ONI.oni_mesh)
        ONI.attach(ONI.root, ONI.oni_head)
    elseif ONI.oni_head then
        ONI.detach(ONI.oni_head)
        ONI.oni_head = nil
    end
end

-- the game swaps the Head object (a rebuild): same name, new transform and mesh
function ONI.rebuild_head()
    for _, j in pairs(ONI.head._joints) do j._valid = false end
    ONI.detach(ONI.head)
    ONI.head_mesh = ONI.mesh(ONI.MAYA_KEYS)
    ONI.head = ONI.tr("Head", face_joints("Head:"), ONI.head_mesh)
    ONI.attach(ONI.root, ONI.head)
end

local info = { call = function(_, m) if m == "get_Object" then return ONI.root:get_GameObject() end end }
local pm = { call = function(_, m)
    if m == "getControllingPlayerInfo" then return ONI.player_on and info or nil end
    error("app.PlayerManager has no method " .. tostring(m) .. " in Onimusha")
end }
sdk.get_managed_singleton = function(name)
    if name == "app.PlayerManager" then return pm end
    return nil   -- no app.DemoMediator, no Wilds managers
end
SCENE = { call = function(_, m) return { call = function(_, mm) if mm == "get_Length" then return 0 end end } end }
