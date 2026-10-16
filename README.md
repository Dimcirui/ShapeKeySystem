# ShapeKeySystem (SKS)

RE 引擎游戏的 REFramework 插件，用于操控游戏内的形态键（或叫 Blend Shape、Shape Key），并提供图形界面。操作方式有三种：

- 自动驱动：读取游戏自身的表情数据，实时驱动形态键，让带形态键的 mod 模型跟着游戏做表情；条件表情和面部互动也属于这一类。
- 手动修改：直接调节形态键的数值，实现捏脸等效果，并可按角色和装备保存为预设。
- 外部接口：其他插件可以通过公开 API 接管形态键，例如接入外部面捕。
- 优先级：外部接口持有某个形态键时，直接覆盖其他方式；手动修改优先于自动驱动，自动驱动会在手动修改的范围基础上重映射。

作者：谛听（Dimcirui）、MK（MonkeySama）。
版本号和更新记录见 `reframework/autorun/ShapeKeySystem_Core/Version.lua`。

## 支持的游戏

| 游戏 | 适配器 | 表情数据来源 |
|---|---|---|
| 怪物猎人：荒野 | `ShapeKeySystem_Games/Wilds/` | fcParam 关节 |
| 鬼武者：剑之道 | `ShapeKeySystem_Games/Onimusha/` | `bsControl` 关节；通道名通过名字哈希反查 |
| 生化危机4 重制版 | `ShapeKeySystem_Games/RE4R/` | Leon 面部骨骼姿态与原生修正通道权重 |

后续要适配的游戏见 #17。

## 功能

- **表情驱动**：信号字典把各游戏的原始数据转换成通用的语义信号，再由表情配置映射到形态键。
- **捏脸**：实时调节形态键，保存成捏脸预设。
- **预设与绑定**：按装备或模型绑定表情配置和捏脸预设。
- **条件表情**：满足条件（受伤、战斗、血量等）时叠加一组表情。
- **面部互动**：在面部导航图上点击额头、脸颊或眼睛，播放对应的反应；拖动嘴部可以改变口型。
- **面部动画测试**：回放录制的面部动画，检查映射效果（目前只支持荒野）。
- **公开 API**：其他插件可以通过 `ShapeKeySystemAPI` 临时接管形态键的值，优先级高于表情和捏脸。

面板默认用 Delete 键打开。操作说明见 [docs/guide.md](docs/guide.md)。

## 依赖

- REFramework。
- [REF-IME](https://github.com/Monkeysama/REF-IME/releases/latest)：中文输入，通用 REF 插件，支持各 RE 游戏。没有安装时也能用普通输入和剪贴板快捷键。
- reframework-d2d（可选）：没有安装时，面板改用 REFramework 自带的 ImGui 绘制（需要 2025-07 之后的 REFramework），这时基础页不显示面部图。设置页的「绘制方式」可以强制使用 ImGui，适用于 d2d 掉帧、Linux / Proton 等情况。
- 和 ArmorVariantManager 共存：SKS 的默认热键是 Delete（AVM 用 Home，游戏暂停用 End），和 AVM 共用输入屏蔽表，也不替换 d2d 的全局对象。

## 目录

| 路径 | 内容 |
|---|---|
| `reframework/` | 结构和游戏里的 `reframework/` 一致，部署时整个复制过去 |
| `reframework/autorun/ShapeKeySystem.lua` | 入口 |
| `reframework/autorun/ShapeKeySystem_Core/` | 后端：扫描、写入、表情、捏脸、预设、条件、播放、API |
| `reframework/autorun/ShapeKeySystem_UI/` | 面板，有 d2d 和 ImGui 两种绘制后端（见 `Draw.lua`） |
| `reframework/autorun/ShapeKeySystem_Games/` | 游戏注册表 `Registry.lua`，以及各游戏的适配器 |
| `reframework/data/ShapeKeySystem/builtin/` | 各游戏通用的表情配置和别名表；`<游戏 id>/` 下放信号字典、装备名、专属配置和录制 |
| `reframework/data/ShapeKeySystem/faces/`、`reframework/images/ShapeKeySystem/` | 面部导航图的样式 |
| `tools/deploy.ps1` | 在仓库和游戏目录之间同步 |
| `tools/package.ps1` | 生成 Fluffy Mod Manager 发布包，附带 REF-IME 附加包 |
| `tools/sks-files.ps1` | 发布文件清单，部署和打包共用 |
| `tools/install-ref-ime.ps1` | 从上游 Release 安装 REF-IME |
| `tools/onimusha_signals.py` | 从鬼武者原版 jcns 生成信号字典 |
| `tools/convert_re4r_profile.py` | 将旧 RE4R 模型配置转换为 SKS 配置 |
| `tools/vrc_profiles/` | 生成 VRChat 模型的表情配置 |
| `tools/face_gen/` | 面部导航图生成器 |
| `tools/profile_offline.py` | 离线性能复测 |
| `tests/` | 离线测试：用 Python lupa 运行 Lua 5.4，配合 REFramework mock |
| `toys/SKS_Mocap/` | 个人玩具：iFacialMocap → ARKit 形态键，不属于 SKS，也不随 SKS 发布 |
| `docs/plans/` | 设计文档和接口约定 |
| `docs/writing/` | 书写规范：注释、提交、发布说明、issue、版本 |
| `docs/releases/unreleased.md` | 下一版发布说明的草稿 |

## 开发

仓库是唯一的源。改完代码后同步到游戏：

```powershell
tools\deploy.ps1 -Check   # 只列出差异
tools\deploy.ps1          # 仓库 -> 游戏
tools\deploy.ps1 -Pull    # 游戏 -> 仓库（直接在游戏目录里改过时用）
```

脚本默认的游戏目录是 `C:\Steam\steamapps\common\MonsterHunterWilds\reframework`，在其他位置时需要设置环境变量 `SKS_GAME_REFRAMEWORK`。脚本只处理 SKS 自己的文件，不读也不写玩家数据（`settings.json`、`user/`、`mods/`、`trail.log`）。

离线测试（需要先 `pip install lupa pillow`）：

```powershell
cd tests
python run.py            # 运行全部检查，最后打印每组的 FAILS
python run.py --shots    # 另外把面板各页渲染成 PNG，存到 tests/shots/
python test_deploy.py    # 在独立目录里验证部署
python test_package.py   # 验证发布包的结构，不联网
```

发布时按 [版本规范](docs/writing/version_guideline.md) 定版，然后运行 `tools\package.ps1` 生成 `dist/ShapeKeySystem-<版本>.zip`，作为附件上传到 GitHub release。

设计文档：

- [shape-key-system.md](docs/plans/shape-key-system.md)：整体架构和里程碑
- [shape-key-system-api.md](docs/plans/shape-key-system-api.md)：UI 与后端的约定、命令、文件格式
- [multi-game-adapter.md](docs/plans/multi-game-adapter.md)：游戏适配器接口
- [onimusha-adapter.md](docs/plans/onimusha-adapter.md)：鬼武者适配的探查结果和待查问题
- [re4r-adapter.md](docs/plans/re4r-adapter.md)：RE4R Leon 的信号来源、写入方式和后续适配

## 第三方代码

见 [THIRD_PARTY.md](THIRD_PARTY.md)。
