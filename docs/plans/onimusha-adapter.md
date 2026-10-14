# 鬼武者·剑之道适配器：探查方法和实施计划（#7）

写给接手的人。适配器接口见 `multi-game-adapter.md`，Core 和 UI 的约定见 `shape-key-system-api.md`，仓库工作规则见
根目录 `CLAUDE.md` 和 `docs/writing/`。本文写于 2026-10-14，记录已经实测确认的事实、实现了什么、还没查的问题和怎么查。

## 0. 现状

已实现（`ShapeKeySystem_Games/Onimusha/`，已在游戏里试过）：

- 游戏 id `onimusha_wots`（`get_game_name()` 的点调用和冒号调用都返回它）。
- 找主角色、脸和部件；通道名靠哈希反查（`NameHash.lua`）。
- `bsControl` 信号（`raw` / `bind` / `read`）和信号字典 `builtin/onimusha_wots/signals.json`：63 个通用信号里 47 个有映射、
  16 个无信号，近似映射标 `guessed`，`full = 0.01`。字典由 `tools/onimusha_signals.py` 从原版 v36 jcns 生成，
  需要 RE-JCNS-Editor 的 modules 路径和显式 `--full`。
- 眼球 `eye_Lt` / `eye_Rt`，用 Core 的角度换算。
- 过场：播放中由 Core 的过场驱动接管（副本 `Pl000_00`，脸 `ch001_00_10_event`），加载中不碰；
  跳过、停止、unload、分段开始用和荒野同名的 `DemoMediator` 钩子。
- 换装检测：部件名换装后不变，`A.child_tag` 把各部件的 mesh 地址拼进 Core 的子节点签名。
- 绑定：所有部件归到一个模型 `musashi`，整个角色用 `<src>/musashi/musashi.json`，单个部件需要时再用
  `<src>/musashi/Head.json`。
- 输入屏蔽（`Onimusha/Input.lua`）：面板打开时借用原生光标控制器 `app.GUI090000` 的菜单优先级让鼠标自由，
  并固定相机旋转；关闭和重载时恢复。

用户的测试数据在游戏目录，不进仓库：`mods/names/`（测试 mod 的名字表）、`mods/sculpt/ShinanoOC.json`、
`mods/profiles/ShinanoOC_Onimusha.json`、`mods/default.json`。

还没做或待确认的见第 3 节。路径：游戏 `E:\Program\Steam\steamapps\common\OnimushaWotS`；原版解包
`OnimushaWotS\EXTRACT\natives\stm\`（角色 mesh、jcns、部分 talk motlist）；用户的测试 mod 在 `OnimushaWotS\natives\stm\`。

## 1. 探查方法

### 1.1 REFramework MCP

游戏里装了 REFramework.NET 和 WebAPI 插件（`reframework\plugins\source\TestWebAPI.cs`），Claude Code 通过
`mcp__reframework__*` 工具直接读游戏。用户要先在桌面应用里开启这个 MCP；`get_game_info` 返回 `pipe not connected`
就是没开。

- 先调 `reframework_help`，里面有工具用法和坑。
- 不需要实例的：`search_types`（按子串找类型）、`get_type`（字段和方法签名，`noFields` 省篇幅）。
- 需要实例的：`get_singletons`、`chain`（从单例走方法 / 字段，最后用 `collect` 读值）、`call_method`、`invoke_method`。
- `chain` 只能展开真正的 `T[]`，`List` 之类要先走到内部数组字段。

已经用这些工具查到的入口：`app.PlayerManager`、`app.DemoMediator`、`app.PauseManager` 都是托管单例。

### 1.2 C# 探针（热重载）

层级遍历、逐帧采样、写入测试这类事用一次性的 C# 探针做（只用于探查，正式功能必须是 Lua，见 `CLAUDE.md`）。

- 文件：`OnimushaWotS\reframework\plugins\source\SksOniProbe.cs`（在游戏目录，不进仓库）。输出写到
  `OnimushaWotS\reframework\data\sks_oni_probe.txt`。
- 流程：改 `.cs` → `reframework_wait_compile` → 读输出文件。保存任何 `.cs` 都会重编译并重新加载**所有**插件，
  没改内容也想重跑，就往文件末尾追加一行注释。编译错误用 `reframework_get_errors` 看。
- 探针在加载后的第一个 `UpdateBehavior` 跑一次；标题画面没有玩家，会报错退出，进游戏后再触发一次。
- 逐帧采样挂 `LateUpdateBehavior` 的 Post，写入测试挂 Pre（和 SKS 写入的时机一致）。
- 现在的探针包含：玩家层级（每个子物体的 mesh、形态键数、关节数、有没有 bsControl / eye_Lt）、每个 mesh 的
  名字哈希和当前权重、Head 的关节名、全场景带 bsControl 的 Motion、600 帧的权重和关节变化幅度、
  一个默认关闭的写入测试（`OnLateWrite` 开头的 `if (true || ...)`）。
- 在 C# 里用 heredoc 生成代码时，`\n` 会被展开成真换行，导致字符串常量断开；换行用 `Environment.NewLine`。

### 1.3 名字哈希对照

运行时读不到通道名，要对照文件确认哈希时：

- 哈希是完整通道名 UTF-16LE 的 murmur3 x86 32 位，seed 0xFFFFFFFF。Python 参考实现在 `tests/mm3ref.py`。
- 做法：把 mesh 文件按 `\0` 切开，能按 UTF-8 解码的片段都算一遍哈希，和探针输出的 `#XXXXXXXX` 对照。
  名字可能带空格、括号、非 ASCII 字符，别用 `[A-Za-z0-9_]` 这种正则抽字符串。
- 读解包文件的 Python 用 `python -I`，脚本放 scratchpad，不放进解包目录。

### 1.4 测试时的注意事项

- **头部 mod 必须带 blendshape。** 用户之前的头部 mod 没有形态键，`Head` 上的 bsControl 关节随之消失，通道数读出来是 0，
  看起来像引擎不支持。测试用原版或带形态键的 mod。
- 原版脸的形态键是叠在骨骼动画上的修正形状，最大位移约 2 mm，权重写到 10 肉眼也几乎看不出。
  验证写入是否生效，要用 mod 头部上明显的形状（如 `eye_close`、`mouth_a1`），一次只写一个。
- 用户在游戏里观察结果，探针运行前先告诉用户要看什么、持续几秒。

## 2. 已确认的事实

### 2.1 角色和部件

- 主角色：`app.PlayerManager:getControllingPlayer()`（`app.cPlayerManageInfo`）→ `get_Object()` → `Player_00`。
  就绪：`PlayerManager:isPlayerReady(false)`，`getControllingPlayer():get_Valid()` / `get_CharacterValid()`。
- `Player_00` 的子物体（按 GameObject 名）：`Head`（脸，带 mesh，`Hair` 挂在它下面）、`Body`、`Cloak`、
  `Gauntlet`、`Amulet`，以及隐藏的 `OniHead` / `OniBody` / `OniHair`（鬼化形态，平时 `DrawSelf = false`）、
  `Gm800_*`（武器道具）、碰撞体和特效节点。
- mesh 资源路径可读：`getComponent(via.render.Mesh):getMesh():get_ResourcePath()`，例如 `Head` →
  `Art/Model/Character/ch0/ch001_00/10/ch001_00_10.mesh`，`Body` → `.../ch001_00/00/ch001_00_00.mesh`。
- NPC：有名字的 NPC（ch002、ch003，脸的 GameObject 叫 `10`，父物体 `Npc002_00`）有完整的 136 个 bsControl 和 403 个形态键；
  路人 NPC（ch200、ch210）只有 12 个 bsControl、没有形态键。

### 2.2 驱动信号

- `Head` 的关节里有 `bsControl_000..135`（父关节 root，静止位置在原点）。普通游玩中局部位置的 x/y/z 都会变，
  幅度 0.001~0.01，例如待机时 `bsControl_000 = (0.0095, 0.0095, 0)`。
- 原版待机时 261 个形态键里有 84 个非零，说明游戏在玩法中也在驱动表情。链路（解包文件分析）：
  motlist 把 bsControl 当骨骼轨道做动画 → `ch001_00_10_wrinkledriver_03.jcns.36` 把每个关节的每个轴映射到一个形态键
  或一个皱纹材质参数 → 形态键。例：`bsControl_000` 的 x/y/z → `browLowerer_R` / `browLowerer_L` / `cheekPuff_R`。
- 用户自己做的 mod 头部用的是荒野那套形态键名（ARKit、MMD 风格），和 jcns 对不上，**游戏不会驱动它们**，
  要由 SKS 读 bsControl 再按表情配置写上去。这就是荒野 fcParam 那套做法。
- 眼球：`eye_Lt` / `eye_Rt` 的局部欧拉角在转（10 秒内约 0.6~1.1 弧度）。另有 `L_Eye` / `R_Eye`，用途没查。
- `Head` 上的组件有 `app.FacialController`（表情 / 口型层）、`via.motion.JointExprGraph`、`via.motion.JointConstraints`。

### 2.3 通道名

- 这个游戏的 `via.render.Mesh` **没有 `getBlendShapeChannelName`**（301 个方法里没有，按签名调用返回 null）。
  只有 `get_BlendShapeChannelNum`、权重读写和 `get_ChannelNameHash()`（`System.UInt32[]`）。
- 原版通道名带前缀，而且每个 mesh 不同：主角 `blendShape1503.browLowerer_R`，有名字的 NPC
  `HeadCorrectives_blendShape.*`，`ch033_00_50` 是 `HeadCorrectives_blendShape_HeadSkinned2.*`。
- 用户的 mod 不带前缀，Head 141 个、Body 29 个通道全部按原名反查成功。
- Core 的处理：引擎缺这个方法时，`Scene` 改从哈希反查（`NameHash.lua`，API 文档第 8 节的 `names/`）。
  REF Lua 里数组和 `get_elements()` 返回的容器都是 userdata，元素也是 userdata，`ToString()` 得到十进制整数。

### 2.4 写入

- `setBlendShapeChannelWeightParam(idx, v)` 写进去能读回来（Pre LateUpdate 写 1 和 10 都读回原值）。
  画面上看不出变化，原因见 1.4，没有排除「游戏在同一帧后面又覆盖了」。

## 3. 待查和待确认

1. **写入是否被覆盖。** 打开探针的写入测试，只写 mod 头部的一个明显形状（如 `eye_close`），Pre 写 1、同帧 Post 读回，
   再让用户看画面。读回不是 1 或画面不变，就要找更晚的写入时机（`re.on_application_entry` 各阶段，或
   `app.FacialController.lateUpdate` 之后）。目前自动表情画面正常，这一项优先级低。
2. **大表情的满值。** jcns 把局部位置 0..1 映射到权重 0..1；待机采样里眨眼峰值约 0.0096，所以 `full = 0.01`。
   说话、受击、过场的张嘴等轴还没采样，不能由待机推断。
3. **换装和鬼化。** `child_tag` 能发现 mesh 被换掉，但还没在游戏里换过装。再看换装时 `PlayerManager.changePlayerModel`
   之类的方法是否触发、是否值得挂成 `events.rebuilt`（让 Core 立即放手，不用等 5 帧一次的签名检查）。
   鬼化形态（`OniHead` / `OniBody`）目前不驱动。
4. **暂停和菜单。** `app.PauseManager:get_IsPaused()`，以及打开菜单、回标题时玩家对象是否还在。
5. **眼球方向。** Core 的约定是 +yaw = 脸自己的右侧、+pitch = 向上；画面上的方向还没核对。记忆
   `sks-gaze-yaw-convention` 写的是 yaw +1 = 角色的左边，和代码注释矛盾，核对时一并确认哪个对。
6. **输入屏蔽的副作用。** 只借用光标控制器的优先级、固定相机旋转，没改命令掩码、鼠标操纵模式和原始输入缓存。
   面板打开时角色是否仍会响应键盘、手柄，还没系统测过。

## 4. 适配器实施计划

### 4.1 文件

```
reframework/autorun/ShapeKeySystem_Games/Onimusha/Adapter.lua      -- 适配器
reframework/autorun/ShapeKeySystem_Games/Onimusha/Input.lua        -- 输入屏蔽
reframework/data/ShapeKeySystem/builtin/onimusha_wots/signals.json -- 信号字典
tools/onimusha_signals.py                                          -- 从原版 jcns 生成字典
tests/tests_onimusha.lua                                           -- 独立运行环境里的离线检查
```

适配器登记在 `Registry.lua` 的 `R.list`。条件（`Conditions.lua`）和只属于这个游戏的配置（`builtin/onimusha_wots/profiles/`）还没有。

### 4.2 按接口逐项（`multi-game-adapter.md` 第 2 节）

| 接口 | 鬼武者的写法 |
|---|---|
| `id`, `name` | `onimusha_wots`；`"Onimusha: Way of the Sword"` |
| `init(events)` | 查必需的类型和方法，缺了返回 `false, 原因`；挂 `DemoMediator` 的过场钩子 |
| `primary_root` | `PlayerManager:getControllingPlayer():get_Object():get_Transform()`，全程 pcall |
| `primary_ready` | `isPlayerReady(false)`，且 `getControllingPlayer()` 的 `get_Valid` / `get_CharacterValid` |
| `gate(frame)` | 过场加载 → `"load"`；过场播放 → `"playing"`（交给 Core 的过场驱动）；玩家没就绪 → 不碰，不给 kind |
| `is_face(tr)` | 有 `bsControl_000`，且 mesh 路径含 `/ch001_`（NPC 的头也有 bsControl） |
| `face_rank(tr)` | GameObject 名是 `Head` 给 1，其余 0 |
| `is_part(name)` | `Head`、`Body`、`Cloak`、`Gauntlet`、`Amulet`，或过场副本按 mesh 命名的 `ch001_NN_NN*` |
| `child_tag(tr, name)` | 部件的 mesh 地址，见 4.3 |
| `eye_joints(face)` | `{ L = eye_Lt, R = eye_Rt }` |
| `raw` | `term = "bsControl"`；key = 关节号 × 3 + 轴（x=0、y=1、z=2）；`parse` 接受 `"bsControl_012.y"` 和 `"012.y"`；不给 `slider` |
| `bind` / `read` | 按 key 找 `bsControl_%03d`，每帧取 `get_LocalPosition()` 的对应轴乘 `inv_full` |
| `model_of` / `representative_of` / `slot_names` | 所有部件归 `musashi`，见 4.3 |
| `input` | `Onimusha/Input.lua` |
| `conditions`, `probe`, `model_names` | 不给 |

### 4.3 部件 id 和换装（2026-10-14 定）

Core 用子物体的 GameObject 名当部件 id。荒野的名字是 `ch03_012_0012` 这种装备编号；鬼武者是固定的 `Head` / `Body`，
换装后名字不变。由此有两个问题，都在适配器里解决，Core 只加了一个可选接口：

- **绑定按角色，不按部件。** `model_of` 把主角的所有部件归到 `musashi`，`representative_of` 也返回 `musashi`，
  所以整个角色共用 `<src>/musashi/musashi.json`，捏脸预设放 `<src>/musashi/sculpt/`。不直接把部件 id 改成同一个：
  Core 按部件 id 去重，Body 会被当成重复项丢掉。换装后的旧 mod 文件靠指纹排除。
- **换装检测。** Core 每 5 帧比较一次主角色子节点的签名，签名原本只有名字。新增可选的 `A.child_tag(tr, name)`，
  返回的字符串拼在名字后面；鬼武者返回部件 mesh 的地址，mesh 重建后地址变了，Core 就放手重扫。

如果以后要按服装区分绑定，可以把 mesh 路径里的 `ch001_00` / `ch001_50` 作为模型的下一层，现在不做。

### 4.4 信号字典

`builtin/<game id>/signals.json`（`sks.signals/2`）把语义信号名（`blink.L`、`jawOpen` 之类，和荒野字典同一套名字，
这样内置的 ARKit / MMD 配置不用改就能用）映射到 `bsControl_NNN.axis`。来源是原版的
`ch001_00_10_wrinkledriver_03.jcns.36`：每个 bsControl 轴对应一个 FACS 名字的形态键（`browLowerer_R`、`eyeClosed_L` ……），
再把 FACS 名字对应到语义信号名。

- jcns 解析器：`E:\Data\Github\Python\RE-JCNS-Editor\modules\jcns_parser.py`（支持 v36）。
- 建议写一个生成脚本放 `tools/`，从 jcns 生成字典，人工核对后提交。对不上的信号标 `"guessed": true`，或者不写 `raw`（无信号）。
- `full` 按 3.4 的实测定。
- 内置配置的编译检查（`tests_games.lua` 的 D6）会对每个适配器跑一遍，字典缺名字会直接报错。

### 4.5 顺序

第 1 到 5 步已完成：最小适配器 → 信号和字典 → 过场 → 部件 id 和换装检测 → 输入屏蔽。剩下的按第 3 节的顺序，
其中换装、鬼化（3.3）最影响稳定性，先做。

## 5. 测试和部署

- 离线：`cd tests; python run.py`。基线是 FAILS 2（两个已知的视线检查）、PREVIEW FAILS 1（关于页版本文字），其余各组 0。
  新适配器自动进入 `tests_games.lua` 的检查（加载时不调 sdk、Core / UI 不出现游戏名、内置配置都能编译）。
  `tests_games.lua` 的 token 扫描禁止 Core / UI 代码里出现 `app.`、`fcParam_`、`ch02`、`ch03`。
- 部署到鬼武者：
  `SKS_GAME_REFRAMEWORK='E:\Program\Steam\steamapps\common\OnimushaWotS\reframework' powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy.ps1`。
  先加 `-Check`。部署会镜像 SKS 自己的目录（`autorun\ShapeKeySystem*`、`data\ShapeKeySystem\builtin` 等），
  不碰 `user/`、`mods/`、`settings.json`。
- 不改荒野的行为。每次改了 Core，也部署到荒野让用户回归一次。
- 提交按 `docs/writing/commit_guideline.md`：标题 `type(scope): 中文`，按类别拆提交，每个提交单独能跑，正文末尾 `Closes #N`。
  不要提交 `README.md`（用户自己的改动）和 `skills/`。在 `dim-dev` 上做，用户在游戏里测过再提交、开 PR。
