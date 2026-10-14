# 鬼武者·剑之道适配器：探查方法和实施计划（#7）

写给接手的人。适配器接口见 `multi-game-adapter.md`，Core 和 UI 的约定见 `shape-key-system-api.md`，仓库工作规则见
根目录 `CLAUDE.md` 和 `docs/writing/`。本文写于 2026-10-14，记录已经实测确认的事实、还没查的问题、怎么查，
以及适配器按什么顺序写。

## 0. 现状

- 荒野适配器在 `reframework/autorun/ShapeKeySystem_Games/Wilds/`，`Registry.lua` 只登记了它。鬼武者还没有适配器，
  在鬼武者里加载 SKS 只会在 REF 菜单显示「暂不支持当前游戏」。
- 通道名反查（`ShapeKeySystem_Core/NameHash.lua`，见第 2.3 节）已经写好，离线测试通过，**在 dim-dev 上还没提交**，
  等用户在荒野里回归测试后提交。接手前先 `git status` 看它是否已经进了 main。
- 游戏路径 `E:\Program\Steam\steamapps\common\OnimushaWotS`。原版解包在 `OnimushaWotS\EXTRACT\natives\stm\`
  （角色 mesh、jcns、部分 talk motlist）。用户的测试 mod 放在 `OnimushaWotS\natives\stm\`。

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
- `Player_00` 的子物体（按 GameObject 名）：`Head`（脸，带 mesh）、`Hair`（在 Head 下）、`Body`、`Cloak`、
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
  **待验证**：REF Lua 里 `get_ChannelNameHash()` 返回的数组用 `get_elements()` 能否拿到整数，见 3.1。

### 2.4 写入

- `setBlendShapeChannelWeightParam(idx, v)` 写进去能读回来（Pre LateUpdate 写 1 和 10 都读回原值）。
  画面上看不出变化，原因见 1.4，没有排除「游戏在同一帧后面又覆盖了」。

## 3. 还没查的问题

按适配器需要的先后排。每一项写明怎么查。

1. **Lua 侧读哈希数组。** 在 `OnimushaWotS\reframework\autorun\` 放一个临时 Lua 脚本：取 Head 的 mesh，
   `local a = mesh:call("get_ChannelNameHash")`，打印 `type(a)`、`a:get_size()`、`a:get_elements()[1]` 的类型和值，
   和探针输出的第 0 个哈希（原版 `D68FFE36`）对照。`NameHash.names_of` 里的 `unbox` 按结果改。用完删掉脚本。
2. **`reframework.get_game_name()` 的值。** 同一个临时脚本里打印 `reframework.get_game_name()` 和
   `reframework:get_game_name()`，适配器的 `A.id` 和 `Registry` 都按它定。
3. **写入是否被覆盖。** 打开探针的写入测试，只写 mod 头部的一个明显形状（如 `eye_close`，在用户的 mod 里是第 0 个通道），
   Pre 写 1，同帧 Post 读回；再让用户看画面。如果 Post 读回不是 1，或者画面不变，说明后面有人覆盖，
   要找更晚的写入时机（REF 的 `re.on_application_entry` 各阶段，或挂在 `app.FacialController.lateUpdate` 之后）。
4. **bsControl 的满值。** 让角色做大表情（说话、受击、过场），探针记录 600 帧里每个关节每个轴的最大值。
   对照 jcns 里的映射范围，定字典的 `full`（荒野是 0.01）。
5. **过场。** `get_type app.DemoMediator`，确认 `get_IsBusy`、`get_IsBusyLoad`、`requestSkip`、`execSkip`、
   `requestStop`、`requestForceStop`、`unload`、`onPlayStartTimeline` 是否和荒野同名同签名（荒野适配器
   `hook_cutscene` 用的就是这些）。再看一段过场里主角是不是还是 `Player_00`，还是另有副本。
6. **换装重建。** 候选：`PlayerManager.changePlayerModel(...)`（两个重载）、`changePlayerModelHQ`、
   `bindObjectToManageInfo`、`evLoadEnd`。用探针或临时 Lua 挂 post 钩子打日志，让用户换一次装，看哪个触发、
   触发后子物体和 mesh 地址是否变了。鬼化（`OniHead` 可见）也要看一次。
7. **暂停 / 菜单。** `app.PauseManager:get_IsPaused()`（现有的眼球 mod `OnimushaEyeMovementIntensity.lua` 用它），
   以及打开菜单、标题画面时玩家对象是否还在。
8. **输入屏蔽。** 荒野靠和 ArmorVariantManager 共享的屏蔽表。鬼武者里有没有要共存的 mod、面板打开时
   怎么挡住游戏输入（`app.PlayerManager.setButtonMask` / `setCommandMask` 是候选），没查。
9. 眼球轴向和正负号（荒野的约定见记忆 `sks-gaze-yaw-convention`：yaw +1 = 角色的左边）。

## 4. 适配器实施计划

### 4.1 文件

```
reframework/autorun/ShapeKeySystem_Games/Onimusha/Adapter.lua      -- 必需
reframework/autorun/ShapeKeySystem_Games/Onimusha/Conditions.lua   -- 可选，先不做
reframework/data/ShapeKeySystem/builtin/<game id>/signals.json     -- 信号字典
reframework/data/ShapeKeySystem/builtin/<game id>/profiles/        -- 只有这个游戏才有的配置（可以没有）
```

`Registry.lua` 的 `R.list` 加一行（括号别丢，见那里的注释）。`<game id>` 用 3.2 查到的 `get_game_name()` 返回值。

### 4.2 按接口逐项（`multi-game-adapter.md` 第 2 节）

| 接口 | 鬼武者的写法 |
|---|---|
| `id`, `name` | 3.2 的游戏名；`"Onimusha: Way of the Sword"` |
| `init(events)` | 检查 `app.PlayerManager`；缓存 `DemoMediator` 的方法；挂过场和换装钩子（3.5、3.6）。缺必需类型时返回 `false, 原因` |
| `primary_root` | `PlayerManager:getControllingPlayer():get_Object():get_Transform()`，全程 pcall |
| `primary_ready` | `isPlayerReady(false)` 且 `getControllingPlayer():get_Valid()` |
| `gate(frame)` | 照荒野：过场加载 / 播放 → 不碰；玩家没就绪 → 不碰。暂停是否要停，按 3.7 定 |
| `is_face(tr)` | `getJointByName("bsControl_000") ~= nil` |
| `face_rank(tr)` | GameObject 名是 `Head` 给 1，`OniHead` 在可见时也给 1（鬼化），其余 0 |
| `is_part(name)` | 见 4.3 |
| `eye_joints(face)` | `{ L = jbn(face, "eye_Lt"), R = jbn(face, "eye_Rt") }`，轴向按 3.9 |
| `raw` | `term = "bsControl"`；key = 关节号 × 3 + 轴（x=0、y=1、z=2）；`parse` 接受 `"bsControl_012.y"` 和 `"012.y"`；`label` 反过来；`slider = nil`（映射编辑器先不给滑块） |
| `bind(face, keys)` | 按 key 找 `bsControl_%03d`，返回 `{key, joint, ...}` 和找到的个数 |
| `read(handle, P, inv_full)` | `get_LocalPosition()` 取对应轴，乘 `inv_full` |
| `model_of` / `representative_of` / `model_names` / `slot_names` | 先不给（捏脸页会显示部件 id）。以后可以按 mesh 路径 `chXXX_YY` 分系列 |
| `conditions`, `input`, `probe` | 先不给 |

### 4.3 部件 id 的问题（要改 Core）

Core 现在用子物体的 GameObject 名当部件 id（`Scene.read_parts` 的 `cname`），绑定、捏脸预设的文件夹、指纹都按它存。
荒野的子物体名是 `ch03_012_0012` 这种装备编号，天然区分不同装备；鬼武者的子物体名是固定的 `Head` / `Body`，
换了服装名字也不变，不同服装的预设会互相覆盖。

建议加一个可选接口 `A.part_id(transform, go_name) -> id`，默认返回 GameObject 名；鬼武者返回 mesh 资源路径的文件名
（`ch001_00_10`）。`is_part` 仍按 GameObject 名判断（`Head`、`Body`、`Hair`、`Cloak`、`Gauntlet`、`Amulet`，
鬼化形态的 `Oni*` 是否算进来按 3.6 的结果定）。这一项改 Core，要同步改 `multi-game-adapter.md` 第 2.2 节，
加离线测试（`tests_fake.lua` 那种独立运行环境最合适）。

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

1. 先查 3.1、3.2（一个临时 Lua 脚本就够）。
2. 写只有 2.2 那几项的最小适配器（找角色、找脸、找部件），不给 `raw`。验收：捏脸页能列出 mod 头部的 141 个键（名字反查），
   拖滑块画面有变化。这一步同时验证 NameHash 在游戏里能用。
3. 做 4.3 的部件 id。
4. 查 3.3、3.4，写 `raw` / `bind` / `read` 和信号字典。验收：ARKit 配置能驱动 mod 头部，表情跟着游戏动。
5. 查 3.5、3.6，加 `gate` 和钩子。验收：过场、跳过过场、换装、鬼化都不闪退，回来以后继续驱动。
6. 眼球（3.9）、条件、输入屏蔽按需要再做。

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
