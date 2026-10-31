<#
Sync ShapeKeySystem between this repo and the game's reframework folder.

  deploy.ps1            repo -> game (refuses when a game file differs and is newer than the repo copy)
  deploy.ps1 -Check     list differences only
  deploy.ps1 -Pull      game -> repo (take edits that were made in the game folder)
  deploy.ps1 -Force     deploy even over newer game files

Only SKS-owned paths are touched: reframework/ and the listed natives/ files beside it. Player data
in data/ShapeKeySystem (settings.json, user/, mods/, trail.log, hash_probe.txt) is never read or
written. Set SKS_GAME_REFRAMEWORK to use another install.
#>
param([switch]$Check, [switch]$Pull, [switch]$Force)
$ErrorActionPreference = "Stop"

$repo = Join-Path (Split-Path -Parent $PSScriptRoot) "reframework"
$game = $env:SKS_GAME_REFRAMEWORK
# 要根据实际安装位置修改，不过是开发用所以问题不大
if (-not $game) { $game = "E:\Program\Steam\steamapps\common\MonsterHunterWilds\reframework" }
if (-not (Test-Path $game)) { throw "game reframework folder not found: $game" }

. (Join-Path $PSScriptRoot "sks-files.ps1")
# REF-IME 从上游最新 Release 独立安装，见 install-ref-ime.ps1；这里仅部署 SKS 主包。

$src = if ($Pull) { $game } else { $repo }
$dst = if ($Pull) { $repo } else { $game }
$copy = @(); $remove = @(); $newer = @()
# natives\ 在 reframework\ 旁边（仓库根目录、游戏根目录）；其文件以 ..\ 开头，Join-Path 后落在根目录
$sets = @(@{ src = $src; dst = $dst; rels = $owned; prefix = "" },
          @{ src = (Split-Path -Parent $src); dst = (Split-Path -Parent $dst); rels = $ownedNatives; prefix = "..\" })
foreach ($set in $sets) {
    foreach ($rel in $set.rels) {
        $a = Get-Files $set.src $rel
        $b = Get-Files $set.dst $rel
        foreach ($k in $a.Keys) {
            $f = $a[$k]; $g = $b[$k]; $name = $set.prefix + $k
            if (-not $g) { $copy += $name; continue }
            if ($f.Length -ne $g.Length -or (Get-FileHash $f.FullName).Hash -ne (Get-FileHash $g.FullName).Hash) {
                $copy += $name
                if ($g.LastWriteTime -gt $f.LastWriteTime) { $newer += $name }
            }
        }
        foreach ($k in $b.Keys) { if (-not $a[$k]) { $remove += $set.prefix + $k } }
    }
}
if (-not $Pull) {
    foreach ($rel in $retired) {
        if (Test-Path -LiteralPath (Join-Path $dst $rel) -PathType Leaf) { $remove += $rel }
    }
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
