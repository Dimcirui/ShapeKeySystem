# RE4R Leon 适配器：接口与当前边界

本地开发基线为 main `02522d6`，适配器结构遵循 `multi-game-adapter.md`。本分支完成离线候选，游戏测试待完成。

## 当前实现

- `ShapeKeySystem_Games/RE4R/Adapter.lua` 处理玩家 context、cha000 头部、部件与重建签名。
- `Signals.lua` 处理骨骼中立位投影、原生修正通道读取与标定规则合成，不持有跨 rig 的引擎引用。
- `builtin/re4/leon.json` 保存 Leon 标定和原生通道名字；`signals.json` 连接本项目语义名。63 项中 39 项已连接，其他项为无信号。
- 复用现有 Core/UI、names、profile、binding、捏脸、外部租约与打包清单。没有复制旧面板或增加 DLL。

来源为 RE4R-ShapeKey-System 0.4.5-rc.1 的 Leon 48 条规则及运行时逻辑。旋转以相对中立位的四元数对数投影到标定轴，单位为度；位移投影单位为毫米。规则依次限幅、乘增益、按输出合并并限幅，不以第一次采样作为中立位。

通用信号中的部分左右来源共享，字典标为 `guessed`。没有对应来源的语义名保留 `raw:null`，不以近似值补满。视线使用现有眼球接口与 Core 的正负方向，不再重复合成旧 ARKit 视线规则。

## 通用接口扩展

以下接口都是可选的。荒野、鬼武者未提供时沿用原路径。

| 接口 | 约定 |
|---|---|
| `A.faces(root)` | 当前扫描组的脸候选；提供时不用默认的全场景搜索 |
| `A.face_root(face, root)` | 明确脸的扫描组根，代替实际父节点；用于 primary 判定和部件归组 |
| `A.parts(root)` | 部件 Transform 数组，可含脸本身；空数组表示没有部件 |
| `A.part_id(tr)` | 稳定的部件 ID，不包含地址 |
| `A.signature(root)` | 根下相关网格身份与通道数签名，重建必须变化 |
| `A.channel_writable(name, mesh?, index?)` | false 的通道不参与表情和捏脸；公开 API 拒绝它，底层写入再次检查 |
| `A.strict_bounds` | 写入/读取同时检查当前 ChannelNum、WeightCount 和 WeightList 长度 |
| `A.hash_names` | 即使名称 getter 存在也按实际名字哈希解析；兼容仅提供 Item 的集合 |
| `A.prepare_mesh(mesh)` | Core 在 pre UpdateMotion / pre PrepareRendering 对当前、就绪目标调用；适配器不保存目标引用 |

`strict_bounds` 适配器每帧在读旧 rig 前检查 gate 和签名；失效时只释放引用，不再尝试清零旧网格。预备阶段、关闭驱动和重载使用同样的生命周期限制。LOD0 只作用于当前目标，不缓存退出后可恢复的旧 mesh 引用；LOD 归还后的实际引擎行为仍需游戏检查。

RE4R raw key 表示标定后的虚拟通道，例如 `jawOpen`。它可组合多项骨骼/tap 规则，值域为 0–1；字典 full=1，因此只归一化一次。raw 名称在加载配置时编译成稳定整数，采样句柄由 Core 的 rig 持有。

## 原生输入保护

91 个原生名字只用于识别哈希，不是固定数组长度或下标假设。tap 可缺失或只有子集，读取只按当前名字哈希和当前数组边界进行。诊断句柄区分 `ok`、`unbound`、`bounds_unavailable`、`out_of_bounds`、`read_failed`。

原生 `Face__geo__*`、`crct_*`、已知原生哈希与未解析的 `#XXXXXXXX` 通道不能写入。扫描时过滤，外部 API 拒绝控制，底层 Writer/Sculpt 的写入与归零再次检查。tap 采样先于该 rig 的输出写入。

## 模型配置转换

`tools/convert_re4r_profile.py INPUT --id ID --output NEW_DIRECTORY` 输出 profiles、names 与 leon/leon 绑定。输入不变，已有输出目录拒绝覆盖。转换使用原始通道 id，不把自定义 `SK__*` 名称改写为 ARKit 名称；ARKit/MMD 映射转换成现有 profile 节点，无映射键保持手动。

只支持已移植的两种 Leon 表；未知 native_map_file 报错。原生 tap 由实际网格子集决定，不需要复制旧全局 profile 或设置。旧手动叠加算法与新捏脸基值重映射不等价，转换报告记录该差异。跨部件同名键遵循新项目规则，不能承诺旧插件的“头部优先、每键一个网格”效果完全不变。

## 部分待确认

- REFramework 实际游戏 id 是否为 `re4`。该标识与历史脚本预期一致，本次只在 mock 使用，尚未在本机游戏查询。
- 当前仅匹配 cha000 资源路径和 Leon 骨骼，不扩展到其他 Leon 服装槽位、Ashley、Ada、NPC 或过场副本。
- 暂无 RE4R 专属过场状态接口：gate 检查当前玩家和头部，不能推导为完整的过场安全证明。游戏验证前保持实验候选，不部署为常用版本。
- 输入屏蔽、条件 getter、录制回放、自动分配身体/头发权重数组未接入。没有相关接口时不伪装成具备能力。
- 旧 System 与本分支不能同时写同一组通道；本分支没有接管旧 Studio API 或 RhyLive DLL。后续面捕应通过本项目现有租约 API 桥接。

## 验证

`cd tests; python run.py` 包含所有游戏和 RE4R 独立运行环境；`python run.py --re4r-only` 单独运行新适配器；`python test_re4r_conversion.py` 检查配置转换。

修改前基线有两项 gaze 失败及一项 about-card 旧版本断言失败。它们不在本分支范围内，不通过调整原期望隐藏失败；对比时要求新增测试为零失败，其他组不增加失败。

游戏验收至少包含待机、眨眼、张嘴、视线、LOD 切换、读档/死亡重试、头部重建、禁用驱动和 Reset Scripts。过场检测与对象销毁时机未确认前，不把离线结果作为游戏稳定性结论。私人模型、原版 MESH、录制、用户设置不进入仓库。
