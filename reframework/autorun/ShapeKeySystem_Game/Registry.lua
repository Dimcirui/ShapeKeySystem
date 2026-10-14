-- 播放游戏适配器注册表：只按 REF 游戏标识加载匹配模块，不探测其他游戏的 app/snow 类型。
-- 本模块仅负责新增录制功能的分派；原有 SKS 游戏层拆分继续由议题 #9 跟踪。
local G = {}
local modules = { mhwilds = "ShapeKeySystem_Game.WildsPlayback" }
function G.load()
    local ok, name = pcall(function() return reframework.get_game_name() end)
    name = ok and type(name) == "string" and name:lower() or "unknown"
    local module = modules[name]
    if not module then return nil, name, "当前游戏尚未提供录制播放适配器：" .. name end
    return require(module), name
end
return G
