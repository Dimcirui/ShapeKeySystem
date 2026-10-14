# ShapeKeySystem (SKS)

怪物猎人荒野的 REFramework 插件：用游戏的表情数据（fcParam）驱动猎人脸上的形态键（ARKit / Shinano / MMD 等配置），并支持实时捏脸、条件表情、脸部互动，以及给其他插件用的公开 API。面板用 reframework-d2d 绘制，没装 d2d 时用 REFramework 自带的 ImGui 绘制。

作者：谛听 Dimcirui。版本见 `reframework/autorun/ShapeKeySystem_Core/Version.lua`。

## 目录

| 路径 | 内容 |
|---|---|
| `reframework/` | 和游戏的 `reframework/` 同结构，安装时整个拷过去 |
| `reframework/autorun/ShapeKeySystem.lua` | 入口 |
| `reframework/autorun/ShapeKeySystem_Core/` | 后端：扫描、写入、表情、捏脸、预设、条件、API |
| `reframework/autorun/ShapeKeySystem_UI/` | 面板（d2d / ImGui 两种绘制后端，见 `Draw.lua`） |
| `reframework/autorun/ShapeKeySystem_Games/` | 游戏注册表与各游戏适配器，当前提供 `Wilds/` |
| `reframework/data/ShapeKeySystem/builtin/` | 通用 profile、别名表；`<游戏 ID>/` 下放信号字典、装备名、专属 profile、录制与参数表 |
| `reframework/data/ShapeKeySystem/faces/` + `reframework/images/ShapeKeySystem/` | 面部导航图样式 |
| `tools/install-ref-ime.ps1` | 从 REF-IME 最新 Release 安装输入法依赖，可指定其他 RE 游戏目录 |
| `tests/` | 离线测试（Python lupa 跑 Lua 5.4 + REFramework mock） |
| `tools/deploy.ps1` | repo 和游戏目录之间同步 |
| `tools/face_gen/` | 面部导航图生成器 |
| `toys/SKS_Mocap/` | 个人玩具：iFacialMocap → ARKit 形态键（不属于 SKS，不随 SKS 发布） |
| `docs/plans/` | 设计文档和 UI ↔ 后端接口约定 |

## 依赖

- REFramework（MH Wilds 版）
- reframework-d2d（可选，官方版本，单独安装；SKS 不打包自己的 d2d）。没装时面板改用 REFramework 自带的 ImGui 绘制（需要 2025-07 之后的 REFramework），这时基础页不显示面部图；设置页的「绘制方式」可以强制选择 ImGui（d2d 掉帧、Linux / Proton 时用）
- 输入法：[REF-IME 最新 Release](https://github.com/Monkeysama/REF-IME/releases/latest)（当前为 `v1.0.0`），将 ZIP 解压至游戏根目录，得到 `reframework/plugins/REF-IME.dll`。该插件使用通用 REF 接口，支持各 RE 游戏，要求兼容的 REFramework（当前 REF API 1.15+ / ImGui 1.92.0 WCHAR32，具体以上游说明为准）。SKS 的表情数据和装备功能仍按游戏提供支持。
  - 搜索框直接在原位置输入；保存命名、新建配置和表情组合在对应操作栏下展开编辑行，点击「确定」或「取消」。Enter/Esc 留给输入法选字，不触发保存。
  - d2d 和 ImGui 绘制后端使用同一套标准 ImGui 输入控件；不再依赖差分管理器 UI DLL，也不打开游戏输入弹窗。未安装 REF-IME 时仍可使用普通输入和系统剪贴板快捷键。
  - 已安装差分管理器时保留它自己的 DLL；SKS 仍保留双方输入屏蔽和光标的兼容逻辑。

## 打包规则

- **主包是纯 Lua**（`reframework/` 下的 autorun、data、images），任何游戏都可以装；游戏相关的功能在运行时按 `reframework.get_game_name()` 判断。
- **REF-IME 独立安装**，主包不捆绑第三方 DLL。依赖始终从上游最新 Release 获取，不再发布 `addons/WildsChineseInput/`。
- `tools/deploy.ps1` 只部署主包并清理旧的 SKS 输入模块；`tools/install-ref-ime.ps1` 单独安装 REF-IME，不删除其他插件的 DLL。

## 开发流程

repo 是唯一的源。改完代码后同步到游戏：

```powershell
tools\deploy.ps1 -Check   # 只看差异
tools\deploy.ps1          # repo -> 游戏
tools\deploy.ps1 -Pull    # 游戏 -> repo（在游戏目录里直接改过时用）
tools\install-ref-ime.ps1 -Check  # 查询最新 REF-IME 版本
tools\install-ref-ime.ps1         # 退出游戏后安装至默认荒野目录
tools\install-ref-ime.ps1 -GameDirectory "D:\Games\RE4" # 也可用于其他 RE 游戏
```

脚本只碰 SKS 自己的文件，玩家数据（`settings.json`、`user/`、`mods/`、`trail.log`）不读也不写。

离线测试（需要 `pip install lupa pillow`）：

```powershell
cd tests
python run.py           # 全部检查，末尾打印各组 FAILS
python run.py --shots   # 另外把面板各页渲染成 PNG（tests/shots/）
python test_deploy.py   # 在独立目录验证部署迁移和用户文件保留，需要 PowerShell
```

## 表情详情里的映射编辑

「表情详情」底部的「视线设置」下方提供可折叠的「面部动画测试」，内置荒野的 `Speak`、`CampMeals` 原版输入重播，支持暂停、循环、调速和跳转。下方分析日志按本次信号命中次数排序，显示用途与当前形态键绑定，支持分页、未绑定筛选和直接添加映射。播放器通过当前游戏适配器的可选 `playback` 接口运行；未实现该接口的游戏显示不可用提示，不安装荒野的播放回调。

内置录制放在 `data/ShapeKeySystem/builtin/mhwilds/recordings/`，参数表为同一游戏目录下的 `recording_catalog.json`。自有录制放在 `data/ShapeKeySystem/user/recordings/`；旧的 `user/games/mhwilds/recordings/` 仍可读取，同名文件以新目录为准。部署只清理旧 `games/mhwilds/` 下的三个内置文件，不移动或删除用户录制。文件格式见 [接口文档的面部动画测试章节](docs/plans/shape-key-system-api.md#15-面部动画测试)。

打开「进阶 → 表情详情」，点击形态键名称可展开配置；「＋ 新建映射」可从已扫描网格选择形态键，也可直接输入名称。部位可选眉、眼、视线、鼻·颊、嘴、下颌、舌或扩展。

- 节点支持面部信号、求和（sum）、取最大值（max）、取最小值（min）、相乘（mul）、相减（sub）、引用其他映射、原始 fcParam、常量及眼球旋转。混合节点可继续展开、添加或移除输入。
- 编辑时使用「映射结构 + 当前节点设置」：树里显示混合关系、信号名、fcParam 和系数，点击节点只编辑该节点。宽窗口左右分栏，窄窗口上下排列；映射说明、标记及网格匹配规则默认折叠。应用和取消放在工作区顶部，编辑时暂时收起通道列表及全局强度控件。
- 形态键名称和面部信号使用可输入的选择框，输入时在下方联想过滤候选，选中后收起。形态键按名称搜索，也可直接输入未扫描的名称；信号按别名、fcParam 或用途搜索，只有选择候选才修改绑定，长列表可翻页。
- 信号选择显示语义别名（例如 `blink.L`）、骨骼名（`fcParam_001`）、用途、角色左右侧、实时值和推测标记。
- 每个输入可设置系数和响应曲线（死区、幂指数、增益）；映射可编辑说明、扩展/推测标记、其他网格名称和排除规则。
- 点击「应用映射」立即在运行配置生效；「取消编辑」丢弃未应用的草稿。「保存映射」写入用户配置；内置或 mod 自带配置需要起新名字，写入 `data/ShapeKeySystem/user/profiles/`，不会改动原文件。保存后可点「设为默认」绑定当前装备。
- 「恢复配置」放弃未保存的运行修改。引用循环、未知信号和无效数值会被拒绝；仍被其他节点引用的映射不能删除。切换配置前需先保存或恢复映射。

## 第三方代码

见 [THIRD_PARTY.md](THIRD_PARTY.md)。
