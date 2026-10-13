-- ShapeKeySystem: plugin version, author and release notes (shown under 设置与调试 → 关于).
-- Semantic versioning: patch = fixes only, minor = new features that keep old files working,
-- major = file formats / the public API change incompatibly. The public API (ShapeKeySystemAPI)
-- keeps its own version in API.lua.
-- Releasing: bump `number` and put the new entry FIRST in `history` (one short line each).

local V = {}

V.name = "ShapeKeySystem"
V.number = "1.1.0"
V.author = "谛听 Dimcirui"

V.history = {
    { version = "1.1.0", notes = "新增 VRChat 素体表情配置" },
    { version = "1.0.0", notes = "首个版本" },
}

return V
