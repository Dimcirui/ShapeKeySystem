# 计划：ShapeKeySystem —— MH Wilds 形态键插件（表情系统 + 捏脸/捏人系统）

状态：规划中（2026-10-08）
前身：`reframework/autorun/ArkitFaceDriver.lua`（已在游戏内验证可用）
相关：[arkit-facetracking-import.md](arkit-facetracking-import.md)（Blender 侧：把 VRC 面捕形态键导入网格）

## 0. 决策记录（2026-10-08，以本节为准，下文与之冲突处待重写）

- **名称**：ShapeKeySystem。
- **两个子系统**：
  - **表情系统**：根据猎人表情实时映射形态键，支持自定义配置。内置的配置分两层：
    - 底层命名体系：ARKit、Unified Expressions、SRanipal、MMD、VRC 口型。
    - 上层模型配置：Shinano、Kaguya、Maya、Milltina 等，用 `extends` 继承底层体系。
    - 扫描后按覆盖率自动推荐配置；信号用语义名，通过信号词典对应到 fcParam 编号。
    - 后续再加：口型合成、平滑滤波、分区强度。
  - **捏脸 / 捏人系统**：类似 Body Shape Slider。
    - 通过"扫描"读取身上装备的形态键（懒读取，不实时）；不同部件中名字完全相同的形态键合并成一项，改一次全部同步，也允许对单个部件单独覆盖。
    - 静态调整，**范围定为 0 ~ 2**。2026-10-08 实测：-1、-0.5、0、0.5、1、1.5、2 写入后读回的值完全一致，引擎不截断；画面上 1.5 和 2 会继续外推。负值本身也能写入，但不提供。
    - 不自带预设，由用户自己建立；mod 自带的预设文件会被自动读取，能匹配上的形态键全部应用。
    - 当前表情配置已经占用的通道，在捏脸列表里默认隐藏。
- **父预设**：文件名按**部件 ID** 命名，指定使用哪个表情配置、哪个捏脸配置（这两类可以用任意名字，语义更清楚）。查找顺序依次回退：
  1. 精确部件 ID：`ch03_012_0012.json`
  2. 同系列：`ch03_012_*.json`
  3. 全局默认：`default.json`

  mod 自带的文件放在 `mods/`（只读），用户自己的放在 `user/`，这样 mod 管理器覆盖安装时不会冲掉用户预设。
- **界面（原型 https://claude.ai/artifact/7gNPX1dR7CDeoQJtaPZNcj）**：
  - 菜单分**基础**和**进阶**两组，标题栏的"进阶"开关负责显示或隐藏进阶组。
    - 基础组：表情（面部图标点选部位后调强度，另有整体表情强度、视线强度）、捏脸。
    - 进阶组：表情详情（按部位分组，可展开收起）、视线、映射编辑、预设、设置与调试。
  - 主角色和名片分身不作区分，按同一个角色同步驱动。
  - 面部图标只用椭圆、圆角矩形、圆这些 d2d 能画的基本图形，点击用坐标判断落在哪个区域。
- **和 ArmorVariantManager 不能冲突**（2026-10-10）：两边受众高度重合。可以不用 AVM 的 DLL，但绝不能冲突。已做：默认热键改为 Delete（2026-10-10：AVM 用 Home，End 是游戏暂停键，Insert 是 REF 菜单；本机 REF 配置只占用了 Insert、小键盘 . / +、PageUp/PageDown（自由视角），Delete 和小键盘数字键空闲；旧设置里的 Home/End 由 hotkey_rev 2 自动迁移一次）；输入屏蔽登记进 AVM 的全局表 `__AVM_UI_INPUT_BLOCKER_STATES`，鼠标模式只在对方没占用时保存、对方放手后才恢复；AVM 打开面板时关掉我们的面板，AVM 开着时不画自己的光标；d2d 绘图函数缺失时自动降级（AVM 的 DLL 自带一份 d2d）。AVM 的许可证是 MIT，可以放进 GPL-3.0 项目。
- **FBS 兼容暂缓**（2026-10-08）：两边用户重叠很少，第一版不做 FBS 检测；下面这条是以后要做时的方案。
- **和 FBS 冲突时**：明确让步。检测到 Female Body Sliders 正在管理的通道，全部交给 FBS，本插件不写，界面上标出"由 FBS 管理"。
- **导出工具链**：倾向在作者的 Modding-Toolkit 里做"导出后注入"。
  - 流程：用户用任意版本的 RE Mesh 照常导出；Toolkit 用自带的 mesh 读写代码，把 Blender 里的形态键写进生成的 `.mesh`，并在批量导出时一起写出配置文件。
  - 好处：不依赖 ridog 分支的内部实现。
  - 许可证：Toolkit 本身就是 GPL-3.0，和移植过来的 RE Mesh Editor 代码兼容（已确认）。
  - 检测到用户装了 MeshFixes 时，可以直接用它的导出。

## 1. 目标

一个独立面板的 REFramework 插件，类似 Female Body Sliders 和 ArmorVariantManager：

1. **表情驱动**：把游戏的面部动画信号实时映射到防具网格的形态键上。映射方式由"表情配置"决定，例如 ARKit、MMD、某个角色专属的形态键。
2. **实时捏脸**：用滑块直接设置形态键的固定权重。平时不写入（懒加载），只在进入编辑模式时实时刷新。
3. **全部由预设驱动**：表情配置、捏脸数值、角色绑定都存成 JSON，可以分享。

不在本插件范围内：Blender 侧导入形态键（见另一份计划），以及 mesh 导出（由 RE-Mesh-Editor 负责）。

## 2. 已验证的运行时事实（2026-10-08）

| 事实 | 依据 |
|---|---|
| 面部动画信号是 `Player_Face` 上的 `fcParam_000..200` 关节，数值存在局部位置 z 上，峰值约 0.01 | 实测，加上 motlist 属性轨道分析 |
| 视线由 `L_EyeJ_LOD02` 和 `R_EyeJ_LOD02` 的旋转决定（lookAt 系统） | 实测 |
| 写入接口：`via.render.Mesh:setBlendShapeChannelWeightParam(i, w)`，写一次就会一直保持 | 实测，FBS 也用这个接口 |
| 防卡死：先确认 `get_BlendShapeChannelWeightCount() >= get_BlendShapeChannelNum()` 再写入 | FBS 源码 |
| 性能：主角色 55 个通道，每帧 0.10 ms（只写变化值、缓存方法对象） | 实测 |
| NPC 的脸也带 fcParam（营地里有 72 张），所以只看 `ch02`、`ch03` 部件 | 实测 |
| 公会名片的预览角色在 `app.GUI040200.onOpen` 之后才生成，需要延时重试扫描 | 实测 |
| 防具面部骨骼是 BoneSystem 用代码逐帧拷贝的（不是引擎约束，有一帧延迟） | 实测 |

## 3. ARKit 官方命名对照

来源：Apple `ARFaceAnchor.BlendShapeLocation`，共 52 个。官方说明的原意是：左右是相对于**这张脸本身**的，例如 eyeBlinkRight 指的就是这张脸的右眼。这和 Wilds 中 `L_`、`R_` 指角色自身左右的约定一致，实测左右没有反。

官方名字一律是小写开头的驼峰（lowerCamelCase）。和当前 Shinano 网格对比：

| 类别 | 数量 | 说明 |
|---|---|---|
| 完全一致 | 10 | `eyeBlinkLeft/Right`、`mouthClose`、`mouthFunnel`、`mouthPucker`、`mouthRollLower/Upper`、`mouthShrugLower/Upper`、`tongueOut` |
| 只差大小写 | 40 | 网格写成大写开头，例如 `BrowDownLeft`、`EyeLookUpLeft`、`JawOpen`、`MouthSmileLeft`、`CheekPuff`、`NoseSneerLeft` 等 |
| 网格里缺少 | 2 | `mouthPressLeft`、`mouthPressRight` |
| 网格里多出（不属于 ARKit） | 60 | 见下表 |

多出来的形态键分类：

| 分组 | 例子 | 用途 |
|---|---|---|
| 左右拆分 | `BrowInnerUpLeft/Right`、`CheekPuffLeft/Right` | 官方是左右合一的，这里拆开后可以单独驱动 |
| 虹膜平面移动 | `LookUp/Down/In/OutLeft/Right` | 适合凹面眼，眼球不用旋转 |
| 眼部细节 | `EyeConstrict`、`EyeDilation`、`Blink.*` | 瞳孔缩放、高光 |
| 张嘴状态下的修正 | `*@Open`、`LipSuck*@Open20`、`JawDrop*`、`MouthOpen*` | 需要乘积组合（例如笑 × 张嘴） |
| 舌头 | `Tongue*`、`*TongueMorph*` | 游戏里没有对应的舌头信号，暂时只能手动或固定值 |

当前驱动脚本里 ARKit 部分还没接上的：`jawForward/Left/Right`、`mouthPucker`、`tongueOut`、`mouthPress*`（网格里本来就没有）。左右合一的 `browInnerUp`、`cheekPuff` 现在用的是拆分版。

**结论（命名规则）：**
- 插件内部统一用官方的 lowerCamelCase 作为标准名。
- 匹配网格通道时**不区分大小写**，同时也接受 `节点.名字` 这种带前缀的写法。
- 另外维护一张**别名表**，覆盖 Unified Expressions、SRanipal 等其他命名体系，例如：

  | 别名 | 标准名 |
  |---|---|
  | `EyeClosedLeft` | `eyeBlinkLeft` |
  | `LipFunnel` | `mouthFunnel` |
  | `LipPucker` | `mouthPucker` |
  | `LipSuckLower` | `mouthRollLower` |

- 非 ARKit 的扩展通道保留原名，在配置里显式声明。

## 4. 架构

```
reframework/autorun/
  ShapeKeySystem.lua                      入口：加载模块、注册回调、快捷键
  ShapeKeySystem_Core/
    Scene.lua        角色和部件发现（主角色、名片分身、可选的其他猎人），按需扫描，ch02/ch03 过滤
    Signals.lua      信号源：fcParam、眼球角度、程序化信号（自动眨眼、呼吸）、手动值
    Profile.lua      表情配置的加载、校验、编译（JSON → 扁平指令数组）
    Layers.lua       图层合成：捏脸层 + 表情层 + 覆盖层 → 每个通道的最终权重
    Writer.lua       只写变化值、防卡死检查、哨兵检测、缓存方法对象
    Presets.lua      预设读写、版本迁移、按防具 ID 绑定、备份
    Names.lua        标准名、别名表、不区分大小写的匹配
    Profiler.lua     分阶段计时
  ShapeKeySystem_UI/        独立面板（见第 7 节）
reframework/data/ShapeKeySystem/
  profiles/*.json    表情配置（ARKit.json、MMD.json、角色专属…）
  sculpt/*.json      捏脸预设
  bindings/*.json    按防具 ID 绑定，例如 ch03_012_0012.json
  settings.json      全局设置（快捷键、界面缩放、性能选项）
```

每帧的流程：
```
Signals（读 fcParam 和眼球）→ Profile（按编译好的指令计算）→ Layers（合成）→ Writer（只写变化的通道）
```

## 5. 预设 JSON 设计

### 5.1 表情配置（profile）

不用自己写表达式解析器，而是用**结构化的 JSON 节点**，编译时展开成扁平指令：

```json
{
  "schema": "sks.profile/1",
  "id": "arkit-default",
  "name": "ARKit 52",
  "naming": { "case_insensitive": true, "aliases": "arkit" },
  "constants": { "full": 0.01 },
  "channels": {
    "eyeBlinkLeft":   { "sum": [ { "p": 1 } ] },
    "mouthSmileLeft": { "sum": [ { "p": 33 }, { "p": 31, "k": 0.5 } ] },
    "mouthFunnel":    { "sum": [ { "p": 43, "k": 0.5 }, { "p": 44, "k": 0.5 } ] },
    "MouthSmileLeftOpenMorph*": { "mul": [ { "ref": "mouthSmileLeft" }, { "ref": "jawOpen" } ] },
    "eyeLookUpLeft":  { "eye": "L", "axis": "pitch", "sign": 1, "full_deg": 20 },
    "browDownLeft":   { "sum": [ { "p": 17 }, { "p": 15, "k": 0.5 } ],
                        "curve": { "deadzone": 0.03, "gamma": 1.0, "gain": 1.0 } }
  }
}
```

节点类型：

| 节点 | 含义 |
|---|---|
| `p` | 读第几个 fcParam，已按 `full` 归一化到 0..1 |
| `k` | 系数，默认 1 |
| `ref` | 引用另一个通道算好的值。编译时做拓扑排序，检测循环引用 |
| `sum`、`mul`、`max`、`min`、`sub` | 组合运算 |
| `eye` | 眼球角度源 |
| `const` | 常数 |
| `curve` | 输出曲线：死区、gamma、增益、截断，可以叠加在任何节点上 |

MMD 配置就是另一份 profile，用组合规则拼出整体表情，例如：
- `あ` = `jawOpen` × (1 − `mouthFunnel`)
- `笑い` = max(`mouthSmileLeft`, `mouthSmileRight`)

### 5.2 捏脸预设（sculpt）

```json
{
  "schema": "sks.sculpt/1",
  "name": "默认脸",
  "target": { "part": "ch03_012_0012", "channel_hash": "a1b2c3" },
  "values": { "option_jaw_narrow": 0.35, "eye_big": 0.2 }
}
```

`channel_hash` 是网格通道名集合的哈希。换了 mesh 之后可以给出提示，但仍然按通道名尽量匹配应用。

### 5.3 防具绑定（binding，参考 AVM 按 body ID 存预设的做法）

```json
{
  "schema": "sks.binding/1",
  "part": "ch03_012_0012",
  "profile": "arkit-default",
  "sculpt": "默认脸",
  "gains": { "mouthSmileLeft": 1.2 },
  "layer_modes": { "eyeBlinkLeft": "override" }
}
```

### 5.4 图层合成规则

```
最终权重 = clamp( 捏脸 ⊕ 表情 ⊕ 覆盖 )
```

`⊕` 默认是相加。每个通道可以单独设为 `max` 或 `override`。同一个通道同时被捏脸和表情使用时，界面上要标出来。

所有 JSON 都带 `schema` 版本号，由 `Presets.lua` 负责迁移旧版本。

## 6. 懒加载捏脸（照搬 Female Body Sliders 的做法）

- **写入时机**：应用预设时、换装或扫描到新部件时、编辑模式下每帧。其余时间完全不写。
- **哨兵检测**：每 60 帧读一次某个捏脸通道的值，发现和应写的值不一致（mesh 重新加载、权重缓冲区重建），就整体重写一遍。
- 捏脸层和表情层**分开记录"上次写入的值"**，避免两层互相触发重写。

## 7. 界面设计（独立面板）

### 7.1 技术方案（参考 ArmorVariantManager）

ArmorVariantManager（MIT 许可）的做法：
- 用 **reframework-d2d**（cursey）绘制。
- 自己写了一套 Lua 组件：Window、Button、Slider、List、Select、Input、Tag 等。
- 配了一个原生 DLL（`ArmorVariantManager_UI.dll`），通过 `d2d.bridge` 提供三样东西：
  - 屏蔽游戏输入（hook `UpdateHID`）
  - 自定义光标
  - 原生文本输入，支持中文输入法，通过 JSON 文件和 Lua 交换数据
- Delete 键打开面板（可在设置里改，含小键盘 0–9），窗口可以拖动、可以改大小。

本插件的方案：
1. 依赖 **reframework-d2d** 绘制，用 imgui 读取鼠标状态。
2. 组件层自己写一个精简版（窗口、按钮、滑块、列表、下拉、开关、标签页）。AVM 的组件可以参考或改写，但要保留它的 MIT 版权声明。
3. **文本输入**（给预设命名）有两种做法，待定：
   - 方案 a：可选依赖 AVM 的 UI bridge DLL。用户装了 AVM 就能用原生输入法。
   - 方案 b：命名时临时弹出一个 imgui 小窗口（REFramework 自带的 imgui 支持文本输入）。
   - 先做 b，以后再接 a。
4. **屏蔽输入**：面板打开时，鼠标点击不能传给游戏。先用最简单的办法，在面板区域内吞掉点击；需要时再参考 AVM 的 `InputBlocker`。

### 7.2 布局

```
┌ ShapeKeySystem ───────────────────────────────────────── [角色: ★主角色 ▾] [● 启用] ─ ✕ ┐
│ ┌──────────┐ ┌───────────────────────────────────────────────────────────────┐ │
│ │ 表情      │ │ 配置: [ARKit 52 ▾]  总增益 ━━━━●━━ 1.00   [只看活跃] [搜索…] │ │
│ │ 捏脸      │ │ ── 眼 ──────────────────────────────────────────────────── │ │
│ │ 眼睛      │ │ eyeBlinkLeft     ▇▇▇▇▇▇░░░ 0.62  增益 ━━●━ 1.0  [测试] [⋯] │ │
│ │ 映射编辑  │ │ eyeBlinkRight    ▇▇▇▇▇▇░░░ 0.61  增益 ━━●━ 1.0  [测试] [⋯] │ │
│ │ 预设      │ │ ── 嘴 ──────────────────────────────────────────────────── │ │
│ │ 调试      │ │ jawOpen          ▇▇░░░░░░░ 0.18  …                        │ │
│ └──────────┘ └───────────────────────────────────────────────────────────────┘ │
│ 0.10 ms/帧 · 写入 3 / 跳过 52 · ch03_012_0012 · 55 通道                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

各个页面：

| 页面 | 内容 |
|---|---|
| **表情** | 按部位分组（眼、眉、鼻、嘴、颊、舌、扩展）。每个通道显示：实时数值条、增益、"测试"（强制设为 1）、"⋯"（跳到映射编辑）。可以只显示正在动的通道。 |
| **捏脸** | 按分组排列的滑块，支持搜索、单项重置、整组重置。"编辑模式"开关打开时实时刷新，关闭时固定下来。可以快速存成预设。 |
| **眼睛** | 实时 yaw/pitch 曲线、满权重对应的角度、反转、中立位校准，两组形态键（`EyeLook*` 和 `Look*`）的开关和增益。 |
| **映射编辑** | 选一个通道，编辑它的节点树：加减 fcParam、调系数、调曲线。参数选择器里显示每个 fcParam 的实时数值和已知含义（来自 fcParam 对照表），方便边做表情边找参数。 |
| **预设** | 三类预设（表情配置、捏脸、绑定）的列表，支持保存、另存、覆盖、删除（带确认）、导入、导出、恢复备份。 |
| **调试** | 分阶段计时、扫描信息（脸的数量、被缓存跳过的数量、驱动对象）、活跃 fcParam 列表、日志。 |

交互细节：
- 快捷键可以配置，默认 Home，注意不要和 AVM 冲突。
- 界面缩放，主题色可以调。
- 窗口位置和大小记住在 `settings.json` 里。
- 角色选择器：主角色和名片分身。打开"始终搜索整个场景"后，也会列出联机中的其他猎人。
- 所有修改实时生效，有改动时提示"未保存"。

## 8. 性能目标

| 项目 | 目标 | 现状 |
|---|---|---|
| 每个角色每帧 | < 0.3 ms | 0.10 ms（55 个通道） |
| 平时的完整扫描 | < 2 ms | 1 ms |
| 名片里的完整扫描 | 可接受（名片不在意延迟） | 14 ms |
| 面板绘制 | 只在打开时计算 | — |

如果以后通道数到几百、或者要驱动多个角色，再考虑：
1. 把全场景扫描拆到多帧做。
2. 只把热路径改成原生代码。

## 9. 里程碑

1. **M1 拆模块**（2026-10-08 代码完成，离线模拟测试 41 项通过，待游戏内验证；实现说明见接口文档第 9 节）：把 `ArkitFaceDriver.lua` 拆成 Core 的几个模块；映射表外置成 `profiles/ARKit.json`；加入不区分大小写的匹配和别名表；补上 `jaw*`、`mouthPucker` 的映射。
2. **M2 图层和捏脸**：实现 Layers 和懒加载捏脸、哨兵检测、捏脸预设和绑定预设。暂时先用 imgui 界面。
3. **M3 独立面板**（2026-10-09 第一版代码完成，离线测试通过，待游戏内验证）：d2d 组件库，表情、捏脸、眼睛、预设、调试这几个页面。实现见 `reframework/autorun/ShapeKeySystem_UI/`：
   - `Draw`（d2d 封装：逻辑坐标 × 界面缩放、手动裁剪、字体按需创建、文字测量缓存、图标用图形画）、`Input`（每帧采样点击排队，供 d2d 按更新率取用；悬浮层挡点击）、`Widgets`（按钮、开关、滑块、下拉、折叠标题、文本框、滚动区）、`InputBlocker`（改写自 AVM，MIT 声明保留在文件头）、`Prompt`（所有文本输入的唯一入口，现在是 imgui 小窗）、`Panel`（窗口拖动 / 改大小、左侧导航、提示条、状态栏、自绘光标、热键）、`Page*.lua`（PageBasic、PageSculpt、PageExpression、PageEyes、PagePresets、PageDebug；REFramework 的 require 只认 autorun 下一层目录，不能再分子目录）。
   - 面部图（2026-10-10 改成可换样式）：每种样式 = `data/ShapeKeySystem/faces/<id>.json`（name、size、各部位点击椭圆、images 前缀）+ `images/ShapeKeySystem/faces/<id>/face_lines.png` 和 `face_<brow|eye|cheek|mouth>_<idle|hover|sel|glow>.png`；`ShapeKeySystem_UI/Faces.lua` 在加载脚本时扫描，设置项 `face_style`（默认 chibi，未知值回落到 chibi），在「设置与调试」里切换。内置 chibi（Q 版大头）和 portrait（正常比例）。配色规则：未选中部位和线稿同色，hover 提亮，选中金色带光晕，glow 是中性白光晕且选中部位不叠。d2d 图片不能染色，所以四层都预先生成。生成工具 `tools/face_gen/make_face.py <style.json> <线稿> <reframework 目录>`（style.json 用框/多边形圈出各部位，示例 chibi.json、portrait.json）。
   - 依赖 reframework-d2d（暂用本机 RE Requiem 里 2026-02 的版本）；没有 d2d 时只有 imgui 调试面板。
   - 下一步（用户 2026-10-09 决定）：像 AVM 一样自带一份 d2d 构建，加原生中文输入法，替换 `Prompt` 的后端。
4. **M4 映射编辑器和 MMD 配置**：节点编辑界面，`mul`/`ref`/`curve` 的支持，MMD 配置，角色专属配置的模板。
5. **M5 收尾**：文本输入接 AVM bridge（可选）、多语言、文档、发布打包。

## 10. 未决问题和风险

- **推测的映射**：fcParam 里约 10 个参数的含义是推测的（`003/004`、`049`、`109/110` 等），需要在映射编辑器里实测确认。
- **游戏没有对应信号的通道**：舌头、`jawForward`、`jawLeft/Right` 在 fcParam 里可能根本没有对应（053–056 的数值很小，可能是下巴横移），需要实测。
- **reframework-d2d 依赖**：版本兼容性，以及和其他使用 d2d 的 mod 同时绘制时会不会冲突。
- **输入屏蔽**：做得不好会导致面板操作时游戏也收到点击。
- **形态键量化精度**：捏脸类形态键位移很大，会挤掉同一子网格里表情形态键的精度。需要导出工具配合检查。
- **联机**：其他玩家如果没装同一套 mod mesh，就不会被驱动，这是预期行为。
