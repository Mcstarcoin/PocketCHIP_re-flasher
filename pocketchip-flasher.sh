#!/usr/bin/env bash
# =============================================================================
#   ┌┴┴┴┴┴┴┴┴┴┴┴┴┐
#  ─┤  C.H.I.P.  ├─   PocketCHIP / C.H.I.P. One-Shot Flasher for Linux Mint
#  ─┤   ▓▓▓▓▓▓   ├─   v2  (2026-11)
#   └┬┬┬┬┬┬┬┬┬┬┬┬┘
# -----------------------------------------------------------------------------
#  Menu-driven wrapper around the community 2025 flashing tools:
#    https://github.com/Elfking29/Flash-CHIP-2025
#    https://github.com/Elfking29/CHIP-tools-2025   (chip-update-firmware.sh)
#
#  v2 changes:
#   - The chip.jfpossibilities.com image mirror is offline (connection refused).
#     Images now come from the Internet Archive "C.H.I.P. Flash Collection"
#     (official Next Thing Co. builds), are MD5-verified, cached, and handed to
#     chip-update-firmware.sh with -L (local images). The old mirror is still
#     tried as a fallback in case it comes back.
#   - Only installs packages that are actually missing; skips apt otherwise.
#   - Progress bar pinned to the bottom of the terminal for every long step.
#   - CHIP ASCII art, live USB status in the menu.
#
#  Usage:   chmod +x pocketchip-flasher.sh && ./pocketchip-flasher.sh
#  Run as your normal user (NOT with sudo). It asks for sudo when needed.
# =============================================================================

set -o pipefail

# ---------------------------- Configuration ---------------------------------
TOOLS_REPO="https://github.com/Elfking29/CHIP-tools-2025.git"
SUNXI_REPO="https://github.com/linux-sunxi/sunxi-tools.git"
SUNXI_FALLBACK_TAG="v1.4.1"   # version the Flash-CHIP-2025 README recommends

IA_BASE="https://archive.org/download/C.h.i.p.FlashCollection"
IA_META_URL="$IA_BASE/C.h.i.p.FlashCollection_files.xml"
MIRROR_URL="http://chip.jfpossibilities.com/chip/images"   # offline as of 2026-11

WORK_DIR="${HOME}/.local/share/pocketchip-flasher"
TOOLS_DIR="${WORK_DIR}/CHIP-tools-2025"
IMG_DIR="${WORK_DIR}/images"          # must be a sibling of TOOLS_DIR (see -L note)
LOG_DIR="${WORK_DIR}/logs"
IA_META="${WORK_DIR}/ia_files.xml"
UDEV_RULE="/etc/udev/rules.d/99-allwinner.rules"
TITLE="PocketCHIP Flasher"

# Flash options (changed from the Advanced menu)
OPT_FLAVOR="p"            # p=PocketCHIP, s=Server, g=GUI desktop, b=Buildroot
OPT_BRANCH="stable"       # stable or testing
OPT_NAND=""               # "" = auto-detect
OPT_NOLIMIT=0             # 1 = raise USB power-draw limit during flash
OPT_FORCE=0               # 1 = delete cached image and re-download
OPT_RESET=0               # 1 = reboot the CHIP after flashing
OPT_SOURCE="auto"         # auto | archive | mirror | local
OPT_LOCAL_PATH=""         # folder or .zip for OPT_SOURCE=local

IMG_LOCALDIR=""           # set by prepare_image (path relative to TOOLS_DIR)
BG_PIDS=()

# Whiptail colour theme
export NEWT_COLORS='root=,black;window=white,black;border=cyan,black;title=brightcyan,black;textbox=white,black;button=black,cyan;actbutton=black,brightcyan;listbox=white,black;actlistbox=black,cyan;actsellistbox=black,brightcyan;sellistbox=brightcyan,black;compactbutton=white,black;entry=white,black;helpline=black,cyan;roottext=cyan,black'

# ------------------------------ Output helpers ------------------------------
HAVE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=1

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'
c_mag=$'\e[35m'; c_dim=$'\e[2m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

fsize() { stat -c%s "$1" 2>/dev/null || echo 0; }
mb()    { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1048576}'; }
mmss()  { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# ---------------------------- ASCII art -------------------------------------
art_banner() {
  printf '%s' "$c_cyn"
  cat <<'EOF'
      .-----------------------------------------.
      |  .-----------------------------------.  |
      |  |  $ ./flash --pocketchip           |  |
      |  |  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░  64%   |  |
      |  |  chip@chip:~$ _                   |  |
      |  '-----------------------------------'  |
      |   [1][2][3][4][5][6][7][8][9][0][-][=]  |
      |   [q][w][e][r][t][y][u][i][o][p][[][]]  |
      |   [a][s][d][f][g][h][j][k][l][;]['][⏎]  |
      |   [z][x][c][v][b][n][m][,][.][/][↑][ ]  |
      '-----------------------------------------'
EOF
  printf '%s' "$c_mag"
  cat <<'EOF'
          P O C K E T   C . H . I . P .   F L A S H E R
EOF
  printf '%s\n' "$c_rst"
}

art_chip() {   # art_chip "line1" "line2"
  local l1=${1:-} l2=${2:-}
  printf '%s' "$c_grn"
  printf '          ┌┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┐\n'
  printf '         ─┤                      ├─\n'
  printf '         ─┤       C.H.I.P.       ├─\n'
  printf '         ─┤ %-20s ├─\n' "$l1"
  printf '         ─┤ %-20s ├─\n' "$l2"
  printf '         ─┤                      ├─\n'
  printf '          └┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┬┘\n'
  printf '%s' "$c_rst"
}

# ------------------------- Bottom-pinned progress bar -----------------------
# Reserves the last two terminal lines (separator + bar) with a scroll region,
# so normal output scrolls above while the bar stays put.
BAR_ON=0; BAR_PCT=0; BAR_LABEL=""; BAR_DETAIL=""
ROWS=24; COLS=80

# The bar is drawn on fd 9 (the terminal itself), so it still shows when a
# step's normal output is redirected or piped.
if [[ -t 1 ]] && { exec 9>/dev/tty; } 2>/dev/null; then :; else exec 9>/dev/null; fi

term_size() {
  local sz; sz=$(stty size </dev/tty 2>/dev/null)
  ROWS=${sz% *}; COLS=${sz#* }
  [[ $ROWS =~ ^[0-9]+$ && $COLS =~ ^[0-9]+$ ]] || { ROWS=24; COLS=80; }
  (( ROWS < 8 )) && ROWS=24; (( COLS < 40 )) && COLS=80
}

bar_start() {
  [[ -t 1 ]] || return 0
  term_size
  clear
  printf '\e[1;%dr\e[1;1H' $((ROWS - 2)) >&9
  BAR_ON=1
  bar_draw 0 "${1:-Starting}"
}

_bar_paint() {   # internal: fill-string empty-string right-text
  local left=" $BAR_LABEL " sep
  printf -v sep '%*s' "$COLS" ''; sep=${sep// /─}
  printf '\e7\e[%d;1H\e[2K%s%s%s\e[%d;1H\e[2K\e[1;97;44m%s\e[0m \e[36m%s\e[90m%s\e[0m\e[1m%s\e[0m\e8' \
    $((ROWS - 1)) "$c_dim" "$sep" "$c_rst" "$ROWS" "$left" "$1" "$2" "$3" >&9
}

bar_draw() {     # bar_draw <pct> <label> [detail]
  (( BAR_ON )) || return 0
  term_size
  local pct=${1%.*}; (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  BAR_PCT=$pct; BAR_LABEL=${2:-$BAR_LABEL}; BAR_DETAIL=${3:-}
  local right; right=$(printf ' %3d%% %s' "$pct" "$BAR_DETAIL")
  local w=$(( COLS - ${#BAR_LABEL} - ${#right} - 4 ))
  if (( w < 10 )); then right=$(printf ' %3d%%' "$pct"); w=$(( COLS - ${#BAR_LABEL} - ${#right} - 4 )); fi
  (( w < 5 )) && w=5
  local fill=$(( pct * w / 100 )) a b
  printf -v a '%*s' "$fill" ''; printf -v b '%*s' $(( w - fill )) ''
  _bar_paint "${a// /█}" "${b// /░}" "$right"
}

bar_busy_frame() {   # bouncing block for steps with unknown length
  (( BAR_ON )) || return 0
  term_size
  BAR_LABEL=${2:-$BAR_LABEL}
  local right=" ${3:-working...}"
  local w=$(( COLS - ${#BAR_LABEL} - ${#right} - 4 )); (( w < 10 )) && w=10
  local blk=8 span=$(( w - 8 )) pos=$(( $1 % (2 * (w - 8)) ))
  (( pos > span )) && pos=$(( 2 * span - pos ))
  local a b c
  printf -v a '%*s' "$pos" ''; printf -v b '%*s' "$blk" ''; printf -v c '%*s' $(( w - pos - blk )) ''
  _bar_paint "${a// /░}${b// /█}" "${c// /░}" "$right"
}

bar_stop() {
  (( BAR_ON )) || return 0
  term_size
  printf '\e[r\e[%d;1H\e[2K\e[%d;1H\e[2K\e[%d;1H' $((ROWS - 1)) "$ROWS" $((ROWS - 2)) >&9
  BAR_ON=0
}

run_busy() {     # run_busy "label" cmd args...   (animated bar while cmd runs)
  local label=$1; shift
  "$@" &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do bar_busy_frame $i "$label"; i=$((i + 1)); sleep 0.12; done
  wait "$pid"
}

cleanup() {
  for p in "${BG_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  bar_stop
}
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT TERM
trap 'if (( BAR_ON )); then term_size; printf "\e7\e[1;%dr\e8" $((ROWS-2)) >&9; bar_draw "$BAR_PCT" "$BAR_LABEL" "$BAR_DETAIL"; fi' WINCH

# ------------------------------ Dialog helpers ------------------------------
pause() { bar_stop; echo; read -r -p "Press Enter to return to the menu..." _; }

msg() {
  bar_stop
  if (( HAVE_WHIPTAIL )); then whiptail --title "$TITLE" --msgbox "$1" "${2:-20}" "${3:-74}"
  else echo; echo "$1"; pause; fi
}

yesno() {
  bar_stop
  if (( HAVE_WHIPTAIL )); then whiptail --title "$TITLE" --yesno "$1" "${2:-12}" "${3:-70}"
  else local a; read -r -p "$1 [y/N] " a; [[ $a =~ ^[Yy] ]]; fi
}

inputbox() {
  bar_stop
  if (( HAVE_WHIPTAIL )); then whiptail --title "$TITLE" --inputbox "$1" 12 74 "${2:-}" 3>&1 1>&2 2>&3
  else local a; read -r -e -p "$1 " -i "${2:-}" a; echo "$a"; fi
}

menu() {   # menu "prompt" tag1 "desc1" ... -> prints chosen tag
  local prompt=$1; shift
  bar_stop
  if (( HAVE_WHIPTAIL )); then
    local lines; lines=$(printf '%s\n' "$prompt" | wc -l)
    local items=$(( $# / 2 ))
    whiptail --title "$TITLE" --menu "$prompt" $(( lines + items + 8 )) 78 "$items" "$@" 3>&1 1>&2 2>&3
  else
    { echo; echo "$prompt"; } >&2
    local tags=()
    while (( $# )); do tags+=("$1"); printf '  %s) %s\n' "$1" "$2" >&2; shift 2; done
    local c; read -r -p "Choose: " c
    for t in "${tags[@]}"; do [[ $c == "$t" ]] && { echo "$c"; return 0; }; done
    return 1
  fi
}

# ------------------------------ Lookups -------------------------------------
flavor_name() {
  case $1 in
    p) echo "PocketCHIP (Pocket OS)";;
    s) echo "Server (headless Debian)";;
    g) echo "GUI (Debian desktop, XFCE)";;
    b) echo "Buildroot (minimal)";;
  esac
}
flavor_dir() { case $OPT_FLAVOR in p) echo pocketchip;; s) echo server;; g) echo gui;; b) echo buildroot;; esac; }

# Builds available in the Internet Archive C.H.I.P. Flash Collection
ia_build() {
  case "$OPT_BRANCH-$(flavor_dir)" in
    stable-pocketchip)  echo 126;;  testing-pocketchip) echo 667;;
    stable-gui)         echo 149;;  testing-gui)        echo 543;;
    stable-server)      echo 149;;  testing-server)     echo 543;;
    stable-buildroot)   echo 34;;   testing-buildroot)  echo 23;;
  esac
}

source_name() {
  case $OPT_SOURCE in
    auto)    echo "Auto (Internet Archive, then old mirror)";;
    archive) echo "Internet Archive only";;
    mirror)  echo "jfpossibilities mirror only";;
    local)   echo "Local: ${OPT_LOCAL_PATH:-<not set>}";;
  esac
}

usb_state() {
  local u; u=$(lsusb 2>/dev/null)
  if   grep -qi '1f3a:efe8' <<<"$u"; then echo "FEL mode - ready to flash ✓"
  elif grep -Eqi '1f3a:1010|18d1:1010' <<<"$u"; then echo "fastboot mode (flashing)"
  elif grep -Eqi '0525:a4a[7a]' <<<"$u"; then echo "booted normally - NOT in FEL mode"
  else echo "not detected"; fi
}

image_complete() {   # folder has everything chip-update-firmware.sh needs?
  local d=$1
  [[ -f $d/sunxi-spl.bin && -f $d/u-boot-dtb.bin && -f $d/uboot-400000.bin ]] || return 1
  compgen -G "$d/chip-*.ubi.sparse" >/dev/null || return 1
  compgen -G "$d/spl-*.bin" >/dev/null
}

# ------------------------------ Setup steps ---------------------------------
# Command -> package. Only missing ones get installed.
REQ=( "git:git" "curl:curl" "unzip:unzip" "whiptail:whiptail" "lsusb:usbutils"
      "mkimage:u-boot-tools" "sunxi-fel:sunxi-tools" "fastboot:fastboot" "md5sum:coreutils" )

missing_pkgs() {
  local p cmd pkg out=()
  for p in "${REQ[@]}"; do
    cmd=${p%%:*}; pkg=${p#*:}
    command -v "$cmd" >/dev/null 2>&1 && continue
    if [[ $pkg == fastboot ]] && ! apt-cache show fastboot >/dev/null 2>&1; then pkg=android-tools-fastboot; fi
    out+=("$pkg")
  done
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}"   # print nothing at all when none are missing
  return 0
}

ensure_deps() {
  local i=0 n=${#REQ[@]} p
  for p in "${REQ[@]}"; do
    i=$((i + 1)); bar_draw $(( i * 100 / n )) "Checking tools" "${p%%:*}"; sleep 0.03
  done
  local -a need; mapfile -t need < <(missing_pkgs | grep -v '^$')
  if (( ${#need[@]} == 0 )); then
    ok "All ${n} required tools are already installed - skipping package install."
    return 0
  fi

  info "Missing: ${need[*]}"
  info "Asking for sudo to install them..."
  bar_stop; sudo -v || { err "sudo is required."; return 1; }
  bar_start "Installing"
  run_busy "Updating package lists" sudo apt-get update -qq >/dev/null 2>&1 || warn "apt update reported problems; continuing."
  i=0
  for p in "${need[@]}"; do
    i=$((i + 1))
    bar_draw $(( (i - 1) * 100 / ${#need[@]} )) "Installing" "$p ($i/${#need[@]})"
    if run_busy "Installing $p" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1; then
      ok "Installed $p"
    else
      warn "Could not install $p"
    fi
  done
  bar_draw 100 "Installing" "done"
  command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=1

  if ! command -v sunxi-fel >/dev/null; then
    warn "sunxi-fel still missing; building sunxi-tools $SUNXI_FALLBACK_TAG from source."
    build_sunxi || return 1
  fi
  mapfile -t need < <(missing_pkgs | grep -v -e '^$' -e '^whiptail$')   # whiptail is optional (text menus fall back)
  if (( ${#need[@]} )); then err "Still missing: ${need[*]}"; return 1; fi
  ok "All tools installed."
}

UDEV_CONTENT='# Allwinner / Next Thing Co. C.H.I.P. and PocketCHIP flashing rules
# FEL (boot ROM) mode
SUBSYSTEM=="usb", ATTRS{idVendor}=="1f3a", ATTRS{idProduct}=="efe8", GROUP="plugdev", MODE="0666", SYMLINK+="usb-chip"
# Fastboot (U-Boot) mode
SUBSYSTEM=="usb", ATTRS{idVendor}=="1f3a", ATTRS{idProduct}=="1010", GROUP="plugdev", MODE="0666", SYMLINK+="usb-chip-fastboot"
SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="1010", GROUP="plugdev", MODE="0666", SYMLINK+="usb-chip-fastboot"
# Any other Allwinner device
SUBSYSTEM=="usb", ATTRS{idVendor}=="1f3a", GROUP="plugdev", MODE="0666"
# CHIP USB serial gadget (after it boots)
SUBSYSTEM=="tty", ATTRS{idVendor}=="0525", ATTRS{idProduct}=="a4a7", GROUP="dialout", MODE="0666", SYMLINK+="usb-serial-adapter"'

setup_permissions() {   # only changes what isn't already set
  local changed=0
  if ! id -nG "$USER" | grep -qw plugdev || ! id -nG "$USER" | grep -qw dialout; then
    sudo usermod -aG dialout,plugdev "$USER" && ok "Added $USER to dialout and plugdev." ; changed=1
  fi
  if [[ "$(cat "$UDEV_RULE" 2>/dev/null)" != "$UDEV_CONTENT" ]]; then
    printf '%s\n' "$UDEV_CONTENT" | sudo tee "$UDEV_RULE" >/dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger
    ok "udev rules installed."; changed=1
  fi
  # USB autosuspend is a common cause of "timed out waiting for fel" (this boot only)
  local as=/sys/module/usbcore/parameters/autosuspend
  if [[ -e $as && "$(cat "$as")" != "-1" ]]; then
    echo -1 | sudo tee "$as" >/dev/null && ok "USB autosuspend disabled until next reboot."; changed=1
  fi
  (( changed )) || ok "USB permissions already set up - skipping."
}

fetch_tools() {
  if [[ -d $TOOLS_DIR/.git ]]; then
    local before; before=$(git -C "$TOOLS_DIR" rev-parse HEAD 2>/dev/null)
    if run_busy "Checking for tool updates" git -C "$TOOLS_DIR" fetch -q --depth 1 origin 2>/dev/null; then
      git -C "$TOOLS_DIR" reset -q --hard FETCH_HEAD
    else
      warn "Could not check for updates; using existing copy."
    fi
    [[ $before == "$(git -C "$TOOLS_DIR" rev-parse HEAD)" ]] && ok "CHIP-tools-2025 already up to date." || ok "CHIP-tools-2025 updated."
  else
    rm -rf "$TOOLS_DIR"
    run_busy "Downloading CHIP-tools-2025" git clone -q --depth 1 "$TOOLS_REPO" "$TOOLS_DIR" \
      || { err "Clone failed. Check your internet connection."; return 1; }
    ok "CHIP-tools-2025 downloaded."
  fi
  chmod +x "$TOOLS_DIR"/*.sh 2>/dev/null
  [[ -x $TOOLS_DIR/chip-update-firmware.sh ]] || { err "chip-update-firmware.sh not found."; return 1; }
}

build_sunxi() {
  bar_stop; sudo -v || return 1; bar_start "sunxi-tools"
  run_busy "Installing build tools" sudo apt-get install -y -qq build-essential pkg-config libusb-1.0-0-dev zlib1g-dev libfdt-dev >/dev/null 2>&1
  local d="$WORK_DIR/sunxi-tools"
  rm -rf "$d"
  run_busy "Downloading sunxi-tools $SUNXI_FALLBACK_TAG" git clone -q --depth 1 --branch "$SUNXI_FALLBACK_TAG" "$SUNXI_REPO" "$d" \
    || { err "Clone failed."; return 1; }
  run_busy "Compiling sunxi-tools" bash -c "cd '$d' && make -s tools misc >/dev/null 2>&1" || { err "Build failed."; return 1; }
  run_busy "Installing sunxi-tools" sudo make -C "$d" -s install-tools install-misc >/dev/null 2>&1 || { err "Install failed."; return 1; }
  hash -r
  bar_draw 100 "sunxi-tools" "done"
  ok "sunxi-tools installed: $(sunxi-fel --version 2>&1 | head -n1)"
}

# ------------------------------ Image handling ------------------------------
download_file() {   # download_file <url> <out> <label> [expected_bytes]
  local url=$1 out=$2 label=$3 total=${4:-0}
  local part="$out.part" try rc
  [[ -f $out ]] && return 0
  (( total > 0 )) && [[ $(fsize "$part") -eq $total ]] && { mv "$part" "$out"; return 0; }
  for try in 1 2 3 4 5; do
    curl -fL --connect-timeout 20 --retry 3 --retry-delay 3 -C - -sS -o "$part" "$url" &
    local pid=$! t0=$SECONDS s0; s0=$(fsize "$part")
    while kill -0 "$pid" 2>/dev/null; do
      local now el spd pct detail
      now=$(fsize "$part"); el=$(( SECONDS - t0 )); spd=$(( el > 0 ? (now - s0) / el : 0 ))
      if (( total > 0 )); then
        pct=$(( now * 100 / total ))
        local eta="--:--"; (( spd > 0 )) && eta=$(mmss $(( (total - now) / spd )))
        detail="$(mb "$now")/$(mb "$total") MB  $(mb "$spd") MB/s  ETA $eta"
        bar_draw "$pct" "$label" "$detail"
      else
        bar_busy_frame $(( SECONDS * 4 )) "$label" "$(mb "$now") MB  $(mb "$spd") MB/s"
      fi
      sleep 0.5
    done
    wait "$pid"; rc=$?
    if (( rc == 0 )); then mv "$part" "$out"; bar_draw 100 "$label" "done"; return 0; fi
    # 22 = HTTP error (e.g. 416 on an already-complete/odd partial), 33 = no resume
    if (( rc == 22 || rc == 33 || rc == 36 )); then rm -f "$part"; fi
    warn "Download interrupted (curl error $rc). Retrying ($try/5)..."
    sleep 3
  done
  return 1
}

ia_meta() {   # fetch archive.org file list (sizes + md5) once
  [[ -s $IA_META ]] && return 0
  curl -fsSL --connect-timeout 15 -m 60 -o "$IA_META" "$IA_META_URL" 2>/dev/null || { rm -f "$IA_META"; return 1; }
}

ia_field() {  # ia_field <filename> <size|md5>
  [[ -s $IA_META ]] || return 1
  awk -v n="$1" -v f="$2" '
    index($0, "name=\"" n "\"") { inb = 1 }
    inb && index($0, "<" f ">") { s = $0; sub(".*<" f ">", "", s); sub("</" f ">.*", "", s); print s; exit }
    inb && index($0, "</file>") { inb = 0 }' "$IA_META"
}

extract_zip() {   # extract_zip <zip> <final_dir> <label>
  local zip=$1 dest=$2 label=$3 tmp="$2.tmp"
  rm -rf "$tmp"; mkdir -p "$tmp"
  local total; total=$(unzip -l "$zip" 2>/dev/null | awk 'END{print $1}')
  [[ $total =~ ^[0-9]+$ ]] || total=0
  unzip -q -o "$zip" -d "$tmp" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    local now; now=$(du -sb "$tmp" 2>/dev/null | awk '{print $1}')
    if (( total > 0 )); then bar_draw $(( now * 100 / total )) "$label" "$(mb "$now")/$(mb "$total") MB"
    else bar_busy_frame $(( SECONDS * 4 )) "$label"; fi
    sleep 0.4
  done
  wait "$pid" || { err "Unzip failed."; rm -rf "$tmp"; return 1; }

  # Find the folder holding the images (zip layout may nest folders or zips)
  local spl; spl=$(find "$tmp" -name sunxi-spl.bin -print -quit)
  if [[ -z $spl ]]; then
    local inner; inner=$(find "$tmp" -name '*.zip' -print -quit)
    if [[ -n $inner ]]; then
      run_busy "$label (inner archive)" unzip -q -o "$inner" -d "$tmp/inner" || { rm -rf "$tmp"; return 1; }
      spl=$(find "$tmp" -name sunxi-spl.bin -print -quit)
    fi
  fi
  [[ -n $spl ]] || { err "No flash images found inside $(basename "$zip")."; rm -rf "$tmp"; return 1; }
  rm -rf "$dest"; mkdir -p "$dest"
  mv "$(dirname "$spl")"/* "$dest"/ && rm -rf "$tmp"
  bar_draw 100 "$label" "done"
  image_complete "$dest" || { err "Image folder is incomplete after extraction."; return 1; }
}

check_space() {   # check_space <bytes_needed>
  local need_kb=$(( $1 / 1024 )) free_kb
  free_kb=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}')
  if (( free_kb < need_kb )); then
    err "Not enough disk space: need ~$(( need_kb / 1024 )) MB, have $(( free_kb / 1024 )) MB free."
    return 1
  fi
}

fetch_from_archive() {   # fetch_from_archive <name> <dir>
  local name=$1 dir=$2 zipname="$1.zip" zip="$IMG_DIR/$1.zip"
  info "Source: Internet Archive - C.H.I.P. Flash Collection ($zipname)"
  run_busy "Reading archive file list" ia_meta || warn "Could not read archive.org file list; skipping checksum."
  local size md5; size=$(ia_field "$zipname" size); md5=$(ia_field "$zipname" md5)
  [[ $size =~ ^[0-9]+$ ]] || size=$(curl -sIL --connect-timeout 15 "$IA_BASE/$zipname" | awk 'tolower($1)=="content-length:"{v=$2} END{gsub("\r","",v); print v+0}')
  if [[ ! -f $zip ]]; then
    check_space $(( size > 0 ? size * 3 + 300000000 : 3500000000 )) || return 1
    info "Downloading $(mb "$size") MB. archive.org can be slow - this may take a while."
    info "If it gets interrupted, just run Flash again: it resumes where it stopped."
    download_file "$IA_BASE/$zipname" "$zip" "Downloading image" "$size" || { err "Download from archive.org failed."; return 1; }
  else
    ok "Found downloaded $zipname"
  fi
  if [[ -n $md5 ]]; then
    local got; got=$(run_busy "Verifying checksum (MD5)" md5sum "$zip" | awk '{print $1}')
    if [[ $got != "$md5" ]]; then
      err "Checksum mismatch - the download is corrupt. Deleting it; run Flash again to re-download."
      rm -f "$zip"; return 1
    fi
    ok "Checksum OK ($md5)"
  else
    run_busy "Testing zip integrity" unzip -tqq "$zip" >/dev/null 2>&1 || { err "Zip is corrupt; deleting it."; rm -f "$zip"; return 1; }
    ok "Zip integrity OK"
  fi
  extract_zip "$zip" "$dir" "Unpacking image" || return 1
  rm -f "$zip"
  ok "Image ready: $dir"
}

fetch_from_mirror() {   # sets IMG_LOCALDIR on success
  local fl; fl=$(flavor_dir)
  info "Trying the old jfpossibilities mirror..."
  local latest; latest=$(curl -fsS --connect-timeout 8 -m 15 "$MIRROR_URL/$OPT_BRANCH/$fl/latest" 2>/dev/null | tr -dc '0-9')
  [[ -n $latest ]] || { err "Mirror is offline (chip.jfpossibilities.com)."; return 1; }
  local name="$OPT_BRANCH-$fl-b$latest" dir="$IMG_DIR/$OPT_BRANCH-$fl-b$latest"
  mkdir -p "$dir"
  local files=(spl-40000-1000-100.bin spl-400000-4000-500.bin spl-400000-4000-680.bin sunxi-spl.bin
               u-boot-dtb.bin uboot-40000.bin uboot-400000.bin)
  case $OPT_NAND in
    Hynix_8G_MLC)     files+=(chip-400000-4000-680.ubi.sparse);;
    Toshiba_4G_MLC)   files+=(chip-400000-4000-500.ubi.sparse);;
    Toshiba_512M_SLC) files+=(chip-40000-1000-100.ubi.sparse);;
    *)                files+=(chip-400000-4000-680.ubi.sparse chip-400000-4000-500.ubi.sparse chip-40000-1000-100.ubi.sparse);;
  esac
  local i=0 f sz
  for f in "${files[@]}"; do
    i=$((i + 1))
    sz=$(curl -sI --connect-timeout 10 "$MIRROR_URL/$OPT_BRANCH/$fl/$latest/$f" | awk 'tolower($1)=="content-length:"{gsub("\r","",$2); print $2+0}')
    download_file "$MIRROR_URL/$OPT_BRANCH/$fl/$latest/$f" "$dir/$f" "File $i/${#files[@]}" "$sz" || return 1
  done
  image_complete "$dir" || return 1
  IMG_LOCALDIR="../images/$name"
}

prepare_local() {
  local p=$OPT_LOCAL_PATH
  [[ -n $p ]] || { err "No local image path set (Advanced > Image source)."; return 1; }
  p=$(readlink -f "$p")
  if [[ -d $p ]]; then
    local d; d=$(dirname "$(find "$p" -name sunxi-spl.bin -print -quit 2>/dev/null)")
    [[ -n $d && -d $d ]] && image_complete "$d" || { err "No complete image found in $p"; return 1; }
    ln -sfn "$d" "$IMG_DIR/local-custom"
    IMG_LOCALDIR="../images/local-custom"
  elif [[ -f $p && $p == *.zip ]]; then
    local name="local-$(basename "$p" .zip)"
    image_complete "$IMG_DIR/$name" || extract_zip "$p" "$IMG_DIR/$name" "Unpacking image" || return 1
    IMG_LOCALDIR="../images/$name"
  else
    err "$p is not a folder or .zip"; return 1
  fi
  ok "Using local image: $p"
}

prepare_image() {
  mkdir -p "$IMG_DIR"
  IMG_LOCALDIR=""
  [[ $OPT_SOURCE == local ]] && { prepare_local; return; }

  local fl b name dir
  fl=$(flavor_dir); b=$(ia_build); name="$OPT_BRANCH-$fl-b$b"; dir="$IMG_DIR/$name"
  if (( OPT_FORCE )); then rm -rf "$dir" "$IMG_DIR/$name.zip" "$IMG_DIR/$name.zip.part"; OPT_FORCE=0; fi

  if [[ $OPT_SOURCE != mirror ]]; then
    if image_complete "$dir"; then
      ok "Image $name already downloaded - skipping download."
      IMG_LOCALDIR="../images/$name"; return 0
    fi
    if fetch_from_archive "$name" "$dir"; then IMG_LOCALDIR="../images/$name"; return 0; fi
    [[ $OPT_SOURCE == archive ]] && return 1
    warn "Internet Archive failed; trying the old mirror as a fallback."
  fi
  fetch_from_mirror
}

# ------------------------------ Actions -------------------------------------
show_instructions() {
  msg "HOW TO PUT YOUR POCKETCHIP INTO FLASH (FEL) MODE

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
mode. You can also download the image first, CHIP unplugged." 26 70
}

check_connection() {
  clear; art_chip "USB check" ""
  info "Looking for a CHIP on USB..."
  local s; s=$(usb_state)
  case $s in
    FEL*)
      ok "CHIP detected in FEL mode (1f3a:efe8)."
      if command -v sunxi-fel >/dev/null; then
        sudo sunxi-fel version && ok "sunxi-fel can talk to the CHIP. Ready to flash."
      fi;;
    fastboot*) ok "CHIP detected in fastboot mode (a flash is probably in progress).";;
    booted*)   warn "CHIP is booted normally. It is NOT in FEL mode - check the FEL-to-GND jumper.";;
    *) err "No CHIP found."
       echo "  - Is the FEL-to-GND jumper in place?"
       echo "  - Is the micro-USB cable a data cable (not charge-only)?"
       echo "  - Try another USB port or a shorter cable.";;
  esac
  pause
}

wait_for_fel_device() {   # up to 120 s, with countdown bar
  local limit=120 t0=$SECONDS
  grep -qi '1f3a:efe8' <(lsusb 2>/dev/null) && { ok "CHIP found in FEL mode."; return 0; }
  info "Plug in the CHIP now (FEL jumper in place)..."
  while (( SECONDS - t0 < limit )); do
    grep -qi '1f3a:efe8' <(lsusb 2>/dev/null) && { bar_draw 100 "Waiting for CHIP" "found!"; ok "CHIP found in FEL mode."; return 0; }
    local left=$(( limit - (SECONDS - t0) ))
    bar_draw $(( (SECONDS - t0) * 100 / limit )) "Waiting for CHIP" "plug it in - ${left}s left"
    sleep 0.5
  done
  err "No CHIP in FEL mode after ${limit}s."
  return 1
}

flash_poller() {   # reads the flash log and drives the bottom bar
  local log=$1 pct=0 label="Flashing" detail=""
  while :; do
    if [[ -f $log ]]; then
      local fel frac
      fel=$(grep -o 'waiting for fel[.]*OK' "$log" 2>/dev/null | wc -l)
      frac=$(grep -oiE "(sending|writing) sparse 'UBI' [0-9]+/[0-9]+" "$log" 2>/dev/null | tail -n1)
      if   grep -q "FLASH VERIFICATION COMPLETE" "$log"; then pct=100; detail="complete!"
      elif [[ -n $frac ]]; then
        local k=${frac##* }; local cur=${k%/*} tot=${k#*/} half=0
        [[ ${frac,,} == writing* ]] && half=1
        (( tot > 0 )) && pct=$(( 30 + 68 * (2 * (cur - 1) + half) / (2 * tot) ))
        detail="${frac,,} - writing system to NAND"
      elif grep -qi "waiting for fastboot" "$log"; then pct=28; detail="switching to fastboot"
      elif (( fel >= 3 )); then pct=24; detail="loading U-Boot over FEL"
      elif grep -q "NAND detected" "$log"; then pct=18; detail="NAND detected"
      elif (( fel >= 1 )); then pct=10; detail="talking to CHIP over FEL"
      elif grep -q "waiting for fel" "$log"; then pct=5; detail="waiting for FEL"
      else pct=2; detail="preparing"; fi
      if grep -qE "TIMEOUT|FAILED|ERROR" "$log" && (( pct < 100 )); then label="Problem"; detail="see messages above"; fi
    fi
    bar_draw "$pct" "$label" "$detail"
    sleep 0.4
  done
}

do_flash() {
  local desc="Flavour : $(flavor_name "$OPT_FLAVOR")
Branch  : $OPT_BRANCH
NAND    : ${OPT_NAND:-auto-detect}
Source  : $(source_name)
No-limit power : $([[ $OPT_NOLIMIT == 1 ]] && echo yes || echo no)
CHIP    : $(usb_state)

This ERASES everything on the CHIP's internal storage.

Start?"
  yesno "$desc" 18 70 || return

  clear
  info "Asking for sudo (USB access during flashing)..."
  sudo -v || { err "sudo is required."; pause; return; }
  ( while sleep 50; do sudo -n true 2>/dev/null || exit; done ) & BG_PIDS+=($!)

  bar_start "Step 1/5 Tools"
  art_chip "flashing" "$(flavor_dir)"
  ensure_deps                       || { err "Dependencies are missing. Fix the errors above and retry."; pause; return; }
  bar_draw 100 "Step 2/5 USB setup";  setup_permissions
  bar_draw 0   "Step 3/5 Flash tools"; fetch_tools || { pause; return; }
  bar_draw 0   "Step 4/5 Image";      prepare_image || { image_fail_help; pause; return; }
  bar_draw 0   "Step 5/5 Connect";    wait_for_fel_device || { fel_fail_help; pause; return; }

  local args=("-$OPT_FLAVOR" -L "$IMG_LOCALDIR")
  [[ -n $OPT_NAND ]] && args+=(-F "$OPT_NAND")
  (( OPT_NOLIMIT ))  && args+=(-n)
  (( OPT_RESET ))    && args+=(-r)

  local log="$LOG_DIR/flash-$(date +%Y%m%d-%H%M%S).log"
  : > "$log"
  info "Running: chip-update-firmware.sh ${args[*]}"
  info "Log file: $log"
  echo

  flash_poller "$log" & local poller=$!; BG_PIDS+=("$poller")
  ( cd "$TOOLS_DIR" && \
    FEL='sudo sunxi-fel' FASTBOOT='sudo fastboot' SNIB=false \
    ./chip-update-firmware.sh "${args[@]}" ) 2>&1 | tee -a "$log"
  sleep 0.5; kill "$poller" 2>/dev/null; wait "$poller" 2>/dev/null

  echo
  # chip-update-firmware.sh exits 0 even on failure, so judge by its output.
  if grep -q "FLASH VERIFICATION COMPLETE" "$log"; then
    bar_draw 100 "DONE" "flash complete"
    art_chip "FLASH COMPLETE!" "enjoy :)"
    ok "Unplug, remove the FEL jumper and reassemble your PocketCHIP."
    echo "   Default login on Pocket OS: user 'chip', password 'chip'."
  else
    bar_draw "$BAR_PCT" "FAILED" "see log"
    err "Flashing did not finish. Log: $log"
    fel_fail_help
  fi
  pause
}

image_fail_help() {
  echo
  echo "  Could not get the firmware image. Options:"
  echo "   1. Run Flash again - downloads resume where they stopped."
  echo "   2. Download it in your browser instead:"
  echo "        $IA_BASE/$OPT_BRANCH-$(flavor_dir)-b$(ia_build).zip"
  echo "      then pick Advanced > Image source > Local and point to the .zip."
}

fel_fail_help() {
  echo "  Things to try (from the Flash-CHIP-2025 README):"
  echo "   1. Just run Flash again - this fixes most FEL/fastboot hiccups."
  echo "   2. Times out waiting for FEL? Low USB power: shorter cable, rear port,"
  echo "      powered hub, or 5V into the CHG-IN pin. Try 'No-limit power' too."
  echo "   3. Still failing? Troubleshooting > build sunxi-tools $SUNXI_FALLBACK_TAG."
  echo "   4. Reboot this computer and try again."
}

download_only() {
  clear
  bar_start "Image"
  art_chip "downloading" "$(flavor_dir) image"
  ensure_deps || { pause; return; }
  prepare_image && ok "Image is cached. Flashing will skip the download." || image_fail_help
  pause
}

run_setup() {
  clear
  sudo -v || { err "sudo is required."; pause; return; }
  bar_start "Setup"
  art_chip "setup" ""
  ensure_deps; bar_draw 60 "Setup" "USB permissions"
  setup_permissions; bar_draw 80 "Setup" "flash tools"
  fetch_tools; bar_draw 100 "Setup" "done"
  ok "Setup finished."
  pause
}

advanced_menu() {
  while true; do
    local c
    c=$(menu "Advanced options (current values shown)" \
      1 "Flavour        : $(flavor_name "$OPT_FLAVOR")" \
      2 "Branch         : $OPT_BRANCH  (build b$(ia_build))" \
      3 "NAND type      : ${OPT_NAND:-auto-detect}" \
      4 "Image source   : $(source_name)" \
      5 "No-limit power : $([[ $OPT_NOLIMIT == 1 ]] && echo ON || echo off)" \
      6 "Force re-download image  : $([[ $OPT_FORCE == 1 ]] && echo ON || echo off)" \
      7 "Reboot CHIP after flash  : $([[ $OPT_RESET == 1 ]] && echo ON || echo off)" \
      0 "Back") || return
    case $c in
      1) local f; f=$(menu "Which OS image?" \
            p "PocketCHIP - Pocket OS (use this for a PocketCHIP)" \
            s "Server - headless Debian" \
            g "GUI - Debian with XFCE desktop" \
            b "Buildroot - minimal") && OPT_FLAVOR=$f ;;
      2) local b; b=$(menu "Image branch" stable "Stable (recommended)" testing "Testing (newer, less tested)") && OPT_BRANCH=$b ;;
      3) local n; n=$(menu "NAND chip (leave auto unless flashing fails)" \
            auto "Auto-detect (recommended)" \
            Hynix_8G_MLC "Hynix 8GB MLC (most CHIPs)" \
            Toshiba_4G_MLC "Toshiba 4GB MLC (some later CHIPs)" \
            Toshiba_512M_SLC "Toshiba 512MB SLC (CHIP Pro)") && \
            { [[ $n == auto ]] && OPT_NAND="" || OPT_NAND=$n; } ;;
      4) local s; s=$(menu "Where to get the firmware image" \
            auto "Auto: Internet Archive, fall back to old mirror" \
            archive "Internet Archive only" \
            mirror "jfpossibilities mirror only (offline as of Nov 2026)" \
            local "A .zip or folder I already downloaded") || continue
         if [[ $s == local ]]; then
           local p; p=$(inputbox "Path to the image .zip or extracted folder:" "${OPT_LOCAL_PATH:-$HOME/Downloads/}") || continue
           p=${p/#\~/$HOME}
           [[ -e $p ]] || { msg "Not found: $p" 8 60; continue; }
           OPT_LOCAL_PATH=$p
         fi
         OPT_SOURCE=$s ;;
      5) OPT_NOLIMIT=$((1 - OPT_NOLIMIT)) ;;
      6) OPT_FORCE=$((1 - OPT_FORCE)) ;;
      7) OPT_RESET=$((1 - OPT_RESET)) ;;
      0) return ;;
    esac
  done
}

troubleshoot_menu() {
  while true; do
    local c used
    used=$(du -sh "$IMG_DIR" 2>/dev/null | awk '{print $1}')
    c=$(menu "Troubleshooting" \
      1 "Build sunxi-tools $SUNXI_FALLBACK_TAG from source (fixes FEL timeouts)" \
      2 "Re-install udev rules and USB permissions" \
      3 "Delete downloaded images (${used:-0} used)" \
      4 "Show last flash log" \
      0 "Back") || return
    case $c in
      1) clear; bar_start "sunxi-tools"; build_sunxi; pause ;;
      2) clear; sudo rm -f "$UDEV_RULE"; setup_permissions; warn "Log out and back in for group changes to fully apply."; pause ;;
      3) yesno "Delete all downloaded images in $IMG_DIR?" 8 70 && rm -rf "$IMG_DIR" "$IA_META" && msg "Images deleted." 8 40 ;;
      4) local last; last=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -n1)
         if [[ -n $last ]]; then
           if (( HAVE_WHIPTAIL )); then whiptail --title "$(basename "$last")" --scrolltext --textbox "$last" 24 78
           else less "$last"; fi
         else msg "No logs yet." 8 30; fi ;;
      0) return ;;
    esac
  done
}

# ------------------------------- Startup ------------------------------------
preflight() {
  if [[ $EUID -eq 0 ]]; then
    err "Do not run this with sudo. Run it as your normal user: ./$(basename "$0")"; exit 1
  fi
  command -v apt-get >/dev/null || { err "This script expects Linux Mint / Ubuntu / Debian."; exit 1; }
  mkdir -p "$WORK_DIR" "$IMG_DIR" "$LOG_DIR"
}

splash() {
  bar_start "Loading"
  art_banner
  ensure_deps || warn "Some tools are missing; they'll be retried when you flash."
  local name="$OPT_BRANCH-$(flavor_dir)-b$(ia_build)"
  image_complete "$IMG_DIR/$name" && ok "Cached image found: $name" || info "Image not downloaded yet (~1 GB, fetched on first flash)."
  bar_draw 100 "Ready" ""
  sleep 1.2
  bar_stop
}

main_menu() {
  while true; do
    local name img c
    name="$OPT_BRANCH-$(flavor_dir)-b$(ia_build)"
    image_complete "$IMG_DIR/$name" && img="downloaded ✓" || img="not downloaded yet"
    [[ $OPT_SOURCE == local ]] && img="local"
    c=$(menu "   ┌┴┴┴┴┴┴┴┴┴┴┐
  ─┤ C.H.I.P. ├─   Image : $(flavor_name "$OPT_FLAVOR"), $OPT_BRANCH b$(ia_build)
  ─┤  ▓▓▓▓▓▓  ├─   Cache : $img
   └┬┬┬┬┬┬┬┬┬┬┘   CHIP  : $(usb_state)" \
      1 "How to connect the PocketCHIP (read this first)" \
      2 "FLASH NOW" \
      3 "Download image only (no CHIP needed)" \
      4 "Check connection" \
      5 "Advanced options (flavour, NAND, image source...)" \
      6 "Setup only (tools + USB permissions)" \
      7 "Troubleshooting" \
      r "Refresh status" \
      0 "Exit") || { clear; exit 0; }
    case $c in
      1) show_instructions ;;
      2) do_flash ;;
      3) download_only ;;
      4) check_connection ;;
      5) advanced_menu ;;
      6) run_setup ;;
      7) troubleshoot_menu ;;
      r) ;;
      0) clear; exit 0 ;;
    esac
  done
}

preflight
splash
main_menu
