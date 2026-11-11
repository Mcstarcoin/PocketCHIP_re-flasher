<p align="center">
  <img src="https://avatars.githubusercontent.com/u/47195960?v=4&s=240" alt="Next Thing Co. logo" width="160">
</p>

# PocketCHIP Flasher

One-shot, menu-driven re-flasher for the Next Thing Co. **PocketCHIP / C.H.I.P.**
Works on **Linux Mint / Ubuntu** and **Windows 10/11**.

> Unofficial community tool. Not affiliated with or endorsed by Next Thing Co.
> The Next Thing Co. name and logo belong to their owners and are shown only to
> identify the hardware this tool is for.

Next Thing Co. shut down in 2018 and its download servers are gone. This tool
gets the official images from a copy in this repo's
[GitHub release](https://github.com/Mcstarcoin/PocketCHIP_re-flasher/releases/tag/images)
or from the Internet Archive, checks them, and flashes them over USB.

## Linux (Mint / Ubuntu / Debian)

```bash
chmod +x pocketchip-flasher.sh
./pocketchip-flasher.sh
```

Run it as your normal user. It asks for sudo when it needs it.
It wraps the community [CHIP-tools-2025](https://github.com/Elfking29/CHIP-tools-2025) scripts.

## Windows 10 / 11

1. Download this repo (green **Code** button > **Download ZIP**, then unzip it), or `git clone` it.
2. Open the `windows` folder and double-click **`PocketCHIP-Flasher.cmd`**.
3. First time only: choose **6 (Setup)**. It does three things:
   - downloads `fastboot.exe` (Google Android Platform-Tools)
   - builds `sunxi-fel.exe` from the official linux-sunxi source. There's no
     official Windows build, so it downloads a portable compiler (~190 MB,
     nothing gets installed) and takes a few minutes.
   - opens **Zadig** to install the WinUSB driver. In Zadig, do this twice:
     *Device > Load Preset Device*, pick `chip-fel.cfg`, then `chip-fastboot.cfg`,
     and click **Install Driver** (WinUSB) each time. The CHIP doesn't need to be plugged in.
4. Put the CHIP in FEL mode (menu **1** explains how), plug it in, choose **2 (FLASH NOW)**.

The Windows version runs natively. It doesn't need WSL or Linux. It does the same
FEL and fastboot steps as CHIP-tools-2025, ported to PowerShell. The menus,
the bottom progress bar and the image caching work the same as on Linux.
Everything it downloads is kept in `%LOCALAPPDATA%\pocketchip-flasher`.

Command line (no menu):

```bash
powershell -ExecutionPolicy Bypass -File windows\pocketchip-flasher.ps1 -Flash -Yes -Flavor p
```

Options: `-Flavor p|s|g|b`, `-Branch stable|testing`, `-Nand Hynix_8G_MLC|Toshiba_4G_MLC|Toshiba_512M_SLC`,
`-Source auto|github|archive|mirror|local`, `-LocalImage <zip or folder>`, `-NoLimit`, `-Reset`, `-DownloadOnly`.

## The Next Thing Co. firmware image

The default image is the last **stable PocketCHIP (Pocket OS)** release that
Next Thing Co. published:

| | |
|---|---|
| File | `stable-pocketchip-b126.zip` |
| Build | stable branch, PocketCHIP flavor, build 126 |
| Size | 1,013,156,421 bytes (~966 MB) |
| MD5 | `b529e97bbefb3fece7b54b1d5fc289d2` |
| SHA-1 | `7aaf3b03bcf66fdb869024e5dc356740391ab514` |
| Download (GitHub copy) | [releases/download/images/stable-pocketchip-b126.zip](https://github.com/Mcstarcoin/PocketCHIP_re-flasher/releases/download/images/stable-pocketchip-b126.zip) |
| Download (Internet Archive) | [archive.org/download/C.h.i.p.FlashCollection/stable-pocketchip-b126.zip](https://archive.org/download/C.h.i.p.FlashCollection/stable-pocketchip-b126.zip) |

The zip holds the files for every NAND type. The flasher detects the NAND chip and picks the matching files.

Other official builds are in the Internet Archive's
[C.H.I.P. Flash Collection](https://archive.org/details/C.h.i.p.FlashCollection).
Choose them under **Advanced > Flavour / Branch**:

| Flavor | Stable | Testing |
|---|---|---|
| PocketCHIP (Pocket OS) | `stable-pocketchip-b126.zip` | `testing-pocketchip-b667.zip` |
| GUI (Debian + XFCE) | `stable-gui-b149.zip` | `testing-gui-b543.zip` |
| Server (headless Debian) | `stable-server-b149.zip` | `testing-server-b543.zip` |
| Buildroot (minimal) | `stable-buildroot-b34.zip` | `testing-buildroot-b23.zip` |

Download order when the source is **Auto**: an already-downloaded copy, then the
GitHub release, then the Internet Archive, then the old jfpossibilities mirror
(offline since 2026). Every download is MD5-checked against the Internet Archive's
file list. If you downloaded a zip yourself, use **Advanced > Image source > Local**.

These images are Next Thing Co.'s original, unmodified builds, copied here so
they're easier to find. Next Thing Co. no longer exists. The images contain
Debian and other open-source software under their own licenses.

## Testing without a CHIP

- Linux: `tests/run-dry-flash.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File windows\tests\run-dry-flash.ps1`

Both should print `PASS`. They use fake USB tools and a small fake image.
