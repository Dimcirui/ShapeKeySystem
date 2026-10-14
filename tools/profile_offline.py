"""使用独立 Lua 运行时测量算法开销和调用次数，不连接游戏或修改玩家数据。"""
import argparse
import ast
import json
import platform
from pathlib import Path
import shutil
import tempfile

import lupa.lua54 as lupa

REPO = Path(__file__).resolve().parents[1]


def runtime(data):
    """复用测试文件层，所有 JSON 写入均落在调用方拥有的临时目录。"""
    source = REPO / "tests" / "run.py"
    node = next(n for n in ast.parse(source.read_text(encoding="utf-8")).body
                if isinstance(n, ast.FunctionDef) and n.name == "boot")
    scope = {"os": __import__("os"), "re": __import__("re"), "json": json, "lupa": lupa,
             "GAME": str(REPO / "reframework")}
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), scope)
    lua, _, convert = scope["boot"](str(data))
    lua.execute((REPO / "tests" / "mock_sks.lua").read_text(encoding="utf-8"))
    lua.execute('package.loaded["ShapeKeySystem_Core.Trail"] = '
                '{ open = function() end, event = function() end, close = function() end }')
    lua.execute("dofile(ENTRY)")
    return lua, convert


def plain(value):
    """将 Lua 测量结果复制为 JSON 数据，避免保留运行时引用。"""
    if lupa.lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and set(keys) == set(range(1, len(keys) + 1)):
        return [plain(value[i]) for i in range(1, len(keys) + 1)]
    return {str(k): plain(value[k]) for k in keys}


BENCHMARK = r'''
local SKS = require("ShapeKeySystem_Core.API")
local Panel = require("ShapeKeySystem_UI.Panel")
local D = require("ShapeKeySystem_UI.Draw")
local Profile = require("ShapeKeySystem_Core.Profile")
local Cond = require("ShapeKeySystem_Core.CondExpr")
local Touch = require("ShapeKeySystem_Core.Touch")
local Scene = require("ShapeKeySystem_Core.Scene")
local Names = require("ShapeKeySystem_Core.Names")
local Writer = require("ShapeKeySystem_Core.Writer")
local Recording = require("ShapeKeySystem_Core.Recording")
local Analysis = require("ShapeKeySystem_Core.PlaybackAnalysis")
local Wilds = require("ShapeKeySystem_Games.Wilds.Adapter")
RESULTS = {}

-- 预热后报告五轮中位数；暂停 GC 的短批次用于测量分配量，不表示常驻内存。
local function measure(name, fn, n)
    fn()
    local times = {}
    for repeat_index = 1, 5 do
        collectgarbage("collect")
        local t = os.clock()
        for i = 1, n do fn() end
        times[#times + 1] = (os.clock() - t) * 1000 / n
    end
    table.sort(times)
    collectgarbage("collect"); collectgarbage("stop")
    local before = collectgarbage("count")
    local allocations = math.min(n, 3)
    for i = 1, allocations do fn() end
    local kb = (collectgarbage("count") - before) / allocations
    collectgarbage("restart"); collectgarbage("collect")
    RESULTS[#RESULTS + 1] = { name = name, median_ms = times[3], min_ms = times[1], max_ms = times[5], allocated_kb = kb }
end

for i = 1, 80 do SKS.tick() end
measure("tick_idle_mock", SKS.tick, 1000)

local index = Names.build_index({ "EyeBlinkLeft", "JawOpen", "LookInLeft" }, {})
local original_channels, original_read = CHANNELS, Writer.M_CNAME.call
local name_calls = 0
Writer.M_CNAME.call = function(...) name_calls = name_calls + 1; return original_read(...) end
for _, n in ipairs({ 25, 200, 1000 }) do
    CHANNELS = {}
    for i = 1, n do CHANNELS[i] = "blendShape1.Unused_" .. i end
    for i = 1, 3 do CHANNELS[i] = ({ "EyeBlinkLeft", "JawOpen", "LookInLeft" })[i] end
    measure("scene_scan_" .. n .. "_channels", function() Scene.scan({ index = index }) end, 10)
    name_calls = 0; Scene.scan({ index = index })
    RESULTS[#RESULTS].channel_name_calls = name_calls
end
CHANNELS, Writer.M_CNAME.call = original_channels, original_read

SKS.call("set_setting", { key = "advanced", value = true })
Panel.set_open(true)
local keep_expression = SKS.state.expression
Panel.ui.page = "expr"
for _, n in ipairs({ 25, 200, 1000 }) do
    local ex = {}
    for k,v in pairs(keep_expression) do ex[k] = v end
    ex.channels = {}; ex.groups = { { key = "eye", name = "眼", channel_slots = {} } }
    for i = 1, n do
        local original = keep_expression.channels[(i - 1) % #keep_expression.channels + 1]
        local c = {}; for k,v in pairs(original) do c[k] = v end
        c.slot, c.name, c.canonical, c.present = i, "FaceKey_" .. i, "FaceKey_" .. i, true
        ex.channels[i], ex.groups[1].channel_slots[i], SKS.live.weight[i] = c, i, 0.5
    end
    SKS.state.expression = ex
    for _, collapsed in ipairs({ false, true }) do
        Panel.ui.page_state.expr = { collapsed_initialized = true, collapsed = { eye = collapsed } }
        measure("ui_" .. n .. (collapsed and "_collapsed" or "_expanded"), function()
            DRAWS, CMDS, DRAWN_IMAGES = {}, {}, {}
            Panel.draw()
            assert(not Panel.ui.page_state.expr.last_err, Panel.ui.page_state.expr.last_err)
        end, 20)
        RESULTS[#RESULTS].visible_text_draws = #DRAWS
    end
end
SKS.state.expression = keep_expression
Panel.set_open(false)

local original_cond = Cond.current
for _, n in ipairs({ 25, 100, 300 }) do
    Cond.reset()
    local values, keys = {}, {}
    for i = 1, n do keys[i] = "Unmapped_Key_" .. i; values[keys[i]] = 0.5 end
    Cond.current = { data = { clips = { test = { values = values, fade_in = 0, fade_out = 0 } }, states = {} } }
    Cond.preview = "test"; Cond.update(false)
    measure("conditional_sculpt_" .. n .. "_keys", function()
        for _, key in ipairs(keys) do Cond.for_key(key, 0) end
    end, 5)
    measure("conditional_sculpt_update_" .. n .. "_keys", function()
        Cond.update(false)
        for _, key in ipairs(keys) do Cond.for_key(key, 0) end
    end, 50)
end
Cond.current, Cond.preview = original_cond, nil; Cond.reset()

local keep_touch = Touch.map
for _, n in ipairs({ 25, 100, 300 }) do
    local targets, keys = {}, {}
    for i = 1, n do keys[i] = "Unmapped_Key_" .. i; targets[keys[i]] = 0.5 end
    Touch.reset(); Touch.set_map({ eye = { values = targets } })
    local keep_clock = os.clock
    local fake_time = 0
    os.clock = function() return fake_time end
    Touch.update(); Touch.poke("eye"); fake_time = 0.1; Touch.update()
    os.clock = keep_clock
    measure("touch_sculpt_" .. n .. "_keys", function()
        for _, key in ipairs(keys) do Touch.for_key(key, 0) end
    end, 50)
end
Touch.reset(); Touch.set_map(keep_touch)

-- 各更新片的时间不含文件解析和引擎连接；报告工作片数量和最大时间。
local function prepare_slices(name, input, catalog)
    local job = Recording.prepare(input, "raw", catalog, "mhwilds", function(decoded, checkpoint)
        return Analysis.new(decoded, 0.01, name, Wilds.raw.label, checkpoint)
    end)
    local durations, done = {}, false
    collectgarbage("collect")
    repeat
        local started = os.clock()
        done = job:step()
        durations[#durations + 1] = (os.clock() - started) * 1000
    until done
    table.sort(durations)
    local total = 0
    for _, ms in ipairs(durations) do total = total + ms end
    RESULTS[#RESULTS + 1] = { name = "prepare_slices_" .. name, slices = #durations,
        median_ms = durations[math.ceil(#durations / 2)], max_ms = durations[#durations], total_ms = total }
end

local catalog = Wilds.playback.catalog()
for _, name in ipairs({ "Speak", "CampMeals" }) do
    local input = json.load_file("ShapeKeySystem\\builtin\\mhwilds\\recordings\\" .. name .. ".json")
    measure("decode_" .. name, function() Recording.decode(input, "raw", catalog, "mhwilds") end, 5)
    prepare_slices(name, input, catalog)
    local decoded = Recording.decode(input, "raw", catalog, "mhwilds")
    measure("analysis_init_" .. name, function() Analysis.new(decoded, 0.01, name, Wilds.raw.label) end, 5)
end
local limit = { schema = "fcparam.recording/2", game = "mhwilds", duration = 300,
    encoding = "quantized-delta", raw_scale = 10000000, params = {}, frames = {} }
local first = {}
for i = 1, 200 do limit.params[i] = { param = i, hash = catalog[i] }; first[i] = 0 end
limit.frames[1] = { t = 0, raw = first }
for i = 2, 9001 do limit.frames[i] = { t = (i - 1) / 30 } end
measure("decode_limit_300s_200params", function() Recording.decode(limit, "raw", catalog, "mhwilds") end, 1)
collectgarbage("collect")
local before = collectgarbage("count")
local clip = Recording.decode(limit, "raw", catalog, "mhwilds")
collectgarbage("collect")
RESULTS[#RESULTS].retained_kb = collectgarbage("count") - before
assert(#clip.frames == 9001)
prepare_slices("limit_300s_200params", limit, catalog)
'''


def playback_calls(lua):
    """复用荒野会话替身，只统计一次完整更新的引擎调用，不将替身耗时当成实机耗时。"""
    source = (REPO / "tests" / "tests_playback_adapter.lua").read_text(encoding="utf-8")
    setup = source.split("local injects, ticks =", 1)[0]
    setup = setup.replace('if m == "get_ValueCount" then return 2 end',
                          'if m == "get_ValueCount" then return 200 end')
    lua.execute(setup + r'''
local calls = {}
local original_call, original_manager = layer.call, sdk.get_managed_singleton
layer.call = function(self, name, ...)
    calls[name] = (calls[name] or 0) + 1
    return original_call(self, name, ...)
end
sdk.get_managed_singleton = function(name)
    calls[name] = (calls[name] or 0) + 1
    return original_manager(name)
end
local data = { schema = "fcparam.recording/1", duration = 1, params = {}, frames = {} }
local raw = {}
for i = 1, 200 do
    indexes[catalog[i]], values[i - 1] = i - 1, 0.0
    data.params[i], raw[i] = { param = i, hash = catalog[i] }, 0.001
end
data.frames = { { t = 0, raw = raw }, { t = 1, raw = raw } }
U.save_json(U.path("user", "recordings", "CallCount.json"), data)
local R = require("ShapeKeySystem_Core.Playback")
R.init({ id = "mhwilds", name = "test", playback = A })
assert(R.request("play", { id = "user:CallCount.json" })); update()
assert(R.state.status == "playing", R.state.message)
calls, writes = {}, {}
update()
pre({ [2] = controller, [4] = layer }); post(0)
R.tick(false)
PLAYBACK_CALLS = {}; for name, count in pairs(calls) do PLAYBACK_CALLS[name] = count end
R.stop(false)
sdk, thread, re.on_pre_application_entry = keep_sdk, keep_thread, keep_entry
''')
    return plain(lua.globals().PLAYBACK_CALLS)


def main():
    """打印测量结果，默认保存到仓库忽略的本地目录。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "local/performance/latest.json",
                        help="结果路径，默认 local/performance/latest.json")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="sks_profile_") as temporary:
        root = Path(temporary)
        shutil.copytree(REPO / "reframework/data/ShapeKeySystem/builtin", root / "ShapeKeySystem/builtin")
        lua, _ = runtime(root)
        lua.execute(BENCHMARK)
        result = {"environment": platform.platform(), "lua": lua.eval("_VERSION"),
                  "benchmarks": plain(lua.globals().RESULTS), "raw_playback_engine_calls": playback_calls(lua)}
        lua.execute('require("ShapeKeySystem_Core.API").shutdown()')
    output = json.dumps(result, ensure_ascii=False, indent=2)
    print(output)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(output + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
