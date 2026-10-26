-- RE4R animation-side correction inputs for meshes without native receiver channels.
-- Rig handles own Motion references; restoration records keep only addresses and numeric hashes.
local Hash = require("ShapeKeySystem_Core.NameHash")
local D = {}
local names = {"jaw_openExtreme", "mouth_purse_L_U", "mouth_purse_L_D", "mouth_purse_R_U",
    "mouth_purse_R_D", "mouth_funnel_L_U", "mouth_funnel_L_D", "mouth_funnel_R_U", "mouth_funnel_R_D"}
local wanted, registrations = {}, {}
for _, name in ipairs(names) do
    local key = "Face__geo__p000_cbs.crct_" .. name
    wanted[name] = Hash.hash(key)
end
local function call(o, method, ...)
    if not o then return nil end
    local ok, value = pcall(o.call, o, method, ...)
    return ok and value or nil
end
local function address(o)
    local ok, value = pcall(function() return o:get_address() end)
    return ok and value or nil
end
local function length(a)
    local n = call(a, "get_Length")
    return type(n) == "number" and n >= 0 and n <= 4096 and n % 1 == 0 and n or nil
end
local function uint32(value)
    local n = type(value) == "number" and math.tointeger(value)
    return n and n >= 0 and n <= 0xFFFFFFFF and n or nil
end
local function list(a, n)
    local out = {}
    for i = 0, n - 1 do
        local raw = call(a, "get_Item(System.Int32)", i)
        local v = uint32(raw)
        if v == nil then return nil, {index = i, value_type = type(raw), value = tostring(raw):sub(1, 80)} end
        out[#out + 1] = v
    end
    return out
end
D.hash_list = list
local function same(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function setup(motion, values)
    local arr = sdk.create_managed_array("System.UInt32", #values):add_ref()
    for i, value in ipairs(values) do
        -- The SDK UInt32 constructor accepts an Int32; preserve the unsigned bit pattern.
        local signed = value >= 0x80000000 and value - 0x100000000 or value
        arr[i - 1] = sdk.create_uint32(signed):add_ref()
        if call(arr, "get_Item(System.Int32)", i - 1) ~= value then error("动画输入哈希回读不一致") end
    end
    motion:call("setupDeformer(System.UInt32[])", arr)
    local actual = call(motion, "get_DeformNameHashes")
    local count = length(actual)
    if not count or not same(list(actual, count), values) then error("动画输入登记回读不一致") end
end
function D.bind(face)
    local motion = call(call(face, "get_GameObject"), "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if not motion then return nil end
    local requested = {}
    for _, name in ipairs(names) do
        requested[#requested + 1] = wanted[name]
    end
    return {motion = motion, wanted = requested, next_check = 0, index = {}, status = "pending"}
end
local function read(h, register)
    if not h then return {} end
    local motion, now = h.motion, os.clock()
    if h.bad_until and now < h.bad_until then return {} end
    local hashes, values = call(motion, "get_DeformNameHashes"), call(motion, "get_DeformValues")
    local hn, vn, ha = length(hashes), length(values), address(hashes)
    if not hn or not vn then h.status = "unavailable"; return {} end
    local changed = h.hash_address ~= ha or h.hash_count ~= hn
    if changed or now >= h.next_check then
        h.next_check = now + 2
        local current = list(hashes, hn)
        if not current then h.status, h.bad_until = "unreadable", now + 2; return {} end
        local index = {}
        for i, hash in ipairs(current) do index[hash] = i - 1 end
        local requested = {}
        for i, hash in ipairs(current) do requested[i] = hash end
        for _, hash in ipairs(h.wanted) do
            if index[hash] == nil then requested[#requested + 1] = hash end
        end
        if #requested > #current and register ~= false and now >= (h.retry_at or 0) then
            local owner = address(motion)
            if not owner then h.status = "unavailable"; return {} end
            local previous = registrations[owner]
            local original = previous and same(current, previous.requested) and previous.original or current
            h.retry_at = now + 2
            local record = {original = original, requested = requested}
            local ok, why = pcall(setup, motion, requested)
            registrations[owner] = record
            h.error = not ok and tostring(why) or nil
            h.status = ok and "warming" or "registration_failed"
            -- setupDeformer resets evaluated values; wait for the next animation update.
            h.hash_address, h.hash_count = nil, nil
            return {}
        end
        h.index, h.hash_address, h.hash_count = index, ha, hn
        h.status = #requested == #current and "ready" or "registration_pending"
        if h.status == "ready" then h.error = nil end
    end
    local out = {}

    for _, name in ipairs(names) do
        local i = h.index[wanted[name]]
        if i ~= nil and i < vn then

            local value = call(values, "get_Item(System.Int32)", i)
            if type(value) == "number" and value == value and math.abs(value) < math.huge then out[name] = value end
        end
    end
    return out
end
function D.read(h, register)
    local values = read(h, register)
    return values
end

-- Prefer already registered inputs without changing the engine's registration table.
function D.existing(h, requested)
    if not h then return {} end
    local motion, now = h.motion, os.clock()
    local cache = h.existing
    -- Empty or unreadable tables are retried on a timer; the caller uses extra-joint meanwhile.
    if cache and #cache.matched == 0 and cache.requested == requested and now < cache.due then
        return {}
    end
    local hashes = call(motion, "get_DeformNameHashes")
    local hn, ha = length(hashes), address(hashes)
    if not hn then
        h.existing = {requested = requested, matched = {}, status = "array_unavailable", due = now + 2}
        return {}
    end
    if not cache or cache.count ~= hn or cache.requested ~= requested or now >= cache.due then
        local current, failure = list(hashes, hn)
        if not current then
            h.existing = {address = ha, count = hn, requested = requested, matched = {},
                status = "index_unreadable", error = failure, due = now + 2}
            return {}
        end
        local index, matched = {}, {}
        for i, hash in ipairs(current) do index[hash] = i - 1 end
        for _, item in ipairs(requested) do
            local i = index[item.hash]
            if i ~= nil then matched[#matched + 1] = {name = item.name, hash = item.hash, index = i} end
        end
        cache = {address = ha, count = hn, requested = requested, matched = matched, due = now + 2,
            status = #matched > 0 and "ready" or "no_matching_inputs"}
        h.existing = cache
    end
    local out = {}
    if #cache.matched > 0 then
        local values = call(motion, "get_DeformValues")
        local vn = length(values)
        if vn then
            for _, item in ipairs(cache.matched) do
                -- Validate the live index before using its value, including wrapper/address changes.
                local mapped = item.index >= 0 and item.index < hn
                    and uint32(call(hashes, "get_Item(System.Int32)", item.index)) == item.hash
                if mapped and item.index < vn then
                    local value = call(values, "get_Item(System.Int32)", item.index)
                    if type(value) == "number" and value == value and math.abs(value) < math.huge then
                        out[item.name] = value
                    end
                elseif not mapped then
                    cache.status, cache.due = "mapping_changed", now
                end
            end
        end
    end
    cache.address = ha
    return out
end

function D.snapshot(h)
    return h and {status = h.status, count = h.hash_count, error = h.error} or {status = "unavailable"}
end
function D.inputs()
    local result = {}
    for i, name in ipairs(names) do result[i] = name end
    return result
end

-- Resolve live components again rather than dereferencing actors retained across a rebuild.
function D.release()
    if next(registrations) == nil then return end
    local function restore(motion)
        local owner = address(motion)
        local record = owner and registrations[owner]
        if not record then return end
        local hashes = call(motion, "get_DeformNameHashes")
        local n = length(hashes)
        local current = n and list(hashes, n)
        if same(current, record.requested) then
            local ok, why = pcall(setup, motion, record.original)
            if not ok then log.warn("RE4R 动画输入恢复失败：" .. tostring(why)) end
        end
        registrations[owner] = nil
    end
    pcall(function()
        local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
        local ctx = call(cm, "getPlayerContextRef()")
        restore(call(call(ctx, "get_BodyUpdater"), "get_HeadMotion"))
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local components = call(scene, "findComponents(System.Type)", sdk.typeof("via.motion.Motion"))
        local count = call(components, "get_Length") or 0
        for i = 0, count - 1 do restore(call(components, "GetValue(System.Int32)", i)) end
    end)
    registrations = {}
end
re.on_script_reset(D.release)
return D
