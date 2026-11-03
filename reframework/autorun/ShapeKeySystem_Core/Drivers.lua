-- ShapeKeySystem: shape key drivers. A driver group is an ordered list of rows; each row computes
-- one value from time, either a waveform (period, low / high value, phase) or a formula the player
-- types. A variable row (`kind = "var"`) stores its value under a name, an output row
-- (`kind = "out"`) holds a shape key at it. Later rows read the names defined above them, so one
-- group computes all its outputs from the same values in the same tick.
--
-- A wave row is compiled through the same formula path: `formula_of` turns it into
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
-- - A group with an error in any row writes nothing: its outputs never mix values of two ticks.
-- - The clock advances by API's tick dt (at most 0.1 s), so a long hitch does not jump the phase.
-- - Groups live in driver sets, one file each under user/drivers/ or mods/drivers/ (see "driver
--   sets"); only the selected set runs. Files of schema 1 (one key per driver) load as groups of one
--   output row.
-- - A group belongs to a character (`actor`, Core/Actors.lua; "" = the player's character). Only
--   the edited character's groups take leases; the others' values go to `D.actor_values`, which
--   ActorInstances writes on that character's rigs.

local U   = require("ShapeKeySystem_Core.Util")
local Ext = require("ShapeKeySystem_Core.External")

local D = {}
D.OWNER = "drivers"
D.SCHEMA = "sks.drivers/2"
D.MAX_GROUPS = 32
D.MAX_ROWS = 32
D.MAX_FORMULA = 200
D.MAX_NAME = 40
-- "expr" = the row's own formula; the others are waveforms over one cycle (see FUNCS)
D.WAVES = { "osc", "tri", "saw", "square", "noise", "expr" }
D.WAVE_NAMES = { osc = "正弦", tri = "三角", saw = "锯齿", square = "方波", noise = "随机平滑", expr = "自定义公式" }
D.KINDS = { "out", "var" }
D.KIND_NAMES = { out = "形态键", var = "变量" }
D.ROW_DEFAULTS = { kind = "out", key = "", var = "", wave = "osc", period = 2.0, lo = 0.0, hi = 1.0, phase = 0.0,
    expr = "" }
D.GROUP_DEFAULTS = { enabled = true, name = "", actor = "" }
-- lo / hi up to Sculpt.MAX_LIMIT; tick clamps an output to the current sculpt_max
D.LIMITS = { period = { 0.05, 120 }, lo = { 0, 5 }, hi = { 0, 5 }, phase = { 0, 1 } }
-- names a variable cannot take: the inputs, constants and `clip` of every formula. `a` is kept
-- for the progress of a condition clip that hosts a group.
local RESERVED = { t = true, a = true, pi = true, tau = true, clip = true, ramp = true, cond = true }

local CFG_PATH = U.path("user", "drivers.json")   -- before driver sets; migrated by D.start
local clock, floor, abs, pi = os.clock, math.floor, math.abs, math.pi

local cfg = { enabled = true, groups = {} }
local st = { save_at = nil, held = {} }   -- held: norm key -> name, leases set on the last tick
-- view: what the page shows (state.drivers). groups[g] = { rows = { [r] = { value, formula,
-- err = { template, args... }, owner = another owner holding the key, dup = { group, row } of the
-- row that already holds it } } }
D.view = { cfg = cfg, groups = {}, time = 0, waves = D.WAVES, wave_names = D.WAVE_NAMES, kinds = D.KINDS,
    kind_names = D.KIND_NAMES, max_groups = D.MAX_GROUPS, max_rows = D.MAX_ROWS, sets = {}, current = nil }
D.time = 0
D.current_actor, D.default_actor = "", ""   -- the edited character, the player's character (API)
D.actor_values = {}   -- actor id -> norm key -> { name, value }, other characters' drivers this tick
-- rand() draws from this seed; a new one per game start, so random schedules differ between runs
D.seed = os.time() % 65536
local compiled = {}   -- group index -> { ok, rows = { { fn, slot } } }
-- clip(name) in a formula: the condition clip's weight, 0..1 along its fade-in / fade-out
-- (CondExpr.alpha, set by API). 0 for a clip that does not exist or does not play.
D.clip_progress = function() return 0 end
-- cond(id) in a formula: a game condition's value this tick (true = 1, false = 0, numbers as
-- they are), 0 while conditions are not sampled (menus) or not readable; cond_known(id) is false
-- for an id the game does not define, which is a formula error (both set by API)
D.cond_value = function() return 0 end
D.cond_known = function() return true end
local cond_seen = false   -- a cond() was compiled in the group being compiled

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
    -- the same x within one whole number gives the same value; D.seed changes the sequence
    rand = { 1, function(x) return hash(floor(x) + D.seed * 0.6180339887) end },
}
local CONSTS = { pi = pi, tau = 2 * pi }
D.FUNCS = FUNCS

-- two-character operators first: "<=" must not tokenize as "<" "="
local CMP2 = { ["<="] = "<=", [">="] = ">=", ["=="] = "==", ["~="] = "~=", ["!="] = "~=" }

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
        elseif CMP2[s:sub(i, i + 1)] then
            toks[#toks + 1] = { k = "cmp", v = CMP2[s:sub(i, i + 1)] }
            i = i + 2
        elseif c == "<" or c == ">" then
            toks[#toks + 1] = { k = "cmp", v = c }
            i = i + 1
        elseif c:match("[%+%-%*/%%%^%(%),]") then
            toks[#toks + 1] = { k = c }
            i = i + 1
        else
            return nil, { "无法识别的字符 %s", c }
        end
    end
    return toks
end

local CMP_FN = {
    ["<"] = function(x, y) return x < y and 1 or 0 end, ["<="] = function(x, y) return x <= y and 1 or 0 end,
    [">"] = function(x, y) return x > y and 1 or 0 end, [">="] = function(x, y) return x >= y and 1 or 0 end,
    ["=="] = function(x, y) return x == y and 1 or 0 end, ["~="] = function(x, y) return x ~= y and 1 or 0 end,
}

-- Recursive descent: cmp := add (op add)?, add := mul (+|- mul)*, mul := unary (*|/|% unary)*,
-- unary := - unary | pow, pow := atom (^ unary)?. Each rule returns a closure of the environment
-- e (`e.t` = seconds, `e[slot]` = the value of a name defined by an earlier row). names: name ->
-- slot.
local function parse(toks, names)
    local pos, depth = 1, 0
    local function peek() return toks[pos] and toks[pos].k end
    local function take() pos = pos + 1; return toks[pos - 1] end
    local cmp
    local function atom()
        local tk = take()
        if not tk then error({ "公式不完整" }, 0) end
        if tk.k == "num" then
            local v = tk.v
            return function() return v end
        elseif tk.k == "(" then
            depth = depth + 1
            if depth > 32 then error({ "括号嵌套太深" }, 0) end
            local e = cmp()
            if peek() ~= ")" then error({ "缺少右括号" }, 0) end
            take(); depth = depth - 1
            return e
        elseif tk.k == "id" then
            local name = tk.v
            if name == "clip" and peek() == "(" then
                take()
                local arg = take()
                if not (arg and arg.k == "id") or peek() ~= ")" then
                    error({ "clip 的参数是一个形态键配置组合的名称（英文字母、数字、下划线），例如 clip(aim)" }, 0)
                end
                take()
                local id = arg.v
                return function() return D.clip_progress(id) end
            end
            if name == "cond" and peek() == "(" then
                take()
                local arg = take()
                if not (arg and arg.k == "id") or peek() ~= ")" then
                    error({ "cond 的参数是一个条件的 id（英文字母、数字、下划线），例如 cond(oni_mode)" }, 0)
                end
                take()
                local id = arg.v
                if not D.cond_known(id) then error({ "没有 id 为 %s 的条件", id }, 0) end
                cond_seen = true
                return function() return D.cond_value(id) end
            end
            if name == "ramp" and peek() == "(" then
                -- ramp(target, in, out): follows target (clamped to 0..1) at 1 / in per second
                -- upward and 1 / out downward, so a switch becomes a fade of its own length. Each
                -- ramp in a formula keeps its own value; it restarts at 0 when the group recompiles.
                take()
                depth = depth + 1
                if depth > 32 then error({ "括号嵌套太深" }, 0) end
                local args = { cmp() }
                while peek() == "," do take(); args[#args + 1] = cmp() end
                if peek() ~= ")" then error({ "缺少右括号" }, 0) end
                take(); depth = depth - 1
                if #args ~= 3 then error({ "%s 需要 %s 个参数", name, 3 }, 0) end
                local target, t_in, t_out = args[1], args[2], args[3]
                local v = 0
                return function(e)
                    local x = target(e)
                    x = x < 0 and 0 or (x > 1 and 1 or x)
                    local dt = e.dt or 0
                    if x > v then
                        local d = t_in(e)
                        v = d > 0 and math.min(x, v + dt / d) or x
                    elseif x < v then
                        local d = t_out(e)
                        v = d > 0 and math.max(x, v - dt / d) or x
                    end
                    return v
                end
            end
            if peek() == "(" then
                local f = FUNCS[name]
                if not f then error({ "未知函数 %s", name }, 0) end
                take()
                depth = depth + 1
                if depth > 32 then error({ "括号嵌套太深" }, 0) end
                local args = {}
                if peek() ~= ")" then
                    args[1] = cmp()
                    while peek() == "," do take(); args[#args + 1] = cmp() end
                end
                if peek() ~= ")" then error({ "缺少右括号" }, 0) end
                take(); depth = depth - 1
                if #args ~= f[1] then error({ "%s 需要 %s 个参数", name, f[1] }, 0) end
                local fn, a, b, c = f[2], args[1], args[2], args[3]
                if f[1] == 1 then return function(e) return fn(a(e)) end end
                if f[1] == 2 then return function(e) return fn(a(e), b(e)) end end
                return function(e) return fn(a(e), b(e), c(e)) end
            end
            if name == "t" then return function(e) return e.t end end
            local v = CONSTS[name]
            if v then return function() return v end end
            local slot = names and names[name]
            if slot then return function(e) return e[slot] end end
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
            return function(e)
                local x, y = a(e), b(e)
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
            return function(e) return -a(e) end
        end
        if peek() == "+" then take(); return unary() end
        return pow()
    end
    local function mul()
        local a = unary()
        while peek() == "*" or peek() == "/" or peek() == "%" do
            local op = take().k
            local l, r = a, unary()
            if op == "*" then a = function(e) return l(e) * r(e) end
            elseif op == "/" then a = function(e) local d = r(e); return d ~= 0 and l(e) / d or 0 end
            else a = function(e) local d = r(e); return d ~= 0 and l(e) % d or 0 end end
        end
        return a
    end
    local function add()
        local a = mul()
        while peek() == "+" or peek() == "-" do
            local op = take().k
            local l, r = a, mul()
            if op == "+" then a = function(e) return l(e) + r(e) end
            else a = function(e) return l(e) - r(e) end end
        end
        return a
    end
    -- comparisons give 1 or 0 and do not chain: `a < b < c` is an error, not (a < b) < c
    cmp = function()
        local a = add()
        if peek() == "cmp" then
            local fn = CMP_FN[take().v]
            local l, r = a, add()
            if peek() == "cmp" then error({ "比较不能连写，请加括号" }, 0) end
            return function(e) return fn(l(e), r(e)) end
        end
        return a
    end
    local e = cmp()
    if pos <= #toks then error({ "多余的内容：%s", toks[pos].v or toks[pos].k }, 0) end
    return e
end

-- Returns a closure of the environment, or nil and an error { template, args... } for I18n.f.
local function compile_env(src, names)
    if type(src) ~= "string" or src:match("^%s*$") then return nil, { "公式为空" } end
    if #src > D.MAX_FORMULA then return nil, { "公式太长（最多 %s 个字符）", D.MAX_FORMULA } end
    local toks, err = tokenize(src)
    if not toks then return nil, err end
    local ok, e = pcall(parse, toks, names)
    if not ok then
        if type(e) == "table" then return nil, e end
        return nil, { "公式有误" }
    end
    return e
end

-- A formula of t alone: a closure t -> number, or nil and an error { template, args... }.
function D.compile(src)
    local fn, err = compile_env(src)
    if not fn then return nil, err end
    local e = {}
    return function(t) e.t = t; return fn(e) end
end

local function num_text(v) return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")) end

-- the formula a row runs: its own for "expr", the waveform written out otherwise
function D.formula_of(it)
    if it.wave == "expr" then return it.expr or "" end
    local x = "t / " .. num_text(it.period)
    if it.phase ~= 0 then x = x .. " + " .. num_text(it.phase) end
    return string.format("lerp(%s, %s, %s(%s))", num_text(it.lo), num_text(it.hi), it.wave, x)
end

-- a name a formula can read: letters, digits and `_`, not starting with a digit, not an input,
-- constant or function
function D.valid_name(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and #s <= D.MAX_NAME
        and not RESERVED[s] and not FUNCS[s]
end

-- ---------------------------------------------------------------- settings
local function sanitize_row(src)
    local it = U.copy(D.ROW_DEFAULTS)
    if type(src) ~= "table" then return it end
    if D.KIND_NAMES[src.kind] then it.kind = src.kind end
    if type(src.key) == "string" then it.key = src.key end
    if type(src.var) == "string" then it.var = src.var:sub(1, D.MAX_NAME) end
    if D.WAVE_NAMES[src.wave] then it.wave = src.wave end
    if type(src.expr) == "string" then it.expr = src.expr:sub(1, D.MAX_FORMULA) end
    for k, lim in pairs(D.LIMITS) do
        local v = tonumber(src[k])
        if v and v == v then it[k] = U.clamp(v, lim[1], lim[2]) + 0.0 end
    end
    return it
end

local function sanitize_group(src)
    local g = U.copy(D.GROUP_DEFAULTS)
    g.rows = {}
    if type(src) ~= "table" then return g end
    if type(src.enabled) == "boolean" then g.enabled = src.enabled end
    if type(src.name) == "string" then g.name = src.name:sub(1, D.MAX_NAME) end
    if type(src.actor) == "string" then g.actor = src.actor end
    for i, r in ipairs(type(src.rows) == "table" and src.rows or {}) do
        if i > D.MAX_ROWS then break end
        g.rows[i] = sanitize_row(r)
    end
    return g
end

-- a schema 1 driver: one output row, the switch and the character move to the group
local function group_of_item(src)
    if type(src) ~= "table" then src = {} end
    local row = sanitize_row(src)
    row.kind = "out"
    local g = sanitize_group({ enabled = src.enabled, actor = src.actor })
    g.rows[1] = row
    return g
end

-- Compiles group g row by row. A variable row defines its name for the rows below it; an output
-- row whose key is a valid name does too, so `jaw = 0.5 * Mouth_open` reads an earlier output.
local function recompile(g)
    local grp = cfg.groups[g]
    local names, nslots = {}, 0
    local cg = { ok = true, rows = {} }
    local vg = { rows = {} }
    cond_seen = false
    for r, row in ipairs(grp.rows) do
        local formula = D.formula_of(row)
        local fn, err = compile_env(formula, names)
        local name
        if row.kind == "var" then
            if not D.valid_name(row.var) then
                err = err or (row.var == "" and { "变量需要名称" }
                    or { "变量名 %s 不可用：只能用英文字母、数字和下划线，不能以数字开头，也不能是函数名或 t、a、pi、tau", row.var })
            elseif names[row.var] then
                err = err or { "名称 %s 已在上面定义", row.var }
            else
                name = row.var
            end
        elseif D.valid_name(row.key) and not names[row.key] then
            name = row.key
        end
        local slot
        if name then nslots = nslots + 1; slot = nslots; names[name] = slot end
        if err then cg.ok = false end
        if name == "live" and row.kind == "var" then cg.live = slot end
        cg.rows[r] = { fn = fn, slot = slot }
        vg.rows[r] = { value = 0, err = err, formula = formula }
    end
    cg.cond = cond_seen
    compiled[g] = cg
    D.view.groups[g] = vg
end

-- true while an enabled group reads cond(): API then samples the conditions even without a
-- condition set
function D.wants_cond()
    if not cfg.enabled then return false end
    for g, grp in ipairs(cfg.groups) do
        local cg = compiled[g]
        if grp.enabled and cg and cg.cond then return true end
    end
    return false
end

local function recompile_all()
    for g in pairs(compiled) do compiled[g] = nil end
    for g in pairs(D.view.groups) do D.view.groups[g] = nil end
    for g = 1, #cfg.groups do recompile(g) end
end

-- the groups of a decoded file, schema 1 or 2
local function groups_of(data)
    local groups = {}
    if type(data) ~= "table" then return groups end
    if type(data.groups) == "table" then
        for i, src in ipairs(data.groups) do
            if i > D.MAX_GROUPS then break end
            groups[i] = sanitize_group(src)
        end
    else
        for i, src in ipairs(type(data.items) == "table" and data.items or {}) do
            if i > D.MAX_GROUPS then break end
            groups[i] = group_of_item(src)
        end
    end
    return groups
end

local function set_groups(groups)
    cfg.groups = groups
    D.view.cfg = cfg
    D.time = 0
    recompile_all()
end

-- data: a decoded drivers file; replaces the groups (and the master switch, when the data has one)
-- of the current set without touching any file (tests)
function D.load(data)
    if type(data) == "table" and type(data.enabled) == "boolean" then cfg.enabled = data.enabled
    else cfg.enabled = true end
    set_groups(groups_of(data))
end

-- ---------------------------------------------------------------- driver sets
-- Each set is one file, user/drivers/<id>.json or mods/drivers/<id>.json (a user file shadows the
-- mods file of the same id; a user file of {"deleted": true} is skipped, so the mods set shows again). The selected set's id and the master
-- switch live in settings.json (API). Edits are saved to the selected set 0.5 s after they settle;
-- a mods set is saved as a user file of the same id, the mods file is never written.
D.list = {}        -- { id, name, source, path }, sorted by name
D.current = nil    -- { id, name, source, path } of the set being edited
D.DEFAULT_ID, D.DEFAULT_NAME = "default", "默认"

local function user_path(id) return U.path("user", "drivers", id .. ".json") end

function D.load_all()
    local list = {}
    for _, src in ipairs({ "user", "mods" }) do
        for _, f in ipairs(U.list_json(src .. "\\drivers")) do
            local d = U.load_json(f.path)
            local taken = false
            for _, e in ipairs(list) do if e.id == f.base then taken = true end end   -- user wins
            if type(d) == "table" and d.deleted ~= true and not taken then
                local name = type(d.name) == "string" and d.name ~= "" and d.name or f.base
                list[#list + 1] = { id = f.base, name = name, source = src, path = f.path }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    D.list = list
    D.view.sets = list
    return list
end

function D.find(name)
    if type(name) ~= "string" or name == "" then return nil end
    for _, e in ipairs(D.list) do if e.id == name then return e end end
    for _, e in ipairs(D.list) do if e.name == name then return e end end
end

local function set_current(cur)
    D.current = cur
    D.view.current = cur and { id = cur.id, name = cur.name, source = cur.source } or nil
end

function D.save()
    st.save_at = nil
    local cur = D.current
    if not cur then return false end
    -- a mods set is written as the user file of the same id
    local path = cur.source == "user" and cur.path or user_path(cur.id)
    if not U.save_json(path, { schema = D.SCHEMA, name = cur.name, groups = cfg.groups }) then return false end
    if cur.source ~= "user" or not D.find(cur.id) then
        cur.source, cur.path = "user", path
        D.load_all()
        set_current(cur)
    end
    return true
end

-- slider drags patch every frame: write the file once they settle
function D.save_soon() st.save_at = clock() + 0.5 end
function D.flush() if st.save_at then D.save() end end

-- Makes the set id (or name) the one in effect; the previous set's pending edits are written first.
-- Its keys go back on the next tick unless the new set drives them too.
function D.select(name)
    local e = D.find(name)
    if not e then return false end
    D.flush()
    set_current({ id = e.id, name = e.name, source = e.source, path = e.path })
    set_groups(groups_of(U.load_json(e.path)))
    return true
end

local function check_name(name)
    if type(name) ~= "string" then return nil, "E_BAD_ARGS", "name must be a string" end
    name = name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, D.MAX_NAME)
    local id = U.file_id(name)
    if id == "" then return nil, "E_BAD_ARGS", "empty name" end
    if D.find(id) or D.find(name) then return nil, "E_EXISTS", "a driver set with this name exists" end
    return name, id
end

-- a new set: empty, or (copy) holding the current groups. Written at once and selected.
local function create(name, copy)
    local id, err
    name, id, err = check_name(name)
    if not name then return false, id, err end
    D.flush()
    local groups = copy and U.copy(cfg.groups) or {}
    set_current({ id = id, name = name, source = "user", path = user_path(id) })
    set_groups(groups)
    if not D.save() then return false, "E_IO", "write failed" end
    return true
end

-- the user file of set id was tombstoned (API confirm_delete). When it was the selected one, the
-- mods set of the same id takes its place, else the first remaining set, else none.
function D.deleted(id)
    D.load_all()
    if D.current and D.current.id == id then
        st.save_at = nil
        set_current(nil)
        if not (D.select(id) or D.list[1] and D.select(D.list[1].id)) then set_groups({}) end
    end
end

-- Once at load. want = settings.drivers. A user/drivers.json from before driver sets becomes
-- user/drivers/default.json (once: a tombstone of it counts). Returns the selected id ("" = none)
-- and false when the old file had the master switch off.
function D.start(want)
    local enabled
    if U.load_json(user_path(D.DEFAULT_ID)) == nil then
        local old = U.load_json(CFG_PATH)
        local groups = groups_of(old)
        if #groups > 0 and U.save_json(user_path(D.DEFAULT_ID), { schema = D.SCHEMA, name = D.DEFAULT_NAME, groups = groups }) then
            if old.enabled == false then enabled = false end
            if want == nil or want == "" then want = D.DEFAULT_ID end
        end
    end
    D.load_all()
    set_current(nil)
    set_groups({})
    if not D.select(want) and D.list[1] then D.select(D.list[1].id) end
    return D.current and D.current.id or "", enabled
end

-- a variable name not used in group grp yet: x1, x2, ...
local function free_var(grp)
    local used = {}
    for _, row in ipairs(grp.rows) do used[row.var] = true; used[row.key] = true end
    local i = 1
    while used["x" .. i] do i = i + 1 end
    return "x" .. i
end

local function new_row(grp, a)
    local row = U.copy(D.ROW_DEFAULTS)
    if a.kind == "var" then
        row.kind = "var"
        row.var = type(a.var) == "string" and a.var:sub(1, D.MAX_NAME) or free_var(grp)
    end
    if type(a.key) == "string" then row.key = a.key end
    return row
end

-- checks every field before changing any: a rejected patch leaves the row as it was
local function patch_row(row, p)
    if p.wave ~= nil and not D.WAVE_NAMES[p.wave] then return false, "E_BAD_ARGS", "unknown wave" end
    if p.kind ~= nil and not D.KIND_NAMES[p.kind] then return false, "E_BAD_ARGS", "unknown kind" end
    for _, k in ipairs({ "key", "var", "expr" }) do
        if p[k] ~= nil and type(p[k]) ~= "string" then return false, "E_BAD_ARGS", k .. " must be a string" end
    end
    for k, lim in pairs(D.LIMITS) do
        if p[k] ~= nil then
            local v = tonumber(p[k])
            if not v or v ~= v then return false, "E_BAD_ARGS", k .. ": number expected" end
        end
    end
    for k, v in pairs(p) do
        local lim = D.LIMITS[k]
        if lim then
            row[k] = U.clamp(tonumber(v), lim[1], lim[2]) + 0.0
        elseif k == "expr" then
            row.expr = v:sub(1, D.MAX_FORMULA)
        elseif k == "var" then
            row.var = v:sub(1, D.MAX_NAME)
        elseif k == "kind" or k == "key" or k == "wave" then
            row[k] = v
        end
    end
    -- a row turned into a variable needs a name to be read by
    if row.kind == "var" and row.var == "" then row.var = "x" end
    return true
end

local ROW_FIELDS = { kind = true, key = true, var = true, wave = true, expr = true, period = true, lo = true,
    hi = true, phase = true }

-- a = { op = "add", key?, actor? } (a new group with one output row)
--   | { op = "remove", index } | { op = "patch", patch } (master switch: { enabled })
--   | { op = "patch", index, patch } (group: enabled, name; row fields go to row 1)
--   | { op = "patch", index, row, patch } | { op = "add_row", index, kind?, key?, var? }
--   | { op = "remove_row", index, row } | { op = "move_row", index, row, to }
--   | { op = "select", name } | { op = "new", name } | { op = "save_as", name } (driver sets)
-- Returns ok, err, msg like the API commands.
function D.command(a)
    if type(a) ~= "table" then return false, "E_BAD_ARGS", "args must be a table" end
    if a.op == "select" then
        if not D.select(a.name) then return false, "E_NOT_FOUND", "driver set not found: " .. tostring(a.name) end
        return true
    elseif a.op == "new" or a.op == "save_as" then
        return create(a.name, a.op == "save_as")
    end
    local groups = cfg.groups
    local function group_of()
        local g = tonumber(a.index)
        return g, g and groups[g]
    end
    if a.op == "add" then
        if #groups >= D.MAX_GROUPS then return false, "E_BAD_ARGS", "too many drivers" end
        local grp = U.copy(D.GROUP_DEFAULTS)
        if type(a.actor) == "string" then grp.actor = a.actor end
        grp.rows = { new_row(grp, { key = a.key }) }
        groups[#groups + 1] = grp
        recompile(#groups)
    elseif a.op == "remove" then
        local g, grp = group_of()
        if not grp then return false, "E_NOT_FOUND", "no such driver" end
        table.remove(groups, g)
        recompile_all()
    elseif a.op == "patch" then
        local p = a.patch
        if type(p) ~= "table" then return false, "E_BAD_ARGS", "patch must be a table" end
        if a.index == nil then
            if type(p.enabled) ~= "boolean" then return false, "E_BAD_ARGS", "enabled must be boolean" end
            cfg.enabled = p.enabled
        else
            local g, grp = group_of()
            if not grp then return false, "E_NOT_FOUND", "no such driver" end
            local r = tonumber(a.row)
            if r == nil then
                if p.enabled ~= nil and type(p.enabled) ~= "boolean" then return false, "E_BAD_ARGS", "enabled must be boolean" end
                if p.name ~= nil and type(p.name) ~= "string" then return false, "E_BAD_ARGS", "name must be a string" end
                local rp = {}
                for k, v in pairs(p) do if ROW_FIELDS[k] then rp[k] = v end end
                if next(rp) then
                    if not grp.rows[1] then return false, "E_NOT_FOUND", "no such row" end
                    local ok, err, msg = patch_row(grp.rows[1], rp)
                    if not ok then return ok, err, msg end
                end
                if p.enabled ~= nil then grp.enabled = p.enabled end
                if p.name ~= nil then grp.name = p.name:sub(1, D.MAX_NAME) end
            else
                local row = grp.rows[r]
                if not row then return false, "E_NOT_FOUND", "no such row" end
                local ok, err, msg = patch_row(row, p)
                if not ok then return ok, err, msg end
            end
            recompile(g)
        end
    elseif a.op == "add_row" then
        local g, grp = group_of()
        if not grp then return false, "E_NOT_FOUND", "no such driver" end
        if #grp.rows >= D.MAX_ROWS then return false, "E_BAD_ARGS", "too many rows" end
        if a.kind ~= nil and not D.KIND_NAMES[a.kind] then return false, "E_BAD_ARGS", "unknown kind" end
        grp.rows[#grp.rows + 1] = new_row(grp, a)
        recompile(g)
    elseif a.op == "remove_row" or a.op == "move_row" then
        local g, grp = group_of()
        if not grp then return false, "E_NOT_FOUND", "no such driver" end
        local r = tonumber(a.row)
        if not (r and grp.rows[r]) then return false, "E_NOT_FOUND", "no such row" end
        if a.op == "remove_row" then
            table.remove(grp.rows, r)
        else
            local to = tonumber(a.to)
            if not (to and grp.rows[to]) then return false, "E_BAD_ARGS", "to: row index expected" end
            table.insert(grp.rows, to, table.remove(grp.rows, r))
        end
        recompile(g)
    else
        return false, "E_BAD_ARGS", "op: add / remove / patch / add_row / remove_row / move_row / select / new / save_as"
    end
    -- the master switch lives in settings.json (API); the first edit without any set creates 默认
    if not (a.op == "patch" and a.index == nil) then
        if not D.current then
            set_current({ id = D.DEFAULT_ID, name = D.DEFAULT_NAME, source = "user", path = user_path(D.DEFAULT_ID) })
        end
        D.save_soon()
    end
    return true
end

-- ---------------------------------------------------------------- per tick
local function release_all()
    if next(st.held) == nil then return false end
    for k in pairs(st.held) do st.held[k] = nil end
    return Ext.release_all(D.OWNER) > 0
end

local function finite(x)
    if x ~= x or x == math.huge or x == -math.huge then return 0 end
    return x
end

-- Once per API tick. hi = the largest value a key takes (Sculpt.RANGE[2]); writable(name) is the
-- adapter's channel check or nil. Returns true when any held value changed.
local now_held, env = {}, {}
function D.tick(dt, hi, writable)
    if st.save_at and clock() >= st.save_at then D.save() end
    local groups = cfg.groups
    for k in pairs(D.actor_values) do D.actor_values[k] = nil end
    if not cfg.enabled or #groups == 0 then
        for _, vg in pairs(D.view.groups) do
            for _, v in pairs(vg.rows) do v.value, v.owner, v.dup = 0, nil, nil end
        end
        return release_all()
    end
    D.time = D.time + dt
    D.view.time = D.time
    for k in pairs(now_held) do now_held[k] = nil end
    local first = {}   -- actor id -> norm key -> { group, row } of the first row naming it
    for g, grp in ipairs(groups) do
        local actor = D.actor_of(grp)
        local cg, vg = compiled[g], D.view.groups[g]
        local run = grp.enabled and cg and cg.ok
        for k in pairs(env) do env[k] = nil end
        env.t, env.dt = D.time, dt
        for r, row in ipairs(grp.rows) do
            local v, c = vg.rows[r], cg.rows[r]
            v.owner, v.dup = nil, nil
            local x = run and finite(c.fn(env)) or 0
            if c.slot then env[c.slot] = x end
            if row.kind == "var" then
                v.value = x
            elseif not run or row.key == "" or (cg.live and env[cg.live] == 0) then
                -- a variable `live` above the outputs at 0 lets their keys go: sculpt and key groups
                -- show through until it turns non-zero
                v.value = 0
            elseif writable and not writable(row.key) then
                v.value, v.owner = 0, "?"
            else
                local key = row.key
                local n = Ext.norm(key)
                x = U.clamp(x, 0, hi)
                v.value = x
                local seen = first[actor] or {}
                first[actor] = seen
                local _, owner = Ext.get(key)
                if seen[n] then
                    v.dup = seen[n]
                elseif actor ~= D.current_actor then
                    seen[n] = { g, r }
                    local values = D.actor_values[actor] or {}
                    D.actor_values[actor] = values
                    values[n] = { name = key, value = x + 0.0 }
                elseif owner and owner ~= D.OWNER then
                    v.owner = owner
                else
                    seen[n] = { g, r }
                    Ext.set(D.OWNER, key, x + 0.0, Ext.DEFAULT_TTL)
                    now_held[n] = key
                end
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

-- the character a group belongs to; "" (older files, games with one character) is the player's
function D.actor_of(grp)
    return (grp.actor ~= nil and grp.actor ~= "") and grp.actor or D.default_actor
end

function D.config() return cfg end

return D
