<#
按 Fluffy Mod Manager 的格式生成发布 zip：dist/ShapeKeySystem-<版本>.zip

  ShapeKeySystem/   modinfo.ini、screenshot.jpg（有预览图时）、reframework/（文件清单见 sks-files.ps1）
  REF-IME/          modinfo.ini（AddonFor=ShapeKeySystem）、reframework/plugins/REF-IME.dll

  package.ps1                                         从 REF-IME 最新 Release 下载并校验 SHA256
  package.ps1 -RefImeZip <zip> -RefImeVersion <tag>   用本地 Release zip，不联网；-RefImeSha256 可选

主包版本取自 Version.lua 的 V.number，REF-IME 版本取自其 Release tag。
#>
param(
    [string]$Screenshot = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\images\screenshot.jpg"),
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "dist"),
    [string]$RefImeZip,
    [string]$RefImeVersion,
    [string]$RefImeSha256
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "sks-files.ps1")
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = Join-Path (Split-Path -Parent $PSScriptRoot) "reframework"
$versionFile = Join-Path $repo "autorun\ShapeKeySystem_Core\Version.lua"
$m = [regex]::Match([IO.File]::ReadAllText($versionFile), 'V\.number\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw "V.number not found in $versionFile" }
$version = $m.Groups[1].Value

# 预览图可缺省：默认路径没有文件时只打包不带图；显式指定的路径必须存在。
$hasShot = Test-Path -LiteralPath $Screenshot -PathType Leaf
if (-not $hasShot) {
    if ($PSBoundParameters.ContainsKey("Screenshot")) { throw "screenshot not found: $Screenshot" }
    Write-Warning "no screenshot at $Screenshot; packaging without a preview image"
} else {
    $head = [IO.File]::ReadAllBytes($Screenshot)
    if ($head.Length -lt 3 -or $head[0] -ne 0xFF -or $head[1] -ne 0xD8 -or $head[2] -ne 0xFF) { throw "screenshot is not a JPEG: $Screenshot" }
}

function Write-ModInfo($pairs) {
    # Fluffy 按行读取 key=value；不写 BOM，否则第一行的 name 读不到。
    $text = (($pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"
    return (New-Object Text.UTF8Encoding $false).GetBytes($text)
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("sks-package-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $temp | Out-Null
$zip = $null; $stream = $null
try {
    if ($RefImeZip) {
        if (-not $RefImeVersion) { throw "-RefImeVersion is required with -RefImeZip" }
        $imeZip = (Resolve-Path -LiteralPath $RefImeZip).Path
        $imeTag = $RefImeVersion
        $expected = $RefImeSha256
    } else {
        $headers = @{ "User-Agent" = "ShapeKeySystem-packager"; "Accept" = "application/vnd.github+json" }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Monkeysama/REF-IME/releases/latest" -Headers $headers
        $assets = @($release.assets | Where-Object { $_.name -eq "REF-IME-$($release.tag_name)-windows-x64.zip" })
        if ($assets.Count -ne 1) { throw "Latest release has no unique Windows x64 ZIP asset: $($release.html_url)" }
        # 发布包必须能核对来源，上游缺少 digest 时不打包。
        if (-not ($assets[0].digest -and $assets[0].digest.StartsWith("sha256:"))) { throw "Release asset has no sha256 digest: $($release.html_url)" }
        $imeZip = Join-Path $temp "REF-IME.zip"
        Invoke-WebRequest -Uri $assets[0].browser_download_url -Headers $headers -OutFile $imeZip -UseBasicParsing
        $imeTag = $release.tag_name
        $expected = $assets[0].digest.Substring(7)
    }
    if ($expected -and (Get-FileHash -LiteralPath $imeZip -Algorithm SHA256).Hash -ne $expected.ToUpperInvariant()) {
        throw "REF-IME ZIP SHA256 mismatch"
    }
    $imeVersion = $imeTag -replace '^v', ''
    $imeDll = Join-Path $temp "REF-IME.dll"
    $src = [IO.Compression.ZipFile]::OpenRead($imeZip)
    try {
        $entries = @($src.Entries | Where-Object { $_.Name -ne "" })
        if ($entries.Count -ne 1 -or $entries[0].FullName -ne "reframework/plugins/REF-IME.dll") {
            throw "Unexpected REF-IME ZIP layout; expected only reframework/plugins/REF-IME.dll"
        }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $imeDll)
    } finally { $src.Dispose() }

    $files = @{}
    foreach ($rel in $owned) {
        $found = Get-Files $repo $rel
        foreach ($k in $found.Keys) { $files[$k] = $found[$k].FullName }
    }
    if ($files.Count -eq 0) { throw "no SKS files found under $repo" }

    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $out = Join-Path (Resolve-Path -LiteralPath $OutDir).Path "ShapeKeySystem-$version.zip"
    # 先写到临时目录，失败时不留下半个 zip。
    $partial = Join-Path $temp "package.zip"
    $stream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    # 条目名一律用正斜杠；5.1 的 Compress-Archive 写反斜杠，部分解压工具会当成文件名的一部分。
    function Add-File($name, $path) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $path, $name) | Out-Null }
    function Add-Bytes($name, $bytes) {
        $w = $zip.CreateEntry($name).Open()
        try { $w.Write($bytes, 0, $bytes.Length) } finally { $w.Dispose() }
    }

    $info = [ordered]@{
        name = "ShapeKeySystem"
        version = $version
        author = "谛听 Dimcirui, MonkeySama"
        description = "用游戏表情驱动猎人脸上的形态键（ARKit / Shinano / MMD 等），支持实时捏脸、条件表情和脸部互动。需要 REFramework。"
    }
    if ($hasShot) { $info.screenshot = "screenshot.jpg" }
    Add-Bytes "ShapeKeySystem/modinfo.ini" (Write-ModInfo $info)
    if ($hasShot) { Add-File "ShapeKeySystem/screenshot.jpg" $Screenshot }
    foreach ($k in ($files.Keys | Sort-Object)) {
        Add-File ("ShapeKeySystem/reframework/" + ($k -replace '\\', '/')) $files[$k]
    }

    $info = [ordered]@{
        name = "REF-IME"
        version = $imeVersion
        author = "Monkeysama"
        description = "ShapeKeySystem 文本框的中文输入法支持（REFramework 插件）。"
        AddonFor = "ShapeKeySystem"
    }
    Add-Bytes "REF-IME/modinfo.ini" (Write-ModInfo $info)
    Add-File "REF-IME/reframework/plugins/REF-IME.dll" $imeDll

    $zip.Dispose(); $zip = $null
    $stream.Dispose(); $stream = $null
    Move-Item -LiteralPath $partial -Destination $out -Force
    Write-Host "ShapeKeySystem $version + REF-IME $imeVersion ($($files.Count) files): $out"
} finally {
    if ($zip) { $zip.Dispose() }
    if ($stream) { $stream.Dispose() }
    Remove-Item -LiteralPath $temp -Recurse -Force
}
