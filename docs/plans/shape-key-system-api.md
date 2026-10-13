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
| `last_scan` | `{time, ms, faces, cached_skip, guild_card}` | 最近一次扫描的信息 |
| `rigs` | list of Rig | 被驱动的角色。主角色和名片分身**不作区分**，界面只显示合并后的结果 |
| `parts` | list of Part | 当前身上的部件，去重后合并 |

`Part`：
```lua
{ id = "ch03_012_0012",        -- 部件 ID，同时也是父预设的文件名
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
  group = "mouth",
  source_text = "smile.L + smileMinor.L×0.5",  -- 来源摘要，显示用
  has_signal = true,             -- false 表示没有游戏信号，只能手动或捏脸
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
| `nodes` | map 通道名 → Node | 当前配置里各通道的节点树（结构同配置 JSON，见计划文档 5.1） |
| `edited` | set of 通道名 | 改过、还没保存的通道 |

`Signal`：`{ slot = 3, name = "smile.L", param = 33, guessed = false, note = "颧大肌" }`。实时值在 `live.signal[slot]`。

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
| `groups` | list of `{key, name, key_indices}` | 自动分组 |
| `keys` | list of SculptKey | 合并后的形态键 |

`SculptKey`：
```lua
{ name = "Waist_thin",
  group = "body",
  parts = { "ch03_012_0012", "ch03_012_0014" },  -- 出现在哪些部件
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
| `sculpt` | list of `{name, source, target_part?}` | 可选的捏脸配置 |
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
`hotkey`、`ui_scale`、`language`、`scene_search_always`、`periodic_scan_sec`、`write_epsilon`、`ui_backend`（`auto` / `d2d` / `imgui`：面板绘制方式，`auto` = 装了 d2d 就用 d2d，否则 ImGui；想要的后端不存在时自动用另一个）、`window = {x, y, w, h}`。修改后立即持久化。

### 3.9 `state.debug`
| 字段 | 类型 | 说明 |
|---|---|---|
| `perf` | `{read, compute, write, scan, total, writes, skipped}` | 最近 60 帧平均，单位 ms |
| `log` | 环形缓冲，最多 200 条 `{time, text}` | |

## 4. 实时数值（`SKS.live`）

每帧由后端原地更新，界面按下标读取：

| 字段 | 类型 | 说明 |
|---|---|---|
| `weight[slot]` | number | 各表情通道最终写入的权重 |
| `region_activity[i]` | number | 各部位的活跃度（该部位通道权重的最大值，面部图标提亮用）。只在面板打开时计算 |
| `signal[slot]` | number | 各信号归一化后的值（0..1）。只在映射编辑或调试页打开时计算 |
| `eye_angle` | `{L = {yaw, pitch}, R = {yaw, pitch}}` | |

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
  builtin/  profiles/*.json, signals.json, aliases.json     （随插件发布，只读）
  mods/     bindings/*.json, profiles/*.json, sculpt/*.json  （随 mod 发布，只读）
  user/     bindings/*.json, profiles/*.json, sculpt/*.json  （用户自己的，插件只写这里）
```

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
  builtin/  profiles/*.json, signals.json, aliases.json
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
