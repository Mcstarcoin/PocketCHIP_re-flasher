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

## Layout
- `pocketchip-flasher.sh` is the script (run as a normal user, not sudo).
- `tests/fake/` holds stub `sudo`, `sunxi-fel`, `fastboot`, `lsusb`, `mkimage` and `whiptail` for the dry run.
- At runtime, data lives in `~/.local/share/pocketchip-flasher/{CHIP-tools-2025,images,logs}`.
