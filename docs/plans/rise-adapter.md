# 怪物猎人崛起适配器：现状、方案和实施计划

写给接手的人。适配器接口见 `multi-game-adapter.md`，已经落地的第二个游戏见 `onimusha-adapter.md`（结构和探查方法都可以照搬），
Core 和 UI 的约定见 `shape-key-system-api.md`，仓库工作规则见根目录 `CLAUDE.md` 和 `docs/writing/`。
本文写于 2026-10-15，第 1.1–1.5 节是从解包文件和引擎类型表确认的事实；1.6 节是 2026-10-16 在游戏里实测的结果，第一阶段的最小适配器（第 4 节）据此写成。

## 0. 结论

崛起和荒野、鬼武者的根本区别：**游戏没有形态键驱动骨骼，也没有表情形态键**。面部表情完全是骨骼动画。所以：

- 荒野那套「读驱动骨骼 → 信号字典 → 表情配置」的信号来源，在崛起不存在，需要换成另外两种来源：
  - **程序化信号**：SKS 自己生成眨眼、视线微动、呼吸（与游戏无关，放进 Core，其他游戏也能用）；
  - **骨骼投影信号**：从原版面部骨骼的姿态推算（参考 RE4R-ShapeKey-System 的做法）。
- 写入端除了引擎的形态键权重，还可以有**骨骼编码形态键**：把一个形态键烘焙成 6 根只做平移的辅助骨（崛起狂三 mod 的做法）。
  这条路不依赖网格里的形态键和权重数组。
- 捏脸和预设这部分（只写形态键权重）照常可用，前提是 mod 网格带形态键、引擎允许写。引擎接口是有的（1.3 节），
  实测能写：防具部件里的 mod 头部要先补上权重缓冲区，通道名靠名字表反查（1.6 节）。

推荐顺序：最小适配器（捏脸） → 程序化表情层 → 骨骼编码写入端 → 骨骼投影信号。理由见 4.6 节。

## 1. 已确认的事实（文件和类型表）

### 1.1 原版面部

解包目录 `E:\Program\Steam\steamapps\common\MonsterHunterRise\MHRSB_EXTRACT\natives\stm\`（角色 mesh 已全部解出，另有全部 362 个
jcns、`player/face_mot/`、`player/prefab/mod/face/`；没解的约 3400 个是场景 mesh）。提取脚本 `MHRSB_EXTRACT\_tools\extract_paks.py`，
文件列表 `E:\Data\MODTools\RE9\REE PAK\ree-pak-tools\filelist\MHR_STM.list`。

- **面部骨骼**：玩家脸 `player/mod/face/pl_face000.mesh`、NPC 脸、`m_face408` 都是约 55 根普通变形骨：`Root`、`Spine_01`、`Neck_00`、`Head_00`，
  左右 `Brow_00/01`、`Up/Lo/Corner_Eyelib`、`Eye`、`Make_Eye`、`Nose`、`Cheek_00..02`、`Corner_Mouth`、`Up/Lo_Mouth_00/01`、
  `SmileLine_00/01`、`UnderMouth_00/01`，以及 `Brow`、`Make_Nose`、`Make_Mouth`、`Up_Mouth`、`Lo_Mouth`、`UnderMouth`、`Jaw_00/01`、`Chin`、`Throat`。
  没有 `fcParam_*` / `bsControl_*` 这类挂在 root 下、不蒙皮的控制关节。
- **面部动画**：`player/face_mot/mf_plc_*.motlist.528`（26 个）和过场的 `*_face_p00.motlist.528` 只有上面这些骨骼的骨骼轨道。
- **形态键**：只有 `pl_face000` 带，LOD0 共 56 个，全是捏脸用的（`f__face000..014`、`m_face000..014` 两组预设，
  `nose_*` / `jaw_*` / `chin_*` / `cheek_*` / `lip_*` 的 Plus / Minus）。NPC 脸没有形态键。整个角色 mesh 里其余带形态键的
  只有 61 个头发 mesh（`blend_front` / `top` / `under` / `EX`，按名字看是戴头盔时的贴合）和一个道具。
- **jcns**：362 个 `jcns.21` 共 4393 条约束，`TransformElement` 只有 0 / 1 / 2 / 4（骨骼目标），没有形态键（3）或材质目标。
  面部 prefab（`face_base.pfb` 等）不引用 jcns，引用的是 `PlayerFaceJointMap.jmap`、`PlayerFaceJointLOD.jointlodgroup`、
  `PlayerUserDataCharaMake.user`。
- `Make_Eye`、`Make_Nose`、`Make_Mouth` 按名字看是捏脸骨，**可能改变其他面部骨的静止姿态**，这一点决定骨骼投影能否写死中性姿态（3.3 节）。

### 1.2 崛起狂三 mod（骨骼编码形态键的现成例子）

`E:\Downloads\崛起+狂三+V1.1`，只读过文件，没运行。

- 脸做在 `f_body311.mesh` 里，只挂 `Head_00` 和 `Face_Parts`，没有原版面部骨，网格里没有形态键。
- `Kr_Blink_XP/XN/YP/YN/ZP/ZN` 是 `Head_00` 下的空子骨。`reframework/data/KurumiPhysics/blink.json`（schema 3）
  给每根一个 ±0.0310 m 的单轴偏移，`source_shape` 是 `eye01`。
- 原理：形态键每个顶点的位移拆成 x/y/z 的正负分量，换成这 6 根骨上的蒙皮权重（分量 ÷ 0.031），顶点剩余权重留给 `Head_00`。
  运行时 6 根骨都写 `set_LocalPosition(offset × w)`；只有平移，线性蒙皮算出的位移严格等于 `w × 原形态键`，法线不变。
- `KurumiBlink.lua`：计时器眨眼，每 7–12 秒一次，闭眼 75 ms（smoothstep）、保持 35 ms、睁眼 120 ms；
  `snow.TimeScaleManager:get__Pausing()` 为真时停。写入在 `re.on_application_entry("UpdateMotion")`；
  `re.on_pre_application_entry("PrepareRendering")` 里检查每根辅助骨离 `Head_00` 不超过 `max_world_distance_m`，超出就停用。
- 找玩家：`snow.player.PlayerManager:findMasterPlayer()` → `get_GameObject()` → `get_Transform()`，
  部件是 GameObject 名匹配 `^f_body%d+$` 的子物体。
- 包里还有 `KurumiRuntimeSetup.dll`、`KurumiToon.addon64`、`Install.ps1`，与 SKS 无关，不要运行。

### 1.3 引擎接口（`MonsterHunterRise\il2cpp_dump.json`）

类型表里有 `getBlendShapeChannelName`、`getBlendShapeChannelWeightParam`、`setBlendShapeChannelWeightParam`、
`get/set_BlendShapeChannelWeightCount`、`get_BlendShapeChannelNum`、`get_ChannelNameHash`，Core 的 `Writer.lua` 用到的方法都在。
还有一组捏脸用的 `BlendShapeCheekUp` / `BlendShapeNosePosDown` 之类的名字和 `BlendShapeController` 类型，没细看。
这些只说明方法存在，**签名和行为没有在游戏里调用过**。

### 1.4 参考实现

- [RE4R-ShapeKey-System](https://github.com/Funnyguysmz/RE4R-ShapeKey-System)（MIT）：`data/RE4R_ShapeKeySystem_native_leon.json`
  是骨骼投影表。每个关节记中性姿态（局部位置 + 四元数）和一根标定轴，每帧算相对中性姿态的位移（毫米）或转角（度）投影到轴上，
  再按 `lo` → `hi` 线性映射到 0..1、乘 `gain`，同名 ARKit 键相加。里昂用了 10 个关节、48 条规则；眨眼、眯眼、张嘴、
  下唇、视线由骨骼推算，嘟嘴（pucker / funnel）要靠游戏自己写的修正形态键（崛起没有）。
- 鬼武者适配器（`ShapeKeySystem_Games/Onimusha/`）：最新、最完整的适配器写法，照它的结构写。

### 1.5 崛起的 REFramework 环境

`MonsterHunterRise\reframework\autorun\` 里已经装了 `ArmorVariantManager.lua`（AVM）、`LuaBoneSystem.lua`、`reframework-d2d.lua`、
`EMV Engine` 等。和鬼武者一样，探查用 REFramework.NET 和 WebAPI 插件（`reframework\plugins\source\TestWebAPI.cs`），
本文假定已经装好（2026-10-15 写作时还没装，用户会补装；装好后先用 `reframework_get_game_info` 确认连上的是崛起）。
AVM 共存规则（Delete 热键、共享屏蔽表、不替换 d2d 全局）同样适用。

### 1.6 游戏内实测（2026-10-16）

探针：C# `SksRiseProbe.cs`（层级）和 Lua `reframework\autorun\sks_rise_probe.lua`（名字哈希、写入、烘焙、权重缓冲区），都在游戏目录，
不进仓库，现在都改成 `.off` 停用了。

- **游戏 id 是 `mhrise`**（崛起的 REFramework 编译的就是这个名字；`dinput8.dll` 里的字符串）。
  SKS 部署后在游戏里核对：适配器选中即说明 `get_game_name()` 返回它。
- **主角色**：`snow.player.PlayerManager:findMasterPlayer()`（村里是 `snow.player.PlayerLobbyBase`）→ `get_GameObject()` → `player00`。
  `isReadyPlayerLoad()` / `isReadyPlayerLoadState()` 在村里都是 true，第一阶段拿前者当就绪标志；读盘、换装时是否变 false 还没看。
  PlayerBase 上没有 `IsSetUp` 一类的方法。
- **`player00` 的子物体**（一次实测，装备是 279 号套装、弓）：

  | GameObject | mesh | 形态键 | 备注 |
  |---|---|---|---|
  | `face_base` | `player/mod/face/pl_face000.mesh` | 56 / 56 | 54 个关节，有 `Head_00`、`L_Eye`；组件含 `via.render.BlendShapeController`、`snow.player.PlayerCharaMake`、`snow.player.PlayerFaceMotionChanger` |
  | `f_hair033` | `player/mod/f/hair/f_hair033/...` | 5 / 5 | 有 `BlendShapeController` |
  | `f_arm279` `f_wst279` `f_leg279` `f_helm279` `f_body279` | `player/mod/f/pl279/f_<slot>279.mesh` | 0 | 没有 `BlendShapeController` |
  | `B_Ydt014` `B_Bow014` | `weapon/Bow/...` | 0 | 武器 |
  | `PlHeadMessage` `PlayerLobbySensor` `d_060_p6_pl_voice_f_19` | 无 | | |

  部件名是 `f_/m_` + `arm/body/helm/leg/wst` + 编号，和 1.2 的推测一致；根自己也带一个 `f_shadow.mesh`。
- **通道名**：`getBlendShapeChannelName` 从 C# 调用**会让游戏闪退**（两次），从 Lua 调用不崩但返回空字符串。
  `get_ChannelNameHash()` 能用，但 `get_elements()` 取出的装箱值全是同一个错数，**要用 `get_Item(i)`**，
  56 个哈希全部和 `pl_face000.mesh` 里的名字对上：0–25 是 `blendShape1.cheek_FoS_Plus` … `jaw_Wide_Minus`（捏脸的 Plus / Minus），
  26–35、46–50 是 `m_face000..014`，36–45、51–55 是 `f__face000..014`。这和 RE4R 的情况相同，Core 已有 `hash_item_only` 处理。
- **权重读写**：`getBlendShapeChannelWeightParam` 在下标小于 `get_BlendShapeChannelWeightCount` 时安全（村里的脸有
  `f__face007 = 1`、`nose_Hight_Plus = 1` 等捏脸值）。LateUpdateBehavior 前写入后，同帧之后和下一帧读回都还是写入值，游戏不覆盖。
- **烘焙（原版脸）**：写进去的值读得回，画面却不变。`face_base` 的 `via.render.BlendShapeController` 把形态键结果烘焙住了。
  调 `unfixBlendShapeRate()` 后脸立刻按当前权重显示，之后每次写入都实时生效；**脚本里调 `fixBlendShapeRate()` 会让整张脸消失**。
  第一阶段 SKS 不写原版脸，适配器也就不碰这个组件；以后要驱动 `face_base` 时只能解除、不能重新烘焙。
- **mod 头部**：用户的 mod 头是做在防具部件里的独立头模（这次是 `f_leg279`，663 个通道），部件上没有 `BlendShapeController`。
  - 网格到手时 **`get_BlendShapeChannelWeightCount` 是 0**，但 `get_ChannelWeightList()` 的长度已经是 663。Core 在权重数小于通道数时
    一律不写，所以滑条都没反应。`set_BlendShapeChannelWeightCount(663)` 不崩，之后写入立刻显示，和 RE4R 的身体、头发是同一个问题（D11）。
  - 重启游戏后部件重新生成、没有 `BlendShapeController`，只补权重数也能正常写，所以**不需要加组件**。
  - 通道名：mod 的 663 个名字大多不在 SKS 已知的名字里，显示成 `#XXXXXXXX`。用 `tools/mesh_names.py` 从 mod 的 `.mesh` 生成名字表
    放进 `mods/names/` 后全部反查成功（Blender 场景里 726 个键，导出后网格里留下 663 个）。
    之后加了各游戏共用的内置名字表 `builtin/names/`（VRChat / MMD 模型调查的形态键名）：这个模型除了基型以外的键里，
    约 100 个（含 `----------EYELID----------` 这类分隔键）原来反查不到，加上内置名字表后全部能反查，不再需要 mod 自带名字表。
- **暂停**：`snow.TimeScaleManager:get__Pausing()` 存在，村里读出 false。

## 2. 探查方法

### 2.1 REFramework MCP

用法和鬼武者相同，见 `onimusha-adapter.md` 1.1。用户要先在桌面应用里开启这个 MCP；`get_game_info` 返回 `pipe not connected` 就是没开。

- 先调 `reframework_help`。
- 不需要实例的：`search_types`（3.6 的过场、换装类型先用它按子串找）、`get_type`（字段和方法签名）。
- 需要实例的：`get_singletons`、`chain`（从 `snow.player.PlayerManager` 走到 `findMasterPlayer` 再往下）、`call_method`、`invoke_method`。
- 3.1 的子物体全表、3.2 的形态键数和通道名，大部分可以直接用 `chain` 读，不必写探针。

### 2.2 C# 探针（热重载）

层级遍历、逐帧采样、写入测试用一次性的 C# 探针（只用于探查，正式功能必须是 Lua，见 `CLAUDE.md`）。

- 文件：`MonsterHunterRise\reframework\plugins\source\SksRiseProbe.cs`（在游戏目录，不进仓库），输出写到
  `MonsterHunterRise\reframework\data\sks_rise_probe.txt`。从鬼武者的 `SksOniProbe.cs` 复制改起。
- 流程：改 `.cs` → `reframework_wait_compile` → 读输出文件。保存任何 `.cs` 都会重编译并重新加载所有插件，
  内容没改也想重跑，就往文件末尾追加一行注释。编译错误用 `reframework_get_errors` 看。
- 逐帧采样挂 `LateUpdateBehavior` 的 Post，写入测试挂 Pre，和 SKS 的写入时机一致；对比狂三 mod 的 `UpdateMotion` 时机见 3.5。
- **崛起里不要从 C# 调 `getBlendShapeChannelName`**，会闪退（1.6 节）。探针输出要逐行追加，崩了才知道停在哪。
  有风险的调用做成 Lua 脚本里的按钮（`re.on_draw_ui`），用户点一次只调一次，比 C# 探针每次重编译都自动跑安全。
- 保存 `.cs` 不一定触发重编译（改名为 `.cs` 不触发），追加一行注释最可靠。
- 采固定帧数（如 600 帧）后停止，只记变化量。
- 用户在游戏里观察结果。探针运行前先说明要看什么、持续几秒。

### 2.3 文件分析

- 读解包文件的 Python 用 `python -I`，脚本放 scratchpad，不放进解包目录。
- 通道名哈希是完整名字 UTF-16LE 的 murmur3 x86 32 位，seed 0xFFFFFFFF，参考实现 `tests/mm3ref.py`。
- jcns 解析：`E:\Data\Github\Python\RE-JCNS-Editor\modules\jcns_parser.py`（`sys.path` 指到 `modules` 目录再 import）。

## 3. 待查（按顺序）

1. **游戏 id 和主角色。**（已查，见 1.6；「装配完成」暂用 `isReadyPlayerLoad`，读盘和换装时的值还没看） `Registry.game_name()` 在崛起返回什么（推测 `mhrise`，以实测为准）。
   `snow.player.PlayerManager:findMasterPlayer()` 下的子物体全表：GameObject 名、mesh 路径、形态键数、关节数、有没有 `Head_00`。
   确认玩家脸（`face_base` prefab 生成的物体）叫什么、挂在哪，以及部件名是否都是 `f_/m_` + `arm/body/helm/leg/wst` + 编号。
   再找「装配完成」的标志（相当于荒野的 `IsSetUp`）。
2. **形态键写入。**（已查，见 1.6：mod 部件要补权重缓冲区，名字走 `get_Item` 哈希加名字表；原版脸是烘焙的） 拿一个带形态键的 mod 部件（或原版 `pl_face000` 的捏脸键），确认 `get_BlendShapeChannelWeightCount` 是否等于通道数、
   `getBlendShapeChannelName` 能否读名字、`setBlendShapeChannelWeightParam` 写进去后画面是否变化、同帧后面是否被覆盖
   （捏脸系统可能每帧写回原版脸的键）。一次只写一个明显的键。
3. **捏脸是否改变面部骨的静止姿态。**（部分已查，见 7.1：眼睑、嘴、眉骨的父骨链静止旋转都是单位四元数，捏脸看起来是形态键；没用第二个捏脸存档核对） 换两个差别大的捏脸存档（或在捏脸界面里拖鼻子、眼睛），读 `L_Up_Eyelib`、`Jaw_00` 等骨骼的局部位置和旋转。
   变了就说明中性姿态必须按角色在运行时采集，不能写死在表里。
4. **原版面部动画在 mod 脸上是否还在。**（已查，见 7.1：在，从 `face_base` 读） 原版脸隐藏或被 mod 替换后，面部骨骼是否仍按 motlist 运动（骨骼投影的信号来源是否存在）。
   再看面部骨骼局部值的量级：张嘴、眨眼时 `Jaw_00`、`Up_Eyelib` 的转角和位移各是多少。
5. **辅助骨写入时机。** 在 LateUpdateBehavior 前写 mod 网格里一根辅助骨的 `set_LocalPosition`，画面是否生效、是否晚一帧；
   不生效就改到 `UpdateMotion` 之后（狂三 mod 的时机）。
6. **过场、暂停和换装。** 暂停：`snow.TimeScaleManager:get__Pausing()`。过场管理器和跳过、停止的方法、换装重建的钩子都还没找，
   先用 MCP 的 `search_types` 按子串搜 `snow.eventcut`、`Demo`、`EquipChange` 之类的类型，再用探针在游戏里确认。
   缺钩子也能运行，Core 有轮询兜底（`multi-game-adapter.md` D9）。
7. **眼球。** `L_Eye` / `R_Eye` 的局部旋转是否有视线运动，轴向是否符合 Core 的约定（+yaw = 脸自己的右侧，+pitch = 向上）。
8. **导出工具。** 上游 RE-Mesh-Editor 能读写崛起 mesh（`VERSION_MHRSB`，文件版本 2109148288），能导入形态键；
   能否**导出**带形态键的崛起 mesh 没确认。派生的 RE-Mesh-Editor-BlendShape 是为 RE4R / 荒野做的，同样要确认。
   导不出的话，崛起 mod 作者只能走骨骼编码（第 6 节）。

## 4. 适配器实施计划

### 4.1 文件

```
reframework/autorun/ShapeKeySystem_Games/Rise/Adapter.lua       -- 适配器
reframework/autorun/ShapeKeySystem_Games/Rise/Input.lua         -- 输入屏蔽（可后做）
reframework/data/ShapeKeySystem/builtin/mhrise/signals.json     -- 信号字典（第 7 节）
reframework/data/ShapeKeySystem/builtin/mhrise/face.json        -- face_base 骨骼标定表（第 7 节，tools/rise_calibrate.py 生成）
tests/tests_rise.lua                                            -- 离线检查
```

适配器登记到 `Registry.lua` 的 `R.list`。适配器顶层不调用 sdk，类型查找都放进 `A.init`（D3）。

### 4.2 按接口逐项

| 接口 | 崛起的写法 |
|---|---|
| `id`, `name` | `mhrise`；`"Monster Hunter Rise"` |
| `hash_names`, `hash_item_only` | true：通道名只从 `get_ChannelNameHash` 的 `get_Item` 取（1.6） |
| `scene_search` | false：第一阶段只驱动自己 |
| `init(events)` | 查 `snow.player.PlayerManager`、`via.Transform.getJointByName` 和 `via.render.Mesh` 的权重数读写、`get_ChannelWeightList`、`get_MeshReady`，缺了返回 `false, 原因`；还没挂钩子 |
| `primary_root` | `PlayerManager:findMasterPlayer():get_GameObject():get_Transform()`，全程 pcall |
| `primary_ready` | `findMasterPlayer()` 不为空且 `isReadyPlayerLoad()` 为 true |
| `gate(frame)` | 只看 `primary_ready`，不给 kind。**暂停不关门**：门一关 Core 就把部件清零、放掉 rig，每次打开菜单都会这样 |
| `is_face(tr)` | GameObject 名是 `face_base` 且有 `Head_00`；`face_rank` 同样只给它 1。程序化层不需要脸，见 5.3 |
| `is_part(name)` | `^[fm]_(arm|body|helm|leg|wst)%d+$`。`face_base` 和头发**不算部件**：Core 放手时把部件清零，会抹掉角色的捏脸值和戴头盔时的头发贴合 |
| `prepare_parts(parts)` | 权重数小于通道数、`get_MeshReady` 为 true、`get_ChannelWeightList` 长度够时，把权重数设成通道数（D11，同 RE4R）。每次扫描都检查，部件重建后自动再补 |
| `model_of` / `representative_of` | `f_arm279` → 模型 `f_279`、槽位 `arm`；整套由 `f_body279` 代表。男女同编号是两个模型（9.3） |
| `slot_names` | `arm` 腕甲、`body` 铠甲、`helm` 头盔、`leg` 腿甲、`wst` 腰甲 |
| `eye_joints(face)` | 第一阶段返回空表；`{ L = L_Eye, R = R_Eye }` 等 3.7 确认后再给 |
| `raw` / `bind` / `read` | Core `BoneSignals`，标定表 `builtin/mhrise/face.json`，绑定在 `face_base` 上（第 7 节） |
| `input` | 先不给（面板打开时游戏照常收输入）；之后参照 Wilds / Onimusha 的 `Input.lua` |
| `conditions` | 先不给；之后用通用 id（`hp_pct`、`dead`、`combat`）实现 |

### 4.3 Core 需要补的能力

`multi-game-adapter.md` 2.1 设计了 `caps`，但 Core 现在还没有读 `caps` 的代码（2026-10-15 检查：Core 和 UI 里没有 `caps.`）。
荒野和鬼武者都有驱动骨骼，所以一直没用上。崛起是第一个需要降级路径的游戏：

- 适配器没有 `A.raw` 时：表情 rig 不读游戏信号，表情页显示「本游戏目前暂不支持表情」，捏脸、预设、外部 API 照常。
  `Expression.read` 已经是 `if A.read then ... end`，要再查 `Profile.lua:42,177`、`API.lua:229,416,2077` 这几处在 `raw` 为 nil 时是否会出错。
- 先用接口是否存在来判断（`A.raw == nil`），等第二种降级需求出现再引入 `caps` 表，避免现在就定一张用不全的表。
- 2026-10-16 检查结果：上面几处在 `raw` 为 nil 时都不会出错（`Profile.load_signals` 把所有信号标成无信号，`p` 节点报「本游戏没有原始通道」，
  `bind_raw` 和 `X.read` 跳过）；`tests_fake.lua` 的假适配器早就在没有 `raw` 的情况下跑捏脸和预设。
  补上的只有界面提示：`SKS.init` 设 `state.expression.no_signals = (A.raw == nil)`，「表情」和「表情详情」两页顶部显示「本游戏目前暂不支持表情」。

### 4.4 第一阶段的验收

状态（2026-10-16）：已在游戏里验收。用户的 mod 头部（`f_leg279`）配上名字表后，捏脸滑条全部识别、拖动立即生效，重启游戏后仍然正常。
预设保存和套用、换装后重新找到部件还没专门测。

主角色在场时，SKS 找到所有部件，捏脸滑条能改 mod 部件的形态键，预设能保存和套用，换装后能重新找到部件。
荒野和鬼武者的离线检查结果不变。

### 4.5 文档同步

- `multi-game-adapter.md` 第 3 节末尾和第 8 节写的是「崛起……先只声明 `caps.expression = false`」「只需要 2.2、2.5 和 2.8」，
  按本文的方案更新，并把本文加进引用。
- `shape-key-system-api.md`：新增程序化层的设置项和骨骼编码绑定文件时同步。

### 4.6 顺序和理由

1. **最小适配器**（第 4 节）：验证找角色、找部件、写形态键这条最短路径，也补上 Core 的降级路径。
2. **程序化表情层**（第 5 节）：与游戏无关，做完后崛起马上就有会眨眼、会看人的脸，鬼武者和荒野也能用来补游戏没给的信号。
3. **骨骼编码写入端**（第 6 节）：如果 3.8 证明崛起导不出形态键，这是 mod 作者能用的唯一写入方式；要和 Blender 导出工具一起做。
4. **骨骼投影信号**（第 7 节）：工作量最大，依赖 3.3、3.4 的结果，且只对仍蒙皮到原版面部骨的脸有意义。

## 5. 程序化表情层（Core，跨游戏）

### 5.1 目标

在没有游戏信号（或信号不全）时，由 SKS 生成一组通用信号，输出的信号名和信号字典相同（`blink.L`、`blink.R`、视线 yaw / pitch 等），
所以内置的 ARKit / MMD / VRC 配置不用改就能驱动。

### 5.2 生成器

- **眨眼**：间隔随机，偶尔连眨两次；单次曲线分闭眼、保持、睁眼三段。初值参考狂三 mod（7–12 s，75 / 35 / 120 ms，smoothstep），
  参数全部可调。左右眼同步，可设很小的不对称。
- **视线微动**：在中立位附近按随机间隔做小幅跳动（saccade），跳动之间保持。有游戏眼球信号时不启用。
- **呼吸 / 闲置**：低频、小幅的周期运动，作用于少数通道（如嘴、鼻翼），默认关闭。

参数（间隔分布、各段时长、幅度、不对称、噪声）可以参考荒野原版表情的统计规律来定。做法是在本地解析荒野面部 motlist，
统计眨眼时长分布、通道共激活关系、常用幅度区间，结论写成文档。**原始曲线只留在本地做研究，不进仓库和发布包**，
仓库里只放统计结论和自己写的生成参数。

### 5.3 和游戏信号的合成

- 每个通用信号的值 = 游戏信号（有的话） 与 程序化信号 按设置合成：「仅游戏」「游戏缺失时用程序化」「叠加」。
  默认「游戏缺失时用程序化」：荒野、鬼武者行为不变，崛起全部由程序化提供。
- 程序化层不依赖脸物体；游戏没有脸（`is_face` 找不到）时，表情 rig 也要能只靠程序化信号运行。这是 Core 现有 rig 模型
  （先找脸、再 `A.bind`）要改的地方，动手前先读 `Scene.lua` 和 `API.lua` 里 rig 的建立过程。
- 游戏暂停时（`gate` 不通过）生成器的时钟停止。

### 5.4 界面

表情页加一个「自动表情」区：总开关、合成方式、眨眼频率和速度、视线微动幅度。设置存 `settings.json`。

### 5.5 实现（2026-10-16，眨眼、视线微动、微微张嘴）

- `ShapeKeySystem_Core/Procedural.lua` 生成 `blink.L` / `blink.R`：基础间隔 7–12 秒（默认频率 2 倍，实际 3.5–6 秒），15% 的概率连眨两次（间隔 0.1 秒），闭眼 / 保持 / 睁眼 75 / 35 / 120 ms，
  smoothstep；参数全部在 `settings.json` 的 `procedural` 里，界面调频率（间隔除以它）和速度（各段时长除以它）。随机数用自带的 LCG，测试固定种子。
- 合成在 `Profile` 编译信号节点时完成（`Procedural.merge`），表情配置不用改；格式和三种模式见 `shape-key-system-api.md`「自动表情」。
- 「缺失」的判断：字典没有原始通道，或适配器的 `procedural` 表列出了这一组。崛起的 `blink.L` / `blink.R` 有骨骼标定（只跟表情姿态里的眼睑），
  所以崛起适配器写 `procedural = { blink = true }`，默认的 `fallback` 取 max(骨骼, 生成)：待机自动眨眼，表情姿态的闭眼照样保留。
  荒野、鬼武者、RE4R 不写，默认模式下行为不变，选「叠加」才会额外眨眼。
- 视线微动：每 0.8–2.5 秒在 ±3°（垂直 ±1.8°）内跳一次，跳动 50 ms，30% 的概率回正前方。崛起 `eye_joints` 返回空表，视线缺失，
  默认模式下直接驱动视线通道（网格有 `eyeLook*` 之类的视线键时才看得到）。
- 微微张嘴：每 7–12 秒 `jawOpen` 升到 0.1、保持、回落（1.2 / 0.4 / 1.6 秒）。崛起骨骼的待机呼吸低于 `jawOpen` 的 `lo`，适配器写
  `procedural = { blink = true, breath = true }`，默认模式取 max(骨骼, 生成)，手势的张嘴照样保留。原第 5.2 节的「呼吸 / 闲置」只做了这一项。
- 时钟：`API.tick` 只在门打开、即将驱动角色时调用 `Procedural.tick`；跳过的帧使下一步长为 0，暂停、读盘、不驱动的过场期间不计时。
- 离线检查：`tests_procedural.lua`（曲线、频率和速度、不对称、固定种子的眨眼时间、连眨不连三次、视线幅度和停顿、张嘴幅度和间隔、
  视线偏移不累加、三种合成、跳帧停表、荒野三种模式），`tests_rise.lua`（崛起默认模式下 mod 头自己眨眼和张嘴、门关闭时停表、恢复后不跳）、
  `tests_ui.lua`（自动表情区）。
- 未做：没有脸物体时只靠程序化信号建 rig（5.3 第二条）。崛起有 `face_base`，不受影响。所有角色共用一个时钟，预览角色和主角色同时眨眼。

## 6. 骨骼编码写入端

### 6.1 原理和限制

一个形态键 = 若干根挂在同一父骨（通常是 `Head_00`）下、静止时为单位变换的辅助骨，每根只沿一个轴平移。写权重 w 就是把每根辅助骨的
局部位置设为 `offset × w`。

- 每个键 6 根骨；每个顶点每个键占 1–3 个权重槽（每个轴只用正负中的一根）。RE 网格每个顶点最多 8 个权重槽，
  所以同一个顶点上大约只能叠 2 个键。
- 只有顶点只蒙皮到辅助骨的父骨时才精确；蒙皮到多根骨（如眼睑骨）的顶点会出错。
- 每个顶点的位移分量之和不能超过 `offset`（权重和不能超过 1），`offset` 取该键的最大位移。
- 法线不随形态键变化。卡通渲染的脸通常可以接受，写实脸可能看得出来。

结论：适合眨眼、张嘴、微笑等少数几个关键键，做不了 52 个 ARKit 键。

### 6.2 绑定文件

mod 随附一份描述，和狂三的 `blink.json` 类似但支持多个键，放在 SKS 的 mod 数据目录（`mods/`，具体位置按 API 文档的绑定规则定）：

```json
{ "schema": "sks.bonekeys/1",
  "parent": "Head_00",
  "keys": [
    { "name": "eye_close", "offset": 0.031,
      "helpers": { "XP": "Kr_Blink_XP", "XN": "Kr_Blink_XN", "YP": "Kr_Blink_YP",
                   "YN": "Kr_Blink_YN", "ZP": "Kr_Blink_ZP", "ZN": "Kr_Blink_ZN" } }
  ] }
```

键名和普通形态键一样参与表情配置和捏脸（同一个名字空间），Writer 按键的类型选择写形态键权重还是写辅助骨。

### 6.3 Writer 的改动

- `Writer.write_target` 现在只写 `setBlendShapeChannelWeightParam`。增加一种目标类型：一个键对应 6 个关节，
  写入时对每个关节调用 `set_LocalPosition`（传入的分量要是浮点数，`v + 0.0`），照样只写变化的键。
- 关节引用和网格引用一样受 `Guard.lua` 管理：部件重建、过场切换时放掉，不跨重建持有。
- 安全检查参照狂三 mod：辅助骨的世界位置离父骨超过 `offset` 的若干倍时停写并报告。
- 写入时机按 3.5 的结果决定。

### 6.4 导出工具

把形态键烘焙成辅助骨和蒙皮权重属于 Blender 导出端，不在 SKS 仓库做。可以交给 RE-Mesh-Editor-BlendShape 那边的会话，
本文 6.1 的约束和 6.2 的格式就是双方的接口。

## 7. 骨骼投影信号

### 7.1 游戏内实测（2026-10-16）

探针 `reframework\autorun\sks_rise_bones.lua`（游戏目录，不进仓库；只读，按钮触发）：列出 `player00` 每个子物体的关节表，
逐帧录制 `face_base` 全部关节和其他部件同名关节的局部姿态，以及面部 `via.motion.Motion` 的动作层。录制 CSV 只留在本地。

- **信号来源存在（3.4）。** mod 套装（279 号，mod 头在 `f_leg279`）上 `face_base` 是隐藏的（`get_Draw` 为 false；脚本里 `set_Draw(true)`
  会被游戏改回去），但它的 54 个关节照样按面部动作运动：做手势时 `Jaw_00` 转 13°，嘴角动约 9 mm，和原版套装上同一个手势的数值相同。
- **mod 部件没有原版面部骨。** `f_leg279` 的 79 个关节和 `face_base` 同名的只有 `Root`、`Spine_01`、`Neck_00`、`Head_00`，
  其他部件同样。所以信号只能从 `face_base` 读，再驱动 mod 头的形态键；mod 头里蒙皮到自己骨骼的顶点不跟着动。
- **动作层。** 层 1、层 2 在待机时是 bank 12 的 30 号和 1 号，嘴部有约 3 秒一周期的呼吸循环（1–2 mm）。手势时两层每 0.3–0.5 秒切到
  bank 12 的 140–146 号之一并停在第 0.5 帧：7 个离散口型轮流出现，不是连续曲线。
- **玩家脸从不眨眼。** 原版套装和 mod 套装上待机都没有眨眼（用户目视确认），眼睑只在个别表情姿态里动。眨眼只能由程序化层生成（第 5 节）。
- **量级。** `Jaw_00` 绕局部 x 最大 13°；上眼睑最多 7.8 mm（单侧的表情姿态）；下眼睑 3 mm；嘴角 9–17 mm；眉骨 1.3–2.8 mm；
  `L_Eye` / `R_Eye` 最多 4–7°。
- **坐标（3.3 相关）。** `face_base` 各骨骼父骨链的静止旋转都是单位四元数，局部轴与 `Head_00` 一致：+x 角色左、+y 上、+z 前。
  眼睑和眼球挂在 `L/R_Make_Eye` 下，嘴部骨挂在 `Make_Mouth` / `Jaw_01` 下。捏脸用的是 56 个形态键，`Make_*` 的作用没有用第二个捏脸存档核对，
  标定表暂时写死中立位。

### 7.2 实现

- **Core `BoneSignals`（#21）。** 从 RE4R 的 `Signals.lua` 搬出与游戏无关的部分：`measure`（位移按毫米、旋转按四元数对数换成度，投影到标定轴）、
  规则求值（`lo` / `hi` 归一化、限幅、乘增益，同名键相加再限幅，`fallback` 规则只补主规则没给出的键）、标定表校验、按名字绑定关节、关节快照。
  输出键是 ARKit 52 个名字，`raw` 和 RE4R 相同。RE4R 保留 `crct_*` 原生通道、通道保护和按角色选表，通过 `source` 回调把原生通道值交给 `evaluate`。
  核对：在 leon.json / ada.json 上用 2000 组随机姿态比较搬迁前后的 `S.read`，20.8 万个输出（其中 3.9 万个非零）差值全为 0；RE4R 离线检查 58 条全部通过。
- **崛起适配器。** `raw = BoneSignals.raw`，`bind` 在 `face_base` 上按 `face.json` 找关节，`read = BoneSignals.read`。
  `native_snapshot` 记下 `face_base` 的 46 个面部关节、各规则的测量值和输出、动作层 1 的 `bank/id`（字段 `motion`），
  所以「设置与调试」页的「原生信号诊断与录制」可以直接录标定数据。
- **信号字典。** `builtin/mhrise/signals.json` 沿用 RE4R 字典的 63 个通用信号名（D6），通用名到 ARKit 键的对应也相同；标定表里没有规则的键写 `"raw": null`。
  现在有 25 个信号可用。

### 7.3 标定

`tools/rise_calibrate.py` 从录制生成 `face.json` 和 `signals.json`，不手调。每条规则只指定 ARKit 键、骨骼、种类和语义方向（例如上眼睑「向下」），其余由数据决定：

- 中立位：待机帧（全程待机的录制，或动作层 1 为 12/30、12/1 的帧）逐分量取中位数；
- 标定轴：超出待机范围、且与语义方向夹角小于 60° 的帧的平均位移；
- `lo`：待机帧的最大投影（呼吸循环不会触发键）；`hi`：所有帧的最大投影；
- 左右成对的规则共用两侧较大的 `lo` / `hi`（单侧眨眼的姿态不会让另一侧提前到 1）；方向帧少于 30 帧或范围太小的规则成对删除。

```
python -I tools/rise_calibrate.py --idle <待机录制> <动作录制...> -o reframework/data/ShapeKeySystem/builtin/mhrise/face.json \
    --signals reframework/data/ShapeKeySystem/builtin/re4/signals.json reframework/data/ShapeKeySystem/builtin/mhrise/signals.json
```

当前的表来自 2026-10-16 的 4 段探针录制（2 段待机、2 段手势，一个角色）。可用的键：眨眼、眯眼、内眉上扬、眉毛下压、外眉上扬、皱鼻、眯颊、张嘴、
嘴角上扬、嘴角下拉、嘟嘴（嘴角向内向前）、上唇上提、下唇下拉。没有数据的键：睁大眼（录制里上眼睑没有向上动）、嘴角横向拉伸（只有单侧凑够了帧）、
抿嘴、卷唇、鼓腮、舌头。

### 7.4 限制和后续

- 信号只覆盖游戏里出现过的面部动作：待机的嘴部呼吸、手势的 7 个口型，以及录制没碰到的受击、发力表情。录更多种动作后重跑脚本即可补全。
- 眨眼、待机张嘴和视线微动由第 5 节的程序化层提供（5.5）；游戏视线（3.7）还是 `eye_joints` 返回空表，眼球转角没有进标定表。
- 口型是离散切换，信号会跳变；需要平滑的话在 Core 的表情读数上加，不改标定表。

### 7.5 验收

部署到崛起后，在 mod 头上选一份通道名能对上的表情配置（ARKit / MMD / 用户配置），做会张嘴的手势，mod 头应当跟着张嘴、嘴角动、眉毛动；
骨骼信号本身在待机时不眨眼，眨眼来自程序化层（5.5）。状态（2026-10-16）：已在游戏里验收，mod 头（`f_leg279`）随手势张嘴、动嘴角和眉毛；荒野回归正常。

## 8. 测试和部署

- 离线：`cd tests; python run.py`。基线以当时的结果为准（2026-10-16：FAILS 2、TOUCH FAILS 1、PREVIEW FAILS 1，其余 0；
  RE4R 那组补上过场类型后能跑完，0 失败）。
  新适配器自动进入 `tests_games.lua` 的检查：加载时不调 sdk、Core / UI 代码不出现游戏专属名、内置配置都能编译。
  Core / UI 里同样不能出现 `snow.`（已加进 `tests_games.lua` 的 token 扫描）。
- 程序化层和骨骼编码写入端是 Core 功能，要在 `tests_*.lua` 里加检查：生成器在固定随机种子下的输出、合成方式、Writer 的辅助骨目标。
- 部署到崛起：
  `SKS_GAME_REFRAMEWORK='E:\Program\Steam\steamapps\common\MonsterHunterRise\reframework' powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy.ps1`，
  先加 `-Check`。部署不碰 `user/`、`mods/`、`settings.json`。
- 每次改了 Core，也部署到荒野（和鬼武者）让用户回归。
- 提交按 `docs/writing/commit_guideline.md`。不要提交 `README.md`（用户自己的改动）和 `skills/`。用户在游戏里测过再提交。

## 9. 未决问题

1. 程序化层放在 Core 里作为每个游戏都有的功能，还是做成一个可选的「信号来源」插件？本文按前者写。
2. 骨骼编码的键和普通形态键共用名字空间，同名时谁优先？建议同一个部件里不允许同名，加载时报错。
3. 崛起男女两套部件（`f_` / `m_`）同编号，绑定是否按性别分开？按 3.1 的实测结果定。
4. 狂三 mod 自带的 `KurumiBlink.lua` 和 SKS 同时驱动同一组辅助骨会互相覆盖。SKS 只驱动在自己绑定文件里声明的辅助骨，
   用户要自己关掉 mod 自带的脚本；是否需要检测并提示，等实际遇到再定。
