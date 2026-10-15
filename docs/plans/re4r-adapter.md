# RE4R Leon 适配器

RE4R 适配器接入 Leon cha000 的自定义形态键驱动和面板鼠标屏蔽，复用 SKS 的表情配置、捏脸、预设绑定、面板和外部接口。

## 功能组成

| 文件 | 职责 |
|---|---|
| `Adapter.lua` | 查找玩家、头部和部件，提供网格重建签名、眼球关节与写入策略 |
| `Signals.lua` | 将面部骨骼姿态和原生修正通道换算为通用表情信号 |
| `Input.lua` | 面板打开时屏蔽游戏鼠标输入，关闭后恢复 |
| `builtin/re4/leon.json` | Leon 骨骼中立位、标定规则和原生通道名字 |
| `builtin/re4/signals.json` | 将 Leon 标定输出连接到 SKS 通用信号名 |

标定采用 [RE4R-ShapeKey-System](https://github.com/Funnyguysmz/RE4R-ShapeKey-System) 0.4.5-rc.1 的 Leon 48 条规则，第三方声明见 `THIRD_PARTY.md`。信号字典连接了 39 项通用信号，近似映射以 `guessed` 标记。

## 表情信号

旋转取相对中立位的四元数对数并投影到标定轴，单位为度；位移投影单位为毫米。各条规则依次限幅、乘增益、合成并限幅，输出范围为 0–1。`jawOpen` 等 raw 名称在配置加载时编译为整数索引，采样句柄由当前 rig 持有。

视线使用 Core 的眼球接口。眨眼映射、骨骼中立位和眼嘴标定沿用旧 System。

## 通道解析与持续写入

RE4R 使用 `get_ChannelNameHash():get_Item()` 的数值结果解析通道名，解决装箱元素 `ToString()` 返回错误数值造成的识别问题。

网格就绪判断兼容 RE4R 的接口集合，通过 MeshReady、当前通道数、已分配权重数组、稳定帧数和对象签名控制写入时机。重建时释放旧 rig，再绑定当前网格。

原生通道按名字哈希识别，91 个候选原生名字用于保护原生表情数据。表情、捏脸和外部接口共同遵循通道保护与数组边界检查。原生 tap 先采样，再计算自定义形态键输出。

RE4R 开启活动权重逐帧写入：最终权重非零时持续写入，回到零时写入归零值。荒野、鬼武者继续使用原来的变化阈值策略。

## 面板鼠标屏蔽

有效入口为 `share.hid.Device.update()` 的后处理。面板打开时，清理游戏托管鼠标的触发、按下、抬起、重复、滚轮和移动状态；面板从原生鼠标读取点击、移动和滚轮，保持界面操作正常。

鼠标字段位置由 TDB 读取，并检查类型、尺寸、对象边界和字段重叠。一次 hook 调用完成后释放设备引用。关闭面板时等待鼠标按键和抬起事件结束，再恢复游戏输入与光标模式。共用输入登记表协调其他面板的接管与恢复。

## Core 和 UI 接口

| 接口 | 用途 |
|---|---|
| `A.faces(root)`、`A.face_root(face, root)` | 提供脸候选及扫描组根 |
| `A.parts(root)`、`A.part_id(tr)` | 提供部件列表和稳定 ID |
| `A.signature(root)` | 识别网格身份和通道数变化 |
| `A.channel_writable(name, mesh?, index?)` | 判断通道写入权限 |
| `A.strict_bounds` | 启用当前通道数和权重数组检查 |
| `A.hash_names`、`A.hash_item_only` | 按数值 Item 哈希解析通道 |
| `A.rewrite_active_weights` | 持续写入活动权重 |
| `A.prepare_mesh(mesh)` | 将当前就绪目标设为 LOD0 |
| `A.input.left_down`、`take_wheel`、`status` | 提供面板鼠标读取与输入状态 |

这些接口按适配器选择启用。RE4R 类型查询与 hook 安装在适配器初始化阶段执行。

## Profile 转换

`tools/convert_re4r_profile.py INPUT --id ID --output NEW_DIRECTORY` 将旧 Profile 转换为 SKS 的 profiles、names 和 leon/leon 绑定，输出至独立目录。

转换保留自定义通道名，将 ARKit/MMD 映射转换为现有 Profile 节点，并为两种 Leon 标定表提供对应规则。转换报告说明旧手动叠加与当前捏脸基值重映射的差异。面部导航互动复用 Core，可通过 interactions 配置模型专属键名。

## 游戏测试结果

用户确认眨眼过渡、张嘴、面板点击、拖动、滚动及关闭后的输入恢复正常，左键、右键、滚轮和鼠标移动穿透已解决。过场和读档正常。

RE4R 离线检查入口为 `python tests/run.py --re4r-only`，Profile 转换检查入口为 `python tests/test_re4r_conversion.py`。已有 gaze 和 about-card 检查由 [#22](https://github.com/Dimcirui/ShapeKeySystem/issues/22) 跟踪。

## 后续适配

当前角色目标为 Leon cha000。后续可继续接入其他角色与槽位、独立过场角色、键盘和手柄屏蔽、游戏状态条件、录制回放及权重数组分配。

跨游戏适配进度见 [#17](https://github.com/Dimcirui/ShapeKeySystem/issues/17)，通用骨骼信号来源见 [#21](https://github.com/Dimcirui/ShapeKeySystem/issues/21)。
