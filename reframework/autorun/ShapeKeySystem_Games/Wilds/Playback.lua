-- 管理荒野主猎人的录制播放会话。
--
-- 面部和动画层引用归 `session` 所有；写入前复查对象身份与参数索引，失效时放弃恢复。
-- 更新回调连接和恢复会话，面部钩子注入已生成的 raw 样本；输入已是引擎单位，不再乘 0.01。
local U = require("ShapeKeySystem_Core.Util")
local Recording = require("ShapeKeySystem_Core.Recording")
local Perf = require("ShapeKeySystem_Core.Perf")
local clock = os.clock
local A = { id = "mhwilds", name = "怪物猎人：荒野", final_unit = 0.01, raw_unit = 0.01 }
local facial, app_type
local session, callbacks, installed
local watched   -- 录制器关注的控制器与动画层；钩子把读到的 raw 存回这张表

function A.now()
    local app = sdk.get_native_singleton("via.Application")
    local now = app and sdk.call_native_func(app, app_type, "get_UpTimeSecond")
    assert(Recording.finite(now, 1e9), "无法读取游戏运行时间")
    return now
end

-- 每次重新查询主猎人的面部，用于验证会话引用是否仍属于当前角色。
local function locate()
    local manager = sdk.get_managed_singleton("app.PlayerManager")
    local player = manager and manager:call("getMasterPlayer")
    local character = player and player:get_field("<Character>k__BackingField")
    if not character or character:call("get_IsSetUp") ~= true then return end
    local dm = sdk.get_managed_singleton("app.DemoMediator")
    if dm and (dm:call("get_IsBusy") or dm:call("get_IsBusyLoad")) then return end
    local object = player and player:call("get_Object")
    local root = object and object:call("get_Transform")
    local child, seen = root and root:call("get_Child"), {}
    for _ = 1, 80 do
        if not child then break end
        local addr = child:get_address()
        if seen[addr] then break end
        seen[addr] = true
        local go = child:call("get_GameObject")
        local name = go and go:call("get_Name") or ""
        if name:find("Player_Face", 1, true) == 1 then
            local controller, layer = A.face_parts(child)
            if controller then return child, controller, layer end
        end
        child = child:call("get_Next")
    end
end
A.locate = locate

-- 面部变换上的表情控制器和第 0 个动画层；过场里的猎人替身也用这一组
function A.face_parts(face)
    local go = face:call("get_GameObject")
    local controller = go and go:call("getComponent(System.Type)", sdk.typeof("app.FacialController"))
    local motion = go and go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local count = motion and motion:call("getLayerCount") or 0
    local layer = count > 0 and count <= 32 and motion:call("getLayer(System.UInt32)", 0) or nil
    if controller and layer then return controller, layer end
end

-- 录制器每次采样都重新登记；超过 1 秒没有登记就停止读取，录制结束后不再逐帧调用引擎。
function A.watch(target) watched = target end

local function read_watched(w, layer)
    local raw = {}
    for i, index in ipairs(w.indices) do
        local v = layer:call("getExtraValue(System.Int32)", index)
        assert(Recording.finite(v, 1000), "面部动画输入无效")
        raw[i] = v
    end
    w.raw, w.read_at = raw, clock()
end

function A.catalog()
    local data = U.load_json(U.path("builtin", A.id, "recording_catalog.json"))
    assert(data and data.schema == "sks.recording.catalog/1" and data.game == A.id and #data.params == 200,
        "荒野录制参数表缺失或不完整")
    local out, seen = {}, {}
    for _, row in ipairs(data.params) do
        assert(Recording.finite(row.param, 200, true) and row.param >= 1 and not out[row.param]
            and Recording.finite(row.hash, 4294967295, true) and row.hash >= 0 and not seen[row.hash]
            and row.source == string.format("fcParam_%03d", row.param), "荒野参数表包含无效编号或哈希")
        out[row.param], seen[row.hash] = row.hash, true
    end
    return out
end

-- 游戏内录制把录制名称写在 label；不过滤文件，读不了的文件仍按文件名列出
function A.describe(data)
    return { name = type(data) == "table" and type(data.label) == "string" and data.label ~= "" and data.label or nil }
end

function A.valid()
    if not session then return false end
    local ok, face, controller, layer = pcall(locate)
    return ok and face and face:get_address() == session.face_addr
        and controller:get_address() == session.controller_addr and layer:get_address() == session.layer_addr
        and layer:call("get_ValueCount") == session.count
end

-- 全部参数索引、关节和基线校验通过后才建立会话，不在连接阶段写入。
function A.connect(clip)
    assert(clip.track ~= "raw" or A.hook_ready, "荒野面部动画回调不可用，无法重播 raw")
    local face, controller, layer = locate()
    assert(face, "请进入存档，在主猎人正常游戏时播放录制")
    local count = layer:call("get_ValueCount")
    assert(Recording.finite(count, 4096, true) and count >= 1, "面部动画层数量异常")
    local slots, seen = {}, {}
    for param, column in pairs(clip.map) do
        local index = layer:call("getValueIndexByNameHash(System.UInt32)", clip.hashes[column])
        assert(Recording.finite(index, count - 1, true) and index >= 0 and not seen[index],
            string.format("fcParam_%03d 在当前面部动画层不可用", param))
        assert(face:call("getJointByName(System.String)", string.format("fcParam_%03d", param)), "当前面部缺少录制参数关节")
        local baseline = layer:call("getExtraValue(System.Int32)", index)
        assert(Recording.finite(baseline, 1000), "当前面部输入基线无效")
        slots[column], seen[index] = { index = index, hash = clip.hashes[column], original = baseline }, true
    end
    session = { face_addr = face:get_address(), controller_addr = controller:get_address(),
        layer_addr = layer:get_address(), count = count, layer = layer, slots = slots,
        changed = {}, last_hook = A.now() }
end

function A.matches(rig)
    return session and rig.primary and rig.face:get_address() == session.face_addr
end

function A.inject(values)
    local started = clock()
    assert(A.valid(), "主猎人、场景或面部动画层已更换，播放已停止")
    -- 数量不变也可能更换输入布局；先核对全部哈希索引，再开始本批写入。
    for _, slot in ipairs(session.slots) do
        assert(session.layer:call("getValueIndexByNameHash(System.UInt32)", slot.hash) == slot.index,
            "面部动画层参数索引已变化，播放已停止")
    end
    for column, slot in ipairs(session.slots) do
        -- 标记先于调用，部分写入抛错时仍能恢复已经尝试写入的列。
        session.changed[column] = true
        session.layer:call("setExtraValue(System.Int32, System.Single)", slot.index, values[column] + 0.0)
    end
    Perf.record("raw_inject", clock() - started)
end

function A.stop(restore)
    local old = session
    local ok, valid = pcall(A.valid)
    session = nil
    if not old or not restore or not ok or not valid then return end
    local first_error
    for column in pairs(old.changed) do
        local slot = old.slots[column]
        local restored, err = pcall(function()
            assert(old.layer:call("getValueIndexByNameHash(System.UInt32)", slot.hash) == slot.index,
                "旧索引已失效，跳过恢复")
            old.layer:call("setExtraValue(System.Int32, System.Single)", slot.index, slot.original + 0.0)
        end)
        if not restored then first_error = first_error or err end
    end
    if first_error then return false, tostring(first_error) end
    return true
end

-- 仅在所选适配器加载时安装；线程局部标记将 pre/post 钩子限定到会话控制器和动画层。
function A.attach(cb)
    callbacks = cb
    if installed then return end
    facial = sdk.find_type_definition("app.FacialController")
    app_type = sdk.find_type_definition("via.Application")
    installed = true
    re.on_pre_application_entry("UpdateMotion", function() callbacks.tick(true) end)
    local method = facial and facial:get_method("updateAfterMotion(via.motion.Motion, via.motion.TreeLayer)")
    if not method or not thread or not thread.get_hook_storage then A.hook_ready = false; return end
    local function inject()
        if not session then return end
        local ok, err = pcall(function()
            -- 实际写入入口 `A.inject` 复查身份与全部索引，同一批次不重复查询角色树。
            callbacks.inject()
            if session then session.last_hook = A.now() end
        end)
        if not ok then callbacks.fail(tostring(err)) end
    end
    local ok, err = pcall(sdk.hook, method, function(args)
        local storage = thread.get_hook_storage()
        storage.sks_playback_target = false
        local w = watched
        if w and clock() - w.touched > 1 then watched, w = nil, nil end
        if not session and not w then return end
        local ok_target, actor, layer_addr, layer = pcall(function()
            local actor, layer = sdk.to_managed_object(args[2]), sdk.to_managed_object(args[4])
            if actor and layer then return actor:get_address(), layer:get_address(), layer end
        end)
        if not ok_target or not actor then return end
        -- 先于注入读取，录到的是动画本身给出的输入
        if w and actor == w.controller_addr and layer_addr == w.layer_addr then
            local read_ok, read_err = pcall(read_watched, w, layer)
            if not read_ok then w.error = tostring(read_err) end
        end
        if session and actor == session.controller_addr and layer_addr == session.layer_addr then
            storage.sks_playback_target = true; inject()
        end
    end, function(retval)
        if thread.get_hook_storage().sks_playback_target then inject() end
        return retval
    end)
    A.hook_ready, A.hook_error = ok, ok and nil or tostring(err)
end

function A.healthy(track)
    assert(A.valid(), "主猎人、场景或面部动画层已更换，播放已停止")
    if track == "raw" then assert(A.now() - session.last_hook <= 1, "面部动画回调未运行，重播已停止") end
end
return A
