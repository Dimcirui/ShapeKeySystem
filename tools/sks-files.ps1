<#
SKS 发布文件清单，由 deploy.ps1 与 package.ps1 共用，避免两份清单不一致。
清单之外的玩家数据（settings.json、user/、mods/、trail.log 等）不部署、不打包。
#>

# relative paths owned by SKS; directories are mirrored (extra files on the target side are removed)
$owned = @(
    "autorun\ShapeKeySystem.lua",
    "autorun\ShapeKeySystem_Core",
    "autorun\ShapeKeySystem_UI",
    "autorun\ShapeKeySystem_Games",
    "autorun\ShapeKeySystem_Game", # 清理旧的播放适配器目录
    "data\ShapeKeySystem\builtin",
    "data\ShapeKeySystem\faces",
    "images\ShapeKeySystem",
    "plugins\ShapeKeySystem_Mocap.dll"   # 面捕游戏内接收，由 native\build.ps1 生成
)
# 仅清理迁入 builtin 的三个旧内置文件，不镜像旧 games 目录，保留玩家另外放入的录制。
$retired = @(
    "data\ShapeKeySystem\games\mhwilds\recording_catalog.json",
    "data\ShapeKeySystem\games\mhwilds\recordings\Speak.json",
    "data\ShapeKeySystem\games\mhwilds\recordings\CampMeals.json"
)

function Get-Files($root, $rel) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { return @{} }
    $out = @{}
    if ((Get-Item $p).PSIsContainer) {
        Get-ChildItem $p -Recurse -File | Where-Object { $_.FullName -notmatch '\\__pycache__\\' } | ForEach-Object {
            $out[$_.FullName.Substring($root.Length + 1)] = $_
        }
    } else {
        $out[$rel] = Get-Item $p
    }
    return $out
}
