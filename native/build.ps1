<#
Build the native REFramework plugins into reframework\plugins\, where deploy.ps1 and package.ps1
pick them up: ShapeKeySystem_Mocap.dll (in-game UDP receiver for 面捕) and ShapeKeySystem_Native.dll
(engine reads too call-heavy for Lua; RE4R, Wilds and RE9).

  build.ps1          build the DLL
  build.ps1 -Test    also build and run the offline test (parsers + Lua table over loopback UDP)

Needs MinGW-w64 gcc (x86_64) on PATH. Lua 5.4.3 is compiled in: it must be the release REFramework
itself uses, because the plugin's Lua API calls run on REFramework's Lua state.
#>
param([switch]$Test, [string]$Gcc = "gcc")
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$src = Join-Path $here "sks_mocap"
$lua = Join-Path $here "third_party\lua-5.4.3"
$api = Join-Path $here "third_party\reframework"
$out = Join-Path (Split-Path -Parent $here) "reframework\plugins"
$build = Join-Path $here "build"
New-Item -ItemType Directory -Force $out, $build | Out-Null

# core + auxlib only: the standard libraries already live in REFramework's state
$core = "lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes lparser lstate lstring ltable ltm lundump lvm lzio lauxlib".Split(" ") |
    ForEach-Object { Join-Path $lua "$_.c" }
$cflags = @("-O2", "-std=c11", "-Wall", "-Wno-unused-function", "-I$lua", "-I$api")

$dll = Join-Path $out "ShapeKeySystem_Mocap.dll"
& $Gcc @cflags -shared -o $dll (Join-Path $src "sks_mocap.c") @core -lws2_32 -static -static-libgcc -s
if ($LASTEXITCODE -ne 0) { throw "DLL build failed" }
Write-Host "built $dll"

# engine reads that are too call-heavy for Lua (RE4R facial pose); same Lua core, no sockets
$native = Join-Path $out "ShapeKeySystem_Native.dll"
& $Gcc @cflags -shared -o $native (Join-Path $here "sks_native\sks_native.c") @core -static -static-libgcc -s
if ($LASTEXITCODE -ne 0) { throw "native DLL build failed" }
Write-Host "built $native"

if ($Test) {
    $libs = "lbaselib lcorolib ldblib liolib lmathlib loadlib loslib lstrlib ltablib lutf8lib linit".Split(" ") |
        ForEach-Object { Join-Path $lua "$_.c" }
    $exe = Join-Path $build "test_sks_mocap.exe"
    & $Gcc @cflags -o $exe (Join-Path $src "test_sks_mocap.c") (Join-Path $src "sks_mocap.c") @core @libs -lws2_32 -static
    if ($LASTEXITCODE -ne 0) { throw "test build failed" }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw "native tests failed" }
}
