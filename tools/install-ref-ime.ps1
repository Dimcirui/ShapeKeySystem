<#
从 REF-IME 最新 GitHub Release 安装通用插件。可指定任意 RE 游戏目录；不改动其他 DLL。
安装前要求目标游戏退出；-Check 只查询版本和下载地址，不写文件。
#>
param(
    [string]$GameDirectory = "C:\Steam\steamapps\common\MonsterHunterWilds",
    [switch]$Check
)
$ErrorActionPreference = "Stop"
$headers = @{ "User-Agent" = "ShapeKeySystem-dependency-installer"; "Accept" = "application/vnd.github+json" }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/Monkeysama/REF-IME/releases/latest" -Headers $headers
$assets = @($release.assets | Where-Object { $_.name -eq "REF-IME-$($release.tag_name)-windows-x64.zip" })
if ($assets.Count -ne 1) { throw "Latest release has no unique Windows x64 ZIP asset: $($release.html_url)" }
$asset = $assets[0]
Write-Host "REF-IME $($release.tag_name): $($asset.browser_download_url)"
if ($Check) { return }
if (-not (Test-Path -LiteralPath $GameDirectory -PathType Container)) { throw "Game directory not found: $GameDirectory" }
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path.TrimEnd('\')
$refRoot = Join-Path $gameRoot "reframework"
if (-not (Test-Path -LiteralPath $refRoot -PathType Container)) { throw "Install REFramework first: $refRoot" }
$destination = Join-Path $refRoot "plugins\REF-IME.dll"
$tempZip = Join-Path ([IO.Path]::GetTempPath()) ("sks-ref-ime-" + [guid]::NewGuid().ToString("N") + ".zip")
$tempDll = [IO.Path]::ChangeExtension($tempZip, ".dll")
$zip = $null
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $tempZip -UseBasicParsing
    if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
        $actual = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash
        if ($actual -ne $asset.digest.Substring(7)) { throw "Release ZIP SHA256 mismatch" }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($tempZip)
    $entries = @($zip.Entries | Where-Object { $_.Name -ne "" })
    if ($entries.Count -ne 1 -or $entries[0].FullName -ne "reframework/plugins/REF-IME.dll") {
        throw "Unexpected ZIP layout; expected only reframework/plugins/REF-IME.dll"
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $tempDll)
    $zip.Dispose(); $zip = $null
    if ((Test-Path -LiteralPath $destination) -and
        (Get-FileHash -LiteralPath $destination).Hash -eq (Get-FileHash -LiteralPath $tempDll).Hash) {
        Write-Host "Already installed: $destination"
        return
    }
    # 用可执行文件的绝对路径检查目标安装目录，不能靠荒野专用的进程名称判断。
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($gameRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($running.Count -gt 0) { throw "Close the target game before installing REF-IME: $($running.Name -join ', ')" }
    New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $tempDll -Destination $destination -Force
    Write-Host "Installed $($release.tag_name): $destination"
} finally {
    if ($zip) { $zip.Dispose() }
    # 只清理本次创建的两个临时文件，不递归删除、不生成备份。
    foreach ($tempFile in @($tempZip, $tempDll)) {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}
