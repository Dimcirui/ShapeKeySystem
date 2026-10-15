# RE4R Leon 适配器：接口与当前边界

适配器遵循 `multi-game-adapter.md`。当前支持 Leon cha000 的自定义形态键驱动、原生通道保护和面板鼠标屏蔽，复用现有 Core、UI、profile、捏脸与外部接口。

## 当前实现

- `ShapeKeySystem_Games/RE4R/Adapter.lua` 查找玩家 context、cha000 头部和部件，提供重建签名与眼球关节。
- `Signals.lua` 读取面部骨骼姿态和保留下来的原生修正通道，不持有跨 rig 的引擎对象。
- `Input.lua` 在 `share.hid.Device.update()` 后清理游戏托管鼠标状态；面板读取未改动的原生鼠标。
- `builtin/re4/leon.json` 保存 Leon 标定和原生通道名；`signals.json` 连接通用语义信号，63 项中 39 项已连接，其余为无信号，部分近似来源标为 `guessed`。
- 入口按游戏选择适配器。未选中的 RE4R 模块只定义函数，不查询游戏类型或安装 hook。

标定来源为 [RE4R-ShapeKey-System](https://github.com/Funnyguysmz/RE4R-ShapeKey-System) 0.4.5-rc.1 的 Leon 48 条规则。旋转取相对中立位的四元数对数并投影到标定轴，单位为度；位移投影单位为毫米。规则依次限幅、乘增益、合成并限幅。固定中立位不由首次采样替代，第三方声明保存在 `THIRD_PARTY.md`。

## 可选接口

荒野、鬼武者未提供这些接口时沿用原路径。

| 接口 | 约定 |
|---|---|
| `A.faces(root)` | 提供当前脸候选，替代默认全场景搜索 |
| `A.face_root(face, root)` | 指定脸的扫描组根 |
| `A.parts(root)`、`A.part_id(tr)` | 提供部件列表和稳定 ID |
| `A.signature(root)` | 包含相关网格身份及通道数，重建时改变 |
| `A.channel_writable(name, mesh?, index?)` | 过滤受保护通道，底层写入再次检查 |
| `A.strict_bounds` | 同时检查当前 ChannelNum、WeightCount 和 WeightList 长度 |
| `A.hash_names` | 按名字哈希解析通道 |
| `A.hash_item_only` | 只接受 `get_Item` 返回的 UInt32 范围整数，失败时不回退到装箱对象 |
| `A.rewrite_active_weights` | 最终权重或上次权重非零时，每帧持续写入；零到零仍可跳过 |
| `A.prepare_mesh(mesh)` | 在准备阶段只处理当前且就绪的目标；RE4R 将其设为 LOD0 |
| `A.input.left_down`、`take_wheel`、`status` | 为共用面板提供可选的原始鼠标读取和输入诊断 |

严格边界模式每帧在读取旧 rig 前检查 gate 和签名。对象失效时释放引用，不清零失效网格。预备、禁用和重载使用相同生命周期约束，不保存退出后恢复所用的旧 mesh 引用。

## 通道解析和写入

本机 RE4R 中，装箱元素的 `ToString()` 会给出错误但可转换为整数的值；`get_Item` 返回的数值与模型通道哈希一致。因此本适配器使用数值 Item 路径，未知或读取失败的通道不写入。

引擎未提供 `get_BlendShapeEnable` 和 `get_BlendShapeReleasedBuffers` 时，不把缺失接口当作 false 标志；MeshReady、通道数、已分配数组和稳定帧检查继续生效。接口存在但禁用或不可读取时仍阻止写入。

91 个原生名字用于哈希识别，不代表固定通道数或下标。原生 `Face__geo__*`、`crct_*`、已知原生哈希和未解析通道不能由表情、捏脸或外部 API 写入。原生 tap 在输出写入前读取，可缺失或仅存在子集。

RE4R 的 raw key 表示标定后的虚拟通道，如 `jawOpen`，范围 0–1，字典 full=1。名字在加载配置时编译，采样句柄由 rig 持有。视线复用 Core 的眼球接口。

活动权重持续写入仅由 RE4R 开启。眨眼映射和骨骼中立位沿用旧 System，未添加额外平滑；其他游戏继续按权重变化阈值写入。

## 鼠标输入

在面板打开或等待关闭点击释放时，清理托管设备的按下、触发、抬起、重复、滚轮及移动字段。字段偏移由 TDB 读取，检查类型、尺寸、对象边界和字段重叠；不写原生设备或键盘、手柄字段。对象引用仅保留在一次 hook 的调用范围内。

光标模式在无人接管时保存，面板打开时释放，关闭且按键及抬起事件结束后恢复；其他已登记面板接管时让其处理。脚本重置后停止清理。共用 UI 的默认输入路径保持兼容。

## 模型配置转换

`tools/convert_re4r_profile.py INPUT --id ID --output NEW_DIRECTORY` 生成 profiles、names 和 leon/leon 绑定，输入不变，已有输出目录拒绝覆盖。保留自定义通道名，将 ARKit/MMD 映射转换为现有 profile 节点，无映射键保持手动。

只接受已移植的两种 Leon 标定表。旧手动叠加与新捏脸基值重映射不同，转换报告记录该差异。跨部件同名键遵循当前项目规则。

## 当前范围

- 当前识别 Leon cha000，不扩展到 Ashley、Ada、NPC、其他服装槽位或全场景过场副本。
- 没有 RE4R 专属过场事件接口，依靠当前玩家就绪检查、签名和重扫管理对象。过场及读档正常不等于所有过场副本都可驱动。
- 键盘和手柄屏蔽、游戏状态条件 getter、录制回放、权重数组自动分配尚未接入。
- 面部导航互动复用 Core；模型键名不能自动匹配的区域需要配置 interactions。
- 旧 System 和本分支不能同时写同一组通道；旧 Studio API 和 RhyLive DLL 不由本适配器接管。
- 通用骨骼信号接口和其他游戏的骨骼来源仍由 [#21](https://github.com/Dimcirui/ShapeKeySystem/issues/21) 跟踪；本实现仅提供 Leon 标定，不关闭该议题。跨游戏进度见 [#17](https://github.com/Dimcirui/ShapeKeySystem/issues/17)。

## 验证与记录

用户已确认眨眼过渡、张嘴、左键、右键、滚轮、移动和面板关闭后恢复正常，并补充确认过场、读档正常。此前鼠标设备 getter 替换无效，当前有效入口为 `share.hid.Device.update()` 后处理；未成功安装的备用入口已从源码移除。原始诊断与已验收游戏脚本保存在 Git 忽略的本地 backup 中，不进入发布包。

`python tests/run.py --re4r-only` 提供 RE4R 独立环境，`python tests/test_re4r_conversion.py` 检查转换。本轮最后的写入与输入修改未重新运行离线测试。已有两个 gaze 和一个 about-card 检查问题由 [#22](https://github.com/Dimcirui/ShapeKeySystem/issues/22) 跟踪，不通过改期望隐藏失败。

玩家设置、私人模型、原版游戏资源、诊断录制与测试 ZIP 不进入仓库。后续问题通过 Issues 跟进，本次不升插件版本或创建 Release。
