-- ShapeKeySystem: plugin version, author and release notes (shown under 设置与调试 → 关于).
-- Semantic versioning: patch = fixes only, minor = new features that keep old files working,
-- major = file formats / the public API change incompatibly. The public API (ShapeKeySystemAPI)
-- keeps its own version in API.lua.
-- Releasing: bump `number` and put the new entry FIRST in `history` (one short line each).

local V = {}

V.name = "ShapeKeySystem"
V.number = "1.20.0"
V.author = "Dimcirui, MK, funnyguyz, Kevin, Motoka, Moon"

V.history = {
    { version = "1.20.0", notes = "RE4R 新增阿什莉、路易斯、克劳萨、威斯克、汉克的捏脸与驱动；修复切换角色后无法切回" },
    { version = "1.19.1", notes = "插件选的键组选项换捏脸配置后继续生效" },
    { version = "1.19.0", notes = "表情可按帧间隔更新，关闭表情更省性能；插件可按角色切换捏脸配置" },
    { version = "1.18.0", notes = "捏脸列表按网格顺序分段，形态键可进多个键组；RE4R 新增一批条件并分类" },
    { version = "1.17.0", notes = "合成条件新增任一阶段选项；荒野与 RE4R 每帧开销进一步降低" },
    { version = "1.16.0", notes = "RE4R 新增持械、武器类型和合成条件，每帧开销大幅降低" },
    { version = "1.15.1", notes = "REFramework 菜单里可以弹出可视化界面" },
    { version = "1.15.0", notes = "新增导出为 mod 和多套驱动配置；鬼武者支持表情镜和条件" },
    { version = "1.14.1", notes = "提醒更新过旧的 REFramework" },
    { version = "1.14.0", notes = "表情镜支持 RE4R、按部位隐藏；面板改为标签页" },
    { version = "1.13.0", notes = "荒野新增表情镜；面捕可驱动任意表情配置" },
    { version = "1.12.1", notes = "崛起减少定期扫描开销" },
    { version = "1.12.0", notes = "捏脸支持键组；鬼武者头发和装备菜单角色可驱动" },
    { version = "1.11.0", notes = "一个角色只用一份绑定；修复鬼武者捏脸预设被改回" },
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
