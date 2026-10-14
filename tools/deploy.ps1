<#
Sync ShapeKeySystem between this repo and the game's reframework folder.

  deploy.ps1            repo -> game (refuses when a game file differs and is newer than the repo copy)
  deploy.ps1 -Check     list differences only
  deploy.ps1 -Pull      game -> repo (take edits that were made in the game folder)
  deploy.ps1 -Force     deploy even over newer game files

Only SKS-owned paths are touched. Player data in data/ShapeKeySystem (settings.json, user/, mods/,
trail.log, hash_probe.txt) is never read or written. Set SKS_GAME_REFRAMEWORK to use another install.
#>
param([switch]$Check, [switch]$Pull, [switch]$Force)
$ErrorActionPreference = "Stop"

$repo = Join-Path (Split-Path -Parent $PSScriptRoot) "reframework"
$game = $env:SKS_GAME_REFRAMEWORK
# 要根据实际安装位置修改，不过是开发用所以问题不大
if (-not $game) { $game = "C:\Steam\steamapps\common\MonsterHunterWilds\reframework" }
if (-not (Test-Path $game)) { throw "game reframework folder not found: $game" }

# relative paths owned by SKS; directories are mirrored (extra files on the target side are removed)
$owned = @(
    "autorun\ShapeKeySystem.lua",
    "autorun\ShapeKeySystem_Core",
    "autorun\ShapeKeySystem_UI",
    "autorun\ShapeKeySystem_Games",
    "autorun\ShapeKeySystem_Game", # 清理旧的播放适配器目录
    "data\ShapeKeySystem\builtin",
    "data\ShapeKeySystem\faces",
    "data\ShapeKeySystem\games",
    "images\ShapeKeySystem"
)
# REF-IME 从上游最新 Release 独立安装，见 install-ref-ime.ps1；这里仅部署 SKS 主包。

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

$src = if ($Pull) { $game } else { $repo }
$dst = if ($Pull) { $repo } else { $game }
$copy = @(); $remove = @(); $newer = @()
foreach ($rel in $owned) {
    $a = Get-Files $src $rel
    $b = Get-Files $dst $rel
    foreach ($k in $a.Keys) {
        $f = $a[$k]; $g = $b[$k]
        if (-not $g) { $copy += $k; continue }
        if ($f.Length -ne $g.Length -or (Get-FileHash $f.FullName).Hash -ne (Get-FileHash $g.FullName).Hash) {
            $copy += $k
            if ($g.LastWriteTime -gt $f.LastWriteTime) { $newer += $k }
        }
    }
    foreach ($k in $b.Keys) { if (-not $a[$k]) { $remove += $k } }
}

$dir = if ($Pull) { "game -> repo" } else { "repo -> game" }
if ($copy.Count -eq 0 -and $remove.Count -eq 0) { Write-Host "in sync ($dir)"; exit 0 }
foreach ($k in $copy) { $tag = if ($newer -contains $k) { "copy (target newer!)" } else { "copy" }; Write-Host ("{0,-22} {1}" -f $tag, $k) }
foreach ($k in $remove) { Write-Host ("{0,-22} {1}" -f "remove", $k) }
if ($Check) { exit 0 }
if ($newer.Count -gt 0 -and -not $Force) {
    Write-Host "`n$($newer.Count) file(s) on the target side are newer than the source ($dir)."
    Write-Host "Run with -Pull first to keep those edits, or -Force to overwrite them."
    exit 1
}
foreach ($k in $copy) {
    $to = Join-Path $dst $k
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item (Join-Path $src $k) $to -Force
}
foreach ($k in $remove) { Remove-Item (Join-Path $dst $k) -Force }
Write-Host "`n$dir : $($copy.Count) copied, $($remove.Count) removed"
