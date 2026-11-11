# Dry-run the whole Windows flash flow with NO CHIP attached and NO real downloads.
#
# - fake\sunxi-fel.cmd and fake\fastboot.cmd stand in for the real tools
#   (sunxi-fel "reads" Hynix 8G NAND info, fastboot prints sparse progress).
# - PCF_FAKE_USB=fel makes the USB check report a CHIP in FEL mode.
# - A small fake image zip and a fake archive.org files.xml (with a matching
#   MD5) are generated, and the image source points at them via file://.
# - The U-Boot script written for the flash is checked: header CRCs, layout,
#   and LF line endings.
#
# Usage:  powershell -ExecutionPolicy Bypass -File windows\tests\run-dry-flash.ps1
# Expect: PASS
param([string]$Shell = 'powershell.exe')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$flasher = Join-Path (Split-Path $here) 'pocketchip-flasher.ps1'
$T = Join-Path ([IO.Path]::GetTempPath()) ("chipflash-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $T | Out-Null
Write-Host "Test dir: $T"

# 1. Fake image zip (nested folder, like the archive.org layout)
$src = Join-Path $T 'src\stable-pocketchip-b126'
New-Item -ItemType Directory -Force -Path $src | Out-Null
$rng = New-Object Random 42
foreach ($f in 'sunxi-spl.bin', 'u-boot-dtb.bin', 'uboot-400000.bin', 'uboot-40000.bin', 'spl-400000-4000-680.bin') {
  $b = New-Object byte[] 20000; $rng.NextBytes($b); [IO.File]::WriteAllBytes((Join-Path $src $f), $b)
}
$b = New-Object byte[] 3000000; $rng.NextBytes($b); [IO.File]::WriteAllBytes((Join-Path $src 'chip-400000-4000-680.ubi.sparse'), $b)
$zip = Join-Path $T 'stable-pocketchip-b126.zip'
Compress-Archive -Path (Join-Path $T 'src\*') -DestinationPath $zip

# 2. Fake archive.org metadata with the right size + md5
$md5 = (Get-FileHash -Algorithm MD5 $zip).Hash.ToLower(); $sz = (Get-Item $zip).Length
Set-Content -Path (Join-Path $T 'files.xml') -Value @"
<files>
<file name="stable-pocketchip-b126.zip" source="original">
<size>$sz</size>
<md5>$md5</md5>
</file>
</files>
"@

# 3. Run the flasher non-interactively against the fakes
$fileUrl = 'file:///' + ($T -replace '\\', '/')
$env:PCF_WORK_DIR = Join-Path $T 'work'
$env:PCF_FEL = Join-Path $here 'fake\sunxi-fel.cmd'
$env:PCF_FASTBOOT = Join-Path $here 'fake\fastboot.cmd'
$env:PCF_FAKE_LOG = Join-Path $T 'calls.txt'
$env:PCF_IA_BASE = $fileUrl
$env:PCF_IA_META_URL = "$fileUrl/files.xml"
$env:PCF_GH_BASE = "$fileUrl/no-such-release"   # GitHub release mirror "missing" -> falls through to archive
$env:PCF_FAKE_USB = 'fel'
$env:SOURCE_DATE_EPOCH = '1700000000'

$out = & $Shell -NoProfile -ExecutionPolicy Bypass -File $flasher -Flash -Yes 2>&1 | Out-String
$rc = $LASTEXITCODE
Write-Host '----- flasher status lines -----'
($out -split "`r?`n" | Where-Object { $_ -match '^(==>|\[ OK \]|\[WARN\]|\[FAIL\])' }) -join "`n" | Write-Host
Write-Host '----- flasher output (last 30 lines) -----'
($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 30) -join "`n" | Write-Host

# 4. Checks
$fails = @()
if ($rc -ne 0) { $fails += "flasher exit code $rc" }
$log = Get-ChildItem (Join-Path $env:PCF_WORK_DIR 'logs') -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $log -or -not (Select-String -Path $log.FullName -Pattern 'FLASH VERIFICATION COMPLETE' -Quiet)) { $fails += 'log has no FLASH VERIFICATION COMPLETE' }
$calls = Get-Content $env:PCF_FAKE_LOG -ErrorAction SilentlyContinue
foreach ($want in 'fel spl .*sunxi-spl.bin', 'fel write 0x4a000000 .*u-boot-dtb.bin', 'fel read 0x7c00 0x100',
                  'fel write 0x4a000000 .*uboot-400000.bin', 'fel write 0x43000000 .*spl-400000-4000-680.bin',
                  'fel write 0x43100000 .*uboot.scr', 'fel exe 0x4a000000', 'fastboot flash UBI .*chip-400000-4000-680.ubi.sparse', 'fastboot continue') {
  if (-not ($calls -match $want)) { $fails += "missing tool call: $want" }
}

# U-Boot script image: check it like U-Boot's own 'source' command would
$scr = Get-ChildItem (Join-Path $env:PCF_WORK_DIR 'logs') -Recurse -Filter 'uboot.scr' | Select-Object -First 1
if (-not $scr) { $fails += 'no uboot.scr written' } else {
  . $flasher -Flavor p   # loads PcfNative + functions only
  $img = [IO.File]::ReadAllBytes($scr.FullName)
  function BE32($o) { ([uint32]$img[$o] -shl 24) -bor ([uint32]$img[$o+1] -shl 16) -bor ([uint32]$img[$o+2] -shl 8) -bor [uint32]$img[$o+3] }
  $hcrc = BE32 4; $hdr = $img[0..63]; $hdr[4] = 0; $hdr[5] = 0; $hdr[6] = 0; $hdr[7] = 0
  if ((BE32 0) -ne 0x27051956) { $fails += 'uboot.scr bad magic' }
  if ([PcfNative]::Crc32([byte[]]$hdr, 0, 64) -ne $hcrc) { $fails += 'uboot.scr header CRC wrong' }
  if ([PcfNative]::Crc32($img, 64, $img.Length - 64) -ne (BE32 24)) { $fails += 'uboot.scr data CRC wrong' }
  if ((BE32 8) -ne 1700000000) { $fails += 'uboot.scr timestamp ignores SOURCE_DATE_EPOCH' }
  if ($img[28] -ne 5 -or $img[29] -ne 2 -or $img[30] -ne 6) { $fails += 'uboot.scr os/arch/type wrong' }
  $len = BE32 64
  if ((BE32 68) -ne 0 -or $len -ne $img.Length - 72) { $fails += 'uboot.scr size table wrong' }
  $text = [Text.Encoding]::ASCII.GetString($img, 72, $len)
  if ($text -match "`r") { $fails += 'uboot.scr has CR line endings' }
  if ($text -notmatch "^nand erase.chip`n" -or $text -notmatch "fastboot 0`nwhile true; do; sleep 10; done;`n$") { $fails += 'uboot.scr text start/end wrong' }
}

Remove-Item Env:PCF_* , Env:SOURCE_DATE_EPOCH -ErrorAction SilentlyContinue
if ($fails) { Write-Host ''; $fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; Write-Host "FAIL (see $T)" -ForegroundColor Red; exit 1 }
Remove-Item -Recurse -Force $T
Write-Host ''; Write-Host 'PASS' -ForegroundColor Green; exit 0
