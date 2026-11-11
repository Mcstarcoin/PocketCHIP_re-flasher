# =============================================================================
#   ┌┴┴┴┴┴┴┴┴┴┴┴┴┐
#  ─┤  C.H.I.P.  ├─   PocketCHIP / C.H.I.P. One-Shot Flasher for Windows
#  ─┤   ▓▓▓▓▓▓   ├─   v2-win  (2026-11)
#   └┬┬┬┬┬┬┬┬┬┬┬┬┘
# -----------------------------------------------------------------------------
#  Windows port of pocketchip-flasher.sh. Same menus, same image handling,
#  same bottom progress bar. Instead of running CHIP-tools-2025's Bash script,
#  it does the same FEL + fastboot steps natively (detect_nand / flash_images
#  from CHIP-tools-2025 common.sh, ported line by line), because that Bash
#  script needs sudo, lsusb, mkimage and a Linux shell.
#
#  Tools it uses (downloaded on first run into %LOCALAPPDATA%\pocketchip-flasher):
#    - fastboot.exe   Google Android SDK Platform-Tools (official zip)
#    - sunxi-fel.exe  built from linux-sunxi source by build-sunxi-fel.ps1
#    - Zadig          installs the WinUSB driver for the CHIP (FEL + fastboot)
#    - mkimage        not needed: the U-Boot script header is built in here
#    - curl.exe, tar.exe   built into Windows 10 1803+ / Windows 11
#
#  Usage: double-click PocketCHIP-Flasher.cmd, or
#         powershell -ExecutionPolicy Bypass -File pocketchip-flasher.ps1
#  Non-interactive: ... -Flash -Yes [-Flavor p|s|g|b] [-Branch stable|testing]
# =============================================================================
[CmdletBinding()]
param(
  [switch]$Flash,          # run the flash straight away, no menu
  [switch]$DownloadOnly,   # just download + unpack the image, no menu
  [switch]$Yes,            # don't ask for confirmation (with -Flash)
  [ValidateSet('p','s','g','b')][string]$Flavor = 'p',
  [ValidateSet('stable','testing')][string]$Branch = 'stable',
  [ValidateSet('','Hynix_8G_MLC','Toshiba_4G_MLC','Toshiba_512M_SLC')][string]$Nand = '',
  [ValidateSet('auto','github','archive','mirror','local')][string]$Source = 'auto',
  [string]$LocalImage = '',
  [switch]$NoLimit,
  [switch]$Reset
)

$ErrorActionPreference = 'Continue'   # native tools write to stderr; don't turn that into exceptions
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------------------------- Configuration ---------------------------------
function EnvOr($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }

# Copies of the official Next Thing Co. images, attached to this repo's "images" release
$GH_BASE     = EnvOr 'PCF_GH_BASE' 'https://github.com/Mcstarcoin/PocketCHIP_re-flasher/releases/download/images'
$IA_BASE     = EnvOr 'PCF_IA_BASE' 'https://archive.org/download/C.h.i.p.FlashCollection'
$IA_META_URL = EnvOr 'PCF_IA_META_URL' "$IA_BASE/C.h.i.p.FlashCollection_files.xml"
$MIRROR_URL  = 'http://chip.jfpossibilities.com/chip/images'   # offline as of 2026-11
$PLATFORM_TOOLS_URL = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$ZADIG_API   = 'https://api.github.com/repos/pbatard/libwdi/releases/latest'
$ANDROID_USB_GUID = '{F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}'   # interface class fastboot.exe looks for

$WORK_DIR  = EnvOr 'PCF_WORK_DIR' (Join-Path $env:LOCALAPPDATA 'pocketchip-flasher')
$TOOLS_DIR = Join-Path $WORK_DIR 'tools'
$IMG_DIR   = Join-Path $WORK_DIR 'images'
$LOG_DIR   = Join-Path $WORK_DIR 'logs'
$IA_META   = Join-Path $WORK_DIR 'ia_files.xml'
$DRIVER_MARK = Join-Path $WORK_DIR 'drivers-installed.txt'
$TITLE     = 'PocketCHIP Flasher'

$FEL      = EnvOr 'PCF_FEL' ''        # resolved by Ensure-Tools
$FASTBOOT = EnvOr 'PCF_FASTBOOT' ''

# Flash options (changed from the Advanced menu)
$script:OPT_FLAVOR = $Flavor       # p=PocketCHIP, s=Server, g=GUI desktop, b=Buildroot
$script:OPT_BRANCH = $Branch
$script:OPT_NAND   = $Nand         # "" = auto-detect
$script:OPT_NOLIMIT = [int][bool]$NoLimit
$script:OPT_FORCE  = 0
$script:OPT_RESET  = [int][bool]$Reset
$script:OPT_SOURCE = $Source
$script:OPT_LOCAL_PATH = $LocalImage
if ($LocalImage -and $Source -eq 'auto') { $script:OPT_SOURCE = 'local' }
$script:IMG_PATH = ''              # set by Prepare-Image (absolute folder)
$script:Interactive = -not ($Flash -or $DownloadOnly)

# ------------------------- Native helpers (C#) ------------------------------
if (-not ('PcfNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PcfNative {
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
  public static bool EnableVT() {
    IntPtr h = GetStdHandle(-11); uint m;
    if (!GetConsoleMode(h, out m)) return false;
    return SetConsoleMode(h, m | 0x0004);   // ENABLE_VIRTUAL_TERMINAL_PROCESSING
  }
  static uint[] table;
  public static uint Crc32(byte[] d, int off, int len) {
    if (table == null) {
      table = new uint[256];
      for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; table[i] = c; }
    }
    uint crc = 0xFFFFFFFFu;
    for (int i = off; i < off + len; i++) crc = table[(crc ^ d[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
  }
  static void BE(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o+1] = (byte)(v >> 16); b[o+2] = (byte)(v >> 8); b[o+3] = (byte)v; }
  // Same bytes as: mkimage -A arm -T script -C none -n <name> -d <file>
  // (legacy uImage header; a script is a multi-file image: size table, 0, data)
  public static byte[] MkScript(byte[] data, string name, uint time) {
    int plen = 8 + data.Length;
    byte[] img = new byte[64 + plen];
    BE(img, 64, (uint)data.Length); BE(img, 68, 0);
    Array.Copy(data, 0, img, 72, data.Length);
    BE(img, 0, 0x27051956u);            // magic
    BE(img, 8, time);                   // timestamp
    BE(img, 12, (uint)plen);            // data size
    BE(img, 16, 0); BE(img, 20, 0);     // load address, entry point
    BE(img, 24, Crc32(img, 64, plen));  // data CRC
    img[28] = 5; img[29] = 2; img[30] = 6; img[31] = 0;   // OS=Linux, arch=ARM, type=script, comp=none
    byte[] n = System.Text.Encoding.ASCII.GetBytes(name);
    Array.Copy(n, 0, img, 32, Math.Min(n.Length, 32));
    BE(img, 4, Crc32(img, 0, 64));      // header CRC (computed with this field = 0)
    return img;
  }
}
'@
}

# ------------------------------ Output helpers ------------------------------
$ESC = [char]27
$script:LogFile = $null
function Log-Line([string]$s) { if ($script:LogFile) { [IO.File]::AppendAllText($script:LogFile, $s + "`r`n") } }
function Say([string]$s, [string]$color = '') {
  if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }
  Log-Line $s
}
function Info([string]$s) { Write-Host '==> ' -ForegroundColor Cyan -NoNewline; Write-Host $s; Log-Line "==> $s" }
function Ok([string]$s)   { Write-Host '[ OK ] ' -ForegroundColor Green -NoNewline; Write-Host $s; Log-Line "[ OK ] $s" }
function Warn([string]$s) { Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline; Write-Host $s; Log-Line "[WARN] $s" }
function Fail([string]$s) { Write-Host '[FAIL] ' -ForegroundColor Red -NoNewline; Write-Host $s; Log-Line "[FAIL] $s" }

function MB($b) { '{0:N1}' -f ([double]$b / 1MB) }
function MMSS([int]$s) { '{0}:{1:D2}' -f [math]::Floor($s / 60), ($s % 60) }
function FSize($p) { if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { 0 } }
function Q([string]$a) { if ($a -match '[\s"]' -or $a -eq '') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }   # quote one argument

# ---------------------------- ASCII art -------------------------------------
function Art-Banner {
  Write-Host @'
      .-----------------------------------------.
      |  .-----------------------------------.  |
      |  |  > flash --pocketchip             |  |
      |  |  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░  64%   |  |
      |  |  chip@chip:~$ _                   |  |
      |  '-----------------------------------'  |
      |   [1][2][3][4][5][6][7][8][9][0][-][=]  |
      |   [q][w][e][r][t][y][u][i][o][p][[][]]  |
      |   [a][s][d][f][g][h][j][k][l][;]['][⏎]  |
      |   [z][x][c][v][b][n][m][,][.][/][↑][ ]  |
      '-----------------------------------------'
'@ -ForegroundColor Cyan
  Write-Host '          P O C K E T   C . H . I . P .   F L A S H E R   (Windows)' -ForegroundColor Magenta
  Write-Host ''
}

function Art-Chip([string]$l1 = '', [string]$l2 = '') {
  $c = 'Green'
  Write-Host '          ┌┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┐' -ForegroundColor $c
  Write-Host '         ─┤                      ├─' -ForegroundColor $c
  Write-Host '         ─┤       C.H.I.P.       ├─' -ForegroundColor $c
  Write-Host ('         ─┤ {0,-20} ├─' -f $l1) -ForegroundColor $c
  Write-Host ('         ─┤ {0,-20} ├─' -f $l2) -ForegroundColor $c
  Write-Host '         ─┤                      ├─' -ForegroundColor $c
  Write-Host '          └┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┘' -ForegroundColor $c
}

# ------------------------- Bottom-pinned progress bar -----------------------
# Reserves the last two console lines (separator + bar) with a VT scroll
# region, so normal output scrolls above while the bar stays put.
$script:VT = $false
if (-not [Console]::IsOutputRedirected) { try { $script:VT = [PcfNative]::EnableVT() } catch { } }
$script:BarOn = $false; $script:BarPct = 0; $script:BarLabel = ''; $script:BarDetail = ''
$script:Rows = 24; $script:Cols = 80

function Term-Size {
  try { $script:Rows = [Console]::WindowHeight; $script:Cols = [Console]::WindowWidth } catch { }
  if ($script:Rows -lt 8) { $script:Rows = 24 }; if ($script:Cols -lt 40) { $script:Cols = 80 }
}
function Raw([string]$s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

function Bar-Start([string]$label = 'Starting') {
  if (-not $script:VT) { return }
  Term-Size
  Clear-Host
  Raw ("$ESC[1;{0}r$ESC[1;1H" -f ($script:Rows - 2))
  $script:BarOn = $true
  Bar-Draw 0 $label
}

function Bar-Paint([string]$fill, [string]$empty, [string]$right) {
  $sep = '─' * $script:Cols
  $fmt = '{7}7{7}[{0};1H{7}[2K{7}[2m{1}{7}[0m{7}[{2};1H{7}[2K{7}[1;97;44m {3} {7}[0m {7}[36m{4}{7}[90m{5}{7}[0m{7}[1m{6}{7}[0m{7}8'
  Raw ($fmt -f ($script:Rows - 1), $sep, $script:Rows, $script:BarLabel, $fill, $empty, $right, $ESC)
}

function Bar-Draw($pct, [string]$label = '', [string]$detail = '') {
  if (-not $script:BarOn) { return }
  Term-Size
  $p = [int][math]::Floor([double]$pct); if ($p -lt 0) { $p = 0 }; if ($p -gt 100) { $p = 100 }
  $script:BarPct = $p; if ($label) { $script:BarLabel = $label }; $script:BarDetail = $detail
  $right = ' {0,3}% {1}' -f $p, $detail
  $w = $script:Cols - $script:BarLabel.Length - $right.Length - 4
  if ($w -lt 10) { $right = ' {0,3}%' -f $p; $w = $script:Cols - $script:BarLabel.Length - $right.Length - 4 }
  if ($w -lt 5) { $w = 5 }
  $f = [int][math]::Floor($p * $w / 100)
  Bar-Paint ('█' * $f) ('░' * ($w - $f)) $right
}

function Bar-Busy([int]$i, [string]$label = '', [string]$detail = 'working...') {
  if (-not $script:BarOn) { return }
  Term-Size
  if ($label) { $script:BarLabel = $label }
  $right = " $detail"
  $w = $script:Cols - $script:BarLabel.Length - $right.Length - 4; if ($w -lt 10) { $w = 10 }
  $span = $w - 8; $pos = $i % (2 * $span); if ($pos -gt $span) { $pos = 2 * $span - $pos }
  Bar-Paint (('░' * $pos) + ('█' * 8)) ('░' * ($w - $pos - 8)) $right
}

function Bar-Stop {
  if (-not $script:BarOn) { return }
  Term-Size
  Raw ("$ESC[r$ESC[{0};1H$ESC[2K$ESC[{1};1H$ESC[2K$ESC[{2};1H" -f ($script:Rows - 1), $script:Rows, ($script:Rows - 2))
  $script:BarOn = $false
}

# Run an external program with an animated bar; returns its exit code.
function Run-Busy([string]$label, [string]$exe, [string[]]$argv, [string]$errFile = '') {
  $sp = @{ FilePath = $exe; ArgumentList = (($argv | ForEach-Object { Q $_ }) -join ' '); NoNewWindow = $true; PassThru = $true }
  if ($errFile) { $sp.RedirectStandardError = $errFile; $sp.RedirectStandardOutput = "$errFile.out" }
  $p = Start-Process @sp
  $h = $p.Handle   # keeps ExitCode available after exit
  $i = 0
  while (-not $p.HasExited) { Bar-Busy $i $label; $i++; Start-Sleep -Milliseconds 120 }
  $p.WaitForExit()
  return $p.ExitCode
}

# ------------------------------ Dialog helpers ------------------------------
function Pause-Menu { Bar-Stop; if ($script:Interactive) { Write-Host ''; [void](Read-Host 'Press Enter to return to the menu') } }
function Msg([string]$text) { Bar-Stop; Write-Host ''; Write-Host $text; Pause-Menu }
function YesNo([string]$q) {
  Bar-Stop
  if ($Yes) { return $true }
  $a = Read-Host "$q [y/N]"; return ($a -match '^[Yy]')
}

function Show-Menu([string]$prompt, [object[]]$items) {   # items: tag, desc, tag, desc...
  Bar-Stop
  Write-Host ''
  Write-Host $prompt -ForegroundColor Cyan
  Write-Host ''
  $tags = @()
  for ($i = 0; $i -lt $items.Count; $i += 2) {
    $tags += [string]$items[$i]
    Write-Host ('  {0,2}) ' -f $items[$i]) -ForegroundColor Yellow -NoNewline; Write-Host $items[$i + 1]
  }
  Write-Host ''
  $c = (Read-Host 'Choose').Trim()
  if ($tags -contains $c) { return $c }
  return $null
}

# ------------------------------ Lookups -------------------------------------
function Flavor-Name($f) {
  switch ($f) { 'p' { 'PocketCHIP (Pocket OS)' } 's' { 'Server (headless Debian)' } 'g' { 'GUI (Debian desktop, XFCE)' } 'b' { 'Buildroot (minimal)' } }
}
function Flavor-Dir { switch ($script:OPT_FLAVOR) { 'p' { 'pocketchip' } 's' { 'server' } 'g' { 'gui' } 'b' { 'buildroot' } } }

# Builds available in the Internet Archive C.H.I.P. Flash Collection
function IA-Build {
  $k = "$($script:OPT_BRANCH)-$(Flavor-Dir)"
  @{ 'stable-pocketchip' = 126; 'testing-pocketchip' = 667; 'stable-gui' = 149; 'testing-gui' = 543
     'stable-server' = 149; 'testing-server' = 543; 'stable-buildroot' = 34; 'testing-buildroot' = 23 }[$k]
}
function Image-Name { "$($script:OPT_BRANCH)-$(Flavor-Dir)-b$(IA-Build)" }

function Source-Name {
  switch ($script:OPT_SOURCE) {
    'auto' { 'Auto (GitHub copy, Internet Archive, old mirror)' } 'github' { 'GitHub release copy only' } 'archive' { 'Internet Archive only' }
    'mirror' { 'jfpossibilities mirror only' } 'local' { "Local: $(if ($script:OPT_LOCAL_PATH) { $script:OPT_LOCAL_PATH } else { '<not set>' })" }
  }
}

# USB devices of interest, with the driver Windows has bound to them
function Get-ChipUsb {
  $fake = $env:PCF_FAKE_USB   # tests: fel | fastboot | none
  if ($fake) {
    if ($fake -eq 'fel') { return @([pscustomobject]@{ Id = 'USB\VID_1F3A&PID_EFE8\FAKE'; Service = 'WinUSB'; Err = 0 }) }
    if ($fake -eq 'fastboot') { return @([pscustomobject]@{ Id = 'USB\VID_1F3A&PID_1010\FAKE'; Service = 'WinUSB'; Err = 0 }) }
    return @()
  }
  try {
    Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\VID_1F3A%' OR DeviceID LIKE 'USB\\VID_18D1&PID_1010%' OR DeviceID LIKE 'USB\\VID_0525&PID_A4A%'" -ErrorAction Stop |
      ForEach-Object { [pscustomobject]@{ Id = $_.DeviceID; Service = $_.Service; Err = $_.ConfigManagerErrorCode } }
  } catch { @() }
}
function Has-Driver($d) { ($d.Err -eq 0) -and ($d.Service -match '^(WinUSB|libusbK|libusb0)$') }

function Usb-State {
  $devs = @(Get-ChipUsb)
  $fel = $devs | Where-Object { $_.Id -match 'VID_1F3A&PID_EFE8' } | Select-Object -First 1
  $fb  = $devs | Where-Object { $_.Id -match 'PID_1010' } | Select-Object -First 1
  $os  = $devs | Where-Object { $_.Id -match 'VID_0525' } | Select-Object -First 1
  if ($fel) { if (Has-Driver $fel) { return 'FEL mode - ready to flash ✓' } else { return 'FEL mode - USB driver missing (menu 6)' } }
  if ($fb)  { if (Has-Driver $fb) { return 'fastboot mode (flashing)' } else { return 'fastboot mode - USB driver missing (menu 6)' } }
  if ($os)  { return 'booted normally - NOT in FEL mode' }
  return 'not detected'
}
function Fel-Present { [bool](@(Get-ChipUsb) | Where-Object { $_.Id -match 'VID_1F3A&PID_EFE8' }) }

function Image-Complete([string]$d) {   # folder has everything the flash needs?
  if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { return $false }
  foreach ($f in 'sunxi-spl.bin', 'u-boot-dtb.bin', 'uboot-400000.bin') { if (-not (Test-Path -LiteralPath (Join-Path $d $f))) { return $false } }
  if (-not (Get-ChildItem -LiteralPath $d -Filter 'chip-*.ubi.sparse' -ErrorAction SilentlyContinue)) { return $false }
  return [bool](Get-ChildItem -LiteralPath $d -Filter 'spl-*.bin' -ErrorAction SilentlyContinue)
}

# ------------------------------ Setup steps ---------------------------------
function Download-Simple([string]$url, [string]$out) {
  & curl.exe -fL --connect-timeout 20 --retry 3 -sS -o "$out.part" $url
  if ($LASTEXITCODE -ne 0) { Remove-Item -Force "$out.part" -ErrorAction SilentlyContinue; return $false }
  Move-Item -Force "$out.part" $out; return $true
}

function Ensure-Base {
  foreach ($t in 'curl.exe', 'tar.exe') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Fail "$t is missing. This needs Windows 10 (1803 or newer) or Windows 11."; return $false }
  }
  return $true
}

function Ensure-Fastboot {
  if ($script:FASTBOOT -and (Test-Path -LiteralPath $script:FASTBOOT)) { return $true }
  $fb = Join-Path $TOOLS_DIR 'platform-tools\fastboot.exe'
  if (-not (Test-Path $fb)) {
    Info 'Downloading Google Android Platform-Tools (fastboot.exe, ~7 MB)...'
    $zip = Join-Path $TOOLS_DIR 'platform-tools.zip'
    $null = Run-Busy 'Downloading fastboot' 'curl.exe' @('-fL', '--connect-timeout', '20', '--retry', '3', '-sS', '-o', $zip, $PLATFORM_TOOLS_URL)
    if (-not (Test-Path $zip)) { Fail 'Could not download Platform-Tools. Check your internet connection.'; return $false }
    $rc = Run-Busy 'Unpacking fastboot' 'tar.exe' @('-xf', $zip, '-C', $TOOLS_DIR)
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    if ($rc -ne 0 -or -not (Test-Path $fb)) { Fail 'Could not unpack Platform-Tools.'; return $false }
    Ok 'fastboot.exe downloaded.'
  } else { Ok 'fastboot.exe already downloaded - skipping.' }
  $script:FASTBOOT = $fb
  return $true
}

function Ensure-SunxiFel {
  if ($script:FEL -and (Test-Path -LiteralPath $script:FEL)) { return $true }
  $exe = Join-Path $TOOLS_DIR 'sunxi-tools\sunxi-fel.exe'
  $onPath = Get-Command 'sunxi-fel.exe' -ErrorAction SilentlyContinue
  if (Test-Path $exe) { Ok 'sunxi-fel.exe already built - skipping.' }
  elseif ($onPath) { $exe = $onPath.Source; Ok "Using sunxi-fel.exe from PATH: $exe" }
  else {
    $builder = Join-Path $PSScriptRoot 'build-sunxi-fel.ps1'
    if (-not (Test-Path $builder)) { Fail "sunxi-fel.exe not found, and build-sunxi-fel.ps1 is not next to this script."; return $false }
    Warn 'sunxi-fel.exe (the FEL USB tool) is not built yet.'
    Write-Host '   There is no official Windows download, so it is compiled from the'
    Write-Host '   linux-sunxi source (v1.4.1). This downloads a portable compiler'
    Write-Host '   (~190 MB, nothing is installed) and takes a few minutes, once.'
    if (-not (YesNo 'Build sunxi-fel.exe now?')) { return $false }
    Bar-Stop
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $builder -OutDir (Split-Path $exe)
    if (-not (Test-Path $exe)) {
      # pwsh has no powershell.exe in $PSHOME; fall back to the system one
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -OutDir (Split-Path $exe)
    }
    if (-not (Test-Path $exe)) { Fail 'Building sunxi-fel.exe failed (see messages above).'; return $false }
    Bar-Start 'Tools'
  }
  $script:FEL = $exe
  return $true
}

function Ensure-Tools {
  Bar-Draw 10 'Checking tools' 'curl, tar'
  if (-not (Ensure-Base)) { return $false }
  Bar-Draw 40 'Checking tools' 'fastboot'
  if (-not (Ensure-Fastboot)) { return $false }
  Bar-Draw 70 'Checking tools' 'sunxi-fel'
  if (-not (Ensure-SunxiFel)) { return $false }
  Bar-Draw 100 'Checking tools' 'done'
  return $true
}

# --- USB drivers (Zadig / WinUSB) ---
$ZADIG_FEL_CFG = @"
# Zadig preset: C.H.I.P. / PocketCHIP in FEL (boot ROM flashing) mode
[device]
  Description = "CHIP FEL mode (Allwinner)"
  VID = 0x1F3A
  PID = 0xEFE8
"@
$ZADIG_FB_CFG = @"
# Zadig preset: C.H.I.P. / PocketCHIP U-Boot fastboot mode (Android USB GUID for fastboot.exe)
[device]
  Description = "CHIP fastboot mode"
  VID = 0x1F3A
  PID = 0x1010
  GUID = "$ANDROID_USB_GUID"
"@

function Ensure-Zadig {
  $z = Join-Path $TOOLS_DIR 'zadig.exe'
  if (Test-Path $z) { return $z }
  Info 'Downloading Zadig (USB driver installer, github.com/pbatard/libwdi)...'
  try {
    $rel = Invoke-RestMethod -Uri $ZADIG_API -Headers @{ 'User-Agent' = 'pocketchip-flasher' } -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -match '^zadig-[\d.]+\.exe$' } | Select-Object -First 1
  } catch { $asset = $null }
  if (-not $asset) { Fail 'Could not find the Zadig download. Get it from https://zadig.akeo.ie and save it as:'; Write-Host "   $z"; return $null }
  if (-not (Download-Simple $asset.browser_download_url $z)) { Fail 'Zadig download failed.'; return $null }
  Ok "Zadig $($asset.name) downloaded."
  return $z
}

function Install-Drivers {
  Clear-Host
  Art-Chip 'USB drivers' 'WinUSB'
  $zdir = Join-Path $TOOLS_DIR 'zadig'
  New-Item -ItemType Directory -Force -Path $zdir | Out-Null
  $felCfg = Join-Path $zdir 'chip-fel.cfg'; $fbCfg = Join-Path $zdir 'chip-fastboot.cfg'
  Set-Content -Encoding Ascii -Path $felCfg -Value $ZADIG_FEL_CFG
  Set-Content -Encoding Ascii -Path $fbCfg -Value $ZADIG_FB_CFG
  $z = Ensure-Zadig
  if (-not $z) { Pause-Menu; return }
  Write-Host @"

  Windows needs the generic WinUSB driver for the CHIP's two flashing modes.
  Zadig will open now (click Yes on the admin prompt). In Zadig, do this TWICE:

    1. Device  >  Load Preset Device  >  choose  chip-fel.cfg
       Make sure the driver box on the right says  WinUSB , click  Install Driver.
    2. Device  >  Load Preset Device  >  choose  chip-fastboot.cfg
       Again  WinUSB , click  Install Driver.

  The CHIP does not need to be plugged in. Close Zadig when both are done.
  Preset files are in: $zdir
"@ -ForegroundColor White
  [void](Read-Host 'Press Enter to open Zadig')
  try { Start-Process -FilePath $z -WorkingDirectory $zdir -Wait } catch { Fail "Could not start Zadig: $_"; Pause-Menu; return }
  if (YesNo 'Did both drivers install successfully?') {
    Set-Content -Path $DRIVER_MARK -Value (Get-Date -Format s)
    Ok 'USB drivers marked as installed.'
  } else {
    Warn 'Drivers not confirmed. You can run this again from the menu (6).'
  }
  Pause-Menu
}

function Check-Drivers {
  if ($env:PCF_FAKE_USB) { return }
  if (Test-Path $DRIVER_MARK) { Ok 'USB drivers already installed - skipping.'; return }
  $d = @(Get-ChipUsb) | Where-Object { $_.Id -match 'PID_EFE8' } | Select-Object -First 1
  if ($d -and (Has-Driver $d)) { Ok "FEL driver present ($($d.Service))."; return }
  Warn 'The CHIP USB drivers (WinUSB) have not been installed yet.'
  if ($script:Interactive -and (YesNo 'Install them now with Zadig?')) { Install-Drivers; Bar-Start 'Drivers' }
}

# ------------------------------ Image handling ------------------------------
function Download-File([string]$url, [string]$out, [string]$label, [long]$total = 0) {
  $part = "$out.part"
  if (Test-Path -LiteralPath $out) { return $true }
  if ($total -gt 0 -and (FSize $part) -eq $total) { Move-Item -Force $part $out; return $true }
  $err = Join-Path $WORK_DIR 'curl-err.txt'
  for ($try = 1; $try -le 5; $try++) {
    $argv = @('-fL', '--connect-timeout', '20', '--retry', '3', '--retry-delay', '3', '-C', '-', '-sS', '-o', $part, $url)
    $p = Start-Process -FilePath 'curl.exe' -ArgumentList (($argv | ForEach-Object { Q $_ }) -join ' ') -NoNewWindow -PassThru -RedirectStandardError $err
    $h = $p.Handle
    $t0 = Get-Date; $s0 = FSize $part
    while (-not $p.HasExited) {
      $now = FSize $part; $el = ((Get-Date) - $t0).TotalSeconds
      $spd = if ($el -gt 0) { [long](($now - $s0) / $el) } else { 0 }
      if ($total -gt 0) {
        $eta = '--:--'; if ($spd -gt 0) { $eta = MMSS ([int](($total - $now) / $spd)) }
        Bar-Draw ($now * 100 / $total) $label ("{0}/{1} MB  {2} MB/s  ETA {3}" -f (MB $now), (MB $total), (MB $spd), $eta)
      } else {
        Bar-Busy ([int]$el * 4) $label ("{0} MB  {1} MB/s" -f (MB $now), (MB $spd))
      }
      Start-Sleep -Milliseconds 500
    }
    $p.WaitForExit(); $rc = $p.ExitCode
    if ($rc -eq 0) { Move-Item -Force $part $out; Bar-Draw 100 $label 'done'; return $true }
    # 22 = HTTP error (e.g. 416 on an odd partial), 33/36 = resume not possible
    if ($rc -in 22, 33, 36) { Remove-Item -Force $part -ErrorAction SilentlyContinue }
    $msg = (Get-Content $err -ErrorAction SilentlyContinue | Select-Object -First 1)
    Warn "Download interrupted (curl error $rc$(if ($msg) { ": $msg" })). Retrying ($try/5)..."
    Start-Sleep -Seconds 3
  }
  return $false
}

function IA-Meta {   # fetch archive.org file list (sizes + md5) once
  if ((FSize $IA_META) -gt 0) { return $true }
  & curl.exe -fsSL --connect-timeout 15 -m 60 -o $IA_META $IA_META_URL 2>$null
  if ($LASTEXITCODE -ne 0) { Remove-Item -Force $IA_META -ErrorAction SilentlyContinue; return $false }
  return $true
}

function IA-Field([string]$file, [string]$field) {
  if ((FSize $IA_META) -le 0) { return $null }
  try {
    [xml]$x = Get-Content -Raw -LiteralPath $IA_META
    $n = $x.files.file | Where-Object { $_.name -eq $file } | Select-Object -First 1
    if ($n) { return [string]$n.$field }
  } catch { }
  return $null
}

function Folder-Bytes([string]$d) { $s = (Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($s) { [long]$s } else { 0 } }

function Extract-Zip([string]$zip, [string]$dest, [string]$label) {
  $tmp = "$dest.tmp"
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $total = 0
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip); $total = ($z.Entries | Measure-Object Length -Sum).Sum; $z.Dispose()
  } catch { $total = 0 }
  $p = Start-Process -FilePath 'tar.exe' -ArgumentList ('-xf ' + (Q $zip) + ' -C ' + (Q $tmp)) -NoNewWindow -PassThru
  $h = $p.Handle
  $i = 0
  while (-not $p.HasExited) {
    if ($total -gt 0) { $now = Folder-Bytes $tmp; Bar-Draw ($now * 100 / $total) $label ("{0}/{1} MB" -f (MB $now), (MB $total)) }
    else { Bar-Busy $i $label; $i += 4 }
    Start-Sleep -Milliseconds 400
  }
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { Fail 'Unzip failed.'; Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue; return $false }

  # Find the folder holding the images (zip layout may nest folders or zips)
  $spl = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'sunxi-spl.bin' | Select-Object -First 1
  if (-not $spl) {
    $inner = Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.zip' | Select-Object -First 1
    if ($inner) {
      New-Item -ItemType Directory -Force -Path "$tmp\inner" | Out-Null
      $null = Run-Busy "$label (inner archive)" 'tar.exe' @('-xf', $inner.FullName, '-C', "$tmp\inner")
      $spl = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'sunxi-spl.bin' | Select-Object -First 1
    }
  }
  if (-not $spl) { Fail "No flash images found inside $(Split-Path $zip -Leaf)."; Remove-Item -Recurse -Force -LiteralPath $tmp; return $false }
  Remove-Item -Recurse -Force -LiteralPath $dest -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $spl.DirectoryName -Destination $dest
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  Bar-Draw 100 $label 'done'
  if (-not (Image-Complete $dest)) { Fail 'Image folder is incomplete after extraction.'; return $false }
  return $true
}

function Check-Space([long]$need) {
  try {
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($WORK_DIR))
    if ($drive.AvailableFreeSpace -lt $need) {
      Fail ("Not enough disk space: need ~{0} MB, have {1} MB free." -f [long]($need / 1MB), [long]($drive.AvailableFreeSpace / 1MB)); return $false
    }
  } catch { }
  return $true
}

function Url-Exists([string]$url) {
  & curl.exe -sfIL --connect-timeout 15 -m 30 -o NUL $url 2>$null
  return ($LASTEXITCODE -eq 0)
}

# Downloads <name>.zip from $base (GitHub release or archive.org), checks the
# MD5 from the archive.org file list (same files on both), unpacks it.
function Fetch-FromArchive([string]$name, [string]$dir, [string]$base = $IA_BASE, [string]$srcLabel = 'Internet Archive - C.H.I.P. Flash Collection') {
  $zipname = "$name.zip"; $zip = Join-Path $IMG_DIR $zipname
  Info "Source: $srcLabel ($zipname)"
  if (-not (Test-Path -LiteralPath $zip) -and -not (Test-Path -LiteralPath "$zip.part") -and -not (Url-Exists "$base/$zipname")) {
    Warn "$zipname is not available there."; return $false
  }
  Bar-Busy 0 'Reading archive file list'
  if (-not (IA-Meta)) { Warn 'Could not read archive.org file list; skipping checksum.' }
  $size = IA-Field $zipname 'size'; $md5 = IA-Field $zipname 'md5'
  [long]$sz = 0; if (-not [long]::TryParse([string]$size, [ref]$sz)) { $sz = 0 }
  if (-not (Test-Path -LiteralPath $zip)) {
    $need = if ($sz -gt 0) { $sz * 3 + 300MB } else { 3500MB }
    if (-not (Check-Space $need)) { return $false }
    Info "Downloading $(MB $sz) MB. This may take a while."
    Info 'If it gets interrupted, just run Flash again: it resumes where it stopped.'
    if (-not (Download-File "$base/$zipname" $zip 'Downloading image' $sz)) { Fail "Download from $srcLabel failed."; return $false }
  } else { Ok "Found downloaded $zipname" }
  if ($md5) {
    Bar-Busy 0 'Verifying checksum (MD5)'
    $got = (Get-FileHash -Algorithm MD5 -LiteralPath $zip).Hash.ToLower()
    if ($got -ne $md5.ToLower()) {
      Fail 'Checksum mismatch - the download is corrupt. Deleting it; run Flash again to re-download.'
      Remove-Item -Force -LiteralPath $zip; return $false
    }
    Ok "Checksum OK ($md5)"
  } else {
    $rc = Run-Busy 'Testing zip integrity' 'tar.exe' @('-tf', $zip) (Join-Path $WORK_DIR 'tar-test.txt')
    if ($rc -ne 0) { Fail 'Zip is corrupt; deleting it.'; Remove-Item -Force -LiteralPath $zip; return $false }
    Ok 'Zip integrity OK'
  }
  if (-not (Extract-Zip $zip $dir 'Unpacking image')) { return $false }
  Remove-Item -Force -LiteralPath $zip
  Ok "Image ready: $dir"
  return $true
}

function Fetch-FromMirror {   # sets IMG_PATH on success
  $fl = Flavor-Dir
  Info 'Trying the old jfpossibilities mirror...'
  $latest = (& curl.exe -fsS --connect-timeout 8 -m 15 "$MIRROR_URL/$($script:OPT_BRANCH)/$fl/latest" 2>$null) -replace '[^0-9]', ''
  if (-not $latest) { Fail 'Mirror is offline (chip.jfpossibilities.com).'; return $false }
  $dir = Join-Path $IMG_DIR "$($script:OPT_BRANCH)-$fl-b$latest"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $files = @('spl-40000-1000-100.bin', 'spl-400000-4000-500.bin', 'spl-400000-4000-680.bin', 'sunxi-spl.bin', 'u-boot-dtb.bin', 'uboot-40000.bin', 'uboot-400000.bin')
  switch ($script:OPT_NAND) {
    'Hynix_8G_MLC'     { $files += 'chip-400000-4000-680.ubi.sparse' }
    'Toshiba_4G_MLC'   { $files += 'chip-400000-4000-500.ubi.sparse' }
    'Toshiba_512M_SLC' { $files += 'chip-40000-1000-100.ubi.sparse' }
    default            { $files += 'chip-400000-4000-680.ubi.sparse', 'chip-400000-4000-500.ubi.sparse', 'chip-40000-1000-100.ubi.sparse' }
  }
  $i = 0
  foreach ($f in $files) {
    $i++
    $u = "$MIRROR_URL/$($script:OPT_BRANCH)/$fl/$latest/$f"
    $len = 0; $hdr = & curl.exe -sI --connect-timeout 10 $u 2>$null
    $m = $hdr | Select-String -Pattern '^content-length:\s*(\d+)' | Select-Object -Last 1
    if ($m) { $len = [long]$m.Matches[0].Groups[1].Value }
    if (-not (Download-File $u (Join-Path $dir $f) "File $i/$($files.Count)" $len)) { return $false }
  }
  if (-not (Image-Complete $dir)) { return $false }
  $script:IMG_PATH = $dir
  return $true
}

function Prepare-Local {
  $p = $script:OPT_LOCAL_PATH
  if (-not $p) { Fail 'No local image path set (Advanced > Image source).'; return $false }
  if (-not (Test-Path -LiteralPath $p)) { Fail "Not found: $p"; return $false }
  $p = (Resolve-Path -LiteralPath $p).Path
  if (Test-Path -LiteralPath $p -PathType Container) {
    $spl = Get-ChildItem -LiteralPath $p -Recurse -Filter 'sunxi-spl.bin' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $spl -or -not (Image-Complete $spl.DirectoryName)) { Fail "No complete image found in $p"; return $false }
    $script:IMG_PATH = $spl.DirectoryName
  } elseif ($p -like '*.zip') {
    $dir = Join-Path $IMG_DIR ('local-' + [IO.Path]::GetFileNameWithoutExtension($p))
    if (-not (Image-Complete $dir)) { if (-not (Extract-Zip $p $dir 'Unpacking image')) { return $false } }
    $script:IMG_PATH = $dir
  } else { Fail "$p is not a folder or .zip"; return $false }
  Ok "Using local image: $p"
  return $true
}

function Prepare-Image {
  New-Item -ItemType Directory -Force -Path $IMG_DIR | Out-Null
  $script:IMG_PATH = ''
  if ($script:OPT_SOURCE -eq 'local') { return (Prepare-Local) }
  $name = Image-Name; $dir = Join-Path $IMG_DIR $name
  if ($script:OPT_FORCE) {
    Remove-Item -Recurse -Force -LiteralPath $dir, (Join-Path $IMG_DIR "$name.zip"), (Join-Path $IMG_DIR "$name.zip.part") -ErrorAction SilentlyContinue
    $script:OPT_FORCE = 0
  }
  if ($script:OPT_SOURCE -ne 'mirror') {
    if (Image-Complete $dir) { Ok "Image $name already downloaded - skipping download."; $script:IMG_PATH = $dir; return $true }
    if ($script:OPT_SOURCE -in 'auto', 'github') {
      if (Fetch-FromArchive $name $dir $GH_BASE 'GitHub release (copy of the Next Thing Co. image)') { $script:IMG_PATH = $dir; return $true }
      if ($script:OPT_SOURCE -eq 'github') { return $false }
      Warn 'GitHub copy not available; trying the Internet Archive.'
    }
    if (Fetch-FromArchive $name $dir) { $script:IMG_PATH = $dir; return $true }
    if ($script:OPT_SOURCE -eq 'archive') { return $false }
    Warn 'Internet Archive failed; trying the old mirror as a fallback.'
  }
  return (Fetch-FromMirror)
}

# --------------------- Flashing (port of CHIP-tools common.sh) --------------
$SPLMEMADDR = '0x43000000'; $UBOOTMEMADDR = '0x4a000000'; $UBOOTSCRMEMADDR = '0x43100000'
$TIMEOUT = 30

# Runs a tool, echoing + logging every line. Returns the exit code.
# Each output line is also handed to the optional $onLine scriptblock.
function Invoke-Tool([string]$exe, [string[]]$argv, [scriptblock]$onLine = $null, [switch]$Quiet) {
  Log-Line ("+ {0} {1}" -f (Split-Path $exe -Leaf), ($argv -join ' '))
  & $exe @argv 2>&1 | ForEach-Object {
    $l = "$_"
    if (-not $Quiet) { Write-Host $l }
    Log-Line $l
    if ($onLine) { & $onLine $l }
  }
  return $LASTEXITCODE
}

function Write-Partial([string]$s) { Write-Host $s -NoNewline; if ($script:LogFile) { [IO.File]::AppendAllText($script:LogFile, $s) } }

function Wait-ForFel {
  Write-Partial 'waiting for fel...'
  for ($i = $TIMEOUT; $i -gt 0; $i--) {
    & $script:FEL ver *> $null
    if ($LASTEXITCODE -eq 0) { Say 'OK'; return $true }
    Write-Partial '.'
    Start-Sleep -Seconds 1
  }
  Say 'TIMEOUT'; return $false
}

function Wait-ForFastboot([int]$timeout = $TIMEOUT) {
  Write-Partial 'waiting for fastboot...'
  for ($i = $timeout; $i -gt 0; $i--) {
    $o = (& $script:FASTBOOT devices 2>$null | Out-String).Trim()
    if ($o) { Say 'OK'; return $true }
    Write-Partial '.'
    Start-Sleep -Seconds 1
  }
  Say 'TIMEOUT'; return $false
}

function Fel([string[]]$argv) {
  $rc = Invoke-Tool $script:FEL $argv
  if ($rc -ne 0) { Fail ("sunxi-fel {0} failed (exit {1})." -f ($argv -join ' '), $rc) }
  return ($rc -eq 0)
}

function New-UbootScript([string[]]$lines, [string]$name, [string]$outFile) {
  # same as: echo each line (LF endings!) | mkimage -A arm -T script -C none -n <name>
  $text = ($lines -join "`n") + "`n"
  $t = if ($env:SOURCE_DATE_EPOCH) { [uint32]$env:SOURCE_DATE_EPOCH } else { [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
  [IO.File]::WriteAllBytes($outFile, [PcfNative]::MkScript([Text.Encoding]::ASCII.GetBytes($text), $name, $t))
  [IO.File]::WriteAllText("$outFile.txt", $text)   # readable copy for the log folder
}

function Detect-Nand([string]$img, [string]$work) {
  $scr = Join-Path $work 'detect-nand.scr'
  New-UbootScript @('nand info', 'env export -t -s 0x100 0x7c00 nand_erasesize nand_writesize nand_oobsize', 'reset') 'detect NAND' $scr
  Bar-Draw 5 'Flashing' 'waiting for FEL'
  if (-not (Wait-ForFel)) { Say 'ERROR: please make sure CHIP is connected and jumpered in FEL mode.'; return $null }
  Bar-Draw 10 'Flashing' 'talking to CHIP over FEL'
  if (-not (Fel @('spl', (Join-Path $img 'sunxi-spl.bin')))) { return $null }
  Start-Sleep -Seconds 1   # wait for DRAM initialization to complete
  if (-not (Fel @('write', $UBOOTMEMADDR, (Join-Path $img 'u-boot-dtb.bin')))) { return $null }
  if (-not (Fel @('write', $UBOOTSCRMEMADDR, $scr))) { return $null }
  if (-not (Fel @('exe', $UBOOTMEMADDR))) { return $null }
  if (-not (Wait-ForFel)) { Say 'ERROR: please make sure CHIP is connected and jumpered in FEL mode.'; return $null }
  $info = Join-Path $work 'nand-info'
  if (-not (Fel @('read', '0x7c00', '0x100', $info))) { return $null }
  $txt = ([IO.File]::ReadAllText($info)) -replace "`0", ''
  Say 'NAND detected:'
  Say $txt.Trim()
  $n = @{}
  foreach ($k in 'nand_erasesize', 'nand_writesize', 'nand_oobsize') {
    if ($txt -match "$k=([0-9a-fA-F]+)") { $n[$k] = $Matches[1] } else { Fail "NAND info is missing $k."; return $null }
  }
  Bar-Draw 18 'Flashing' 'NAND detected'
  return $n
}

function Get-UbootFlashScript([hashtable]$n, [string]$flavor, [string]$ubootsize) {
  # Text identical to flash_images() in CHIP-tools-2025 common.sh.
  # NB: like the original, pages-per-eraseblock divides the hex digit strings
  # as if they were decimal (400000/4000 = 100 -> 0x64). Kept on purpose.
  $pagespereb = '{0:x}' -f [int]([long]$n.nand_erasesize / [long]$n.nand_writesize)
  $dtb = if ($n.nand_oobsize -eq '100') { 'ntc-gr8-crumb.dtb' } else { 'sun5i-r8-chip.dtb' }
  $noLimit = if ($script:OPT_NOLIMIT) { 'while itest.b *0x80400000 -ne 03; do i2c mw 0x34 0x30 0x03; i2c read 0x34 0x30 1 0x80400000; done; ' } else { '' }
  $resetCmd = if ($script:OPT_RESET) { 'reset' } else { 'while true; do; sleep 10; done;' }

  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('nand erase.chip')
  $L.Add("nand write.raw.noverify $SPLMEMADDR 0x0 $pagespereb")
  $L.Add("nand write.raw.noverify $SPLMEMADDR 0x400000 $pagespereb")
  $L.Add("nand write $UBOOTMEMADDR 0x800000 $ubootsize")
  $L.Add('setenv mtdparts mtdparts=sunxi-nand.0:4m(spl),4m(spl-backup),4m(uboot),4m(env),-(UBI)')
  $L.Add('setenv bootargs root=ubi0:rootfs rootfstype=ubifs rw earlyprintk ubi.mtd=4')
  $L.Add('setenv bootcmd ''gpio set PB2; if test -n ${fel_booted} && test -n ${scriptaddr}; then echo ''(FEL boot)''; source ${scriptaddr}; fi; mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload $fdt_addr_r /boot/' + $dtb + '; ubifsload $kernel_addr_r /boot/zImage; bootz $kernel_addr_r - $fdt_addr_r''')
  $L.Add('setenv fel_booted 0')
  $L.Add('echo Enabling Splash')
  $L.Add('setenv stdout serial')
  $L.Add('setenv stderr serial')
  $L.Add('setenv splashpos m,m')
  $L.Add('echo Configuring Video Mode')
  $bootcmd2    = 'setenv bootcmd ''' + $noLimit + 'run test_fastboot; if test -n ${fel_booted} && test -n ${scriptaddr}; then echo (FEL boot); source ${scriptaddr}; fi; for path in ${bootpaths}; do run boot_$path; done'''
  $bootInitrd  = 'setenv boot_initrd ''mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload $fdt_addr_r /boot/' + $dtb + '; ubifsload 0x44000000 /boot/initrd.uimage; ubifsload $kernel_addr_r /boot/zImage; bootz $kernel_addr_r 0x44000000 $fdt_addr_r'''
  $bootNoInitrd = 'setenv boot_noinitrd ''mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload $fdt_addr_r /boot/' + $dtb + '; ubifsload $kernel_addr_r /boot/zImage; bootz $kernel_addr_r - $fdt_addr_r'''
  $dipCmd      = 'setenv dip_overlay_cmd ''if test -n "${dip_overlay_name}"; then ubifsload $dip_addr_r $dip_overlay_dir/$dip_overlay_name; fi'''
  if ($flavor -eq 'pocketchip') {
    $L.Add('setenv clear_fastboot ''i2c mw 0x34 0x4 0x00 4;''')
    $L.Add('setenv write_fastboot ''i2c mw 0x34 0x4 66 1; i2c mw 0x34 0x5 62 1; i2c mw 0x34 0x6 30 1; i2c mw 0x34 0x7 00 1''')
    $L.Add('setenv test_fastboot ''i2c read 0x34 0x4 4 0x80200000; if itest.s *0x80200000 -eq fb0; then echo (Fastboot); i2c mw 0x34 0x4 0x00 4; fastboot 0; fi''')
    $L.Add('setenv bootargs root=ubi0:rootfs rootfstype=ubifs rw ubi.mtd=4 quiet lpj=501248 loglevel=3 splash plymouth.ignore-serial-consoles')
    $L.Add('setenv bootpaths ''initrd noinitrd''')
    $L.Add($bootcmd2); $L.Add($bootInitrd); $L.Add($bootNoInitrd)
    $L.Add('setenv video-mode')
    $L.Add('setenv dip_addr_r 0x43400000')
    $L.Add('setenv dip_overlay_dir /lib/firmware/nextthingco/chip/early')
    $L.Add($dipCmd)
    $L.Add('setenv fel_booted 0')
    $L.Add('setenv bootdelay 1')
  } else {
    $L.Add('setenv bootpaths ''initrd noinitrd''')
    $L.Add($bootcmd2); $L.Add($bootInitrd); $L.Add($bootNoInitrd)
    $L.Add('setenv dip_addr_r 0x43400000')
    $L.Add('setenv dip_overlay_dir /lib/firmware/nextthingco/chip/early')
    $L.Add($dipCmd)
    $L.Add('setenv video-mode sunxi:640x480-24@60,monitor=composite-ntsc,overscan_x=40,overscan_y=20')
  }
  $L.Add('saveenv')
  $L.Add('echo going to fastboot mode')
  $L.Add('fastboot 0')
  $L.Add($resetCmd)
  return ,$L.ToArray()
}

function Fastboot-Progress([string]$l) {
  if ($l -match "(?i)(sending|writing) sparse 'UBI' (\d+)/(\d+)") {
    $half = if ($Matches[1] -match '^(?i)writing') { 1 } else { 0 }
    $cur = [int]$Matches[2]; $tot = [int]$Matches[3]
    if ($tot -gt 0) { Bar-Draw (30 + 68 * (2 * ($cur - 1) + $half) / (2 * $tot)) 'Flashing' ("{0} sparse {1}/{2} - writing system to NAND" -f $Matches[1].ToLower(), $cur, $tot) }
  }
}

function Flash-Chip([string]$img, [string]$work) {   # returns $true on success
  $flavor = Flavor-Dir
  Say '== preparing images =='
  if ($script:OPT_NAND) {
    Say "== Format $($script:OPT_NAND) selected =="
    $n = switch ($script:OPT_NAND) {
      'Hynix_8G_MLC'     { @{ nand_erasesize = '400000'; nand_writesize = '4000'; nand_oobsize = '680' } }
      'Toshiba_4G_MLC'   { @{ nand_erasesize = '400000'; nand_writesize = '4000'; nand_oobsize = '500' } }
      'Toshiba_512M_SLC' { @{ nand_erasesize = '40000';  nand_writesize = '1000'; nand_oobsize = '100' } }
    }
  } else {
    $n = Detect-Nand $img $work
    if (-not $n) { return $false }
  }
  $type = "$($n.nand_erasesize)-$($n.nand_writesize)-$($n.nand_oobsize)"
  $ubi = Join-Path $img "chip-$type.ubi.sparse"
  $spl = Join-Path $img "spl-$type.bin"
  $uboot = Join-Path $img "uboot-$($n.nand_erasesize).bin"
  foreach ($f in $ubi, $spl, $uboot) { if (-not (Test-Path -LiteralPath $f)) { Say "Could not locate $(Split-Path $f -Leaf) for NAND type $type"; return $false } }
  Say '== Cached UBI located =='

  $ubootsize = '0x{0:x8}' -f (FSize $uboot)
  $scr = Join-Path $work 'uboot.scr'
  New-UbootScript (Get-UbootFlashScript $n $flavor $ubootsize) "flash $flavor" $scr

  if (-not (Wait-ForFel)) { Say 'ERROR: please make sure CHIP is connected and jumpered in FEL mode.'; return $false }
  Bar-Draw 20 'Flashing' 'loading U-Boot over FEL'
  if (-not (Fel @('spl', (Join-Path $img 'sunxi-spl.bin')))) { return $false }
  Start-Sleep -Seconds 1   # wait for DRAM initialization to complete
  if (-not (Fel @('write', $UBOOTMEMADDR, $uboot))) { return $false }
  if (-not (Fel @('write', $SPLMEMADDR, $spl))) { return $false }
  if (-not (Fel @('write', $UBOOTSCRMEMADDR, $scr))) { return $false }
  if (-not (Fel @('exe', $UBOOTMEMADDR))) { return $false }
  Bar-Draw 28 'Flashing' 'switching to fastboot'

  $ok = Wait-ForFastboot
  if (-not $ok) {
    # U-Boot sits in fastboot mode until it gets the image, so a missing
    # driver can be fixed now without starting over.
    $fb = @(Get-ChipUsb) | Where-Object { $_.Id -match 'PID_1010' } | Select-Object -First 1
    if ($fb -and -not (Has-Driver $fb)) { Warn 'The CHIP is in fastboot mode, but Windows has no WinUSB driver for it.' }
    else { Warn 'fastboot.exe cannot see the CHIP. Usually the fastboot USB driver is missing or has the wrong GUID.' }
    if ($script:Interactive -and (YesNo 'Open the USB driver setup now? (the CHIP waits in fastboot mode)')) {
      Install-Drivers; Bar-Start 'Flashing'; Bar-Draw 28 'Flashing' 'switching to fastboot'
      $ok = Wait-ForFastboot 60
    }
  }
  if (-not $ok) { Say 'failed to flash the UBI image.'; return $false }

  Bar-Draw 30 'Flashing' 'sending system image'
  $rc = Invoke-Tool $script:FASTBOOT @('flash', 'UBI', $ubi) { param($l) Fastboot-Progress $l }
  if ($rc -ne 0) { Fail "fastboot flash failed (exit $rc)."; return $false }
  $null = Invoke-Tool $script:FASTBOOT @('continue') -Quiet
  return $true
}

function Ready-To-Roll {
  Say ''
  Say 'FLASH VERIFICATION COMPLETE.' 'Green'
  Say ''
  Say "   #  #  #`n  #########`n###       ###`n  # {#}   #`n###  '%######`n  #       #`n###       ###`n  ########`n   #  #  #" 'Green'
  Say ''
  Say 'CHIP is ready to roll!' 'Green'
}

# ------------------------------ Actions -------------------------------------
function Show-Instructions {
  Msg @"
HOW TO PUT YOUR POCKETCHIP INTO FLASH (FEL) MODE

0. First time on this PC: menu 6 installs the USB drivers (WinUSB via Zadig).

1. Power the PocketCHIP off. Unscrew the back and lift the
   C.H.I.P. board out of the PocketCHIP case.

2. Connect the FEL pin to a GND pin with a jumper wire or a
   bent paperclip (labeled on the board's silkscreen).

3. Plug the CHIP's micro-USB port into this computer. Use a
   short, good-quality DATA cable, ideally a rear USB port.

4. Choose 'FLASH NOW'. Leave the jumper in until you see
   FLASH VERIFICATION COMPLETE.

5. Unplug, remove the jumper, put the board back in the
   PocketCHIP and power on. First boot takes a few minutes.

Tip: the menu header shows live whether the CHIP is in FEL
mode. You can also download the image first, CHIP unplugged.
"@
}

function Check-Connection {
  Clear-Host; Art-Chip 'USB check' ''
  Info 'Looking for a CHIP on USB...'
  $s = Usb-State
  switch -Wildcard ($s) {
    'FEL mode - ready*' {
      Ok 'CHIP detected in FEL mode (1f3a:efe8) with WinUSB driver.'
      if ($script:FEL -or (Test-Path (Join-Path $TOOLS_DIR 'sunxi-tools\sunxi-fel.exe'))) {
        if (-not $script:FEL) { $script:FEL = Join-Path $TOOLS_DIR 'sunxi-tools\sunxi-fel.exe' }
        $null = Invoke-Tool $script:FEL @('ver')
        if ($LASTEXITCODE -eq 0) { Ok 'sunxi-fel can talk to the CHIP. Ready to flash.' }
      }
    }
    'FEL mode - USB driver*' { Warn 'CHIP is in FEL mode but has no WinUSB driver. Use menu 6 (USB drivers).' }
    'fastboot*' { Ok "CHIP detected in fastboot mode ($s)." }
    'booted*' { Warn 'CHIP is booted normally. It is NOT in FEL mode - check the FEL-to-GND jumper.' }
    default {
      Fail 'No CHIP found.'
      Write-Host '  - Is the FEL-to-GND jumper in place?'
      Write-Host '  - Is the micro-USB cable a data cable (not charge-only)?'
      Write-Host '  - Try another USB port or a shorter cable.'
    }
  }
  Pause-Menu
}

function Wait-FelDevice {   # up to 120 s, with countdown bar
  $limit = 120; $t0 = Get-Date
  if (Fel-Present) { Ok 'CHIP found in FEL mode.'; return $true }
  Info 'Plug in the CHIP now (FEL jumper in place)...'
  while (((Get-Date) - $t0).TotalSeconds -lt $limit) {
    if (Fel-Present) { Bar-Draw 100 'Waiting for CHIP' 'found!'; Ok 'CHIP found in FEL mode.'; return $true }
    $el = [int]((Get-Date) - $t0).TotalSeconds
    Bar-Draw ($el * 100 / $limit) 'Waiting for CHIP' "plug it in - $($limit - $el)s left"
    Start-Sleep -Milliseconds 500
  }
  Fail "No CHIP in FEL mode after ${limit}s."
  return $false
}

function Image-FailHelp {
  Write-Host ''
  Write-Host '  Could not get the firmware image. Options:'
  Write-Host '   1. Run Flash again - downloads resume where they stopped.'
  Write-Host '   2. Download it in your browser instead:'
  Write-Host "        $GH_BASE/$(Image-Name).zip   (GitHub copy)"
  Write-Host "        $IA_BASE/$(Image-Name).zip"
  Write-Host '      then pick Advanced > Image source > Local and point to the .zip.'
}

function Fel-FailHelp {
  Write-Host '  Things to try (from the Flash-CHIP-2025 README):'
  Write-Host '   1. Just run Flash again - this fixes most FEL/fastboot hiccups.'
  Write-Host '   2. Times out waiting for FEL? Low USB power: shorter cable, rear port,'
  Write-Host "      powered hub, or 5V into the CHG-IN pin. Try 'No-limit power' too."
  Write-Host '   3. Windows: make sure both USB drivers are installed (menu 6).'
  Write-Host '      In Device Manager the CHIP should appear under "Universal Serial Bus devices".'
  Write-Host '   4. Unplug the CHIP, plug it back in (jumper still in) and retry.'
}

function Do-Flash {   # returns $true on success
  $desc = @"
Flavour : $(Flavor-Name $script:OPT_FLAVOR)
Branch  : $($script:OPT_BRANCH)
NAND    : $(if ($script:OPT_NAND) { $script:OPT_NAND } else { 'auto-detect' })
Source  : $(Source-Name)
No-limit power : $(if ($script:OPT_NOLIMIT) { 'yes' } else { 'no' })
CHIP    : $(Usb-State)

This ERASES everything on the CHIP's internal storage.
"@
  Write-Host ''; Write-Host $desc
  if (-not (YesNo 'Start?')) { return $false }

  Bar-Start 'Step 1/5 Tools'
  Art-Chip 'flashing' (Flavor-Dir)
  if (-not (Ensure-Tools)) { Fail 'Tools are missing. Fix the errors above and retry.'; Pause-Menu; return $false }
  Bar-Draw 100 'Step 2/5 USB drivers'; Check-Drivers
  Bar-Draw 0 'Step 3/5 Image'
  if (-not (Prepare-Image)) { Image-FailHelp; Pause-Menu; return $false }
  Bar-Draw 0 'Step 4/5 Connect'
  if (-not (Wait-FelDevice)) { Fel-FailHelp; Pause-Menu; return $false }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $script:LogFile = Join-Path $LOG_DIR "flash-$stamp.log"
  $work = Join-Path $LOG_DIR "flash-$stamp"
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  Set-Content -Path $script:LogFile -Value '' -NoNewline
  Info "Step 5/5: flashing $(Flavor-Name $script:OPT_FLAVOR) from $($script:IMG_PATH)"
  Info "Log file: $($script:LogFile)"
  Write-Host ''
  Bar-Draw 2 'Flashing' 'preparing'

  $ok = Flash-Chip $script:IMG_PATH $work
  Write-Host ''
  if ($ok) {
    Ready-To-Roll
    Bar-Draw 100 'DONE' 'flash complete'
    Art-Chip 'FLASH COMPLETE!' 'enjoy :)'
    Ok 'Unplug, remove the FEL jumper and reassemble your PocketCHIP.'
    Write-Host "   Default login on Pocket OS: user 'chip', password 'chip'."
  } else {
    Say "`n FLASH VERIFICATION FAILED.`n" 'Red'
    Bar-Draw $script:BarPct 'FAILED' 'see log'
    Fail "Flashing did not finish. Log: $($script:LogFile)"
    Fel-FailHelp
  }
  $script:LogFile = $null
  Pause-Menu
  return $ok
}

function Download-Only {
  Bar-Start 'Image'
  Art-Chip 'downloading' "$(Flavor-Dir) image"
  $ok = (Ensure-Base) -and (Prepare-Image)
  if ($ok) { Ok 'Image is cached. Flashing will skip the download.' } else { Image-FailHelp }
  Pause-Menu
  return $ok
}

function Run-Setup {
  Bar-Start 'Setup'
  Art-Chip 'setup' ''
  $null = Ensure-Tools
  Bar-Stop
  if (-not (Test-Path $DRIVER_MARK)) { Install-Drivers } else { Ok 'USB drivers already installed (menu 6 to redo).'; Pause-Menu }
}

function Advanced-Menu {
  while ($true) {
    $c = Show-Menu 'Advanced options (current values shown)' @(
      '1', "Flavour        : $(Flavor-Name $script:OPT_FLAVOR)"
      '2', "Branch         : $($script:OPT_BRANCH)  (build b$(IA-Build))"
      '3', "NAND type      : $(if ($script:OPT_NAND) { $script:OPT_NAND } else { 'auto-detect' })"
      '4', "Image source   : $(Source-Name)"
      '5', "No-limit power : $(if ($script:OPT_NOLIMIT) { 'ON' } else { 'off' })"
      '6', "Force re-download image  : $(if ($script:OPT_FORCE) { 'ON' } else { 'off' })"
      '7', "Reboot CHIP after flash  : $(if ($script:OPT_RESET) { 'ON' } else { 'off' })"
      '0', 'Back')
    switch ($c) {
      '1' { $f = Show-Menu 'Which OS image?' @('p', 'PocketCHIP - Pocket OS (use this for a PocketCHIP)', 's', 'Server - headless Debian', 'g', 'GUI - Debian with XFCE desktop', 'b', 'Buildroot - minimal'); if ($f) { $script:OPT_FLAVOR = $f } }
      '2' { $b = Show-Menu 'Image branch' @('stable', 'Stable (recommended)', 'testing', 'Testing (newer, less tested)'); if ($b) { $script:OPT_BRANCH = $b } }
      '3' { $n = Show-Menu 'NAND chip (leave auto unless flashing fails)' @('auto', 'Auto-detect (recommended)', 'Hynix_8G_MLC', 'Hynix 8GB MLC (most CHIPs)', 'Toshiba_4G_MLC', 'Toshiba 4GB MLC (some later CHIPs)', 'Toshiba_512M_SLC', 'Toshiba 512MB SLC (CHIP Pro)')
            if ($n) { if ($n -eq 'auto') { $script:OPT_NAND = '' } else { $script:OPT_NAND = $n } } }
      '4' { $s = Show-Menu 'Where to get the firmware image' @('auto', 'Auto: GitHub copy, then Internet Archive, then old mirror', 'github', 'GitHub release copy only (this repo)', 'archive', 'Internet Archive only', 'mirror', 'jfpossibilities mirror only (offline as of Nov 2026)', 'local', 'A .zip or folder I already downloaded')
            if ($s -eq 'local') {
              $def = if ($script:OPT_LOCAL_PATH) { $script:OPT_LOCAL_PATH } else { Join-Path $env:USERPROFILE 'Downloads' }
              $p = (Read-Host "Path to the image .zip or extracted folder [$def]").Trim('"', ' ')
              if (-not $p) { $p = $def }
              if (-not (Test-Path -LiteralPath $p)) { Msg "Not found: $p"; continue }
              $script:OPT_LOCAL_PATH = $p
            }
            if ($s) { $script:OPT_SOURCE = $s } }
      '5' { $script:OPT_NOLIMIT = 1 - $script:OPT_NOLIMIT }
      '6' { $script:OPT_FORCE = 1 - $script:OPT_FORCE }
      '7' { $script:OPT_RESET = 1 - $script:OPT_RESET }
      '0' { return }
      default { return }
    }
  }
}

function Troubleshoot-Menu {
  while ($true) {
    $used = MB (Folder-Bytes $IMG_DIR)
    $c = Show-Menu 'Troubleshooting' @(
      '1', 'Rebuild sunxi-fel.exe from source'
      '2', 'Re-run USB driver setup (Zadig)'
      '3', "Delete downloaded images ($used MB used)"
      '4', 'Show last flash log'
      '5', 'Open Device Manager'
      '0', 'Back')
    switch ($c) {
      '1' { Remove-Item -Force (Join-Path $TOOLS_DIR 'sunxi-tools\sunxi-fel.exe') -ErrorAction SilentlyContinue; $script:FEL = ''; $null = Ensure-SunxiFel; Pause-Menu }
      '2' { Remove-Item -Force $DRIVER_MARK -ErrorAction SilentlyContinue; Install-Drivers }
      '3' { if (YesNo "Delete all downloaded images in $IMG_DIR?") { Remove-Item -Recurse -Force $IMG_DIR, $IA_META -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $IMG_DIR | Out-Null; Msg 'Images deleted.' } }
      '4' { $last = Get-ChildItem -Path $LOG_DIR -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($last) { Start-Process notepad.exe -ArgumentList (Q $last.FullName) } else { Msg 'No logs yet.' } }
      '5' { Start-Process devmgmt.msc }
      default { return }
    }
  }
}

# ------------------------------- Startup ------------------------------------
function Preflight {
  if ($env:OS -ne 'Windows_NT') { Fail 'This is the Windows version. On Linux use pocketchip-flasher.sh.'; exit 1 }
  New-Item -ItemType Directory -Force -Path $WORK_DIR, $TOOLS_DIR, $IMG_DIR, $LOG_DIR | Out-Null
}

function Splash {
  Bar-Start 'Loading'
  Art-Banner
  $n = 0
  foreach ($t in 'curl.exe', 'tar.exe') { $n++; Bar-Draw ($n * 25) 'Checking tools' $t; if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Warn "$t missing (needs Windows 10 1803+)." } }
  if (Test-Path (Join-Path $TOOLS_DIR 'platform-tools\fastboot.exe')) { Ok 'fastboot.exe ready.' } else { Info 'fastboot.exe will be downloaded on first flash (~7 MB).' }
  if (Test-Path (Join-Path $TOOLS_DIR 'sunxi-tools\sunxi-fel.exe')) { Ok 'sunxi-fel.exe ready.' } else { Info 'sunxi-fel.exe will be built on first flash (one time, a few minutes).' }
  if (Test-Path $DRIVER_MARK) { Ok 'USB drivers installed.' } else { Info 'USB drivers not installed yet (menu 6).' }
  $name = Image-Name
  if (Image-Complete (Join-Path $IMG_DIR $name)) { Ok "Cached image found: $name" } else { Info 'Image not downloaded yet (~1 GB, fetched on first flash).' }
  Bar-Draw 100 'Ready' ''
  Start-Sleep -Milliseconds 1200
  Bar-Stop
}

function Main-Menu {
  while ($true) {
    $name = Image-Name
    $img = if ($script:OPT_SOURCE -eq 'local') { 'local' } elseif (Image-Complete (Join-Path $IMG_DIR $name)) { 'downloaded ✓' } else { 'not downloaded yet' }
    Clear-Host
    $c = Show-Menu @"
   ┌┴┴┴┴┴┴┴┴┴┴┐
  ─┤ C.H.I.P. ├─   Image : $(Flavor-Name $script:OPT_FLAVOR), $($script:OPT_BRANCH) b$(IA-Build)
  ─┤  ▓▓▓▓▓▓  ├─   Cache : $img
   └┬┬┬┬┬┬┬┬┬┬┘   CHIP  : $(Usb-State)
"@ @(
      '1', 'How to connect the PocketCHIP (read this first)'
      '2', 'FLASH NOW'
      '3', 'Download image only (no CHIP needed)'
      '4', 'Check connection'
      '5', 'Advanced options (flavour, NAND, image source...)'
      '6', 'Setup: tools + USB drivers (run once per PC)'
      '7', 'Troubleshooting'
      'r', 'Refresh status'
      '0', 'Exit')
    switch ($c) {
      '1' { Show-Instructions }
      '2' { $null = Do-Flash }
      '3' { $null = Download-Only }
      '4' { Check-Connection }
      '5' { Advanced-Menu }
      '6' { Run-Setup }
      '7' { Troubleshoot-Menu }
      '0' { Bar-Stop; return }
      default { }
    }
  }
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
  Preflight
  if ($Flash)        { if (Do-Flash) { exit 0 } else { exit 1 } }
  if ($DownloadOnly) { if (Download-Only) { exit 0 } else { exit 1 } }
  Splash
  Main-Menu
} finally {
  Bar-Stop
}
