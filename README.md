# ShapeKeySystem (SKS)

怪物猎人荒野的 REFramework 插件：用游戏的表情数据（fcParam）驱动猎人脸上的形态键（ARKit / Shinano / MMD 等配置），并支持实时捏脸、条件表情、脸部互动，以及给其他插件用的公开 API。面板用 reframework-d2d 绘制。

作者：谛听 Dimcirui。版本见 `reframework/autorun/ShapeKeySystem_Core/Version.lua`。

## 目录

| 路径 | 内容 |
|---|---|
| `reframework/` | 和游戏的 `reframework/` 同结构，安装时整个拷过去 |
| `reframework/autorun/ShapeKeySystem.lua` | 入口 |
| `reframework/autorun/ShapeKeySystem_Core/` | 后端：扫描、写入、表情、捏脸、预设、条件、API |
| `reframework/autorun/ShapeKeySystem_UI/` | d2d 面板 |
| `reframework/data/ShapeKeySystem/builtin/` | 内置 profile、别名表、装备名、信号 |
| `reframework/data/ShapeKeySystem/faces/` + `reframework/images/ShapeKeySystem/` | 面部导航图样式 |
| `tests/` | 离线测试（Python lupa 跑 Lua 5.4 + REFramework mock） |
| `tools/deploy.ps1` | repo 和游戏目录之间同步 |
| `tools/face_gen/` | 面部导航图生成器 |
| `toys/SKS_Mocap/` | 个人玩具：iFacialMocap → ARKit 形态键（不属于 SKS，不随 SKS 发布） |
| `docs/plans/` | 设计文档和 UI ↔ 后端接口约定 |

## 依赖

- REFramework（MH Wilds 版）
- reframework-d2d（官方版本，单独安装；SKS 不打包自己的 d2d）

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
