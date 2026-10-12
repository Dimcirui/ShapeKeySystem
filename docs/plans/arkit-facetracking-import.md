# 计划：从 VRChat 面捕包把 ARKit 形态键导入到指定面部网格

状态：未开始（2026-10-08 立项，以后实现）
相关：MH Wilds 面部 fcParam 驱动链路（见本文末“运行时侧”）

## 目标

在 Blender 里一键把 VRChat 面捕（Face Tracking）方案里的形态键，载入到用户指定的面部网格上，并统一转换成 ARKit 52 命名，供 Wilds 导出（Export Shapekeys = Mode 0）和运行时脚本驱动。

理想输入：**未解包的 `.unitypackage`**；也支持已解包的 `Assets/` 目录。

## 输入格式（以 Triturbo Shinano FT 1.1.0 为参考样本）

参考包：`E:\Data\2-模型\VRC\0Shinano\0FaceTracking\FaceTracking_1.1.0_for_Shinano_1.02`

1. **`.unitypackage`**：gzip 压缩的 tar。每个资源是一个以 GUID 命名的目录，里面有：
   - `asset`：文件本体
   - `asset.meta`：Unity meta
   - `pathname`：原始工程路径，例如 `Assets/Triturbo/Shinano_FT/Blendshapes/...`

   Python 标准库 `tarfile` 可以直接流式读取，不需要先解包到磁盘。
2. **BlendShare 资源**（`*_BlendShare*.asset`，Unity YAML，约 22MB）：这是真正的形态键数据。
   - `m_MeshDataList[]`：每一项对应原模型里的一个网格。字段有 `m_MeshName`（如 `Body`）、`m_VertexCount`、`m_VerticesHash`、`m_OriginMesh`（指向原 FBX 的 guid 和 fileID）、`m_ShapeNames[]`。
   - 每个形态键有 `m_ShapeName`，以及 `m_UnityBlendShapeData.m_Frames[]`：
     - `m_FrameWeight`
     - **稀疏**的 `m_VertexIndices` + `m_DeltaVertices`
     - `m_DeltaNormals` / `m_DeltaTangents`
   - 另有 `m_FbxBlendShapeData`：按 FBX 控制点（control point）索引存的数据（`m_PointsIndices`、`m_DeltaControlPointsList`）。
   - 关键点：这些偏移量是**相对用户手里那份原版模型**的。BlendShare 本身不分发模型，而是靠 `m_VertexCount` 和 `m_VerticesHash` 校验目标网格是否匹配。
3. 其他会出现的文件：`.anim`、`.controller`、BlendTree `.asset`。这些描述 VRChat 参数如何驱动形态键，导入形态键用不到，以后做"表情参数映射"时可以参考。
4. 其他面捕方案：
   - 有的直接在 FBX 里带形态键（例如 Shinano 场景里的 `-----FT ARKit Mod-----` 段）。
   - 有的使用 Unified Expressions、SRanipal 等命名。

   需要一个命名转换层，见下文。

## 步骤

1. **读包**：用 `tarfile` 遍历 `.unitypackage`，通过 `pathname` 找到 BlendShare 的 `.asset`、FBX 和 `.meta`，不落盘或只解到临时目录。
2. **解析 BlendShare YAML**：数据量大（12 万个 `m_X/m_Y/m_Z/m_W` 条目），要用流式或正则的快速解析，不要整份加载成 PyYAML 对象树。
3. **目标匹配**：
   - 首选：用户在 Blender 里选中的网格，其顶点数等于 `m_VertexCount`。顶点顺序必须是 Unity 导入后的顺序；Blender 导入的 FBX 可能会拆分或重排顶点。
   - 先尝试 Unity 顶点空间的数据（`m_UnityBlendShapeData`）。如果对不上，退回到 FBX 控制点空间（`m_FbxBlendShapeData`），它和 Blender FBX 导入后的顶点更容易一一对应。
   - 再不行就按位置做最近点匹配，并在报告里写明匹配失败的顶点数。
   - 实现 `m_VerticesHash` 的校验（需要先弄清它的哈希算法），给出明确的不匹配提示。
4. **坐标转换**：Unity 是左手系 Y-up，单位米；Blender 是右手系 Z-up。偏移量需要按 FBX 导入时的轴转换和缩放来处理，X 取反、Y/Z 对调，最后以和原模型对齐为准。
5. **写入形态键**：Basis + 每个形态键 = Basis 坐标 + 偏移量；有多帧的取权重最高的那一帧。默认不覆盖同名形态键，可选择"覆盖"或"跳过"。
6. **命名统一为 ARKit 52**：做一张可编辑的映射表（JSON），处理以下几类：
   - 大小写差异：`BrowDownLeft` → `browDownLeft`，`eyeBlinkLeft` 这类已是标准写法的不变。
   - Unified Expressions → ARKit：`EyeClosedLeft` → `eyeBlinkLeft`，`LipFunnel` → `mouthFunnel`，`LipPucker` → `mouthPucker`，`LipSuckLower` → `mouthRollLower`，`CheekSuck*` 没有直接对应。
   - 合并 / 拆分：
     - `BrowInnerUp` 可以由 `BrowInnerUpLeft` 和 `BrowInnerUpRight` 合成。
     - `CheekPuff` 同理由左右两半合成。
   - 非 ARKit 的扩展形态键（`*@Open`、`*Morph*`、`Tongue*`、`EyeConstrict` 等）保留原名，并统一打上前缀或分组，由用户勾选是否导出。
7. **导出前瘦身**：只保留勾选的形态键，去掉分隔用的形态键（例如 `=======EYE=======`，可以改名为 `DUMMY_` 前缀，导出时会自动跳过）。原因：
   - 导出体积：大约等于 顶点数 × 形态键数 × 4 字节。
   - Wilds 量化：同一个分区内的所有通道共用一个对称 AABB。

## 运行时侧（已验证的前提，2026-10-08）

- 玩家面部动画是 `Player_Face` 骨架上的 `fcParam_001..200` 关节，数值存在它们的局部位置 z 上，峰值约 0.01。
- `via.render.Mesh.setBlendShapeChannelWeightParam(i, w)` 按通道名写入权重，实测可以生效并保持。Female Body Sliders 也用同一套接口；写入前需要检查 `get_BlendShapeChannelWeightCount() >= get_BlendShapeChannelNum()`。
- 驱动脚本：每帧读取 fcParam，按 fcParam → ARKit 对照表算出权重（权重 = z / 0.01 × 各通道倍率），写进防具网格对应名字的形态键。

## 未决问题

- `m_VerticesHash` 用的是什么哈希算法。
- Blender FBX 导入后的顶点顺序与 Unity 顶点顺序的对应关系（不同导入设置下是否稳定）。
- 是否要支持导入 `m_DeltaNormals`。Wilds 不存法线偏移，运行时法线靠重算，所以大概率可以忽略。
