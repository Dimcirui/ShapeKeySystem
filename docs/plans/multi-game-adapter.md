# 多游戏适配器接口（#2，属于 #9）

目标：一个纯 Lua 主包装进任意 RE 引擎游戏，加载时按 `reframework.get_game_name()` 选择游戏适配器；
Core 和 UI 里不再出现 `app.*` 类型名和游戏专属概念（猎人、名片、fcParam 编号、ch02/ch03）。

本文只定接口和搬迁路线，**接口确认前不动代码**。代码基准：`f067d8c`（#1 合并之后）。

## 0. 决定摘要（2026-10-13 讨论后修订：D6、D9–D11、2.6 通用 id）

| # | 决定 | 理由 |
|---|---|---|
| D1 | 适配器放在 `autorun/ShapeKeySystem_Games/<Game>/`，入口为 `Adapter.lua`，其余按领域分文件（`Wilds/Conditions.lua`、`Wilds/Input.lua`、`Wilds/Probe.lua`） | 荒野中两级 require（`A.B.C`）可以正常解析，目录深度不受限制；仍须在加载时 require |
| D2 | 适配器是一张 Lua 表，字段可选，按能力（`caps`）声明支持哪些功能；缺的功能由 Core 降级，不报错 | 崛起没有形态键驱动骨骼，只能用捏脸；有的游戏没有过场 hook |
| D3 | 适配器顶层只定义表，**不调用 sdk**（不做 `find_type_definition` / `sdk.hook` / 单例查询）；这些都放进 `A.init(events)`，只有选中的适配器才会调用 | #6：所有适配器都在加载时 require，没选中的不能碰游戏 |
| D4 | `via.*` 引擎类型（`via.render.Mesh`、`via.Transform`、`via.Joint`、`via.hid.Mouse`、`via.SceneManager`、`via.motion.Motion`）留在 Core | 所有 RE 引擎游戏都有，不属于游戏层 |
| D5 | 信号分两层：通用信号名（`blink.L`）放在各游戏的信号字典里；原始通道（`p`）的取值格式由适配器定义 | 通用 profile（ARKit、MMD、VRC）只用 `s`，可以跨游戏复用 |
| D6 | 每个游戏的信号字典必须列出全部通用信号名；本游戏没有的写成 `"raw": null`（值恒为 0，界面上标出来）。字典里没出现的名字仍按现在的规则报错。离线测试检查每份通用 profile 都能用每个游戏的字典编译通过 | 接入游戏时就把缺口处理掉，而不是靠运行时兜底；拼错的信号名照样能被发现 |
| D7 | 用户数据目录（`user/`、`mods/`、`settings.json`）不按游戏分开 | 每个游戏有自己的 `reframework/` 目录，用户数据本来就是分开的；只有随包发布的 `builtin/` 需要分游戏（#5） |
| D8 | API 里的游戏概念改成通用词：猎人 → 主角色（primary），名片 / 存档选择预览 → 预览角色（preview），过场 → cutscene（保留），菜单 → menu（保留） | #3 的要求；界面上显示的文字由适配器的 `terms` 提供 |
| D9 | 生命周期事件（2.5）全部可选；适配器不提供时 Core 退回轮询（子节点签名、定期重扫） | RE4R 的两个插件都没有用 `sdk.hook`，过场角色靠定期扫描跟上 |
| D10 | 信号字典的每个条目可以单独写归一化范围 `lo` / `hi`，不写就用全局的 `full` | RE4R 从骨骼姿态推算的信号，每个都有自己的单位和范围（眨眼 3–28 度、张嘴 0.8–8 毫米） |
| D11 | 新增可选能力 `caps.alloc_weights`：权重数组一直没分配的网格，由 SKS 调用 `set_BlendShapeChannelWeightCount` 分配。默认关闭，只有实测过的游戏才打开 | RE4R 只有头部网格由游戏分配权重数组，身体和头发一直是 0；荒野的做法是一直等下去 |

## 1. 分层

```
ShapeKeySystem.lua                 入口：选适配器 -> SKS.init(adapter)，注册 re.* 回调
ShapeKeySystem_Core/*              与游戏无关：profile 编译、表情计算、写入、捏脸、预设、条件求值、扫描框架
ShapeKeySystem_UI/*                与游戏无关：面板；游戏相关的文字从 adapter.terms 取
ShapeKeySystem_Games/Registry.lua  require 全部适配器，pick(game_name) -> adapter | nil
ShapeKeySystem_Games/Wilds/*.lua   荒野适配器
```

依赖方向：入口 → Games / Core / UI；Core 只通过 `SKS.adapter`（由 init 注入）访问游戏层，不 require
`ShapeKeySystem_Games.*`。UI 只读 `SKS.state` 和 `SKS.adapter.terms`。

## 2. 适配器接口

下面每一节都写了：接口、荒野怎么实现、现在的代码在哪里、搬到哪里。行号以 `f067d8c` 为准。

### 2.1 元信息和能力

```lua
local A = {
    id = "mhwilds",               -- = reframework.get_game_name()，也是 builtin/<id>/ 的目录名
    name = "Monster Hunter Wilds",
    caps = {                      -- 缺省 = false
        expression = true,        -- 有形态键驱动骨骼，可以读信号（#4）
        eyes = true,              -- 能读眼球角度（视线组）
        preview = true,           -- 有预览角色（名片、存档选择）
        cutscene = true,          -- 有过场钩子，可以在过场中驱动
        conditions = true,        -- 提供条件 getter
        input_block = true,       -- 能屏蔽游戏输入
        alloc_weights = false,    -- D11：由 SKS 给没有权重数组的网格分配
    },
    terms = { primary = "猎人", preview = "名片", part = "防具" },   -- 界面文字
    defaults = { eyes = { full_deg = { yaw = 25.0, pitch = 20.0 } }, signal_full = 0.01 },
}
function A.init(events) end       -- 唯一允许调用 sdk 的入口，见 2.5
```

`caps.expression = false` 时 Core 不建表情 rig，只保留捏脸、预设和外部 API；表情页显示「本游戏没有表情信号」。

### 2.2 找角色和脸

Core 保留扫描框架（`Scene.scan`：一个父节点只保留一张脸、子节点签名缓存、`read_parts`、
`build_target`、指纹），游戏专属的判断改为调用适配器：

```lua
A.primary_root()        -> via.Transform | nil   -- 主角色（玩家自己）的根
A.primary_ready()       -> bool                  -- 主角色已经装配完成（不是换装、读盘中）
A.is_face(tr)           -> bool                  -- 这个 transform 是带驱动骨骼的脸
A.face_rank(tr)         -> number                -- 同一个父节点下有多张脸时，分数高的胜出
A.is_part(name)         -> bool                  -- 这个子节点名是可驱动的装备部件
A.scene_search_type     = "via.motion.Motion"    -- 全场景搜索其他角色时用的组件类型
```

| 现在 | 荒野实现 | 搬到 |
|---|---|---|
| `Scene.lua:21` `S.master_root`：`app.PlayerManager:getMasterPlayer():get_Object():get_Transform()` | `A.primary_root` | `Wilds/Adapter.lua` |
| `Guard.lua:66-70`：`getMasterPlayer().<Character>k__BackingField:get_IsSetUp()` | `A.primary_ready` | `Wilds/Adapter.lua` |
| `Scene.lua:38`：脸 = 有 `fcParam_001` 关节 | `A.is_face` | `Wilds/Adapter.lua` |
| `Scene.lua:45,135`：`Player_Face*` 子节点优先 | `A.face_rank`；主角色根下只找 rank > 0 的子节点 | `Wilds/Adapter.lua` |
| `Scene.lua:70`：只看 `ch02*` / `ch03*` 子节点（NPC 的脸也有 fcParam） | `A.is_part` | `Wilds/Adapter.lua` |
| `Scene.lua:48-58`、`Writer.lua:19`：`findComponents(via.motion.Motion)` 全场景搜索 | 保持不变，类型名从 `A.scene_search_type` 读 | Core |

角色分类不变：`primary`（父节点 = `primary_root()`），其他的都是非主角色（预览角色、过场副本 `Pl000_00`、其他玩家），
全部通过全场景搜索找到。Core 不需要知道它们各自是哪一种。

两点要为其他游戏留出余地（RE4R-ShapeKey-System 的做法）：
- **部件不一定是按名字排列的子节点**。RE4R 是从 `chainsaw.CharacterManager` 的玩家 context 出发，遍历头部、身体、头发的
  transform 找网格。所以适配器可以提供可选的 `A.parts(root) -> {transform...}`，提供了就用它，代替按 `A.is_part` 过滤子节点。
- **脸本身也可以是被驱动的部件**。RE4R 的 mod 把形态键直接做在头部网格上，同一个网格既提供信号又被写入。
  Core 不能假设「脸」和「部件」是两个不同的节点。

### 2.3 读信号（#4）

现在：`Profile.needs` 给出 fcParam 编号列表 → `Scene.joints`（`Scene.lua:111`）按 `fcParam_%03d` 找关节
→ `Expression.read`（`Expression.lua:42`）每帧读 `get_LocalPosition().z * inv_full`。改成：

```lua
A.raw = {
    term   = "fcParam",                      -- 界面上原始通道的叫法
    slider = { min = 0, max = 200, fmt = "%03d" },   -- 映射编辑器里 p 节点的取值范围；nil 时只显示不编辑
    parse  = function(v) -> key | nil, err,  -- profile 的 "p" 值或字典的 "raw" 值 -> 内部 key
    label  = function(key) -> string,        -- 界面显示，荒野 "fcParam_033"
}
A.bind(face, keys)          -> handle, n     -- 扫描时调用一次：找到这些通道对应的关节，n = 找到的个数
A.read(handle, P, inv_full)                  -- 每帧调用：P[key] = 原始值 / full
```

- **key 由适配器决定**，荒野是整数；`P` 按 key 直接索引（每帧热路径不能用字符串拼接）。
- 每个信号的 `lo` / `hi` 在 `Profile.load_signals` 里换算成 `P[key] * a + b`，`A.read` 不需要知道。
- 荒野：`parse` 接受 0..200 的整数，key = 编号；`bind` 返回现在的 `{n1, joint1, n2, joint2, ...}`；`read` 就是现在
  `X.read` 里的循环（读 z）。
- 鬼武者（推测，待 #7 实测）：`p` 写成 `"bsControl_012.y"`，key = 关节号 × 3 + 轴；`read` 按轴取 x/y/z。
- RE4R（参考 RE4R-ShapeKey-System 0.4.5-rc.1）有两种来源，都能放进同一个接口：
  - 游戏写入头部网格的修正形态键权重（`Face__geo__p000_cbs.crct_*`，如 `brow_lower_L`），`read` 调用 `getBlendShapeChannelWeightParam`；
  - 面部骨骼姿态（`C_Chin`、眼睑等）：相对待机姿态的位移（毫米）或旋转（度）投影到标定的主轴上。
  所以 `A.bind` / `A.read` 内部怎么读完全由适配器决定，Core 只拿到 `P[key]`。
- `Profile.lua:138` 的 `0..200` 范围检查、`Profile.lua:142` 和 `MappingEditor.lua:72,88,176,180,224` 的
  `fcParam_%03d` 文字和 0..200 滑块全部改成调用 `A.raw`。
- `X.read` 在 Core 里保留，读通道那部分换成 `A.read(handle, P, inv_full)`，眼球部分见 2.4。

### 2.4 眼球

```lua
A.eye_joints(face)  -> { L = joint|nil, R = joint|nil }
A.eye_angles(joint) -> yaw, pitch    -- SKS 约定：+yaw = 脸自己的右侧，+pitch = 向上，单位是度；可选，不提供时 Core 用 LocalRotation 换算
```

- 荒野：`L_EyeJ_LOD02` / `R_EyeJ_LOD02`（`Scene.lua:174`），角度换算就是现在的 `quat_to_yaw_pitch`（`Expression.lua:33`）。
- Core 提供 `Expression.quat_to_yaw_pitch` 给适配器复用（RE 引擎通用坐标系：右手系、Y 向上、脸朝 +Z），
  只有轴向不同的游戏才需要自己实现。
- 中立位标定、反向、满权重角度仍由 Core 处理并存进 `settings.json`；默认值从 `A.defaults.eyes` 读。
- 没有 `caps.eyes` 时 eye 节点的值恒为 0，视线组在界面上标为不可用。

### 2.5 生命周期事件

```lua
A.gate(frame) -> ok, reason, kind
    -- kind: "load" 过场读取中 | "playing" 过场播放中 | "setup" 主角色没装配好（标题、存档选择、读盘）
A.init(events)
    -- events 由 Core 提供，适配器在自己的 sdk.hook 里调用；每一项都是可选的（D9）：
    events.release(reason)   -- 过场跳过 / 停止 / 卸载：马上放掉所有引用（必须是前置钩子）
    events.segment(index)    -- 过场新的一段开始（前置钩子）
    events.rebuilt()         -- 有角色重建了装备（后置钩子）
    events.menu(name, open)  -- 标题 / 存档选择界面开关；只记一个标记，一帧可能调用很多次
    events.preview(open)     -- 预览角色界面（名片）开关
```

| 现在 | 搬到 |
|---|---|
| `Guard.lua:24-26` `app.DemoMediator` 类型和方法（顶层，违反 D3） | `Wilds/Adapter.lua` 的 `init` |
| `Guard.lua:55` `G.game_stable`：DemoMediator `IsBusy` / `IsBusyLoad` + 主角色 `IsSetUp`（每 10 帧查一次） | `A.gate`；Core 的 `Guard.game_stable` 改为调用它 |
| `Guard.lua:82` `G.hook_cutscene`：`requestSkip` / `execSkip` / `requestStop` / `requestForceStop` / `unload`、`onPlayStartTimeline` | `Wilds/Adapter.lua` 的 `init` → `events.release` / `events.segment` |
| `Guard.lua:105` `G.hook_equip_build`：`app.HunterCharacter.onEquipBuildEnd` | `init` → `events.rebuilt` |
| `Guard.lua:114` `G.hook_menus`：`GUI010100` / `GUI010101` 只 hook onOpen，`GUI010102` hook onOpen / onClose | `init` → `events.menu` |
| `ShapeKeySystem.lua:19` `app.GUI040200` onOpen / onClose | `init` → `events.preview` |
| `Guard.lua` 的 `mesh_ready` / `mesh_still_ready` / `release_refs` / `STABLE_FRAMES` | 留在 Core（只用 `via.render.Mesh`） |

API 改名（D8）：`SKS.on_guild_card` → `SKS.on_preview`，`C.gc_open` → `C.preview_open`，
`SKS.on_equip_build` → `SKS.on_rebuilt`，`SKS.on_cutscene_stop` → `SKS.on_release`；
`state.scene.last_scan.guild_card` → `preview`（同时改 `PageDebug.lua:123` 和 `shape-key-system-api.md:50`）。
外部 API（`External.lua`）没有暴露这些字段，不受影响。

没有 `caps.cutscene` 的游戏：`gate` 不会返回 load / playing，`cutscene_drive` 设置项隐藏。
没有 `A.gate` 的游戏：只要主角色根存在就视为稳定。不发事件的游戏靠现有的轮询兜底：每 5 帧比较主角色的子节点签名、
每 30 帧比较非主角色的父节点签名，再加上定期重扫（`periodic_scan_sec`）。

### 2.6 条件 getter

现在 `Conditions.lua` 一半是通用的（定义注册、求值、滞回、`value_text`），一半是荒野的（`HUNTER_BOOLS`、
`C.WEAPONS`、武器形态、`C.sample` 里的全部 getter）。拆成：

```lua
A.conditions = {
    defs = { {id, kind, label, options, min, max} ... },   -- 本游戏有哪些条件
    sample = function(V, frame) -> bool,                    -- 把本帧的值写进 V；读不到主角色时返回 false
    reset = function() end,                                 -- 场景切换时丢掉缓存的对象
}
```

- Core 的 `Conditions.lua` 保留 `def` / `eval_condition` / `eval_rule` / `value_text` / `NUM_OPS`，加载时注册
  `A.conditions.defs`。
- **掉血 / 回血**（`hp_decreased` / `hp_increased`）的判断移进 Core：适配器只写 `V.hp`、`V.hp_max`
  （内部值，不出现在条件列表里），Core 算 `hp_pct` 和两个事件。这样每个游戏都不用重复实现。
- **通用 id**：`hp_pct`（0–100）、`hp_decreased` / `hp_increased`、`dead`、`combat`，新游戏实现时沿用这些 id 和单位，
  条件集就能跨游戏用。对照过 RE4 差分管理器：它把血量叫 `hp_ratio`、战斗叫 `is_battle`，可见不写下来就会各叫各的；
  它没有耐力，也没有「拔刀」，所以 `stamina_pct`、`weapon_on` 和 `weapon_type`、`weapon_form`、`spirit_level` 一样留给荒野。条件集文件里出现本游戏没有的 id 时，按现有规则视为不满足
  （`Conditions.lua` 头部注释），不需要做迁移。
- 荒野的 getter 原样搬进 `Wilds/Conditions.lua`（`Conditions.lua:20-29,63-195`）。

### 2.7 输入屏蔽

`InputBlocker.lua` 里通用的部分留在 UI：AVM 共享表 `__AVM_UI_INPUT_BLOCKER_STATES`、`via.hid.Mouse` 模式切换、
虚拟光标、设备滚轮 / 位移读取。荒野专属的三处移到适配器：

```lua
A.input = {
    install = function(is_enabled, failed, forced) end,  -- 安装游戏侧钩子；is_enabled() 返回面板当前是否屏蔽输入，
                                                          -- failed(text) 报告没装上的钩子，forced() 记一次放开光标
    capture_mouse = function() -> dx, dy, wheel | nil,    -- UpdateMotionFrame 前调用：读取并清掉游戏的鼠标输入
}
```

| 现在 | 搬到 |
|---|---|
| `InputBlocker.lua:204` `clear_game_inputs` + `:216-232` hook `app.GameInputManager.updatePlayerInput/updateUIInput` | `Wilds/Input.lua` 的 `install` |
| `InputBlocker.lua:236-248` hook `app.GUIManager.isMouseCursorAvailable` 返回 true（放开光标） | `Wilds/Input.lua` 的 `install` |
| `InputBlocker.lua:182` `capture_and_clear_mouse` 里的 `app.AppMouseKeyboardManager` | `Wilds/Input.lua` 的 `capture_mouse` |
| `InputBlocker.lua` 其余部分 | 留在 UI |

没有 `A.input` 的游戏：面板照常可用，但游戏也会收到输入；状态栏显示「本游戏不支持输入屏蔽」。
AVM 共存规则（Delete 热键、共享屏蔽表、不替换 d2d 全局）不变，见 CLAUDE.md。

### 2.8 部件命名和模型显示名

| 现在 | 接口 | 荒野实现 |
|---|---|---|
| `Presets.lua:35` `model_of`：`ch03_012_0014` → `ch03_012_001` + 槽位 `4` | `A.model_of(part) -> model, slot` | 原有正则 `^(ch%d+_%d+_%d+)(%d)$` |
| `Presets.lua:41` `representative_of`：槽位 2（身体）代表整个模型 | `A.representative_of(part) -> part` | `model .. "2"` |
| `API.lua:410-420` `armor_name`：读 `builtin/armor_names.json` | `A.model_names = "armor_names.json"`（文件放在 `builtin/<id>/`）；`A.slot_names = {[槽位] = 部位名}`，可选 | 现有文件搬到 `builtin/mhwilds/`；槽位 1~5 = 腕部、躯干、头部、腿部、腰部 |

没有 `model_of` 的游戏：model = 部件 id 本身，绑定只有「每个部件自己的文件」和 `default.json` 这两层。
绑定文件的目录结构（`<src>/<model>/<part>.json`）不变。

### 2.9 调试探针

`Probe.lua` 只服务荒野（`app.CharacterEditRegionRoot` 的 blendshape 哈希表），改成可选的 `A.probe(path)`，
文件搬到 `ShapeKeySystem_Games/Wilds/Probe.lua`；没有 probe 的游戏隐藏调试页的按钮。

## 3. 信号字典和 profile 跨游戏复用（#4）

信号字典按游戏放：`builtin/<id>/signals.json`。格式基本不变，`param` 改名为 `raw`（读取时仍接受 `param`）：

```json
{ "schema": "sks.signals/2", "full": 0.01,
  "signals": [
    { "name": "blink.L",    "raw": 1, "note": "L_EyeClose 闭眼" },
    { "name": "tongueOut",  "raw": null, "note": "本游戏没有" },
    { "name": "jawOpen",    "raw": "C_Chin", "lo": 0.8, "hi": 8.0, "note": "RE4R 写法示例：毫米" }
  ] }
```

- `raw` 交给 `A.raw.parse` 解析，荒野是整数，鬼武者是 `"bsControl_000.y"` 这种字符串。
- **信号名是跨游戏的约定**：能对应上的游戏使用相同的名字（`blink.L`、`jawOpen`、`browDown.L` ……）。
  名字清单以荒野现在的 `signals.json`（63 个，覆盖全部内置 profile 用到的信号名）为基础。
- D6：新游戏的字典必须列出全部通用信号名，没有的写 `"raw": null`。`Profile.compile` 遇到 `raw` 为 null 的信号，
  节点值恒为 0，通道标记为 `no_signal`，表情详情里提示「本游戏没有这个信号」；遇到字典里根本没有的名字仍然报错。
  完全没有字典文件的游戏（只做捏脸）没法检查拼写，所有信号名都按 `no_signal` 处理，表情配置照常加载。
- D10：`lo` / `hi` 是这个信号的归一化范围（`(值 - lo) / (hi - lo)`），不写时等价于 `lo = 0`、`hi = full`。荒野的字典不用改。
- `p` 节点保留，表示游戏专属的原始通道。用了 `p` 的 profile 应在顶层写 `"game": "mhwilds"`；
  加载时跳过其他游戏的 profile。没写 `game` 的旧 profile 视为当前游戏专用（兼容现有的用户文件）。
- 内置的 ARKit、MMD 和 VRC profile 目前都只用 `s`（已检查：`builtin/profiles/*.json` 里没有 `"p"`），可以直接作为通用 profile。
- `API.lua:1873-1875`（`inv_full`、`dict_params`）和 `API.lua:1000`（`live.signal`）改为用 `raw` key。

**限制**（#4 的补充说明）：信号字典只是把「游戏已有的信号」统一命名，没有信号来源的游戏要另想办法。
- 有专门的形态键驱动骨骼：荒野（fcParam）、鬼武者（bsControl，未实测）；推测还有 RE9、PRAGMATA。
- **RE4R（更正 #4 里「推测没有」的说法）**：没有专门的驱动骨骼，但 RE4R-ShapeKey-System 已经在游戏里验证了两种来源：
  游戏写入头部网格的修正形态键权重，以及从面部骨骼姿态推算（`native_leon.json`，10 根骨骼、48 条规则）。
  后者正是「没有驱动骨骼的游戏」要单开的那个 issue 的现成参考；配合 D10 的 `lo` / `hi`，它也能放进同一个字典。
- 崛起：只有约 55 根面部变形骨骼，没有修正形态键，只能走骨骼姿态推算这条路，先只声明 `caps.expression = false`。

## 4. 内置数据按游戏分目录（#5）

```
builtin/aliases.json            通用
builtin/profiles/*.json         通用 profile（只用 s 节点）
builtin/<id>/signals.json       信号字典
builtin/<id>/armor_names.json   模型显示名（由 A.model_names 指定文件名）
builtin/<id>/profiles/*.json    游戏专属 profile（用了 p 或眼球节点的特定写法）
builtin/<id>/recording_catalog.json  录制参数编号与名称哈希表
builtin/<id>/recordings/*.json       内置面部动画录制
faces/、images/                 通用
```

- profile 的加载顺序：`builtin/profiles` → `builtin/<id>/profiles` → `mods/profiles` → `user/profiles`，后面的覆盖前面的。
- 旧路径兼容：更新时 mod 管理器不一定会删掉旧的 `builtin/signals.json` / `builtin/armor_names.json`。加载时
  **只读 `builtin/<id>/`**，根目录下的旧文件一律忽略；`deploy.ps1` 和 #8 的打包脚本负责清理。用户目录不需要迁移（D7）。
- 离线测试的 `run.py` 会把整个 `builtin/` 复制进临时目录，所以子目录自动包含在内。

## 5. 加载时选择适配器（#6）

```lua
-- ShapeKeySystem.lua
local Games = require("ShapeKeySystem_Games.Registry")   -- 加载时 require 全部适配器
local game = Games.game_name()
local Game = Games.pick(game)
local ok, why = false, "暂不支持当前游戏（" .. tostring(game) .. "）"
if Game then ok, why = SKS.init(Game) end    -- 先调用 A.init(events)，返回 false 时其余都不做
if not ok then
    re.on_draw_ui(function()
        if imgui.tree_node("ShapeKeySystem") then
            imgui.text("ShapeKeySystem 没有启动：" .. tostring(why))
            imgui.tree_pop()
        end
    end)
    return                                     -- 不注册任何钩子，也不读写数据目录
end
```

- `Registry.lua` 是一个列表 `{ Wilds, ... }`，`pick` 按 `id` 匹配。`game_name` 先试静态调用
  `reframework.get_game_name()`，失败再试 `reframework:get_game_name()`；哪种写法可用以实测为准。
- 运行时识别只在这里做一次；Core 和 UI 里不出现 `if game == ...`，只看 `A.caps` 和接口是否存在。
- `A.init` 先校验它离不开的类型（荒野是 `app.PlayerManager`），缺了就返回 `false, 原因`；`SKS.init` 在注入适配器、
  读设置和数据之前调用它，失败时直接返回，入口按「不支持」处理并显示原因（游戏更新后类型被改名时有用）。

## 6. 测试和验收

- 现有的 mock（`tests/mock_sks.lua`）是按类型名模拟 `sdk` 的（`app.DemoMediator`、`app.PlayerManager` ……），
  荒野适配器在 mock 下照常运行，所以现有的检查不需要改，只要在 mock 里加上 `reframework.get_game_name = function() return "mhwilds" end`。
- 下面这些检查在 `tests/tests_games.lua`（选择、入口、静态检查、D6）和 `tests/tests_fake.lua`（假适配器，单独的 Lua 运行环境）里。
- 新增检查：
  - 静态检查：`ShapeKeySystem_Core/` 和 `ShapeKeySystem_UI/` 的代码里（不算注释）不出现 `app.`、`fcParam_`、`ch02`、`ch03`；
  - 未知游戏：`pick` 返回 nil，不注册任何钩子；
  - 适配器顶层不调用 sdk：require 时把 `sdk` 换成会报错的表；
  - D6：每份通用 profile 用每个游戏的字典都能编译通过；`raw` 为 null 的信号编译后通道带 `no_signal` 标记；
    字典里没有的信号名仍然报错；
  - 一个最小的假适配器（`caps` 全为 false）下，捏脸和预设仍然能用。
- #3 的验收：`python run.py` 各组的 FAILS 和搬迁前一致（目前 `tests.lua` 有两个 gaze 检查本来就失败），
  进游戏后的表现完全一致（主角色、名片、存档选择、过场跳过、换装）。

## 7. 实施顺序

1. **#3** 拆出 `Wilds/Adapter.lua` / `Wilds/Conditions.lua` / `Wilds/Input.lua` / `Wilds/Probe.lua`，Core 通过 `SKS.adapter` 调用；
   入口暂时固定选荒野。只搬代码和改名（D8），不加新功能。
2. **#4** 引入 `A.raw` / `A.bind` / `A.read`、signals `raw` 字段、D6 和 D10。
3. **#5** builtin 分目录，加载路径改成 `builtin/<id>/`，`deploy.ps1` 清理旧文件。
4. **#6** `Registry.pick` 和不支持游戏的提示，加上 6 节列出的测试。
5. **#7** 第二个游戏：先实测探查，再写适配器（见 8 节）。
6. **#8** 打包脚本和以上各项互不依赖，可以随时穿插进来做。

## 8. 第二个游戏要先实测的问题（#7）

鬼武者·剑之道（优先，有驱动骨骼）：
- `reframework.get_game_name()` 的返回值；
- 主角色从哪个单例取（相当于荒野的 `PlayerManager`）、有没有「装配完成」的标志；
- 脸的 GameObject 能否用 `getJointByName("bsControl_000")` 找到，`get_LocalPosition` 的值域（满值是 1 还是像荒野那样是 0.01）；
- 服装网格是否有 blendshape、通道名格式、谁给服装的 bsControl 赋值（荒野靠 BoneSystem.dll 复制面部关节，有一帧延迟）；
- 过场管理器以及跳过、停止的方法；换装重建的钩子；
- 眼球关节名和轴向。

RE4R（游戏没装，现成的参考实现是 [RE4R-ShapeKey-System](https://github.com/Funnyguysmz/RE4R-ShapeKey-System) 和
[RE4R-ShapeKey-Studio](https://github.com/Funnyguysmz/RE4R-ShapeKey-Studio)，只用作参考）：
- 主角色：`chainsaw.CharacterManager:getPlayerContextRef()` → `BodyUpdater`，头部在 `get_HeadMotion():get_GameObject()`；
- 信号：修正形态键（`crct_*`）只有在 mod 的头部网格保留这些通道时才读得到；骨骼姿态那套标定是按里昂做的，其他角色要重新标定；
- 可操作角色不止一个（里昂、艾达等），绑定可能要按角色区分；
- 身体、头发网格的权重数组要由插件分配（D11），越界写入会让游戏崩溃。

崛起：没有驱动骨骼，按 `caps.expression = false` 接入时，只需要 2.2（找部件）、2.5（gate）和 2.8，用来验证捏脸和预设的降级路径。

## 9. 未决问题

1. 不支持的游戏是完全不启动（#6 的写法），还是用一个只带捏脸的通用适配器启动？建议先按 #6 完全不启动，
   等崛起试点证明降级路径可用后再讨论。
2. `terms` 只覆盖调试页和状态行里出现的「猎人 / 名片」（目前 3 处）；条件的中文标签已经放进 `A.conditions.defs`，不另做本地化。
3. 其他玩家：荒野现在靠全场景搜索（`scene_search_always`）找到，没有专门的接口。如果别的游戏需要按玩家列表找，
   再加一个可选的 `A.other_roots()`，现在不加。

## 10. 面部动画测试的可选接口

`A.playback` 提供录制测试，入口将选中的同一个适配器传给 `Playback.init`，不另设游戏注册表。
适配器未提供该接口时，测试区显示不可用提示；捏脸和预设仍按原有能力运行。

- `catalog()` 返回录制参数编号与名称哈希的对应表；`raw_unit`、`final_unit` 提供幅值单位。
- `attach(callbacks)` 在加载阶段安装当前游戏的回调；`callbacks.tick(true)` 推进时钟并注入样本，
  `callbacks.inject()` 只注入已有样本，`callbacks.fail(reason)` 停止测试。
- `now()`、`connect(clip)`、`healthy(track)` 管理游戏时钟和会话验证；`inject(values)` 写入原版输入。
- `matches(rig)` 限定最终信号覆盖的角色；`stop(restore)` 释放引擎引用，只在对象和参数索引仍有效时恢复。

荒野实现放在 `ShapeKeySystem_Games/Wilds/Playback.lua`，引擎类型查询推迟到所选适配器的 `attach`，
模块加载时不调用 SDK。内置录制放在 `builtin/<id>/recordings/`，参数表放在 `builtin/<id>/recording_catalog.json`。
用户录制放在 `user/recordings/`，按 D7 依靠游戏安装目录隔离，不再套一层游戏 ID。
旧的 `user/games/<当前游戏 id>/recordings/` 只作读取回退，同名文件优先读取新目录；不改写或移动用户文件。
旧内置 `games/<id>/` 不再读取，部署只清理荒野的参数表、`Speak.json`、`CampMeals.json`，保留其他文件。
目前的录制格式为 `fcparam.recording/1`、`fcparam.recording/2`；新游戏使用其他格式时需增加对应解码支持。
分析绑定使用字典的 `key`，显示名称使用 `A.raw.label`，Core 和 UI 不构造游戏专属骨骼名称。
