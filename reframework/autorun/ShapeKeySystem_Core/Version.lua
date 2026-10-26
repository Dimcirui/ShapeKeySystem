-- ShapeKeySystem: plugin version, author and release notes (shown under 设置与调试 → 关于).
-- Semantic versioning: patch = fixes only, minor = new features that keep old files working,
-- major = file formats / the public API change incompatibly. The public API (ShapeKeySystemAPI)
-- keeps its own version in API.lua.
-- Releasing: bump `number` and put the new entry FIRST in `history` (one short line each).

local V = {}

V.name = "ShapeKeySystem"
V.number = "1.10.0"
V.author = "谛听, MK, Funnyguyz"

V.history = {
    { version = "1.10.0", notes = "条件规则的组合可从捏脸配置导入" },
    { version = "1.9.2", notes = "RE4R 减少表情驱动开销；修复切换角色后后台表情停止" },
    { version = "1.9.1", notes = "崛起减少掉帧" },
    { version = "1.9.0", notes = "新增形态键驱动、RE9 实验性支持等" },
    { version = "1.8.0", notes = "新增英文界面；鬼武者支持鬼化形态" },
    { version = "1.7.0", notes = "崛起支持条件规则" },
    { version = "1.6.2", notes = "RE4R 支持缺失面骨与原生修正输入补偿；支持禁用骨骼表情" },
    { version = "1.6.1", notes = "修复设置与调试页导致卡死" },
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
