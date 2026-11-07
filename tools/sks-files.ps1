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
    "plugins\ShapeKeySystem_Mocap.dll",  # 面捕游戏内接收，由 native\build.ps1 生成
    "plugins\ShapeKeySystem_Native.dll"  # RE4R 面部姿态等原生读取，由 native\build.ps1 生成
)
# 游戏根目录 natives\ 下的文件，相对仓库根目录与游戏根目录；逐个列出，不镜像目录（natives 由许多 mod 共用）
$ownedNatives = @(
    "natives\STM\GUI\ui_texture\tex_render\rtt_facemirror_00.rtex.6",   # 表情镜的渲染贴图（荒野）
    "natives\STM\_Chainsaw\UI\FaceMirror\rtt_facemirror_00.rtex.5",    # 表情镜的渲染贴图（RE4R）
    "natives\STM\GUI\ui_texture\tex_render\rtt_facemirror_oni_00.rtex.6"  # 表情镜的渲染贴图（鬼武者）
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
