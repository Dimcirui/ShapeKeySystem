-- ShapeKeySystem: shape key drivers. Each driver holds one key at a value computed from time,
-- either a waveform (period, low / high value, phase) or a formula the player types.
--
-- A wave driver is compiled through the same formula path: `formula_of` turns it into
-- `lerp(lo, hi, wave(t / period + phase))`, and the page shows that text so a wave can be
-- copied into a formula and edited.
--
-- Formulas are parsed here into closures, never handed to `load`: driver files may be shared, and
-- a Lua chunk reaches the string library through the string metatable whatever its environment.
--
-- Constraints:
-- - Values go out as External leases (owner "drivers"), so they override expression and sculpt
--   and pass the same write guards as every other value. A key another owner holds (face mocap,
--   another plugin) is left to that owner; the driver resumes once the key is free.
-- - The clock advances by API's tick dt (at most 0.1 s), so a long hitch does not jump the phase.
-- - Settings live in user/drivers.json, not settings.json.

local U   = require("ShapeKeySystem_Core.Util")
local Ext = require("ShapeKeySystem_Core.External")

local D = {}
D.OWNER = "drivers"
D.MAX_ITEMS = 32
D.MAX_FORMULA = 200
-- "expr" = the item's own formula; the others are waveforms over one cycle (see FUNCS)
D.WAVES = { "osc", "tri", "saw", "square", "noise", "expr" }
D.WAVE_NAMES = { osc = "正弦", tri = "三角", saw = "锯齿", square = "方波", noise = "随机平滑", expr = "自定义公式" }
D.ITEM_DEFAULTS = { enabled = true, key = "", wave = "osc", period = 2.0, lo = 0.0, hi = 1.0, phase = 0.0, expr = "" }
-- lo / hi up to Sculpt.MAX_LIMIT; tick clamps the value to the current sculpt_max
D.LIMITS = { period = { 0.05, 120 }, lo = { 0, 5 }, hi = { 0, 5 }, phase = { 0, 1 } }

local CFG_PATH = U.path("user", "drivers.json")
local clock, floor, abs, pi = os.clock, math.floor, math.abs, math.pi

local cfg = { enabled = true, items = {} }
local st = { save_at = nil, held = {} }   -- held: norm key -> name, leases set on the last tick
-- view: what the page shows (state.drivers). items[i] = { value, err = { template, args... },
-- owner = another owner holding the key, dup = index of the driver that already holds it }
D.view = { cfg = cfg, items = {}, time = 0, waves = D.WAVES, wave_names = D.WAVE_NAMES, max_items = D.MAX_ITEMS }
D.time = 0
local compiled = {}   -- index -> closure(t) or false

-- ---------------------------------------------------------------- formula
local function frac(x) return x - floor(x) end
local function smooth(x)
    if x <= 0 then return 0 elseif x >= 1 then return 1 end
    return x * x * (3 - 2 * x)
end
local function hash(i) return frac(math.sin(i * 12.9898) * 43758.5453) end

-- the cycle functions take x in cycles and return 0..1, starting at 0 on a whole cycle (square
-- starts high)
local FUNCS = {
    sin = { 1, math.sin }, cos = { 1, math.cos }, abs = { 1, abs }, floor = { 1, floor },
    sqrt = { 1, function(x) return x > 0 and math.sqrt(x) or 0 end },
    frac = { 1, frac }, smoothstep = { 1, smooth },
    min = { 2, math.min }, max = { 2, math.max },
    clamp = { 3, function(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end },
    lerp = { 3, function(a, b, k) return a + (b - a) * k end },
    osc = { 1, function(x) return 0.5 - 0.5 * math.cos(2 * pi * x) end },
    tri = { 1, function(x) return 1 - abs(2 * frac(x) - 1) end },
    saw = { 1, frac },
    square = { 1, function(x) return frac(x) < 0.5 and 1 or 0 end },
    pulse = { 2, function(x, duty) return frac(x) < duty and 1 or 0 end },
    noise = { 1, function(x)
        local i = floor(x)
        local a, b = hash(i), hash(i + 1)
        return a + (b - a) * smooth(x - i)
    end },
}
local CONSTS = { pi = pi, tau = 2 * pi }
D.FUNCS = FUNCS

local function tokenize(s)
    local toks, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("[%d%.]") then
            local num = s:match("^%d*%.?%d*[eE][%+%-]?%d+", i) or s:match("^%d*%.?%d*", i)
            local v = tonumber(num)
            if not v then return nil, { "无法识别的数字 %s", num } end
            toks[#toks + 1] = { k = "num", v = v }
            i = i + #num
        elseif c:match("[%a_]") then
            local id = s:match("^[%w_]+", i)
            toks[#toks + 1] = { k = "id", v = id }
            i = i + #id
        elseif c:match("[%+%-%*/%%%^%(%),]") then
            toks[#toks + 1] = { k = c }
            i = i + 1
        else
            return nil, { "无法识别的字符 %s", c }
        end
    end
    return toks
end

-- Recursive descent: add := mul (+|- mul)*, mul := unary (*|/|% unary)*, unary := - unary | pow,
-- pow := atom (^ unary)?. Each rule returns a closure of t.
local function parse(toks)
    local pos, depth = 1, 0
    local function peek() return toks[pos] and toks[pos].k end
    local function take() pos = pos + 1; return toks[pos - 1] end
    local add
    local function atom()
        local tk = take()
        if not tk then error({ "公式不完整" }, 0) end
        if tk.k == "num" then
            local v = tk.v
            return function() return v end
        elseif tk.k == "(" then
            depth = depth + 1
            if depth > 32 then error({ "括号嵌套太深" }, 0) end
            local e = add()
            if peek() ~= ")" then error({ "缺少右括号" }, 0) end
            take(); depth = depth - 1
            return e
        elseif tk.k == "id" then
            local name = tk.v
            if peek() == "(" then
                local f = FUNCS[name]
                if not f then error({ "未知函数 %s", name }, 0) end
                take()
                depth = depth + 1
                if depth > 32 then error({ "括号嵌套太深" }, 0) end
                local args = {}
                if peek() ~= ")" then
                    args[1] = add()
                    while peek() == "," do take(); args[#args + 1] = add() end
                end
                if peek() ~= ")" then error({ "缺少右括号" }, 0) end
                take(); depth = depth - 1
                if #args ~= f[1] then error({ "%s 需要 %s 个参数", name, f[1] }, 0) end
                local fn, a, b, c = f[2], args[1], args[2], args[3]
                if f[1] == 1 then return function(t) return fn(a(t)) end end
                if f[1] == 2 then return function(t) return fn(a(t), b(t)) end end
                return function(t) return fn(a(t), b(t), c(t)) end
            end
            if name == "t" then return function(t) return t end end
            local v = CONSTS[name]
            if v then return function() return v end end
            error({ "未知名称 %s", name }, 0)
        end
        error({ "公式不完整" }, 0)
    end
    local unary
    local function pow()
        local a = atom()
        if peek() == "^" then
            take()
            local b = unary()
            return function(t)
                local x, y = a(t), b(t)
                if x < 0 and y ~= floor(y) then return 0 end
                return x ^ y
            end
        end
        return a
    end
    unary = function()
        if peek() == "-" then
            take()
            local a = unary()
            return function(t) return -a(t) end
        end
        if peek() == "+" then take(); return unary() end
        return pow()
    end
    local function mul()
        local a = unary()
        while peek() == "*" or peek() == "/" or peek() == "%" do
            local op = take().k
            local l, r = a, unary()
            if op == "*" then a = function(t) return l(t) * r(t) end
            elseif op == "/" then a = function(t) local d = r(t); return d ~= 0 and l(t) / d or 0 end
            else a = function(t) local d = r(t); return d ~= 0 and l(t) % d or 0 end end
        end
        return a
    end
    add = function()
        local a = mul()
        while peek() == "+" or peek() == "-" do
            local op = take().k
            local l, r = a, mul()
            if op == "+" then a = function(t) return l(t) + r(t) end
            else a = function(t) return l(t) - r(t) end end
        end
        return a
    end
    local e = add()
    if pos <= #toks then error({ "多余的内容：%s", toks[pos].v or toks[pos].k }, 0) end
    return e
end

-- Returns a closure t -> number, or nil and an error { template, args... } for I18n.f.
function D.compile(src)
    if type(src) ~= "string" or src:match("^%s*$") then return nil, { "公式为空" } end
    if #src > D.MAX_FORMULA then return nil, { "公式太长（最多 %s 个字符）", D.MAX_FORMULA } end
    local toks, err = tokenize(src)
    if not toks then return nil, err end
    local ok, e = pcall(parse, toks)
    if not ok then
        if type(e) == "table" then return nil, e end
        return nil, { "公式有误" }
    end
    return e
end

local function num_text(v) return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")) end

-- the formula a driver runs: its own for "expr", the waveform written out otherwise
function D.formula_of(it)
    if it.wave == "expr" then return it.expr or "" end
    local x = "t / " .. num_text(it.period)
    if it.phase ~= 0 then x = x .. " + " .. num_text(it.phase) end
    return string.format("lerp(%s, %s, %s(%s))", num_text(it.lo), num_text(it.hi), it.wave, x)
end

-- ---------------------------------------------------------------- settings
local function sanitize_item(src)
    local it = U.copy(D.ITEM_DEFAULTS)
    if type(src) ~= "table" then return it end
    if type(src.enabled) == "boolean" then it.enabled = src.enabled end
    if type(src.key) == "string" then it.key = src.key end
    if D.WAVE_NAMES[src.wave] then it.wave = src.wave end
    if type(src.expr) == "string" then it.expr = src.expr:sub(1, D.MAX_FORMULA) end
    for k, lim in pairs(D.LIMITS) do
        local v = tonumber(src[k])
        if v and v == v then it[k] = U.clamp(v, lim[1], lim[2]) + 0.0 end
    end
    return it
end

local function recompile(i)
    local it = cfg.items[i]
    local formula = D.formula_of(it)
    local fn, err = D.compile(formula)
    compiled[i] = fn or false
    D.view.items[i] = { value = 0, err = err, formula = formula }
end

local function recompile_all()
    for i in pairs(compiled) do compiled[i] = nil end
    for i in pairs(D.view.items) do D.view.items[i] = nil end
    for i = 1, #cfg.items do recompile(i) end
end

-- data: a decoded drivers.json (tests); default user/drivers.json
function D.load(data)
    if data == nil then data = U.load_json(CFG_PATH) end
    cfg.enabled, cfg.items = true, {}
    if type(data) == "table" then
        if type(data.enabled) == "boolean" then cfg.enabled = data.enabled end
        for i, src in ipairs(type(data.items) == "table" and data.items or {}) do
            if i > D.MAX_ITEMS then break end
            cfg.items[i] = sanitize_item(src)
        end
    end
    D.time = 0
    recompile_all()
end

function D.save()
    st.save_at = nil
    return U.save_json(CFG_PATH, { schema = "sks.drivers/1", enabled = cfg.enabled, items = cfg.items })
end

-- slider drags patch every frame: write the file once they settle
function D.save_soon() st.save_at = clock() + 0.5 end
function D.flush() if st.save_at then D.save() end end

-- a = { op = "add", key } | { op = "remove", index } | { op = "patch", index?, patch }
-- (patch without index: { enabled }). Returns ok, err, msg like the API commands.
function D.command(a)
    if type(a) ~= "table" then return false, "E_BAD_ARGS", "args must be a table" end
    local items = cfg.items
    if a.op == "add" then
        if #items >= D.MAX_ITEMS then return false, "E_BAD_ARGS", "too many drivers" end
        local it = U.copy(D.ITEM_DEFAULTS)
        if type(a.key) == "string" then it.key = a.key end
        items[#items + 1] = it
        recompile(#items)
    elseif a.op == "remove" then
        local i = tonumber(a.index)
        if not i or not items[i] then return false, "E_NOT_FOUND", "no such driver" end
        table.remove(items, i)
        recompile_all()
    elseif a.op == "patch" then
        local p = a.patch
        if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
        if a.index == nil then
            if type(p.enabled) ~= "boolean" then return false, "E_BAD_ARGS", "enabled must be boolean" end
            cfg.enabled = p.enabled
        else
            local i = tonumber(a.index)
            local it = i and items[i]
            if not it then return false, "E_NOT_FOUND", "no such driver" end
            if p.wave ~= nil and not D.WAVE_NAMES[p.wave] then return false, "E_BAD_ARGS", "unknown wave" end
            if p.enabled ~= nil and type(p.enabled) ~= "boolean" then return false, "E_BAD_ARGS", "enabled must be boolean" end
            for _, k in ipairs({ "key", "expr" }) do
                if p[k] ~= nil and type(p[k]) ~= "string" then return false, "E_BAD_ARGS", k .. " must be a string" end
            end
            for k, v in pairs(p) do
                local lim = D.LIMITS[k]
                if lim then
                    v = tonumber(v)
                    if not v or v ~= v then return false, "E_BAD_ARGS", k .. ": number expected" end
                    it[k] = U.clamp(v, lim[1], lim[2]) + 0.0
                elseif k == "expr" then
                    it.expr = v:sub(1, D.MAX_FORMULA)
                elseif k == "enabled" or k == "key" or k == "wave" then
                    it[k] = v
                end
            end
            recompile(i)
        end
    else
        return false, "E_BAD_ARGS", "op: add / remove / patch"
    end
    D.save_soon()
    return true
end

-- ---------------------------------------------------------------- per tick
local function release_all()
    if next(st.held) == nil then return false end
    for k in pairs(st.held) do st.held[k] = nil end
    return Ext.release_all(D.OWNER) > 0
end

-- Once per API tick. hi = the largest value a key takes (Sculpt.RANGE[2]); writable(name) is the
-- adapter's channel check or nil. Returns true when any held value changed.
local now_held = {}
function D.tick(dt, hi, writable)
    if st.save_at and clock() >= st.save_at then D.save() end
    local items = cfg.items
    if not cfg.enabled or #items == 0 then
        for _, v in pairs(D.view.items) do v.value, v.owner, v.dup = 0, nil, nil end
        return release_all()
    end
    D.time = D.time + dt
    D.view.time = D.time
    local t = D.time
    for k in pairs(now_held) do now_held[k] = nil end
    local first = {}   -- norm key -> index of the first driver naming it
    for i, it in ipairs(items) do
        local v = D.view.items[i]
        v.owner, v.dup = nil, nil
        local fn = compiled[i]
        local key = it.key
        if not (it.enabled and fn and key ~= "") then
            v.value = 0
        elseif writable and not writable(key) then
            v.value, v.owner = 0, "?"
        else
            local n = Ext.norm(key)
            local x = fn(t)
            if x ~= x or x == math.huge or x == -math.huge then x = 0 end
            x = U.clamp(x, 0, hi)
            v.value = x
            local _, owner = Ext.get(key)
            if first[n] then
                v.dup = first[n]
            elseif owner and owner ~= D.OWNER then
                v.owner = owner
            else
                first[n] = i
                Ext.set(D.OWNER, key, x + 0.0, Ext.DEFAULT_TTL)
                now_held[n] = key
            end
        end
    end
    -- keys no driver holds any more (switched off, renamed, removed) go back at once
    local released = false
    for n, name in pairs(st.held) do
        if not now_held[n] then
            if Ext.release(D.OWNER, name) then released = true end
            st.held[n] = nil
        end
    end
    for n, name in pairs(now_held) do st.held[n] = name end
    return released or next(now_held) ~= nil
end

function D.config() return cfg end

return D
