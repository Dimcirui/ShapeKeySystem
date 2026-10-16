# RE4R Leon 适配器

适配器接口见 `multi-game-adapter.md`，表情配置与绑定格式见 `shape-key-system-api.md`。本文记录 RE4R 的信号来源、写入方式和后续适配。

## 现状

- 游戏 id 为 `re4`，当前角色为 Leon cha000。适配器从玩家 context 查找头部与部件，按网格身份和通道数识别重建。
- 表情有两种来源：面部骨骼相对中立位的位移或旋转，以及头部网格的原生修正通道权重。
- 信号字典 `builtin/re4/signals.json` 的 63 个通用信号中，39 个有映射，24 个为 `raw: null`；近似映射标为 `guessed`。
- 眼球使用 `L_Eye` / `R_Eye`，由 Core 换算视线。
- 自定义形态键在活动期间逐帧写入，归零时同步写回。
- 面板打开时屏蔽鼠标点击、滚轮和移动，面板关闭后恢复游戏输入。
- 游戏内眨眼、张嘴、面板操作、过场和读档正常。

## 实现

### 文件

| 文件 | 内容 |
|---|---|
| `ShapeKeySystem_Games/RE4R/Adapter.lua` | 角色、脸和部件查找，重建签名，LOD 准备和适配器入口 |
| `ShapeKeySystem_Games/RE4R/Signals.lua` | 骨骼姿态换算、原生修正通道采样与通道保护 |
| `ShapeKeySystem_Games/RE4R/Input.lua` | 鼠标输入屏蔽和光标恢复 |
| `builtin/re4/leon.json` | Leon 中立位、标定规则和原生通道名字 |
| `builtin/re4/signals.json` | 通用信号字典 |
| `tools/convert_re4r_profile.py` | 旧模型配置转换 |

### 信号

Leon 标定取自 [RE4R-ShapeKey-System](https://github.com/Funnyguysmz/RE4R-ShapeKey-System) 0.4.5-rc.1，共 48 条规则；许可见 `THIRD_PARTY.md`。

旋转用相对中立位的四元数对数投影到标定轴，单位为度；位移投影单位为毫米。每条规则限幅后乘增益，同名输出合成后再次限幅。`jawOpen` 等标定输出作为适配器的 raw 通道，范围为 0–1，字典 `full = 1`。Core 按通用信号计算 Profile。

原生修正通道先采样，再写入自定义形态键。91 个原生名字用于哈希识别；实际采样按当前网格的通道和数组长度确定。

### 通道和写入

RE4R 的装箱元素 `ToString()` 会返回错误的数值，通道哈希改从 `get_ChannelNameHash():get_Item()` 读取。适配器通过 `hash_item_only` 选择这条路径。

网格就绪判断检查 MeshReady、通道数、权重数组长度和稳定帧数，并兼容 RE4R 缺少的可选启用标志。每帧通过 gate 和网格签名检查当前 rig，重建后重新绑定。

扫描、表情、捏脸和外部接口共同使用通道保护规则，保留游戏驱动的原生修正通道。`strict_bounds` 在读取和写入时检查当前数组边界。

游戏对照中，按变化阈值跳过写入时，眨眼过快且缺少过渡。因此当前为 RE4R 单独启用活动权重逐帧写入，后续继续改进写入策略。`rewrite_active_weights` 在当前或上次权重非零时持续写入，零到零可以跳过。荒野和鬼武者沿用变化阈值策略。

### 鼠标输入

`Input.lua` 在 `share.hid.Device.update()` 后清理游戏托管鼠标的触发、按下、抬起、重复、滚轮和移动字段。面板从原生鼠标读取操作数据。

字段偏移由类型信息取得，并检查类型、尺寸、对象边界和重叠。设备引用保留在一次 hook 调用内。关闭面板时，等按键与抬起事件结束后恢复输入和光标模式；共用登记表协调其他面板的接管。

## 模型配置转换

运行 `tools/convert_re4r_profile.py INPUT --id ID --output NEW_DIRECTORY`，输出 profiles、names 和 leon/leon 绑定。转换保留自定义形态键名，将 ARKit/MMD 映射转换为 SKS Profile 节点，并为两种 Leon 标定表选择对应信号。

旧手动叠加与当前捏脸基值重映射的差异写入转换报告。面部导航互动沿用 Core 的名字匹配，也可以通过条件集的 `interactions` 配置模型专属键名。

## 后续适配

- 角色与部件：其他角色、服装槽位及独立过场副本。
- 输入：键盘和手柄屏蔽。
- 可选能力：游戏状态条件、面部动画回放和权重数组分配。

跨游戏进度见 [#17](https://github.com/Dimcirui/ShapeKeySystem/issues/17)，通用骨骼信号来源见 [#21](https://github.com/Dimcirui/ShapeKeySystem/issues/21)。
