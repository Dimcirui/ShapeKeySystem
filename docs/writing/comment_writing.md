# 注释写法

本文承接 [comment_guideline.md](comment_guideline.md)。规范回答「哪些内容应当写进注释」，本文回答「写成什么样」。改编自 EFX-Editor 的 `docs/writing/comment_writing.md`。

## 文件头注释

定型结构是一句职责、一个空行，然后维护约束。

```lua
-- ShapeKeySystem: write safety for blendshape meshes.
--
-- Constraints:
-- - Nothing is written while a cutscene loads or plays or while the player is not set up.
-- - A mesh must stay ready for STABLE_FRAMES before it is written to.
-- - Engine references are dropped (and collected) the moment any of the above changes.
```

约束只有一两条时写成段落，不列表化。

```lua
-- ShapeKeySystem: file helpers, name normalisation, small utilities.
-- Paths are relative to reframework/data (what json.load_file / fs.glob use).
```

首行写职责，不写位置。文件路径、模块名和所属目录由文件本身表达，不在首行复述；模块在架构中处于哪一层，也不是首行要回答的问题。

- 适用：管理、驱动、写入、扫描、加载、在 A 与 B 之间映射、为 X 提供 Y。
- 避免：「XX 层」「XX 工具集」「XX 基础设施」单独成句。

「胶水层」「适配层」这类词信息量偏低。只有在需要强调「负责连接两个系统，但不拥有核心数据或业务逻辑」时才有价值，且必须同时写清连接什么、谁拥有数据、允许怎样回退。

## 措辞

**主语保持一致。** 文件头注释的主语是模块或数据，不是维护者，也不是玩家。

**使用技术关系词，而非动作叙述。** 「映射为」表示持续对应关系，「转换成」读起来像一次性转换。

**不使用悬空补语。** 并列的职责写成并列分句，不写成「……，含 X 的 Y」。

**抽象概括必须落到具体。** 「引用联动」应写作「维护绑定与当前部件的对应关系」；「重置状态」应写作「清空 `C.scan_at` 并放掉全部 rig」。

**约束使用确定语气。** 必须、不得、仅、始终、失败时。不使用应该、尽量、理论上、建议。

**代码标识符以反引号标出**，例如 `rig.dict_params`、`C.gc_open`、`STABLE_FRAMES`。

**不写自我评价。** 「刻意保持薄」「结构清晰」「零风险」既不可验证，也拦不住任何改动。

**使用书面语。** 中文注释不写「吃」「碰」「甩」「够得着」「一丁点」「摔进」「拉着走」这类口语动词与量词，改用「参与」「作用于」「偏向」「可对准」「极为敏感」「落入」「由……处理」。比喻只在没有等价术语时使用。

## 函数前注释

以一行为主，说明返回语义、失败取值和关键副作用。

```lua
-- Returns ok, reason, kind; kind is "load", "playing" or "setup" when not ok.
function G.game_stable(frame)

-- Zeroes every channel of the target; errors are swallowed (the mesh may be gone).
function W.zero_target(t)
```

不复述参数类型，不把函数体翻译成自然语言。名称与参数已经说清的函数不写注释。

**机制描述放在文件头，不放在函数前。** 换算公式、坐标约定、为何采用这种写入顺序，都属于模块级的机制说明；函数前注释只写输入、输出、退化情形与副作用。一个机制往往横跨多个函数，写在其中一个函数前面，读其他函数的人看不到。

## 行内注释

写这一行为什么必须这样，不写这一行在做什么。

```lua
-- the same mesh found again keeps its warm-up count, so a rescan does not pause writing
```

分节横线（`-- ------------------------------------------------ per frame`）是结构标记而非说明，长文件中可以保留。

单位、类型和取值范围在相邻代码已经表达时不重复标注。

## 保留一条约束之前先验证它

写着「必须」「依赖」「否则会」的注释最值得怀疑。它们失效时不会报错，只会让后续维护绕路，或让人以为某条检查已经存在。

保留这类注释之前，确认它描述的依赖当前真实存在：

- **顺序约束**：读被调用方的实现，确认后一步确实使用了前一步建立的状态。各步互不依赖时，顺序不构成约束。
- **为测试预留的写法**：确认那个测试存在。测试不存在时，这条约束没有支撑物。
- **游戏行为断言**：例如「这个 hook 一帧调用多次」「写入早于缓冲区分配会卡死」。已有实测结论的保留结论，没有的移入专题文档，等实测后再写进注释。
- **全称判断**：含「唯一」「全部」「从不」的句子逐一找反例。

验证不通过时，删除该注释，或降级为对当前实现的描述。补写一条听起来成立而实际不成立的约束，比没有注释更糟。

## 约束必须指向本仓库内的具体后果

判断一条注释能否拦住错误重构时，要能回答：本仓库的哪一处代码或数据会因为不知道它而出错。答不出具体位置的，删除。

合格的形式是内部依赖：某个模块靠这个前缀过滤部件、某两个函数必须保持同一顺序、某个字段名被已保存的绑定文件引用、某处写入会因取错来源而越界。

不合格的形式是以外部资料为主语：某个插件这样实现、某份逆向笔记的结构与此不符、另一个游戏的命名与此有出入。这类句子的主语不是本模块，本仓库也没有任何行为依赖它们；真正需要记录外部资料分歧时，写进对应的专题文档。

## 只记录，不顺手修

修缮注释时会发现命名不一致、默认值多处不同步、别名表缺条目这类问题。这些记进对应 issue 或专题文档，不在修缮注释的同一轮里改掉。注释改动应能单独确认没有改变行为，混进数据或逻辑改动就失去这个保证。

## 改写对照

记录探查历史和日期的文件头，改为维护约束。

```lua
-- 前
-- ShapeKeySystem: write safety. Ported from the SKS_Mocap crash investigation (2026-10-09):
--   * writing weights while a hunter part is rebuilt (entering the game, end of a cutscene)
--     crashed a game worker thread on a null blendshape buffer;
--   * holding Lua references to objects the game tears down (cutscene skip / end) crashed it
--     even with every weight at 0.
-- (halved 2026-10-09: the crashes these guarded against were traced to BoneSystem.dll)

-- 后
-- ShapeKeySystem: write safety for blendshape meshes.
--
-- Constraints:
-- - Nothing is written while a part is rebuilt or a cutscene loads or plays.
-- - No engine reference is held across a cutscene skip or end, even with every weight at 0.
```

列出验证来源的文件头，去掉来源，只留路径约定。

```lua
-- 前
-- MH Wilds paths verified live 2026-10-10 (REE MCP): app.PlayerManager:getMasterPlayer():
-- get_Character() = app.HunterCharacter; HP: get_HunterHealth() -> <HealthMgr>k__BackingField

-- 后
-- Hunter state comes from getMasterPlayer():get_Character() (app.HunterCharacter);
-- HP from get_HunterHealth().<HealthMgr>k__BackingField.
```

## 自检

在 [comment_guideline.md](comment_guideline.md) 的审阅检查表之外补充：

1. 改写后的行数是否少于改写前。
2. 保留下来的每条「必须」是否都经过验证。
3. 每条约束能否指出本仓库内会因此出错的具体位置。
4. 是否出现未落到具体的抽象标签。
5. 段落主语是否统一为模块或数据，而非外部资料。
