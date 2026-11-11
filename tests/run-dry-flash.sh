#!/usr/bin/env bash
# Dry-run the whole flash flow with NO CHIP attached and NO real downloads.
#
# - tests/fake/ provides stand-ins for sudo, sunxi-fel, fastboot, lsusb,
#   mkimage and whiptail (lsusb always reports a CHIP in FEL mode).
# - A small fake image zip and a fake archive.org files.xml (with a matching
#   MD5) are generated, and IA_BASE points at them via file://.
# - The REAL CHIP-tools-2025 chip-update-firmware.sh is cloned and run, so the
#   -L relative-path handling and log parsing are exercised for real.
#
# Usage:  tests/run-dry-flash.sh            (needs git + network for the clone)
# Expect: "FLASH VERIFICATION COMPLETE." near the end of the output.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
T=$(mktemp -d /tmp/chipflash-test.XXXXXX)
echo "Test dir: $T"

# 1. Fake image zip (nested folder, like the archive.org layout)
mkdir -p "$T/src/stable-pocketchip-b126"
for f in sunxi-spl.bin u-boot-dtb.bin uboot-400000.bin uboot-40000.bin spl-400000-4000-680.bin; do
  head -c 20000 /dev/urandom > "$T/src/stable-pocketchip-b126/$f"
done
head -c 3000000 /dev/urandom > "$T/src/stable-pocketchip-b126/chip-400000-4000-680.ubi.sparse"
if command -v zip >/dev/null; then (cd "$T/src" && zip -qr "$T/stable-pocketchip-b126.zip" .)
else (cd "$T/src" && python3 -m zipfile -c "$T/stable-pocketchip-b126.zip" stable-pocketchip-b126); fi

# 2. Fake archive.org metadata with the right size + md5
MD5=$(md5sum "$T/stable-pocketchip-b126.zip" | cut -d' ' -f1)
SZ=$(stat -c%s "$T/stable-pocketchip-b126.zip")
cat > "$T/files.xml" <<EOF
<files>
<file name="stable-pocketchip-b126.zip" source="original">
<size>$SZ</size>
<md5>$MD5</md5>
</file>
</files>
EOF

# 3. Load the script's functions without starting the menu
sed '/^preflight$/,$d' "$ROOT/pocketchip-flasher.sh" > "$T/lib.sh"

# 4. Real CHIP-tools-2025
mkdir -p "$T/work/logs"
git clone -q --depth 1 https://github.com/Elfking29/CHIP-tools-2025.git "$T/work/CHIP-tools-2025"

cat > "$T/run.sh" <<EOF
export PATH="$HERE/fake:\$PATH"
source "$T/lib.sh"
WORK_DIR="$T/work"; IMG_DIR="\$WORK_DIR/images"; TOOLS_DIR="\$WORK_DIR/CHIP-tools-2025"; LOG_DIR="\$WORK_DIR/logs"
IA_META="$T/files.xml"; IA_BASE="file://$T"; GH_BASE="file://$T/no-such-release"
HAVE_WHIPTAIL=0
setup_permissions() { ok "(setup_permissions skipped in test)"; }
do_flash <<< \$'y\n\n'
EOF

# 5. Run inside a pseudo-terminal so the bottom progress bar code paths run
script -qec "stty rows 30 cols 100; bash '$T/run.sh'" "$T/screen.txt" >/dev/null 2>&1 || true

echo "----- screen output (progress bar frames stripped) -----"
perl -pe 's/\x1b7.*?\x1b8//gs' "$T/screen.txt" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr '\r' '\n' | grep -v '^\s*$' | tail -40
echo "----- progress bar states -----"
perl -ne 'while(/\x1b7(.*?)\x1b8/gs){$x=$1; $x=~s/\x1b\[[0-9;]*[a-zA-Z]//g; $x=~s/[─█░]//g; print "$x\n" if $x=~/Flashing|DONE|Problem|Unpack|Download/}' "$T/screen.txt" | sed 's/  */ /g' | uniq

if grep -q "FLASH VERIFICATION COMPLETE" "$T"/work/logs/*.log 2>/dev/null; then
  echo; echo "PASS"; exit 0
else
  echo; echo "FAIL (see $T)"; exit 1
fi
