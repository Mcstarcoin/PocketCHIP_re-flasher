# =============================================================================
#  Builds sunxi-fel.exe (the Allwinner FEL USB tool) for Windows from the
#  official linux-sunxi source. There is no official Windows build, and the
#  "prebuilt" ones floating around have no clear origin, so we make our own.
#
#  What it downloads (all into the -WorkDir build folder, nothing is installed):
#    - llvm-mingw (portable Clang + MinGW-w64 compiler)  github.com/mstorsjo/llvm-mingw
#    - libusb Windows release (static library)          github.com/libusb/libusb
#    - sunxi-tools source, tag v1.4.1                    github.com/linux-sunxi/sunxi-tools
#
#  Result: <OutDir>\sunxi-fel.exe  (statically linked, no DLLs needed)
#
#  Usage:  powershell -ExecutionPolicy Bypass -File build-sunxi-fel.ps1 [-OutDir <dir>]
# =============================================================================
[CmdletBinding()]
param(
  [string]$OutDir   = (Join-Path $env:LOCALAPPDATA 'pocketchip-flasher\tools\sunxi-tools'),
  [string]$WorkDir  = (Join-Path $env:LOCALAPPDATA 'pocketchip-flasher\build'),
  [string]$SunxiTag = 'v1.4.1',            # the version the Flash-CHIP-2025 README recommends
  [string]$LlvmMingwTag = '20261104',
  [string]$LibusbTag    = 'v1.0.30'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'   # Windows' bsdtar reads .zip and .7z
if (-not (Test-Path $tar)) { throw "tar.exe not found (needs Windows 10 1803 or newer)." }

New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null
$dl = Join-Path $WorkDir 'dl'; New-Item -ItemType Directory -Force -Path $dl | Out-Null

function Get-File($url, $out) {
  if (Test-Path $out) { return }
  Step "Downloading $(Split-Path $url -Leaf)"
  & curl.exe -fL --retry 3 -sS -o "$out.part" $url
  if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
  Move-Item -Force "$out.part" $out
}

# 1. Compiler
$llvmName = "llvm-mingw-$LlvmMingwTag-ucrt-x86_64"
$llvmDir  = Join-Path $WorkDir $llvmName
if (-not (Test-Path (Join-Path $llvmDir 'bin\x86_64-w64-mingw32-gcc.exe'))) {
  $zip = Join-Path $dl "$llvmName.zip"
  Get-File "https://github.com/mstorsjo/llvm-mingw/releases/download/$LlvmMingwTag/$llvmName.zip" $zip
  Step "Unpacking compiler (about 1 GB unpacked)"
  & $tar -xf $zip -C $WorkDir
  if ($LASTEXITCODE -ne 0) { throw "Could not unpack $zip" }
}
$cc = Join-Path $llvmDir 'bin\x86_64-w64-mingw32-gcc.exe'

# 2. libusb
$luVer = $LibusbTag.TrimStart('v')
$luDir = Join-Path $WorkDir "libusb-$luVer"
if (-not (Test-Path (Join-Path $luDir 'MinGW64\static\libusb-1.0.a'))) {
  $sz = Join-Path $dl "libusb-$luVer.7z"
  Get-File "https://github.com/libusb/libusb/releases/download/$LibusbTag/libusb-$luVer.7z" $sz
  New-Item -ItemType Directory -Force -Path $luDir | Out-Null
  & $tar -xf $sz -C $luDir
  if ($LASTEXITCODE -ne 0) { throw "Could not unpack $sz" }
}
$luInc = Join-Path $luDir 'include'
if (-not (Test-Path (Join-Path $luInc 'libusb.h'))) { $luInc = Join-Path $luDir 'include\libusb-1.0' }

# 3. sunxi-tools source
$src = Join-Path $WorkDir "sunxi-tools-$SunxiTag"
if (-not (Test-Path (Join-Path $src 'fel.c'))) {
  $tgz = Join-Path $dl "sunxi-tools-$SunxiTag.zip"
  Get-File "https://github.com/linux-sunxi/sunxi-tools/archive/refs/tags/$SunxiTag.zip" $tgz
  $tmp = Join-Path $WorkDir 'src.tmp'; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  & $tar -xf $tgz -C $tmp
  Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $src
  Remove-Item -Recurse -Force $tmp
}

# 4. Compile (same sources as the Makefile's sunxi-fel target)
Step "Compiling sunxi-fel.exe ($SunxiTag)"
$exe = Join-Path $OutDir 'sunxi-fel.exe'
Push-Location $src
try {
  # common.h includes version.h, which the Makefile normally generates
  Set-Content -Encoding Ascii -Path 'version.h' -Value "#define VERSION `"$SunxiTag-win`""
  & $cc -O2 -std=gnu99 -Wall -Iinclude "-I$luInc" -static `
        -o $exe fel.c progress.c (Join-Path $luDir 'MinGW64\static\libusb-1.0.a')
  if ($LASTEXITCODE -ne 0) { throw "Compile failed (see errors above)." }
} finally { Pop-Location }

& $exe --help 2>&1 | Select-Object -First 1 | Out-Host
Write-Host "[ OK ] Built $exe" -ForegroundColor Green
