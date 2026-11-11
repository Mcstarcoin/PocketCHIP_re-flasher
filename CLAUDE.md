# PocketCHIP Flasher: project notes for Claude Code

## What this is
`pocketchip-flasher.sh` is a single Bash script for Linux Mint (Ubuntu 24.04 "noble" base) that re-flashes a Next Thing Co. PocketCHIP / C.H.I.P. The terminal interface uses whiptail menus, falling back to plain `read` menus. It wraps the community tools:
- https://github.com/Elfking29/Flash-CHIP-2025 (reference flash environment; its `Flash.sh` was the starting point)
- https://github.com/Elfking29/CHIP-tools-2025 (`chip-update-firmware.sh` + `common.sh`, cloned at runtime into `~/.local/share/pocketchip-flasher/CHIP-tools-2025`)

The user's preferences: a one-shot script, an easy menu-driven terminal interface, a progress bar along the bottom of the terminal, CHIP ASCII art, skipping work that's already done, and spelled-out acronyms in explanations.

## History / decisions (from the chat this session came from)
1. **v1** wrapped Flash.sh's steps (apt deps, dialout/plugdev groups, udev rules, clone CHIP-tools-2025, run `chip-update-firmware.sh -p`).
2. **Failure on the user's machine:** CHIP-tools-2025 hard-codes `DL_URL=http://chip.jfpossibilities.com/chip/images`, and that host now **refuses connections** (Nov 2026). Its `latest` lookup came back empty, so the URL had `pocketchip//`, and the script **exits 0 even on failure**.
3. **v2 fix:** download the official images from the Internet Archive "C.H.I.P. Flash Collection" (`https://archive.org/download/C.h.i.p.FlashCollection/<branch>-<flavor>-b<N>.zip`), MD5-verify them against `C.h.i.p.FlashCollection_files.xml`, unzip them to `~/.local/share/pocketchip-flasher/images/<name>/`, then run `chip-update-firmware.sh -L ../images/<name>`.
   - **`-L` gotcha:** CHIP-tools makes `ln -s ../../$LOCALDIR .new/firmware/images`, so LOCALDIR **must be relative to the CHIP-tools dir**. That's why `images/` is a sibling of `CHIP-tools-2025/` and the path passed is `../images/<name>`. Absolute paths break.
   - Builds in the archive: stable pocketchip b126, gui b149, server b149, buildroot b34; testing pocketchip b667, gui b543, server b543, buildroot b23 (see `ia_build`).
   - Success is judged by `FLASH VERIFICATION COMPLETE` in the log, not by the exit code.
   - Auto source order: cached image, then archive.org, then the old jfpossibilities mirror. A local .zip or folder is also supported.
   - Downloads use `curl -C -` with retries, so they resume after an interruption.
4. **v2 extras:** only installs missing packages (`REQ` command:package map; `fastboot` falls back to `android-tools-fastboot`). The udev rules, groups and USB autosuspend are only touched if they differ. The bottom progress bar uses a scroll region (`\e[1;Nr`) and is drawn on **fd 9 = /dev/tty**, so it survives redirected or piped output. The flash progress comes from `flash_poller` tailing the log (FEL handshakes, then "NAND detected", then fastboot `Sending/Writing sparse 'UBI' k/n`).
5. **Bug fixed afterwards:** `missing_pkgs` printed one blank line when nothing was missing (`printf '%s\n'` with an empty array). The script counted that line as a missing package, which caused "Installed (blank) / Still missing: (blank)". Now it prints nothing, and callers filter out blank lines. whiptail is optional.

6. **GitHub image copy (2026-11-11):** `stable-pocketchip-b126.zip` (the NTC original, MD5 `b529e97b...89d2`) is attached to this repo's release tag `images`. That's a release asset, not a repo file, because GitHub rejects repo files over 100 MB. Both scripts try `GH_BASE` (`.../releases/download/images`) first, then archive.org, then the mirror. A HEAD check skips a missing asset quickly. The MD5 always comes from archive.org's files.xml. Other builds are only on archive.org.
7. **Windows port (2026-11-11), `windows/`:** `pocketchip-flasher.ps1` targets PowerShell 5.1+ and is saved as UTF-8 **with BOM**, because 5.1 misreads box-drawing characters without it. `PocketCHIP-Flasher.cmd` is the double-click launcher. It does **not** run CHIP-tools' Bash. Instead it ports `detect_nand` and `flash_images` from `common.sh` natively:
   - The U-Boot command text must match `common.sh` exactly (checked line by line for pocketchip/server x no-limit on/off). It is written with **LF** endings. Pages-per-eraseblock keeps the original quirk: the hex strings are divided as decimal (`400000/4000=100 -> 0x64`).
   - mkimage is replaced by `PcfNative.MkScript` (C# via Add-Type). It writes a legacy uImage header with magic, CRCs, OS=Linux, arch=ARM, type=script and a size table, and honours `SOURCE_DATE_EPOCH`.
   - Tools come from `%LOCALAPPDATA%\pocketchip-flasher\tools`. `fastboot.exe` is from Google platform-tools. `sunxi-fel.exe` is built by `build-sunxi-fel.ps1` from sunxi-tools **v1.4.1** with portable llvm-mingw and the static libusb from libusb's release. There is no trustworthy prebuilt binary. That build has **not been run yet**, because the sandbox blocked running the downloaded compiler.
   - Drivers: Zadig presets. FEL `1f3a:efe8` uses WinUSB. Fastboot `1f3a:1010` uses WinUSB with `GUID = {F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}` (the Android USB class that fastboot.exe enumerates). Without that GUID, fastboot.exe can't see the device. If fastboot times out, the script offers driver setup, because U-Boot waits in fastboot mode.
   - Test hooks: the env vars `PCF_WORK_DIR`, `PCF_FEL`, `PCF_FASTBOOT`, `PCF_IA_BASE`, `PCF_IA_META_URL`, `PCF_GH_BASE`, `PCF_FAKE_USB=fel` and `PCF_FAKE_LOG`. Dot-sourcing the script loads only its functions.

## Current status
- The dry-run test passes (fake USB tools + the real CHIP-tools-2025 script).
- **Not yet confirmed on real hardware.** The user's next step was FLASH NOW after the missing-package fix (about a 966 MB download from archive.org).
- The archive zip's internal layout wasn't verified from here. `extract_zip` locates `sunxi-spl.bin` wherever it sits and handles one nested .zip.

## Possible follow-ups if a real flash fails
- Modern `fastboot` against NTC's old U-Boot fastboot: check the log for sparse or max-download-size errors. Options are adding `-S 256M` or patching `common.sh`.
- `waiting for fel...TIMEOUT`: usually power or cable (see the Flash-CHIP-2025 README). The menu can build sunxi-tools v1.4.1.
- Flash-CHIP-2025's `Flash.sh` is cloned only for reference. This script doesn't use it.

## Testing
- `bash -n pocketchip-flasher.sh` for a syntax check.
- `tests/run-dry-flash.sh` runs the full flow end to end without a CHIP (needs network to clone CHIP-tools-2025). It should print `PASS`.
- Never run the real flash in CI; it needs sudo and a CHIP in FEL mode.
- Windows: `powershell -ExecutionPolicy Bypass -File windows\tests\run-dry-flash.ps1` (add `-Shell pwsh` for PowerShell 7). It should print `PASS`. It also checks the uboot.scr header CRCs and LF endings.
- The Windows version has **not been run on real hardware**. Its untested pieces are the WinUSB/Zadig drivers, the fastboot GUID and the sunxi-fel.exe build.

## Layout
- `pocketchip-flasher.sh` is the script (run as a normal user, not sudo).
- `tests/fake/` holds stub `sudo`, `sunxi-fel`, `fastboot`, `lsusb`, `mkimage` and `whiptail` for the dry run.
- At runtime, data lives in `~/.local/share/pocketchip-flasher/{CHIP-tools-2025,images,logs}`.
- `windows/` holds `pocketchip-flasher.ps1`, `PocketCHIP-Flasher.cmd`, `build-sunxi-fel.ps1`, `zadig/*.cfg` and `tests/` (fake `.cmd` tools). At runtime its data lives in `%LOCALAPPDATA%\pocketchip-flasher\{tools,images,logs}`.
- `.gitattributes` keeps `*.sh` LF and `*.ps1`/`*.cmd` CRLF. This matters because the checkout uses `core.autocrlf=true`.
