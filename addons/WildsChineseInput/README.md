# WildsChineseInput（可选组件，只限怪物猎人荒野）

让 SKS 面板的输入框直接用 Windows 中文输入法打字。

- 内容：`reframework/plugins/ArmorVariantManager_UI.dll`，即差分管理器（ArmorVariantManager）的 UI DLL，和差分管理器 4.3.0 发布的文件逐字节相同。经差分管理器作者同意随 SKS 发布，条件是只用于荒野。
- 安装：把 `reframework` 文件夹放进游戏根目录。路径和差分管理器完全相同：两个都装时 mod 管理器会提示冲突，直接覆盖即可，最后只有一份。已经装了差分管理器 4.3+ 的玩家不需要这个组件。
- 不能放进其他游戏：REFramework 启动时会自动加载 `plugins/` 下的所有 DLL，与 SKS 的 Lua 无关（这个 DLL 在崛起上会让游戏在加载阶段崩溃）。
- SKS 侧：`ShapeKeySystem_UI/NativeText.lua` 以 `ShapeKeySystem` 客户端身份使用它的输入法服务，通信目录 `reframework/data/ShapeKeySystem/Runtime/`。没有这个 DLL 时，SKS 退回「中文」按钮（弹出游戏自己的输入框，`GameText.lua`）。
- 维护：差分管理器更新这个 DLL 时，这里也换成同一版本（后装的会覆盖先装的）。`tools/deploy.ps1` 不部署这里的文件；开发时手动复制到游戏的 `reframework/plugins/`。
