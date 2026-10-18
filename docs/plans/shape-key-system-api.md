# ShapeKeySystem 接口说明（界面 ↔ 后端）

版本：草案 v0.1（2026-10-08）
依据：[shape-key-system.md](shape-key-system.md) 第 0 节的决策；界面原型 https://claude.ai/artifact/7gNPX1dR7CDeoQJtaPZNcj
适用范围：插件内部的界面层（d2d 面板，开发期间先用 imgui 调试面板）与后端（Core 模块）之间的约定。

---

## 1. 原则

1. **界面只读状态、只调命令。** 界面不调用任何引擎接口（`sdk`、`via.*`），也不直接读写 JSON 文件。
2. **后端是唯一的数据来源。** 所有修改都通过命令完成。命令返回之前，状态里对应的字段已经更新。写入引擎的那一步发生在下一次更新（`LateUpdateBehavior`）里。
3. **状态按分区组织，每个分区带一个修订号 `rev`。** 每次修改该分区时 `rev + 1`。界面比较 `rev`，只在变了的时候重建列表，平时只刷新实时数值。
4. **实时数值和结构分开。** 通道列表这类结构很少变化；每帧变化的数值（权重、活跃度、角度）放在单独的扁平数组里，按下标读取，读的时候不产生新表。
5. **面板关闭时，界面相关的计算全部停掉。** 后端只做驱动必需的工作；为界面准备的统计（例如部位活跃度）只在面板打开时计算。
6. **不暴露引擎对象。** 状态里只有数字、字符串、布尔和普通 Lua 表，不放 `REManagedObject`。

## 2. 入口

```lua
local SKS = require("ShapeKeySystem_Core.API")

SKS.version          -- 接口版本，例如 "0.1"
SKS.state            -- 状态根表（只读约定，见第 3 节）
SKS.live             -- 实时数值（见第 4 节）
SKS.call(cmd, args)  -- 执行命令，返回 ok, err_code, message, result
SKS.set_ui_open(b)   -- 告诉后端面板是否打开（影响第 1 节第 5 条）
```

- 命令统一通过 `SKS.call` 调用，便于记录日志、统一错误处理，以及以后加撤销。
- 状态表**按引用暴露**。界面拿到后只读不写；开发版会给状态表设置只读元表，误写时直接报错。

## 3. 状态（`SKS.state`）

下面用 Lua 表结构描述。`?` 表示可能为 `nil`。

### 3.1 `state.runtime`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | 修订号 |
| `enabled` | bool | 总开关 |
| `ui_open` | bool | 面板是否打开 |
| `advanced` | bool | 界面是否显示进阶栏目（只影响界面，持久化到设置） |
| `notices` | list of `{id, level, text, time}` | 给界面显示的提示，例如"已保存"、"预设与网格不匹配"。`level` 取值：`info` / `warn` / `error` |

### 3.2 `state.scene`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `last_scan` | `{time, ms, faces, cached_skip, preview}` | 最近一次扫描的信息 |
| `rigs` | list of Rig | 被驱动的角色。主角色和名片分身**不作区分**，界面只显示合并后的结果 |
| `parts` | list of Part | 当前身上的部件，去重后合并 |

`Part`：
```lua
{ id = "ch03_012_0012",        -- 部件 ID，同时也是父预设的文件名
  display = "希望 α · 躯干",   -- 角色或模型名称与部位名称；原始 ID 保留在 id
  slot = "body",               -- head / body / arm / waist / leg / other
  channels = 55,               -- 网格通道总数
  fingerprint = "a1b2c3",      -- 通道名集合的哈希
  binding = "user/ch03_012_0012.json" }  -- 实际命中的父预设文件，没有命中时为 nil
```

### 3.3 `state.expression`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `profile` | `{id, name, source, extends}` | 当前表情配置。`source`：`builtin` / `mod` / `user` |
| `coverage` | `{arkit_hit, arkit_total, extra, recommended}` | 覆盖率和自动推荐结果 |
| `binding_source` | string? | 配置是由哪个父预设指定的 |
| `no_signals` | bool | 适配器没有原始通道（`A.raw`），表情不读游戏信号；捏脸、预设和外部 API 照常 |
| `master_gain` | number | 整体表情强度，0~2 |
| `gaze_gain` | number | 视线强度，0~2 |
| `smoothing` | number | 平滑程度，0~1 |
| `regions` | list of Region | 部位，顺序固定为 眉、眼、鼻·颊、嘴 |
| `groups` | list of Group | 进阶页的分组，含组合修正、无游戏信号等 |
| `channels` | list of Channel | 全部通道，`channels[i].slot` 对应 `live.weight[slot]` |

`Region`：`{ key = "eye", name = "眼", gain = 1.0, channel_slots = {…} }`
`Group`：`{ key = "mouth", name = "嘴", region = "mouth"?, channel_slots = {…} }`
`Channel`：
```lua
{ slot = 12,                     -- live 数组下标
  name = "MouthSmileLeft",       -- 网格里的实际名字
  canonical = "mouthSmileLeft",  -- 标准名（ARKit 写法）；扩展通道为原名
  label = "嘴型：微笑（左）",     -- 显示名；「翻译形态键」关闭、没有译名或界面不是中文时为 nil（见第 8 节 labels.json）；命令照旧用 name / canonical
  group = "mouth",
  source_text = "smile.L + smileMinor.L×0.5",  -- 来源摘要，显示用
  has_signal = true,             -- false 表示没有游戏信号，只能手动或捏脸
  no_signal = false,             -- true 表示用到的信号本游戏没有，值恒为 0
  guessed = false,               -- 映射是否来自推测
  gain = 1.0,
  forced = false,                -- 是否处于"测试"状态（强制为 1）
  owner = "expression" }         -- expression / fbs，见第 6 节
```

### 3.4 `state.eyes`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `full_deg` | `{yaw, pitch}` | 满权重对应的角度 |
| `invert` | `{yaw, pitch}` | bool |
| `neutral` | `{L = {yaw, pitch}, R = {yaw, pitch}}` | 中立位校准值 |
| `sets` | `{eye_look = bool, look = bool}` | 驱动 EyeLook*（眼睑跟随）和 Look*（虹膜平面移动）哪一组 |

### 3.5 `state.mapping`（进阶 · 映射编辑）
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `signals` | list of Signal | 信号词典 |
| `raw` | `{term, slider = {min, max, fmt}}` 或 nil | 本游戏原始通道（`p` 节点）的名称和编辑范围；nil 表示没有原始通道 |
| `nodes` | map 通道名 → Node | 当前配置里各通道的节点树（结构同配置 JSON，见计划文档 5.1） |
| `edited` | set of 通道名 | 改过、还没保存的通道 |

`Signal`：`{ slot = 3, name = "smile.L", label = "fcParam_033", no_signal = false, guessed = false, note = "颧大肌" }`。
`label` 是适配器给出的原始通道名；`no_signal` 为 true 时本游戏没有这个信号，实时值恒为 0。实时值在 `live.signal[slot]`，
已按信号自己的 `lo` / `hi` 归一化。`p` 节点的显示名用 `SKS.raw_label(v)` 取得。

### 3.6 `state.sculpt`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `scan` | `{time, parts = {ids}, keys = int, hidden_by_expression = int}` | 扫描结果概要 |
| `edit_mode` | bool | 编辑模式。关闭时数值固定，不再每帧写入 |
| `ab_preview` | bool | 是否正在预览 mod 默认值 |
| `dirty` | bool | 是否有未保存的修改 |
| `can_undo` / `can_redo` | bool | |
| `preset` | `{name, source}?` | 当前捏脸配置 |
| `groups` | list of `{key, name, key_indices}` | 按部件分组；`key` 是部件 id，`name` 是装备名和部位（如「护锁刃龙 α/β · 躯干」），认不出时等于 `key` |
| `keys` | list of SculptKey | 合并后的形态键 |

`SculptKey`：
```lua
{ name = "Waist_thin",
  label = "腰变细",                               -- 显示名，规则同 Channel.label；同一部件里两个键显示名相同时，后面加「（原名）」
  group = "body",
  parts = { "ch03_012_0012", "ch03_012_0014" },  -- 出现在哪些部件
  part_labels = { "躯干", "腿部" },               -- parts 的显示名；都属于同一件已知装备时只写部位，认不出的保留 id
  value = 0.30,                                  -- 合并值，0~2
  default = 0.30,                                -- mod 自带默认值，没有时为 0
  overrides = { ["ch03_012_0014"] = 0.5 },       -- 按部件单独设的值
  owner = "self",                                -- self / fbs / expression
  range = { 0, 1 } }   -- 上端 = 设置 sculpt_max（全局，默认 1，可调到 5；改小时超出的值会被截断）
```

### 3.7 `state.presets`
| 字段 | 类型 | 说明 |
|---|---|---|
| `rev` | int | |
| `binding` | 见下 | 当前父预设的解析结果 |
| `expression` | list of `{name, source, extends?}` | 可选的表情配置 |
| `sculpt` | list of `{name, source, target_part?}` | 可选的捏脸配置；同一文件夹里和用户配置同名的 mod 配置不列出（加载的总是用户那份） |
| `pending_delete` | `{kind, name}?` | 等待确认的删除操作 |

`binding`：
```lua
{ part = "ch03_012_0012",
  chain = {                                        -- 按查找顺序排列
    { path = "user/ch03_012_0012.json", exists = true,  hit = true  },
    { path = "mods/ch03_012_0012.json", exists = true,  hit = false },
    { path = "ch03_012_*.json",         exists = false, hit = false },
    { path = "default.json",            exists = false, hit = false } },
  expression = "Shinano (ARKit + 扩展)",
  sculpt = "Airi 日常脸",
  fingerprint_ok = true }
```

### 3.8 `state.settings`

`scene_search_available` 由适配器的 `scene_search` 提供；适配器设为 `false` 时，两个面板均隐藏全场景搜索开关。该字段属于运行能力，不写入设置文件。

`hotkey`、`ui_scale`、`language`、`scene_search_always`、`periodic_scan_sec`、`write_epsilon`、`translate_keys`（bool，默认 false：形态键显示中文译名，只在 `language = "zh"` 时生效）、`ui_backend`（`auto` / `d2d` / `imgui`：面板绘制方式，`auto` = 装了 d2d 就用 d2d，否则 ImGui；想要的后端不存在时自动用另一个）、`window = {x, y, w, h}`、`expression_enabled`（bool，默认 true：关闭后游戏表情不再写入形态键，捏脸、条件规则、面部互动和其他插件的值照常写入）、`hold_face_bones`（bool，默认 false：禁用骨骼驱动的表情，只用形态键控制，见 3.8a）。修改后立即持久化。

`hold_available` 表示当前适配器提供 `expression_joints` 与 `face_layers`；`hold_status` 是禁用骨骼表情的当前状态文字。二者属于运行能力，不写入设置文件。

### 3.8a 禁用骨骼表情

`FaceHold.lua` 在 UpdateMotion 之后把每个被驱动 rig 的面部表情骨骼写回中性姿势，使游戏的面部骨骼动画不再改变脸型，表情只由形态键表现。中性姿势取自运行时而非骨架的 Base 姿势：捏脸会让面部骨骼偏离 Base。读取时把该面部的所有动画层 `BlendRate` 置 0 约 2–3 帧，记下未动画姿势后恢复原值；期间 fcParam 读数为 0，Core 跳过表情写入，网格保留上一帧的权重。rig 被放掉（换装、过场、菜单）后重新读取。

被禁用的骨骼仍可作为信号来源：适配器用 `FaceHold.watch(names)` 登记需要的骨骼名，`FaceHold.pose(face_addr, name)` 返回本帧写回之前的动画姿势。眼球骨骼不在禁用范围内，视线照常读取。

### 3.9 `state.debug`
| 字段 | 类型 | 说明 |
|---|---|---|
| `perf` | `{read, compute, write, scan, stages, total, writes, skipped, timings}` | 分类按最近 60 帧平均，单位 ms；`total` 为完整 SKS 更新，`stages` 为分类之和 |
| `log` | 环形缓冲，最多 200 条 `{time, text}` | |

## 4. 实时数值（`SKS.live`）

每帧由后端原地更新，界面按下标读取：

| 字段 | 类型 | 说明 |
|---|---|---|
| `weight[slot]` | number | 各表情通道最终写入的权重 |
| `region_activity[i]` | number | 各部位的活跃度（该部位通道权重的最大值，面部图标提亮用）。只在面板打开时计算 |
| `signal[slot]` | number | 各信号归一化后的值（0..1）。只在映射编辑或调试页打开时计算 |
| `eye_angle` | `{L = {yaw, pitch}, R = {yaw, pitch}}` | |
| `procedural` | `{blink, mouth, gaze = {yaw, pitch}}` | 自动表情生成器的当前值：左眼眨眼（0..1）、张嘴（`jawOpen` 的生成值）、视线偏移（度）；关闭时为 0。见「自动表情」一节 |

## 5. 命令（`SKS.call(cmd, args)`）

返回值：`ok, err_code, message, result`。下表"持久化"一栏说明命令会写入哪个文件。

### 5.1 通用
| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `set_enabled` | `{on}` | 总开关；关闭时所有通道写回 0 | settings |
| `set_setting` | `{key, value}` | 修改设置 | settings |
| `rescan` | `{}` | 立即完整扫描（同时刷新表情和捏脸的部件信息） | — |
| `dismiss_notice` | `{id}` | 关闭一条提示 | — |

### 5.2 表情
| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `set_profile` | `{id, discard?}` | 切换表情配置；映射未保存时返回 `E_UNSAVED`，显式 `discard=true` 可丢弃修改 | 不自动写父预设，需要 `write_binding` |
| `preview_profile` | `{id?}` | 只读浏览一个未生效的配置：编译后和当前装备的网格通道名匹配，结果放在 `state.expression.preview = {id, name, source, channels, groups, present, total}`；不传 id、或 id 就是当前配置时清除。换装重扫后自动重建，`set_profile` 切到它时自动清除。表情详情页下拉选中即调用 | `E_NOT_FOUND` |
| `set_master_gain` | `{value}` | 0~2 | 父预设 `gains` |
| `set_gaze_gain` | `{value}` | 0~2 | 同上 |
| `set_region_gain` | `{region, value}` | 0~2 | 同上 |
| `set_smoothing` | `{value}` | 0~1 | 同上 |
| `set_channel_gain` | `{name, value}` | 0~3 | 同上 |
| `force_channel` | `{name, on}` | 测试：强制为 1 | — |
| `set_eye_cfg` | `{patch}` | 修改 `state.eyes` 中的部分字段 | 同上 |
| `calibrate_eye_neutral` | `{}` | 把当前眼球朝向设为正前方 | 同上 |
| `gaze_hold` | `{yaw, pitch, frames?}` | 两眼都看向给定角度（度，已含反转；+yaw = 角色自身的右，+pitch = 上），覆盖游戏视线；`frames` 帧内（默认 15）不续就自动失效。面板在眼睛上按住拖动时每次绘制都发 | `E_BAD_ARGS` |
| `gaze_release` | `{}` | 立刻交还给游戏视线 | — |
| `set_procedural` | `{patch}` | 修改自动表情设置（`enabled`、`mode`、`frequency`、`speed`、`blink.*`、`gaze.*`、`breath.*`），见「自动表情」一节；数值超出范围时截到范围内，未知的 `mode` 或非布尔的开关返回 `E_BAD_ARGS`，此时什么都不改 | settings |

增益类修改先只改内存，界面显示"未保存"。用户点保存后才写进父预设，避免拖动滑块时反复写文件。

### 5.3 映射编辑
| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `edit_node` | `{name, node}` | 替换某个通道的节点树；先校验，校验不通过返回 `E_NODE_INVALID` | — |
| `set_mapping` | `{entry, create?}` | 提交完整映射（节点 + name/group/note/any/unless 等元数据）；`create=true` 新建，否则替换已有同名映射。编译通过后更新索引、清空旧 slot 并安排 tick 重扫；重名/别名匹配冲突返回 `E_EXISTS` | — |
| `remove_mapping` | `{name}` | 删除映射；仍被节点引用时返回 `E_NODE_INVALID`，运行配置保持原样 | — |
| `revert_mappings` | `{}` | 将节点、元数据和已删除通道整体恢复至加载/上次保存时的版本 | — |
| `revert_node` | `{name}` | 恢复为配置文件里的原值 | — |
| `create_profile` | `{name}` | 新建空白用户表情配置并选中；拒绝重名和未保存映射，空配置不会被自动推荐替换 | user/profiles |
| `save_profile` | `{as_name?}` | 保存节点、映射结构及元数据到 `user/profiles/`，建立新的干净基线；不填 `as_name` 时覆盖当前用户配置，内置/mod 返回 `E_READONLY`；另存名与其他配置重名返回 `E_EXISTS` | user/profiles |

映射编辑器共用 `MappingEditor.lua`，两种绘制后端使用相同页面和节点树。`state.mapping.entries[name]` 为完整映射快照，`nodes[name]` 为纯节点，`edited[name]` 标记新增/改动映射，`dirty` 也涵盖删除，`profile_id` 用于识别草稿所属配置。运行修改通过后才换入；所有网格写入仍仅发生在 tick。`set_profile` 在映射未保存时返回 `E_UNSAVED`，显式 `discard=true` 可放弃修改。

### 5.4 捏脸
| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `sculpt_scan` | `{}` | 懒读取：读取当前部件的形态键，合并同名，并应用 mod 自带预设 | — |
| `set_edit_mode` | `{on}` | 打开后每帧写入；关闭时固定写一次，然后停止 | — |
| `set_sculpt_key` | `{name, value}` | 设置合并值，范围 0~2 | — |
| `set_sculpt_override` | `{name, part, value?}` | 单个部件单独设值；`value` 为 nil 时恢复跟随合并值 | — |
| `reset_sculpt_key` | `{name}` | 恢复为 mod 默认值 | — |
| `reset_sculpt_all` | `{}` | 所有键恢复为 mod 默认值，算一步撤销（`sculpt_undo` 可以全部恢复）；没有可重置的值时返回 `{done = false}`，不产生撤销步 | — |
| `sculpt_undo` / `sculpt_redo` | `{}` | 撤销 / 重做（最多 50 步，拖动滑块的一次操作算一步） | `{ done }`：没有可撤销 / 重做时返回成功且 done=false，不算错误 |
| `set_ab_preview` | `{on}` | 临时显示 mod 默认值 | — |
| `save_sculpt` | `{name}` | 保存到 `user/sculpt/` | user/sculpt |

### 5.5 预设
| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `write_binding` | `{part, expression, sculpt, gains?}` | 写父预设，**只写 `user/`** | user/bindings |
| `restore_mod_binding` | `{part}` | 删除 user 版本，回到 mod 自带的父预设 | user/bindings |
| `request_delete` | `{kind, name}` | 进入待确认状态（`state.presets.pending_delete`） | — |
| `confirm_delete` / `cancel_delete` | `{}` | 确认或取消删除；只能删除 `user/` 下的文件 | user/* |
| `import_preset` | `{kind, path}` | 从指定路径复制到 `user/`，复制前先校验 | user/* |

### 5.6 错误码
| 代码 | 含义 |
|---|---|
| `E_BAD_ARGS` | 参数缺失或类型错误 |
| `E_NOT_FOUND` | 通道、部件或预设不存在 |
| `E_READONLY` | 试图修改内置或 mod 自带文件 |
| `E_FBS_OWNED` | 该通道由 FBS 管理，本插件不写入 |
| `E_NODE_INVALID` | 节点树校验失败（例如循环引用、引用了不存在的通道） |
| `E_UNSAVED` | 映射存在未保存修改，需保存或恢复后再切换配置 |
| `E_SCHEMA` | JSON 格式或 schema 版本不支持 |
| `E_IO` | 文件读写失败 |
| `E_NOT_SCANNED` | 捏脸操作前还没有扫描 |

## 6. 通道归属（`owner`）

> **2026-10-10 更新：表情和捏脸可以共用一个形态键。** 表情占用的键（`owner = "expression"`，状态里 `mixed = true`）不再锁定，可以在捏脸里设值、存进捏脸预设。写入时把捏脸值 s 当作静止位置，表情值 e 重映射到它上面：`最终值 = s + (1 - s) × e`（s = 0 时和以前一样；s ≥ 1 时直接用 s）。例：闭眼键捏到 0.4 做睡眼，静止 0.4、半眨 0.7、全闭 1.0。按部件单独设的值也按部件合成；外部插件的值不参与合成，直接写入。实现：`Sculpt.mix`、`API.drive`（`refresh_base` / `link_base_keys`）、`Writer.write_target` 的 base 参数。错误码 `E_EXPRESSION_OWNED` 不再出现。

> **2026-10-08 决定：FBS 兼容暂缓。** 使用 FBS 和使用 SKS 的用户重叠很少，第一版不做 FBS 检测，`owner` 只会是 `expression` 或 `self`。`fbs` 这个取值和 `E_FBS_OWNED` 错误码先保留在接口里，以后需要时直接补上检测即可，不用改界面。

每个形态键通道只能有一个"主人"，后端按以下优先级判定：

1. **`fbs`**：Female Body Sliders 正在管理的通道。本插件**完全不写**，界面锁定并标出"由 FBS 管理"。
   - 检测方法（待实现时确认）：读取 FBS 在 `reframework/data/` 下保存的当前装备预设 JSON，凡是其中出现的通道名都算 FBS 的。
2. **`expression`**：当前表情配置用到的通道。捏脸列表里默认隐藏。
3. **`self`**：其余通道，归捏脸系统。

捏脸修改一个 `fbs` 通道时返回 `E_FBS_OWNED`。

## 7. 时序

```
每帧 LateUpdateBehavior：
  1. 处理到期的扫描请求（换装检测、名片重试、手动 rescan）
  2. 读信号（fcParam、眼球角度）
  3. 计算表情权重 → live.weight
  4. 合成：捏脸层（编辑模式开启或需要重写时）+ 表情层
  5. 只写有变化的通道（跳过 fbs 通道）
  6. 面板打开时：计算 region_activity / signal，更新性能统计

每帧 d2d 绘制（面板打开时）：
  读 state（看 rev 有没有变）和 live → 绘制 → 根据用户操作调用 SKS.call
```

命令调用发生在绘制回调里。命令只修改内存状态和标记，真正写引擎在下一次 `LateUpdateBehavior` 里进行，所以绘制回调里不会出现引擎写入。

## 8. 文件目录

```
reframework/data/ShapeKeySystem/
  settings.json
  builtin/  profiles/*.json, aliases.json, labels.json, names/*.json   （随插件发布，只读；各游戏通用）
            <游戏 id>/ signals.json, armor_names.json, profiles/*.json   （只属于这个游戏，荒野是 mhwilds/）
                       recording_catalog.json, recordings/*.json       （内置面部动画测试数据）
  mods/     bindings/*.json, profiles/*.json, sculpt/*.json, names/*.json  （随 mod 发布，只读）
  user/     bindings/*.json, profiles/*.json, sculpt/*.json, names/*.json  （用户自己的，插件只写这里）
            recordings/*.json                             （用户面部动画录制）
            mocap.json                                    （面捕设置，见「面捕」一节）
  mocap/    live.json                                     （ifm_bridge.py 写入的最新一帧；builtin/mocap/ 放这个脚本）
```

`names/*.json`（`sks.names/1`，`{"names": ["Breasts_big", …]}`）只在引擎没有可用的 `getBlendShapeChannelName` 时用到（鬼武者、崛起；`tools/mesh_names.py` 能从 mod 的 `.mesh` 生成）。这时通道名只能从 `get_ChannelNameHash()` 反查：哈希是完整通道名 UTF-16LE 的 murmur3（seed 0xFFFFFFFF），SKS 拿自己知道的名字去算（ARKit、别名表、所有表情配置的通道和 `any`、捏脸预设和条件片段里的键、显示名表里的名字，再加上这些名字表），每个 ASCII 名字还会试 `BrowDownLeft`、`browDownLeft`、`Brow_Down_Left`、`brow_down_left` 几种写法。名字表按 `user/names` → `mods/names` → `builtin/names` 的顺序读，同一个哈希先到先得。`builtin/names/` 随插件发布、每个游戏都一样：`vrc.json`、`mmd.json` 是 VRChat / MMD 模型调查里的全部形态键名（`tests/vrc_faces.json`、`tests/mmd_names.json` 的并集），用常见命名的 mod 不用自带名字表。哈希数组的读法由适配器的 `hash_item_only` 决定：为 true 时只读 `get_Item`（有的游戏装箱的元素读出来是错数），否则先读 `get_elements()`、读不到再用 `get_Item`；RE4R 的原生通道查找用同一个读取函数。反查不到的通道显示为 `#XXXXXXXX`；用这个名字存进捏脸预设的值，以后名字能反查出来时照样生效（`NameHash.lua`）。

显示名（`Labels.lua`）：打开面板右上角的「翻译形态键」（设置 `translate_keys`）后，界面上用中文名代替形态键名，鼠标悬停时显示原名，搜索两种都能搜到。译名表只有中文，界面语言不是中文时仍显示原名。显示名只用于显示，匹配、预设、绑定和命令都还用原名。
- `builtin/labels.json`（`sks.labels/1`）：`{"sets": {"arkit": {"source": "…", "labels": {"eyeBlinkLeft": "左眼闭眼", …}}, …}}`。按命名体系分组，每组的 `source` 写明出处。现有 `arkit`（Apple ARFaceAnchor.BlendShapeLocation）、`mmd`（MikuMikuDance 自带的あにまさ式ミク）、`sks_mmd`（内置 mmd 配置的其余通道名），以及 `avatar_*`（VRChat / MMD 模型调查里确定的译名，按类别分组；来源和不确定的名字记在 `docs/labels/`）。
- `names/*.json` 可以加 `"labels": {"Breasts_big": "胸部变大", "#1A2B3C4D": "眼睛大小"}`，给 mod 自己的键起名，也可以覆盖内置的。
- 查找顺序：`user/names` → `mods/names` → 内置表 → 通过别名表对应到 ARKit 名的内置显示名 → 没有（显示原名）。名字比较和通道匹配用同一套规则（大小写、下划线、空格、全角半角、`节点.` 前缀、`_LODn` 都忽略）。
- 有显示名的名字也加进哈希反查用的名字列表。

父预设查找顺序：`user/bindings/<部件ID>.json` → `mods/bindings/<部件ID>.json` → 同系列 `<ch03_012>_*.json`（先 user 后 mods）→ `default.json`。

## 9. M1 实现说明（2026-10-08）

代码在游戏目录 `reframework/autorun/ShapeKeySystem.lua` 和 `ShapeKeySystem_Core/`（Util、Names、Profile、Scene、Writer、Expression、API、DebugUI）。和上文的差异：

- `SKS.set_ui_open(open, want_signals)`：多一个参数，映射编辑或调试页打开时传 `true`，后端才计算 `live.signal`。
- `live.eye_angle` 的结构是 `{L = {yaw =, pitch =}, R = {…}}`。
- 捏脸和预设类命令暂时返回 `E_NOT_IMPLEMENTED`（M2 实现）。
- 父预设还没有实现，所以表情增益、视线设置**暂时直接存进 `settings.json`**（拖动滑块后约 1 秒写一次）。M2 做父预设时再迁移过去。
- 首次运行时会从旧的 `ArkitFaceDriver.json` 导入增益和视线设置；旧脚本已改名为 `ArkitFaceDriver.lua.disabled`。
- 配置 JSON 的 `channels` 改为**数组**（保持顺序），信号用语义名 `{"s": "smile.L"}`，也可以直接写 `{"p": 33}`。
- 网格通道匹配：大小写、下划线、连字符、空格都忽略；接受 `节点.名字`；`_LODn` 结尾的通道会和 LOD0 一起驱动；再查别名表（`builtin/aliases.json`，配置里用 `aliases` 选择启用哪几组）。
- `Channel` 额外字段：`present`（网格里有没有）、`extension`、`gaze_set`、`note`、`edited`。
- 状态表暂时没有加只读元表。

**2026-10-09 补充（写入安全，`Guard.lua`；依据 SKS_Mocap 会话的闪退排查）：**
- 过场动画加载或播放时（`app.DemoMediator` 的 IsBusy / IsBusyLoad），以及玩家没有初始化好时（IsSetUp），完全不碰角色：先把还能安全写的通道清零，再放掉所有引擎对象引用，然后 `collectgarbage`。`state.debug.status` 显示 `paused: 原因`。
- 收到跳过或停止过场的请求（`requestSkip` 等钩子）时，立即放掉所有引用。
- 装备构建完成（`app.HunterCharacter.onEquipBuildEnd`）后，或部件名单发生变化时（每 5 帧检查一次），立即放掉引用，30 帧后重新扫描。
- 每个网格要连续 60 帧处于就绪状态（MeshReady、BlendShapeEnable、缓冲区没有被释放、权重缓冲已分配）才开始写入；之后每帧再做两项快速检查。定期重扫时，同一个网格（按地址识别）保留之前的就绪计数和上次写入的值，所以不会停写，也不会重写。
- 每帧只读网格上实际存在的通道要用到的 fcParam（引用也会追踪）。测试网格每帧的读取次数从 51 降到 10。`scene.rigs[i].reads` 显示这个数。
- 如果当前表情配置在这些部件上一个通道都驱动不了，而另一个配置能匹配到至少 3 个，就自动切换过去并给出提示。这是 M2 父预设出来之前的临时办法。
- 新增内置配置 `shinano.json`，对应 Shinano 原生的形态键名。
- 开关 `cutscene_drive`（2026-10-09 起默认开启；跳过后仍在播放 90 帧会自动重新驱动，加载结束进入播放也视为新的一段）：过场播放中（IsBusy 为真、IsBusyLoad 为假）照常驱动猎人。分段靠 `app.DemoMediator` 的钩子，都是前置钩子，在游戏执行之前先放掉引用：
  - `onPlayStartTimeline(i)`：每一段开始时触发（Lua Bone System 也挂在这里）。触发后放掉所有引用，等 30 帧，然后**搜索整个场景**重新扫描（过场里显示的猎人通常是副本 `Pl000_00`，不是主角色），再经过 60 帧预热后写入。
  - `requestSkip` / `execSkip` / `requestStop` / `requestForceStop` / `unload`：立刻放掉所有引用，直到下一段开始前都不再碰。
  - 如果一直收不到分段钩子，就把播放开始当作这一段的开始。
  - 在跳过、停止、unload、分段开始的前置钩子里，先把网格仍然就绪的通道清零，再放手。
  - 事件记录：`data/ShapeKeySystem/trail.log` 逐行立即落盘，记录门控变化、钩子调用、扫描、开始写入、清零和放手，用来查闪退前最后一刻的情况。2026-10-09 有一次闪退：退出 CG 回到选择界面 1~2 秒后，在游戏工作线程上读到空指针（RIP exe+0xb11b950，RCX=0），原因未知。
  - 2026-10-09 放弃了按时间轴判断：一条时间轴可能跨好几段（总长约 240000，播到约 207000 就切到下一个场景），中途不会重置，有的 CG 根本找不到时间轴。
- 探针实测（2026-10-09）：`_BlendShapeHashToIndexTable` 的键是 `getBlendShapeChannelName` 返回的**完整字符串**的 murmur3（UTF-16LE，seed 0xFFFFFFFF）。原版脸带 `BS_Face.` 前缀，哈希就是对带前缀的全名算的；mod 导出的名字不带前缀。下标和 mesh 通道一致（76/76、41/41）。
- 调试面板新增"通道哈希探针"：读取 `_BlendShapeHashToIndexTable`，判断键是用短名还是全名算的哈希，结果写入 `data/ShapeKeySystem/hash_probe.txt`。只读，不写游戏。

## 9b. M2 实现说明（2026-10-09，取代第 8 节的目录和查找顺序）

新增模块 `ShapeKeySystem_Core/Presets.lua`（父预设和捏脸预设的读写）、`ShapeKeySystem_Core/Sculpt.lua`（捏脸层）。第 5.4、5.5 节的命令已全部实现，另加 `load_sculpt`、`save_tuning`。离线测试 140 项通过，**还没在游戏内验证**。

### 三种预设的关系（2026-10-09 定）

| | 表情配置 profile | 捏脸预设 sculpt | 父预设 binding |
|---|---|---|---|
| 作用范围 | 全局，按通道名匹配，不认具体 mesh | 一个建模专属，或通用 | 一个部件 |
| 位置 | `builtin/`、`mods/profiles/`、`user/profiles/` | `<src>/<建模>/sculpt/` 或 `<src>/sculpt/`（通用） | `<src>/<建模>/<部件ID>.json`、`<src>/default.json` |
| 引用别人 | 只能 `extends` | 无 | 按 id 引用表情配置，按名字引用捏脸预设 |

- **增益和视线设置只跟着部件走**，存在父预设里：`gains`（整体、部位、视线强度、平滑、单通道增益、`for_profile`）和 `eyes`（`full_deg`、`invert`、`sets`）。
- **捏脸列表固定为全部通道**：表情配置驱动的键标为 `owner = "expression"`、`locked = true`，修改时返回 `E_EXPRESSION_OWNED`，捏脸层不写入这些通道，捏脸预设里也不保存它们。以后可以考虑"表情 + 捏脸混合"，根据捏脸形态键的取值动态调整表情强度。

### 目录

```
reframework/data/ShapeKeySystem/
  settings.json                           全局设置；增益和视线只在这里作为"没有父预设时"的兜底
  builtin/  profiles/*.json, aliases.json, <游戏 id>/（见第 8 节）
  mods/ | user/                           mods/ 随 mod 发布、只读；user/ 是唯一会写的地方
    default.json                          全局默认父预设
    profiles/*.json                       表情配置
    sculpt/*.json                         通用捏脸预设
    <建模>/<部件ID>.json                   各部位的父预设，例如 ch03_012_001/ch03_012_0014.json
    <建模>/sculpt/*.json                   这个建模的捏脸预设
```

建模文件夹取部件 ID 去掉最后一位（`ch03_012_0014` → `ch03_012_001`）。不符合 `chXX_SSS_MMMs` 格式的部件，直接用部件 ID 作文件夹名。

### 父预设查找

部件 ID 的结构是 `ch03_012_0014`：`012` 是系列，`001` 是建模，最后一位 `4` 是部位。同一建模的 2 号部位（身体，例如 `ch03_012_0012`）是这套建模的**代表部件 R**。以部件 P 为例，依次：

1. R 的文件写了 `"global": true` → 这套建模的所有部位都只用 R，各部位自己的文件一律忽略；
2. P 自己的文件（各部位自己的优先级最高）；
3. R 的文件（同一建模共用）；
4. `default.json`。

每一级都先 `user/` 后 `mods/`。同系列下不同建模的模型不同，所以不按系列回退。

- **过期预设**：`mods/` 下的父预设可以带 `"fingerprints": {"<部件ID>": "<通道指纹>"}`。指纹和实际穿着的 mesh 不一致时，说明这是被后装 mod 覆盖了 mesh、但没覆盖预设而留下的旧文件，跳过并提示一次。`user/` 下的文件不做这个检查。
- **生效的父预设**：在身上所有部件命中的父预设里，按 global、部位自己、建模代表、`default.json` 的顺序取最具体的一个；同级时选通道多的部件。它的 `profile` 在部件穿戴期间代替全局配置，部件脱下后恢复全局配置。只有在没有父预设指定配置时，才会按覆盖率自动切换配置。
- **父预设里的捏脸预设名**：先在这个父预设所在的建模文件夹里找，再到通用预设里找。不会跨到别的建模文件夹。
- **没有形态键的部件**：不需要任何 json。
- **删除 = 写删除标记**：REFramework 的 Lua 不能可靠地删除文件，所以删除和"恢复 mod 父预设"都是往 `user/` 下写 `{"deleted": true}`，读取时当作不存在。

### 增益和视线（跟着部件走）

- 父预设生效时，`cfg.expression` 和 `cfg.eyes` 里放的是**这个部件的工作副本**：以 `settings.json` 的兜底值为底，覆盖上父预设里的值。修改只改内存，`state.expression.tuning.dirty = true`；`save_tuning` 把它写进这个父预设对应的 `user/` 文件（层级不变：global、模型代表、`default.json` 都写回原来那一级），并保留 profile、sculpt、global、fingerprints 等其他字段。
- `settings.json` **只保存兜底值**，不会被父预设里的值污染。没有父预设时，修改照旧直接存进 `settings.json`。
- 只有父预设里的增益和视线内容、命中的文件或表情配置发生变化时，才会重新加载。定期重扫不会冲掉未保存的修改。
- `gains.for_profile`：单通道增益是为哪个表情配置调的。当前配置不同时，单通道增益不生效（`tuning.profile_mismatch = true`，并提示一次）；整体、部位、视线这些设置照常生效。`save_tuning` 不会覆盖掉为另一个配置调的单通道增益。
- 视线的中立位校准（`eyes.neutral`）仍然是全局的，因为它属于猎人的脸部骨骼，和 mesh 无关。
- `state.expression.tuning = {source = "binding" / "settings", path, dirty, profile_mismatch, for_profile}`。

### 捏脸

- **键名**：取通道名最后一个 `.` 之后的部分，再去掉 `_LODn`。同名的 LOD 副本和不同部件里的同名形态键合并成一项。
- **`default` 和 `value`**：
  - `default`：只看 mod 自带的父预设链（`mods/`）选出的捏脸预设，没有则为 0。"恢复默认"和 A/B 预览都用它。
  - `value`：生效的父预设所选的捏脸预设。用户改过的键（`touched`）在重新扫描、换预设时保留，没改过的跟着预设走。
- **`load_sculpt {name, folder?}`**：加载一份捏脸预设，不写父预设，算一步撤销。预设里没提到的键回到 mod 默认值。`folder` 省略时，先找当前建模文件夹，再找通用预设。换装后，"当前预设"会自动恢复成父预设里的那份。
- **`save_sculpt {name, general?}`**：默认存进 `user/<当前建模>/sculpt/`；`general = true` 时存为通用预设 `user/sculpt/`。
- **`request_delete {kind = "sculpt", name, folder?}`**：只能删除 `user/` 下的文件。
- **写入**：
  - 网格连续就绪 60 帧后写一次；值变了才再写；编辑模式下每帧写。
  - 第一次处理某个 mesh 时（包括重新扫描之后），先读一次引擎里的当前值。和目标值相同的通道不写；之前写过、在重新扫描后丢了记录的值，也能被正确清零。
  - 关闭总开关或脚本重置时，只把非零的通道清零。过场或重建时释放引用、不写入，恢复后补写。
- **撤销**：同一个键相隔 5 帧以内的连续修改合并成一步（拖动滑块），最多 50 步。
- **`scan`** 的字段：`{time, parts, keys, expression_keys}`。

### mod 作者（以及 Toolkit 导出）需要放的文件

```
reframework/data/ShapeKeySystem/mods/ch03_012_001/ch03_012_0012.json     # 只为带形态键的部件生成
  {"schema": "sks.binding/1", "part": "ch03_012_0012",
   "profile": "shinano",                         # 可省：用全局配置
   "sculpt": "Airi 日常脸",                       # 可省：捏脸值为 0
   "gains": {"for_profile": "shinano", "master_gain": 1.0, "region_gains": {"mouth": 1.0},
             "channel_gains": {"mouthSmileLeft": 1.2}},
   "eyes": {"full_deg": {"yaw": 25, "pitch": 20}, "invert": {"yaw": false}, "sets": {"look": true}},
   "global": false,                              # 只在 2 号部位的文件里有意义
   "fingerprints": {"ch03_012_0012": "1a2b3c4d"}}
reframework/data/ShapeKeySystem/mods/ch03_012_001/sculpt/Airi 日常脸.json
  {"schema": "sks.sculpt/1", "name": "Airi 日常脸",
   "target": {"part": "ch03_012_0012", "channel_hash": "1a2b3c4d"},
   "values": {"Waist_thin": 0.3}, "overrides": {"ch03_012_0014": {"Waist_thin": 0.5}}}
reframework/data/ShapeKeySystem/mods/profiles/<作者前缀.名字>.json            # 只有内置配置覆盖不到时才需要
```

- `values` 的键是**捏脸键名**（通道名去掉 `xxx.` 前缀和 `_LODn` 后缀，大小写保持不变），只写不归表情配置管的键。
- 通道指纹：把这个部件全部通道名（mesh 里的完整名字）排序后用 `\n` 连接，算 FNV-1a 32 位，写成 8 位小写十六进制（`Util.fnv`）。

## 10. 待定

- FBS 管理通道的检测方法（第 6 节）：已暂缓，第一版不做。
- 撤销是否扩展到表情增益和映射编辑（目前只覆盖捏脸）。
- 多语言文本由界面层负责还是后端返回 key：建议后端只返回 key 和参数，界面负责翻译。

## 11. 给其他插件的公开接口 `ShapeKeySystemAPI`（2026-10-10，v1.0）

其他 REFramework Lua 插件可以通过这个接口控制形态键。实现在 `ShapeKeySystem_Core/External.lua` 和 `API.lua` 末尾。

### 11.1 规则
- **覆盖**：外部插件设置的值会盖过表情和捏脸，优先级为 外部 > 表情 > 捏脸。多个插件控制同一个键时，最后设置的生效。
- **租约**：每次 `set` 只在 `ttl` 秒内有效，默认 0.5 秒，最长 60 秒。持续控制的插件需要在这段时间内再次 `set`，最简单的做法是每帧都调用。插件崩溃或被卸载后，值会自动归还，不会一直留在角色身上。`ttl = 0` 表示一直保持，直到调用 `release`。
- **数值范围**：会被截断到 0 ~ 用户设置的捏脸上限（`sculpt_max`，默认 1）。
- **写入安全**：外部插件的值和表情、捏脸一样，都走同一套保护（网格稳定后才写入、过场 / 换装时先放手）。接口本身不调用任何引擎函数，可以在任意回调里调用。
- **用户优先**：面板上会把这些键标成"由 某某 控制"，用户随时可以"收回"（调试页有"全部收回"）。收回后，如果插件继续 `set`，值会重新生效。
- **键名**：不区分大小写，忽略 `_`、`-`、`.` 和空格。可以用网格里的形态键名（去掉 `blendShape1.` 前缀和 `_LODn` 后缀），也可以用表情配置里的标准名（例如 ARKit 的 `jawOpen`），或者别名表里的写法。

### 11.2 获取接口
REFramework 只在脚本加载阶段能 `require` 到模块，各插件的加载顺序也不确定，所以接口以全局变量的形式提供：

```lua
local function on_sks(api)
    -- api.version == "1.0"
end
if ShapeKeySystemAPI then
    on_sks(ShapeKeySystemAPI)
else
    -- SKS 还没加载：排队，SKS 初始化时会依次调用
    ShapeKeySystemAPI_pending = ShapeKeySystemAPI_pending or {}
    table.insert(ShapeKeySystemAPI_pending, on_sks)
end
```

脚本重置时 SKS 会清掉全局变量，重新加载后再发布新的接口表。长期持有引用的插件，建议每次使用前都重新读一次 `ShapeKeySystemAPI`。

### 11.3 函数
| 函数 | 返回 | 说明 |
|---|---|---|
| `api.set(owner, name, value, opts?)` | `ok, err, msg` | `owner`：插件名（1~64 字符）；`opts.ttl`：租约秒数 |
| `api.release(owner, name)` | `ok` | 归还一个键；只能归还自己持有的 |
| `api.release_all(owner)` | `ok` | 归还自己持有的全部键 |
| `api.get(name)` | `value, controller` | 当前（或即将写入的）值；`controller` 为 `"external:<owner>"` / `"expression"` / `"sculpt"`，不认识的键返回 nil |
| `api.channels()` | list | 身上所有形态键（按名字合并）：`{name, parts, value, controller, expression}` |
| `api.on("scan", fn)` | id | 每次扫描（换装、重新扫描）后调用 `fn()` |
| `api.off(id)` | — | 移除监听 |
| `api.is_ready()` | bool | 已经扫描到形态键 |

错误码同第 5.6 节：参数错误返回 `false, "E_BAD_ARGS", 说明`。

### 11.4 例子
```lua
-- 呼吸时胸部轻微起伏（每帧刷新，插件停止后 0.5 秒自动归还）
local t = 0
re.on_frame(function()
    local api = ShapeKeySystemAPI
    if not api then return end
    t = t + 1 / 60
    api.set("BreathMod", "Breast_big", 0.15 + 0.05 * math.sin(t * 1.5))
end)
```

### 11.5 面板命令
用户收回控制：`external_release {owner?, name?}`（两个都不填 = 全部收回）。状态：`state.external = {rev, held = {{name, owner, value}}, by_norm}`。

## 12. 条件表情（2026-10-10）

游戏状态满足规则时，播放一个**表情片段**，覆盖片段里写到的形态键，带淡入淡出。实现：`Core/Conditions.lua`（条件注册表和读取）、`Core/CondExpr.lua`（规则、保持时间、淡变、合成）、`UI/PageConditions.lua`。

- **优先级**：外部插件 > 条件表情 > fcParam 表情（含捏脸合成）> 纯捏脸。片段的值相当于"表情值"：`e' = e × (1 − α) + 目标 × α`，然后照常和捏脸值做重映射 `s + (1 − s) × e'`，外部插件仍然可以覆盖。不受表情驱动的键按 e = 0 处理，走同一个重映射（2026-10-10 用户决定统一成重映射；之前是从捏脸值线性插值到目标，会把捏过的值往下拉）。所以片段只会在捏脸值之上往上加，不会压低捏脸值；捏脸值 ≥ 1 时片段不起作用。面部图互动同理。
- **作用范围**：只作用于游戏中的主角色。菜单、加载、过场、公会卡里不判断条件，片段会重置。
- **规则**（沿用用户 RE4 变体管理器的设计）：状态列表从上到下排优先级，第一个命中的状态播放它的片段。每个状态可以有多条规则，任意一条命中即算命中。规则内的条件统一用"且"或"或"连接，空规则永远不命中。条件读不到值时算不满足。`hold` 表示条件结束后再保持多少秒。数值条件的 `band` 是回差，命中后要越过阈值这么多才算结束。`auto = false` 时暂停所有规则。面板的「预览」可以强制播放某个片段。
- **文件**：`user/conditions/<id>.json` 或 `mods/conditions/<id>.json`，schema 为 `sks.conditions/1`，格式见 `CondExpr.lua` 文件头。父预设用 `"conditions": "<id>"` 引用；没有父预设引用时，使用 `settings.conditions`。
- **命令**：`cond_select {name}`、`cond_new {name}`、`cond_edit {data}`（整份替换工作副本）、`cond_save {as_name?}`、`cond_revert`、`cond_preview {clip?}`；删除走 `request_delete {kind = "conditions"}`。`write_binding` 增加 `conditions` 参数；不传这个参数时，保留同一部件原有的引用。
- **状态**：`state.conditions = {rev, sets, current = {id, name, source, dirty, data}, defs, binding_name, binding_part, global_name}`。实时值在 `live.cond = {values, status, playing, alpha, sampled}`，只在面板打开时更新。
- **第一版的条件**（2026-10-10 用 REE MCP 实测过路径）：
  - 布尔：拔刀、被怪物察觉、战斗中、大型怪物战斗中、怪物愤怒中、半战斗、骑乘、攀爬、帐篷、营地、生活区域、炎热 / 寒冷区域、群袭、倒地。
  - 数值：血量%、红血%、耐力%、太刀气刃等级、蓄力等级。
  - 事件：受伤、回血。按血量绝对值变化判断，最大血量不变才算；读不到时重置基准值。
  - 枚举：武器类型、武器形态（双刀、斩斧、盾斧、操虫棍）。
- 第二版：动作识别（钩 `changeActionRequest`）、见切成功、异常状态。

## 13. 面部图互动（2026-10-10）

基础「表情」页的面部图只用来做互动，不再用来选部位；调哪个部位的强度，改用右侧的选区按钮。实现在 `Core/Touch.lua` 和 `UI/PageBasic.lua`（`face_press`）。

- **点一下**（按下后不移动就松开）：额头 → 额头反应；脸颊 → 脸红；眼睛 → 闭眼。片段淡入 0.08 秒、保持 1 秒（可配置 `hold`）、淡出 0.35 秒。连续点击会重新计时。点嘴巴不触发反应。
- **按住拖动**：嘴巴 → 往拖动方向拉。拖到嘴巴半宽的 2.5 倍时达到满权重；松手后在 0.3 秒内回弹。眼睛 → 视线（`gaze_hold`，原有功能，现在要移动超过 4 像素才算拖动）。
- **额头热区**：面部风格里没有额头区，所以用眉毛的椭圆往上推算一个，不需要美术图层。悬停时会画出它的轮廓。
- **合成**：外部插件 > 互动 > 条件表情 > fcParam 表情 > 捏脸，插值方式和条件表情相同。互动作用于所有被驱动的角色。游戏处于加载等不稳定状态时会重置。
- **键的映射**：条件表情配置里可以加一段 `interactions`：`{forehead = {values = {key = w}, hold}, cheek, eye, mouth = {left, right, up, down}}`；没写到的部位，按键名自动识别：
  - 额头：`eye_><` + `mouth_△`；或者 `eyeSquint*` + `mouthPucker`。
  - 脸颊：`other_cheek_2` / `blush`；或者 `cheekPuff*`。
  - 眼睛：`eye_close`；或者 `eyeBlink*`。
  - 嘴巴：`mouthLeft` / `mouthRight` / `mouthUpperUp*` / `mouthLowerDown*`。
  - 方向约定：面部图是正对观看者的，所以往观看者的右边拉，对应的是脸自己的左边（`mouthLeft`）。
- **命令**：`touch_poke {zone}`、`touch_drag {x, y}`（拖动期间每帧调用，范围 -1..1）、`touch_release {}`。**状态**：`state.touch = {rev, zones = {forehead, cheek, eye, mouth}, map}`。

## 14. 界面整理（2026-10-10）："当前绑定"取代"父预设"

- **界面用语**：界面上不再出现"父预设"，统一叫"绑定"。后端的文件、schema 和字段名都不变（`sks.binding/1`）。
- **绑定**：按装备（模型）记录"穿上它时默认用哪个表情配置 / 捏脸配置 / 条件表情配置，以及增益和视线设置"。它只是引用，不会改动配置文件本身。手动切换的配置在换装之前一直有效（表情配置用 `C.profile_manual` 记录）。
- **三个页面统一结构**：捏脸、表情详情、条件表情的顶部都是 配置下拉 + [设为默认] + 保存 / 另存为（表情详情是 应用 + 保存调整）。下拉里，这套装备的默认配置后面标"· 默认"；只有全局默认生效时标"· 全局默认"，按钮这时写成"设为 <装备名> 的默认"。当前选中的就是默认配置时，不显示按钮。实现：`W.default_suffix`、`W.default_button`。装备名放在按钮的悬停提示里。
  - 捏脸页「保存」：当前是自己的配置时直接覆盖；当前是 mod 自带的或还没有配置时在操作栏下展开命名编辑行。「另存为…」取代原来的「新建…」。「保存并绑定」去掉了。
- **命令** `bind_config {kind = "sculpt" | "expression" | "conditions", name}`：只改生效绑定里对应的那一个字段，其他字段保留，写到 `user/`（mod 的绑定会复制一份，原文件不动）。身上没有绑定时，为通道最多的那个部件所属模型新建一个整套共用的绑定。状态在 `state.presets.bind = {base, model, display, active}`，`state.presets.binding` 里新增 `profile_id`、`conditions`。
- **装备名**：`builtin/armor_names.json`（418 个模型编号，由 Modding-Toolkit 的 `assets/mhws/armor_sets/mhws_armor_sets.json` 生成）。显示优先级：绑定文件里的 `name` > 原版装备名 > 模型编号。
- **页面调整**：「预设」页从导航移除，内容放进「设置与调试」底部可折叠的"绑定与配置文件"区，给排查问题用。查找过程里，整套共用的绑定不再重复列出。「视线」页并进了表情详情底部的「视线设置」区。
- **捏脸**：新增 `reset_sculpt_all`（重置）、`zero_sculpt_all`（归零），各算一步撤销。新增「隐藏非预设通道」（`SculptKey.in_preset`），「A/B 对比」改名为「对比初始」。

## 15. 面部动画测试

### 目录与所有权

- 内置录制：`builtin/<游戏 id>/recordings/*.json`；参数表：`builtin/<游戏 id>/recording_catalog.json`，随主包发布、只读。
- 用户录制：`user/recordings/*.json`。每个游戏有自己的安装目录，用户数据不再按游戏分层。
- 兼容读取旧 `user/games/<当前游戏 id>/recordings/`，同名文件优先使用新目录；内置与用户文件分别使用
  `builtin:<文件名>.json`、`user:<文件名>.json` 作为播放 ID，迁移不改变 ID。
- 旧内置 `games/mhwilds/` 不再读取。部署只清理其中的参数表及 `Speak.json`、`CampMeals.json`，保留其他文件和全部用户数据。

### 录制格式

`Recording.decode` 接受 `fcparam.recording/1` 和 `fcparam.recording/2`。参数表使用 `sks.recording.catalog/1`，
包含 `game` 和 `params = [{param, hash, source}]`；荒野表中的 `source` 是对应的骨骼名。

| 字段 | 约束 |
|---|---|
| `game` | 可省略；存在时必须等于当前适配器 ID |
| `duration` | 有限数值，大于 0、不超过 300 秒 |
| `params` | 1～200 项，每项包含唯一参数编号 `param` 和名称哈希 `hash`；必须与当前游戏参数表一致 |
| `frames` | 2～9001 帧；`t` 有限、非负、严格递增，最后一帧时间等于 `duration` |
| `/1` 帧 | 每帧提供完整 `raw` 数组；如有 `final`，每帧也必须提供完整数组，长度与 `params` 一致 |
| `/2` 编码 | `encoding = "quantized-delta"`，`raw_scale = 10000000`；存在最终轨时 `final_scale = 100000` |
| `/2` 首帧 | `raw` 及已声明的 `final` 使用完整整数数组，解码时除以对应比例 |
| `/2` 后续帧 | `d` 为 raw 差分，`df` 为 final 差分；形如 `[列号, 新绝对值, ...]`，列号为 `params` 的一基下标且严格递增 |

差分值替换前一帧的对应列，不是增量相加；缺失或空差分保留前一帧。解码同时校验已声明的两条轨道，
再在相邻帧间线性插值。raw 解码结果为引擎输入单位，不能再乘信号字典的 `full`。
final 解码结果经适配器的 `final_unit / 字典 full` 换算后用于 SKS 求值，只作用于匹配会话的主角色；缺失参数置零，眼球角度默认归零，也可由适配器应用录制视线。

### 命令与状态

UI 通过 `SKS.call("playback", args)` 提交命令，`args.action` 为 `refresh`、`play`、`pause`、`resume`、
`stop`、`seek` 或 `options`。`play` 指定已登记的 `id` 和 `mode = "raw" | "final"`；`seek` 指定秒数 `time`；
`options` 接受 `speed`（0.25～2）和布尔值 `loop`。只有 `refresh` 立即更新文件列表，其余操作按顺序在游戏更新回调执行。

`state.playback` 提供录制列表、支持状态、播放状态、时间、速度、循环选项、提示及 `analysis`。
播放状态为 `stopped`、`preparing`、`playing` 或 `paused`。准备阶段分片完成全量校验及分析，
`preparation_progress` 为当前阶段的 0～1 进度；所有轨道校验通过后才连接游戏对象。
准备时允许停止、重新播放和调整选项；跳转必须等待准备完成。暂停命令在准备结束后生效。
文件读取及 JSON 解析仍同步执行。解码快照只读，连续空差分共享同一快照；采样结果独立于快照。

`debug.perf.timings` 按最近 60 次调用提供 `avg`、`max`、`last`、`p95` 和 `count`，耗时单位为 ms。
分类包括 `tick`、`scan`、`ui`、`playback_load`、`playback_prepare`、`playback_tick` 和 `raw_inject`；
各分类会重叠，不得相加。P95 每 60 次调用更新，首次调用也提供初值。
分析按实际经过的录制帧统计绝对幅值超过 1% 的信号，raw 用适配器的 `raw_unit` 判断，final 用归一化幅值判断。
暂停不累计，循环累计，跳转只计目标显示帧；同命中数按参数编号排序。
绑定从当前已应用配置的完整依赖树计算，包含原始通道和间接引用；停止保留统计并可刷新绑定，重新播放清零。

## 原生信号诊断

适配器的可选接口 `native_snapshot()` 返回纯数据快照。`source` 为角色及部件身份签名；`joints` 按名字保存局部位置 xyz 与旋转四元数 xyzw，位置单位为米；`measurements` 为标定轴上的测量值，单位由标定的 kind 决定（pos 为毫米、rot 为度）；`taps` 为原生通道权重；`outputs` 为适配器归一化输出；`status` 保存缺失或不可读来源的原因。

可选字段 `buffers` 保存头部权重状态：`channels` 为通道数，`count` 为可写数量，`length` 为现有权重列表长度。

`SKS.call("native_signals", {action = ..., label = ...})` 支持 `start`、`stop`、`baseline`、`snapshot` 和 `retry`。命令在下一次更新中处理，采样先于 SKS 权重写入。`state.native_signals` 提供支持状态、录制状态、样本数、已录时长、骨骼变化、提示和保存路径。中立位只参与诊断比较，不改变运行标定。

录制格式为 `sks.native-signals/1`，包含 `game`、`label`、`rate_hz`、`duration`、`calibration`、`summary`、`reason` 和 `samples`。目标采样率为 20 Hz，每个样本以 `t` 保存实际经过秒数，`values` 保存快照；标定表只在文件顶层保存一次。录制最长 90 秒，来源消失或身份变化时自动结束。文件保存在 `ShapeKeySystem/native_signals_<game>_*.json`，保存失败时保留数据用于重试。

独立快照格式为 `sks.native-snapshot/1`，包含 `game` 和 `snapshot`，文件保存在 `ShapeKeySystem/native_snapshot_<game>_*.json`。诊断数据供信号分析和标定使用，与面部动画测试的 `fcparam.recording` 格式分别处理。

### 命名信号回放

RE4R 的播放适配器通过可选的 `decode` 使用 `sks.native-signals/1`，沿用播放命令与状态；模式为 `final`，界面显示“录制信号回放”。`outputs` 中的 ARKit 名称映射为适配器原始通道编号，数值维持 0..1，当前 Profile 继续负责形态键映射。

可选的 `recording_dirs` 扩展录制目录；`describe(data)` 过滤格式并提供显示名称和轨道支持信息；`default_mode`、`modes` 和 `message(decoded)` 提供播放模式与说明。解码器返回通用的 `frames`、`map`、`hashes`、`n`、`duration` 和 `track`，沿用分片准备、时间采样和分析。

RE4R 的解码帧另存 `eye_columns`，指向录制视线的 yaw/pitch 列。可选的 `apply_angles(rig, values, clip, eyes)` 在输入覆盖时应用视线；未提供时沿用最终信号测试的眼球角度归零行为。

录制标定表包含 `eye_reference` 时，解码先消除对应眼球的参考旋转，再计算视线角，以兼容已有录制。当前实时视线沿用 SKS 的眼球中立位设置。

## 自动表情（程序化表情层）

Core 的 `Procedural.lua` 有三个生成器：眨眼（`blink.L` / `blink.R`）、待机微微张嘴（`jawOpen`）和视线微动。前两个输出与信号字典同名的信号，
所以内置的 ARKit、MMD、VRC 配置不用改：`Profile` 编译这些名字的 `s` 节点时套一层合成，节点值 = 游戏信号与生成值按 `mode` 合成。
生成器关闭、总开关关闭或 `mode` 为 `game` 时不产生值，节点就是原来的游戏信号。字典里没有原始通道（`raw` 为 null，或游戏没有字典）的这几个信号
不标 `no_signal`，来源文字显示「（自动表情）」。视线微动是以度为单位的偏移，`drive` 读完眼球角度后由 `Procedural.apply_gaze` 加到 rig 的视线角上
（在面板拖动视线 `gaze_hold` 之前），之后照常经过 `eye` 节点和满权重角度。

| `mode` | 合成 |
|---|---|
| `game` | 只用游戏信号和游戏视线 |
| `fallback`（默认） | 只补游戏缺失的部分：信号取 max(游戏, 生成)，视线加上偏移。信号缺失 = 字典没有原始通道；视线缺失 = 这个角色没有眼球关节；两者也可以由适配器的 `procedural` 表声明（崛起 `procedural = { blink = true, breath = true }`：眼睑骨和下颌骨有标定，但待机从不眨眼，嘴部呼吸低于 `jawOpen` 的 `lo`）。荒野、鬼武者、RE4R 都有眨眼、张嘴信号和眼球关节，行为不变 |
| `add` | 全部叠加：信号 = 游戏 + 生成（游戏值不超过 1 时结果截到 1），视线 = 游戏视线 + 偏移 |

生成器的时钟只在连续帧上前进：门（`gate`）关闭、过场不驱动等跳过的帧不计时，恢复后第一帧步长为 0；单帧步长最多 0.1 秒。所有角色共用一个时钟。
三个生成器各用一条随机数序列，调一个的参数不影响另外两个的时间。

`settings.json` 的 `procedural`（不随父预设的调整保存）：

```json
"procedural": { "enabled": true, "mode": "fallback", "frequency": 2.0, "speed": 1.0,
  "blink": { "enabled": true, "interval_min": 7.0, "interval_max": 12.0, "close": 0.075, "hold": 0.035, "open": 0.12,
             "double_chance": 0.15, "double_gap": 0.1, "asym": 0.0 },
  "gaze": { "enabled": true, "amplitude": 3.0, "interval_min": 0.8, "interval_max": 2.5, "move": 0.05, "center_chance": 0.3 },
  "breath": { "enabled": true, "amplitude": 0.1, "interval_min": 7.0, "interval_max": 12.0, "open": 1.2, "hold": 0.4, "close": 1.6 } }
```

- 眨眼：间隔在 `interval_min`..`interval_max` 秒间均匀取值，再除以 `frequency`（0.2–4，默认 2，即约 3.5–6 秒一次）；单次分闭眼 `close`、
  保持 `hold`、睁眼 `open` 三段（秒），闭眼和睁眼用 smoothstep，各段除以 `speed`（0.25–3）；`double_chance` 为连眨两次的概率，两次之间隔
  `double_gap` 秒，第二次不会再连眨；`asym` 为右眼滞后的秒数（0–0.1）。`frequency` 和 `speed` 只作用于眨眼。
- 视线微动：每隔 `interval_min`..`interval_max` 秒跳到新的目标，跳动用 `move` 秒（smoothstep），之后停住；目标的水平角在 ±`amplitude` 度内
  （0–15），垂直角在 ±0.6×`amplitude` 内，`center_chance` 的概率回到正前方。两眼同步。
- 微微张嘴：每隔 `interval_min`..`interval_max` 秒，`jawOpen` 用 `open` 秒升到 `amplitude`（0–1），保持 `hold` 秒，再用 `close` 秒回到 0（smoothstep）。
- 各组的 `enabled` 单独开关这个生成器；顶层 `enabled` 是总开关。

修改间隔或频率时，若等待中的间隔比新的最长间隔还长，就重新取一次；切换开关或合成方式时重排全部时间。

`state.procedural`：`enabled`、`mode`、`frequency`、`speed`、`blink`、`gaze`、`breath`（同上），`modes`（顺序）、`mode_names`（界面文字），
`lacking`（`blink.L`、`blink.R`、`jawOpen` 是否按「缺失」处理；`gaze` 按主角色有没有眼球关节或适配器的声明，每次扫描后更新）。
「表情详情」页的「自动表情」区提供总开关、合成方式，眨眼的开关、频率和速度，视线微动的开关和幅度，微微张嘴的开关和幅度，每行右侧是当前值。

## 面捕（iFacialMocap）

进阶「面捕」页。手机上的 iFacialMocap 把 ARKit 52 个通道和头部角度用 UDP 发到电脑；REFramework 的 Lua 不能开 socket，所以由 `builtin/mocap/ifm_bridge.py`（只用标准库）接收，每收到一包就把最新一帧整体替换写入 `mocap/live.json`，SKS 每帧读一次（`Mocap.lua`）。

```
python reframework/data/ShapeKeySystem/builtin/mocap/ifm_bridge.py <手机 IP>   # 向手机发开始信号
python reframework/data/ShapeKeySystem/builtin/mocap/ifm_bridge.py             # 只监听（手机已在发）
```

`live.json`：`{"seq": n, "w": [52 个 0..1，顺序同 Names.ARKIT52], "head": [6 个数] | null, "le": [...], "re": [...]}`。`seq` 不变就当没有新数据；SKS 启动后看到的第一份文件不算数（可能是上次留下的）。Windows Defender 实时扫描开着时每次读取约 5 毫秒，需要把 `mocap/` 加入排除项。

写入：52 个通道作为外部值（`External.lua`，所有者 `mocap`）每帧续租，和其他插件一样覆盖表情和捏脸、走同一套写入保护（预热、过场、换装重建）。每个通道 = 手机值 × 淡入系数 + 纯表情值 ×（1 − 淡入系数），所以数据开始或中断时脸在 `fade_sec` 秒内平滑交接；系数回到 0 时放掉全部外部值。通道名先按当前表情配置的槽位解析，解析不到的再按名字匹配捏脸键；部件上没有 ARKit 键（或别名）的脸收不到。

头部转动：`UpdateMotion` 之后，把转角按 Neck_0 25%、Neck_1 25%、Head 50% 分到荒野猎人的骨骼上（角色空间：yaw 绕上、pitch 绕侧、roll 绕前，叠加在动画之上）。只在上一帧驱动了主角色时才碰骨骼；SKS 放掉角色（换装、过场跳过或结束、菜单）时同时放掉骨骼引用，下次再重新取。

| 命令 | 参数 | 作用 | 持久化 |
|---|---|---|---|
| `mocap` | `{patch}` | 修改面捕设置：`enabled`、`mirror`、`gain`（0–3）、`smoothing`（0–1）、`fade_sec`（0–2）、`timeout`（0.1–5 秒，多久没新数据算中断）、`channel_gains = {ARKit 名 = 0–3 或 false}`（1 和 false 都表示不单独调）、`head = {enabled, gain 0–2, max_deg 5–90, smoothing 0–1, invert = {pitch/yaw/roll = bool}, order = {pitch/yaw/roll = 1–3}}`、`test = {on, pitch, yaw, roll}`（−60–60°，不用手机的测试姿势，不保存）。数值截到范围内；类型不对、未知通道、`order` 不在 1–3 时返回 `E_BAD_ARGS`，什么都不改 | `user/mocap.json`（约 0.5 秒后写） |
| `mocap_calibrate` | `{what}` | `face`：把手机当前各通道值记为放松时的基准（之后按 `(v − 基准) / (1 − 基准)` 换算）；`head`：把当前头部角度记为正前方；`clear`：清除面部基准 | `user/mocap.json` |

`state.mocap`：`names`（52 个 ARKit 名）、`raw` / `out`（手机原始值 / 换算后的值，按 `names` 顺序）、`head_raw`、`head_out = {pitch, yaw, roll}`、`live`、`age`（距上次新数据的秒数，没收到过为 nil）、`rx_hz`、`fade`、`held`、`resolved`（能落到当前部件网格键上的通道数）、`status`、`head_status`、`read_ms`、`test`、`cfg`（当前设置，只读）。
