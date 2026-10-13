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
| `reframework/data/ShapeKeySystem/builtin/` | 内置 profile、别名表、装备名、信号 |
| `reframework/data/ShapeKeySystem/faces/` + `reframework/images/ShapeKeySystem/` | 面部导航图样式 |
| `addons/WildsChineseInput/` | 可选组件（只限荒野）：差分管理器的 UI DLL，用于中文输入，见其中的 README |
| `tests/` | 离线测试（Python lupa 跑 Lua 5.4 + REFramework mock） |
| `tools/deploy.ps1` | repo 和游戏目录之间同步 |
| `tools/face_gen/` | 面部导航图生成器 |
| `toys/SKS_Mocap/` | 个人玩具：iFacialMocap → ARKit 形态键（不属于 SKS，不随 SKS 发布） |
| `docs/plans/` | 设计文档和 UI ↔ 后端接口约定 |

## 依赖

- REFramework（MH Wilds 版）
- reframework-d2d（可选，官方版本，单独安装；SKS 不打包自己的 d2d）。没装时面板改用 REFramework 自带的 ImGui 绘制（需要 2025-07 之后的 REFramework），这时基础页不显示面部图；设置页的「绘制方式」可以强制选择 ImGui（d2d 掉帧、Linux / Proton 时用）
- 中文输入（只限荒野）：
  - 可选组件 `addons/WildsChineseInput/`：差分管理器（ArmorVariantManager）的 UI DLL，经作者同意随 SKS 发布、只用于荒野，装到和差分管理器**完全相同的路径**（`reframework/plugins/ArmorVariantManager_UI.dll`）。两个插件都装时 mod 管理器提示冲突，直接覆盖即可，最后只有一份；装了差分管理器 4.3+ 就不需要这个组件。SKS 只用它的原生输入法服务（`ShapeKeySystem_UI/NativeText.lua`，自己的通信目录 `data/ShapeKeySystem/Runtime/`）。
  - 没有这个 DLL 时，输入框旁的「中文」按钮会弹出游戏自己的输入框（`GameText.lua`）。
  - 其他游戏只有 ImGui 输入框（只能打英文，可以「粘贴」）。

## 打包规则

- **主包是纯 Lua**（`reframework/` 下的 autorun、data、images），任何游戏都可以装；游戏相关的功能在运行时按 `reframework.get_game_name()` 判断。
- **DLL 只能放在单独的组件里**（`addons/`），不能进主包：REFramework 启动时会自动加载 `reframework/plugins/` 下的所有 DLL，发生在任何 Lua 运行之前，Lua 里的游戏判断管不了加载。`ArmorVariantManager_UI.dll` 在崛起上会让游戏在加载阶段崩溃。
- `tools/deploy.ps1` 只部署主包；组件在开发时手动复制。

## 开发流程

repo 是唯一的源。改完代码后同步到游戏：

```powershell
tools\deploy.ps1 -Check   # 只看差异
tools\deploy.ps1          # repo -> 游戏
tools\deploy.ps1 -Pull    # 游戏 -> repo（在游戏目录里直接改过时用）
```

脚本只碰 SKS 自己的文件，玩家数据（`settings.json`、`user/`、`mods/`、`trail.log`）不读也不写。

离线测试（需要 `pip install lupa pillow`）：

```powershell
cd tests
python run.py           # 全部检查，末尾打印各组 FAILS
python run.py --shots   # 另外把面板各页渲染成 PNG（tests/shots/）
```

## 第三方代码

见 [THIRD_PARTY.md](THIRD_PARTY.md)。
