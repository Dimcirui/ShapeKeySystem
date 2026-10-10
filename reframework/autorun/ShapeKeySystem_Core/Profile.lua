-- ShapeKeySystem: expression profiles (sks.profile/1) and the signal dictionary.
-- Loads profiles from builtin/, mods/ and user/, resolves "extends", validates node trees
-- and compiles them into per-channel evaluation closures.
--
-- Node forms (any node may also carry "k" = multiplier and "curve" = {deadzone, gamma, gain}):
--   { "s": "smile.L" }        signal from the dictionary, normalised 0..1
--   { "p": 33 }               raw fcParam number, normalised 0..1
--   { "ref": "jawOpen" }      another channel's value (before gains)
--   { "const": 0.5 }
--   { "eye": "L", "axis": "pitch", "sign": 1 }   eye angle / full_deg, clamped 0..1
--   { "sum": [...] } { "mul": [...] } { "max": [...] } { "min": [...] } { "sub": [a, b] }
-- A channel entry is itself a node plus name / group / gaze_set / extension / note, and
-- optionally any (more mesh names, best first) / unless (channels that disable it), see
-- Names.build_index. A channel with no node keys has no game signal (manual / sculpt only).

local U = require("ShapeKeySystem_Core.Util")

local P = {}

local SOURCES = { "builtin", "mods", "user" }    -- later sources override earlier ones
local NODE_KEYS = { "s", "p", "ref", "const", "eye", "sum", "mul", "max", "min", "sub" }
local NODE_MODS = { "k", "curve", "full_deg", "axis", "sign" }
local OPS = { sum = true, mul = true, max = true, min = true, sub = true }

P.signals = { list = {}, by_name = {}, full = 0.01 }
P.registry = {}   -- id -> { id, name, source, path, data }
P.list = {}       -- sorted list of registry entries (for the UI)

function P.load_signals()
    local data = U.load_json(U.path("builtin", "signals.json")) or {}
    local s = { list = {}, by_name = {}, full = tonumber(data.full) or 0.01 }
    for i, e in ipairs(data.signals or {}) do
        if type(e.name) == "string" and tonumber(e.param) then
            local sig = { slot = i, name = e.name, param = math.floor(tonumber(e.param)),
                          guessed = e.guessed == true, note = e.note or "" }
            s.list[#s.list + 1] = sig
            s.by_name[e.name] = sig
        end
    end
    P.signals = s
    return s
end

function P.load_all()
    local reg = {}
    for _, src in ipairs(SOURCES) do
        for _, f in ipairs(U.list_json(src .. "\\profiles")) do
            local data = U.load_json(f.path)
            if data and data.schema == "sks.profile/1" and type(data.channels) == "table" then
                local id = type(data.id) == "string" and data.id or f.base
                reg[id] = { id = id, name = data.name or id, source = src, path = f.path,
                            extends = data.extends, data = data }
            end
        end
    end
    P.registry = reg
    local list = {}
    for _, e in pairs(reg) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.name < b.name end)
    P.list = list
    return reg
end

-- Resolve "extends" into one flat definition: { id, name, source, aliases, channels = {entry...} }.
-- Child entries replace parent entries of the same name in place; new ones are appended.
function P.resolve(id, seen)
    seen = seen or {}
    local e = P.registry[id]
    if not e then return nil, "E_NOT_FOUND", "profile not found: " .. tostring(id) end
    if seen[id] then return nil, "E_SCHEMA", "extends cycle at " .. id end
    seen[id] = true
    local channels, pos, aliases = {}, {}, {}
    if type(e.extends) == "string" then
        local parent, code, msg = P.resolve(e.extends, seen)
        if not parent then return nil, code, msg end
        for _, ch in ipairs(parent.channels) do
            channels[#channels + 1] = ch; pos[ch.name] = #channels
        end
        for _, a in ipairs(parent.aliases) do aliases[#aliases + 1] = a end
    end
    for _, ch in ipairs(e.data.channels) do
        if type(ch) == "table" and type(ch.name) == "string" then
            if pos[ch.name] then channels[pos[ch.name]] = ch
            else channels[#channels + 1] = ch; pos[ch.name] = #channels end
        end
    end
    for _, a in ipairs(e.data.aliases or {}) do aliases[#aliases + 1] = a end
    return { id = e.id, name = e.name, source = e.source, extends = e.extends,
             aliases = aliases, channels = channels }
end

local function has_node(t)
    for _, k in ipairs(NODE_KEYS) do if t[k] ~= nil then return true end end
    return false
end
P.has_node = has_node

-- The node part of a channel entry (strips name/group/... metadata).
function P.node_of(entry)
    local n = {}
    for _, k in ipairs(NODE_KEYS) do n[k] = entry[k] end
    for _, k in ipairs(NODE_MODS) do n[k] = entry[k] end
    return n
end

local function fmt_k(k) return (k == 1) and "" or string.format("×%g", k) end

-- Compile one node into (fn(ctx) -> number, text, flags). Raises error(msg) on invalid input.
-- ctx = { P = normalised params[param], A = {L={yaw,pitch}, R=...}, V = channel values[slot],
--         fy = full yaw deg, fp = full pitch deg }
local function compile_node(node, env, depth)
    if type(node) ~= "table" then error("node must be an object") end
    if depth > 16 then error("node tree too deep") end
    local fn, text
    if node.s ~= nil then
        local sig = env.signals.by_name[node.s]
        if not sig then error("unknown signal: " .. tostring(node.s)) end
        local p = sig.param
        env.params[p] = true
        if sig.guessed then env.guessed = true end
        fn = function(ctx) return ctx.P[p] or 0 end
        text = sig.name
    elseif node.p ~= nil then
        local p = tonumber(node.p)
        if not p or p < 0 or p > 200 then error("fcParam out of range: " .. tostring(node.p)) end
        p = math.floor(p)
        env.params[p] = true
        fn = function(ctx) return ctx.P[p] or 0 end
        text = string.format("fc%03d", p)
    elseif node.ref ~= nil then
        local slot = env.slot_of[node.ref]
        if not slot then error("ref to unknown channel: " .. tostring(node.ref)) end
        env.deps[#env.deps + 1] = slot
        fn = function(ctx) return ctx.V[slot] or 0 end
        text = "@" .. node.ref
    elseif node.const ~= nil then
        local c = tonumber(node.const)
        if not c then error("const must be a number") end
        fn = function() return c end
        text = string.format("%g", c)
    elseif node.eye ~= nil then
        local side = node.eye
        if side ~= "L" and side ~= "R" then error("eye must be L or R") end
        local yaw = node.axis == "yaw"
        if not yaw and node.axis ~= "pitch" then error("axis must be yaw or pitch") end
        local sign = (tonumber(node.sign) or 1) < 0 and -1 or 1
        local own_full = tonumber(node.full_deg)
        env.eye = true
        fn = function(ctx)
            local a = ctx.A[side]
            local w = yaw and (a[1] / (own_full or ctx.fy)) or (a[2] / (own_full or ctx.fp))
            w = w * sign
            return (w < 0) and 0 or ((w > 1) and 1 or w)
        end
        text = string.format("eye.%s %s%s", side, node.axis, sign > 0 and "+" or "-")
    else
        local op
        for k in pairs(OPS) do if node[k] ~= nil then op = k end end
        if not op then error("node has no type") end
        local list = node[op]
        if type(list) ~= "table" or #list == 0 then error(op .. " needs a non-empty list") end
        if op == "sub" and #list ~= 2 then error("sub needs exactly two items") end
        local fns, texts = {}, {}
        for i, sub in ipairs(list) do fns[i], texts[i] = compile_node(sub, env, depth + 1) end
        local n = #fns
        if op == "sum" then
            if n == 1 then fn = fns[1] else
                fn = function(ctx) local s = 0; for i = 1, n do s = s + fns[i](ctx) end; return s end
            end
            text = table.concat(texts, " + ")
        elseif op == "mul" then
            fn = function(ctx) local s = 1; for i = 1, n do s = s * fns[i](ctx) end; return s end
            text = "(" .. table.concat(texts, ") × (") .. ")"
        elseif op == "max" then
            fn = function(ctx) local s = fns[1](ctx); for i = 2, n do local v = fns[i](ctx); if v > s then s = v end end; return s end
            text = "max(" .. table.concat(texts, ", ") .. ")"
        elseif op == "min" then
            fn = function(ctx) local s = fns[1](ctx); for i = 2, n do local v = fns[i](ctx); if v < s then s = v end end; return s end
            text = "min(" .. table.concat(texts, ", ") .. ")"
        else
            local a, b = fns[1], fns[2]
            fn = function(ctx) return a(ctx) - b(ctx) end
            text = texts[1] .. " − " .. texts[2]
        end
    end

    local k = tonumber(node.k)
    if k and k ~= 1 then
        local inner = fn
        fn = function(ctx) return inner(ctx) * k end
        text = (text:find("[ ,]") and ("(" .. text .. ")") or text) .. fmt_k(k)
    end
    local c = node.curve
    if type(c) == "table" then
        local dz = U.clamp(tonumber(c.deadzone) or 0, 0, 0.95)
        local gamma = tonumber(c.gamma) or 1
        local gain = tonumber(c.gain) or 1
        if gamma <= 0 then error("curve gamma must be > 0") end
        local inner = fn
        fn = function(ctx)
            local v = inner(ctx)
            if dz > 0 then v = (v - dz) / (1 - dz) end
            if v <= 0 then return 0 end
            if gamma ~= 1 then v = v ^ gamma end
            return v * gain
        end
        text = "curve(" .. text .. ")"
    end
    return fn, text
end

-- Compile a resolved profile. edits: channel name -> replacement node (mapping editor).
-- Returns prog or nil, err_code, message.
--   prog.channels[slot] = { slot, name, group, gaze_set, extension, note, has_signal, guessed,
--                           source_text, fn, node, params (own fcParams), deps (ref slots), is_eye }
--   prog.order = slot evaluation order (refs first), prog.params = sorted fcParam list,
--   prog.has_eye, prog.n, prog.slot_of, prog.names
function P.compile(resolved, edits)
    edits = edits or {}
    local prog = { id = resolved.id, name = resolved.name, source = resolved.source,
                   extends = resolved.extends, aliases = resolved.aliases,
                   channels = {}, order = {}, params = {}, has_eye = false,
                   n = 0, slot_of = {}, names = {} }
    for i, ch in ipairs(resolved.channels) do
        prog.n = i; prog.slot_of[ch.name] = i; prog.names[i] = ch.name
    end
    local need = {}
    local deps_of = {}
    for i, entry in ipairs(resolved.channels) do
        local node = edits[entry.name] or P.node_of(entry)
        local c = { slot = i, name = entry.name, group = entry.group or "extra",
                    gaze_set = entry.gaze_set, extension = entry.extension == true,
                    note = entry.note, has_signal = false, guessed = entry.guessed == true,
                    source_text = "—", fn = nil, node = node, edited = edits[entry.name] ~= nil }
        if has_node(node) then
            local env = { signals = P.signals, slot_of = prog.slot_of, params = {}, deps = {},
                          guessed = false, eye = false }
            local ok, fn, text = pcall(compile_node, node, env, 0)
            if not ok then
                return nil, "E_NODE_INVALID", entry.name .. ": " .. tostring(fn):gsub("^.-:%d+: ", "")
            end
            c.fn, c.source_text, c.has_signal = fn, text, true
            c.guessed = c.guessed or env.guessed
            if env.eye then prog.has_eye = true; c.is_eye = true end
            deps_of[i] = env.deps
            c.deps = env.deps
            c.params = {}
            for p in pairs(env.params) do need[p] = true; c.params[#c.params + 1] = p end
        end
        prog.channels[i] = c
    end
    -- topological order so refs are evaluated before their users
    local mark = {}
    local function visit(s, path)
        if mark[s] == 2 then return true end
        if mark[s] == 1 then return false, path .. " → " .. prog.names[s] end
        mark[s] = 1
        for _, d in ipairs(deps_of[s] or {}) do
            local ok, cyc = visit(d, path .. " → " .. prog.names[s])
            if not ok then return false, cyc end
        end
        mark[s] = 2
        if prog.channels[s].fn then prog.order[#prog.order + 1] = s end
        return true
    end
    for s = 1, prog.n do
        local ok, cyc = visit(s, "")
        if not ok then return nil, "E_NODE_INVALID", "ref cycle:" .. cyc end
    end
    for p in pairs(need) do prog.params[#prog.params + 1] = p end
    table.sort(prog.params)
    return prog
end

-- fcParams (sorted list) and eye use needed to evaluate the given slots, following refs.
function P.needs(prog, slots)
    local params, seen, eyes = {}, {}, false
    local visited = {}
    local function visit(s)
        if visited[s] then return end
        visited[s] = true
        local c = prog.channels[s]
        if not c or not c.fn then return end
        if c.is_eye then eyes = true end
        for _, p in ipairs(c.params) do
            if not seen[p] then seen[p] = true; params[#params + 1] = p end
        end
        for _, d in ipairs(c.deps) do visit(d) end
    end
    for s in pairs(slots) do visit(s) end
    table.sort(params)
    return params, eyes
end

-- Profile JSON for saving: the resolved channels with edits applied, no "extends".
function P.to_json(resolved, edits, id, name)
    local channels = {}
    for _, entry in ipairs(resolved.channels) do
        local out = {}
        for k, v in pairs(entry) do out[k] = U.copy(v) end
        local e = edits and edits[entry.name]
        if e then
            for _, k in ipairs(NODE_KEYS) do out[k] = nil end
            for _, k in ipairs(NODE_MODS) do out[k] = nil end
            for k, v in pairs(e) do out[k] = U.copy(v) end
        end
        channels[#channels + 1] = out
    end
    return { schema = "sks.profile/1", id = id, name = name, based_on = resolved.id,
             aliases = U.copy(resolved.aliases), channels = channels }
end

-- Lookup index (norm name / alias -> true) per registered profile, for coverage ranking.
function P.match_count(id, mesh_names, Names)
    local r = P.resolve(id)
    if not r then return 0 end
    local names = {}
    for i, ch in ipairs(r.channels) do names[i] = ch.name end
    local idx = Names.build_index(names, r.aliases, r.channels)
    local hit = {}
    local n = 0
    for _, s in ipairs(Names.match_part(idx, mesh_names)) do
        if s and not hit[s] then hit[s] = true; n = n + 1 end
    end
    return n
end

return P
