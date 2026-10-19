-- ShapeKeySystem: plugin version, author and release notes (shown under 设置与调试 → 关于).
-- Semantic versioning: patch = fixes only, minor = new features that keep old files working,
-- major = file formats / the public API change incompatibly. The public API (ShapeKeySystemAPI)
-- keeps its own version in API.lua.
-- Releasing: bump `number` and put the new entry FIRST in `history` (one short line each).

local V = {}

V.name = "ShapeKeySystem"
V.number = "1.6.1"
V.author = "谛听, MK, Funnyguyz"

V.history = {
    { version = "1.6.1", notes = "修复打开设置与调试后面板消失、游戏卡死" },
    { version = "1.6.0", notes = "RE4R 支持多角色；修复崛起过场中失效问题" },
    { version = "1.5.0", notes = "新增面捕；荒野新增表情录制；其他优化与问题修复" },
    { version = "1.4.1", notes = "条件表情更名为条件规则" },
    { version = "1.4.0", notes = "支持怪物猎人崛起；新增自动表情" },
    { version = "1.3.0", notes = "支持生化危机4 重制版" },
    { version = "1.2.0", notes = "支持鬼武者·剑之道；新增面部动画测试" },
    { version = "1.1.1", notes = "修复渲染重置时面板报错" },
    { version = "1.1.0", notes = "新增 VRChat 素体表情配置" },
    { version = "1.0.0", notes = "首个版本" },
}

return V
