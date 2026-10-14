-- 验证可选 JSON 缺失、损坏文件诊断及绑定读取复用；文件操作仅使用测试数据目录。
local U = require("ShapeKeySystem_Core.Util")
local P = require("ShapeKeySystem_Core.Presets")
local failures = 0
local function check(ok, label)
    print((ok and "ok   " or "FAIL ") .. "[json] " .. label)
    if not ok then failures = failures + 1 end
end
local original_load, original_glob, original_open = json.load_file, fs.glob, io.open
local original_exists, original_adapter = U.file_exists, P.adapter
local loads, diagnostics, globs = {}, {}, 0
json.load_file = function(path)
    loads[path] = (loads[path] or 0) + 1
    -- 模拟 REF 先记录诊断再返回 nil，调用方的 pcall 无法取消已记录的错误。
    local ok, data = pcall(original_load, path)
    if not ok or data == nil then diagnostics[#diagnostics + 1] = path; return nil end
    return data
end
fs.glob = function(...)
    globs = globs + 1
    return original_glob(...)
end
local missing = U.path("user", "json-tests", "missing.json")
local absent = true
for _ = 1, 20 do absent = absent and U.load_json(missing) == nil end
check(absent, "repeated missing optional reads return nil")
check(U.load_json(nil) == nil and U.load_json(42) == nil, "invalid paths remain unreadable rather than throwing")
check(loads[missing] == nil and #diagnostics == 0 and globs == 0,
    "missing files never enter JSON parsing or trigger recursive directory scans")

local fresh = U.path("user", "json-tests", "fresh.json")
check(U.load_json(fresh) == nil, "missing path is initially absent")
U.save_json(fresh, { marker = 1 })
check(U.load_json(fresh).marker == 1, "creating a previously absent file is visible immediately")
U.save_json(fresh, { marker = 2 })
check(U.load_json(fresh).marker == 2, "rewritten JSON is visible without clearing a global cache")
local malformed = U.path("user", "json-tests", "malformed.json")
local file = assert(io.open(malformed, "wb")); file:write("{"); file:close()
local empty = U.path("user", "json-tests", "empty.json")
file = assert(io.open(empty, "wb")); file:close()
local before = #diagnostics
check(U.load_json(malformed) == nil and loads[malformed] == 1 and #diagnostics == before + 1,
    "existing malformed files still reach the parser and produce diagnostics")
check(U.load_json(empty) == nil and loads[empty] == 1 and #diagnostics == before + 2,
    "an existing empty file remains a format error rather than a missing file")
U.save_json(malformed, { repaired = true })
check(U.load_json(malformed).repaired, "repairing malformed JSON takes effect immediately")

local unicode = U.path("user", "json-tests", "中文预设.json")
U.save_json(unicode, { marker = 4 })
check(U.load_json(unicode).marker == 4, "Unicode preset names use enumeration and remain readable")

local exact = U.path("user", "json-tests", "A+B[1](v).json")
U.save_json(exact, { marker = 3 })
io.open = nil
check(U.load_json(exact).marker == 3, "older REF fallback escapes regex metacharacters in real paths")
check(U.load_json(U.path("user", "json-tests", "freshXjson")) == nil,
    "fallback matches an exact path rather than treating dots as wildcards")
local slash = exact:gsub("\\", "/")
check(U.load_json(slash).marker == 3, "fallback accepts both path separator forms")
io.open = original_open

local closed = 0
io.open = function()
    return { close = function() closed = closed + 1 end }
end
check(U.file_exists(fresh) and closed == 1, "existence checks release their file handle")
io.open = original_open

P.adapter = {
    model_of = function() return "json-tests" end,
    representative_of = function() return "representative" end,
}
local user_rep = U.path("user", "json-tests", "representative.json")
local mod_rep = U.path("mods", "json-tests", "representative.json")
local mod_own = U.path("mods", "json-tests", "own.json")
U.save_json(user_rep, { profile = "first" })
U.save_json(mod_own, { profile = "own" })
local checks = {}
U.file_exists = function(path)
    checks[path] = (checks[path] or 0) + 1
    return original_exists(path)
end
loads = {}
local r = P.resolve_binding("own")
check(r.base == "own" and r.source == "mods" and r.level == "own" and r.data.profile == "own",
    "own-part bindings retain precedence over a non-global representative")
check(loads[user_rep] == 1 and checks[mod_rep] == 1,
    "global and model steps reuse both loaded and missing representative results")
checks, loads = {}, {}
r = P.resolve_binding("representative")
check(loads[user_rep] == 1 and checks[mod_rep] == 1 and r.level == "own",
    "representative global and own steps read each path once")
U.save_json(user_rep, { global = true, profile = "second" })
r = P.resolve_binding("own")
check(r.base == "representative" and r.level == "global" and r.data.profile == "second",
    "a subsequent resolution sees rewritten configuration and preserves global priority")
U.save_json(user_rep, { deleted = true })
U.save_json(mod_rep, { profile = "new-mod" })
r = P.resolve_binding("representative")
check(r.source == "mods" and r.data.profile == "new-mod",
    "tombstones still fall through and newly created mod files are discovered")
before = #diagnostics
check(U.load_json(missing) == nil and #diagnostics == before,
    "binding resolution and later missing probes add no spurious JSON diagnostics")

U.file_exists, P.adapter = original_exists, original_adapter
json.load_file, fs.glob, io.open = original_load, original_glob, original_open
print("JSON FAILS:", failures)
assert(failures == 0, "optional JSON regression")
