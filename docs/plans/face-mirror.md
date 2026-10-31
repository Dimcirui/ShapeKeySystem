# 表情镜（荒野）：原理与限制

写给接手的人。代码在 `ShapeKeySystem_Games/Wilds/FaceMirror.lua`，命令和设置格式见 `shape-key-system-api.md`「表情镜」一节。本文记录引擎侧的做法和不能做的事，改动前先读完第 5 节。

## 1. 组成

- **渲染目标**：`natives/STM/GUI/ui_texture/tex_render/rtt_facemirror_00.rtex.6`，由原版 `rtt080000_00.rtex.6`（装备预览用）复制，宽高改为 512×512。文件共 64 字节：`RTEX`、版本 6，0x0C 为格式（0x1D），0x10 / 0x14 为宽、高（u32）。打包与部署由 `tools/sks-files.ps1` 的 `$ownedNatives` 带上。
- **相机**：GameObject `FaceMirrorRtexCam`，组件 `via.Camera`、`via.render.RenderOutput`、`via.render.ToneMapping`、`via.render.LDRPostProcess`。RenderOutput 先设 `RenderOutputID = Secondary`，再设 `RenderTarget` 为上面 rtex 的 `RenderTargetTextureResourceHolder`。
- **显示**：GameObject `FaceMirrorGUI`（放在场景文件夹 `GUIHud` 下），带 `via.gui.GUI`，资源是 `GUI/ui000000/ui000200/lib000204.gui`（只有一个面板和一个贴图元素、场景里没有其他人用的库界面），取其中的元素 `tex_saleMark`，`setTexture` 设为同一 rtex 的普通 `TextureResourceHolder`。
- 元素需要：`AssetType = Texture`；`UVType = UV`，UV 范围 0..1（原元素的 UV 来自 UV 序列，不设时只显示一个像素）；`Degamma = false`；`IgnoreAlpha = false`（裁掉的背景保持透明）；停止视图和各级父控件的状态动画（`set_Play(false)`），否则每帧被改回原来的位置和大小。元素位置是视图坐标：原点在 1920×1080 的左上角，Y 向下，元素以中心定位。

## 2. 相机的位置

- 相机是玩家 Transform 的子物体，`set_ParentJoint` 指向所选骨骼，局部位姿固定，只在设置改变时写一次。引擎在更新骨骼时一并算出相机，相机与脸永远是同一时刻的姿势。
- 不用每帧在世界坐标里写相机：即使在 `PrepareRendering` 之后写、CPU 侧每帧都对得上，急转弯时仍有个别帧渲染器用了另一时刻的相机，镜子里的头一帧跳开又回来。
- 可选骨骼：`Head`（相机随头一起转，脸在画面里不动）、`Spine_2`、`COG`（`Hip` 与 `COG` 位置重合，不单列）。局部位姿 = 对准点 `aim` +（按 Y、X、Z 顺序转过 `rot` 后的）+Z 方向 × `dist`，相机的 −Z 朝向对准点。`Head` 与 `COG` 的局部轴在绑定姿势下与角色一致（+Z 前、+Y 上）；`Spine_2` 的轴未核对，靠「对准脸部」和角度调整。
- 「对准脸部」把对准点设为 Head 坐标系里 (0, 0.04, 0.08) 那一点（脸前）在所选骨骼坐标系里的位置，取当前帧的姿势。
- 近、远裁剪面只保留对准点前后 `clip_front` / `clip_back` 的一段，其余像素透明，背景因此去掉。

## 3. 画面

- **曝光**：镜子用固定曝光（`setAutoExposure(2)`），`EV = 主相机 SnappedRealEV + 主相机 EV + 设置的 ev`。主相机的 `EV` 是 `ace.DynamicExposure` 按场景写入的补偿（营地 0，野外约 1.5–2），不加它野外会发白。镜子用自己的自动曝光时，主画面里的猎人会过曝（亮度相关的着色可能读到了镜子的曝光），所以默认固定曝光。
- **调色**：每 120 帧把主相机 `ToneMapping`（除曝光、TAA 等）和 `LDRPostProcess` 的全部可读写属性复制过来，再复制 `LDRPostProcess.ColorCorrect` 子对象：`ColorCube0..2`（场景 LUT 与 CommonHDR）、混合率、8 组 `LinearParams`。不复制 ColorCorrect 时镜子偏暖。
- 镜子关闭 TAA：历史帧会留下重影。
- 关闭游戏里的色彩校正（其他 mod 的后处理开关）时镜子会过曝，只保证开着色彩校正时与主画面一致。

## 4. 生命周期

- 相机与 GUI 的 GameObject 只创建一次，之后只隐藏（`set_DrawSelf(false)`），按名字重新找回；引擎引用随 SKS 的 rigs 一起丢弃（`drop_refs`）。
- GUI 在 `UpdateBehavior` 之前创建；相机和画面在 `PrepareRendering` 之后处理。
- 过场、读取、猎人未就绪（`C.last_gate ~= "stable"`）时隐藏。镜子不随 HUD 隐藏，打开菜单时仍显示。
- 每 30 帧检查主相机仍是 `Main Camera`，不是就停止表情镜，避免自己的相机被当成主相机（会接管 HUD、剔除和声音）。
- 未验证：任务读取、回到标题时如果引擎重建了玩家 GameObject，挂在上面的相机会被一起销毁；按名字找不到时会重新创建一台。

## 5. 做过、会出问题的事

- RenderOutput 用 Primary（或不设目标）：相机变成 `MainView.PrimaryCamera`，画面闪烁；反复销毁、重建这种相机后渲染器里留下孤立的输出（多出一份 HUD、地图损坏），直到重启游戏。
- 给成为主相机的输出设 l > r 的 `Region`：D3D 致命错误 `E_INVALIDARG`，游戏崩溃。
- 在镜子相机上创建 `CustomFilter` / `SoftBloom` / `FFTBloom` 并复制主相机的设置：崩溃。
- 在 `PrepareRendering` 中对 HUD 控件调用 `via.gui.Control.duplicate`：返回成功后崩溃。改 GUI 树只在 `UpdateBehavior` 中做。
- 借用原版 HUD 元素（时间图标）显示时，改它的 `AssetType` 会丢掉它的 UV 序列，直到重启都恢复不了；所以用自己的 GUI。
- 在 `PrepareRendering` 之前取骨骼的世界位置：还是上一帧的，跑动时相机落后约 19 cm。
