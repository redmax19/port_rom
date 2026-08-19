#!/usr/bin/env bash
# =============================================================================
#  QuantumROM Tools — build_quantum.sh
#  Local equivalent of .github/workflows/sixteen.yml
# =============================================================================
#
#  USAGE:
#    chmod +x build_quantum.sh
#    ./build_quantum.sh            → normal build (asks about upload)
#    ./build_quantum.sh --clean-all → wipes the entire build environment
#
# =============================================================================
#                        ★  CONFIGURATION AREA  ★
#  Edit the variables below before running the script.
# =============================================================================

# Stock device model or "None"
STOCK_DEVICE="SM-G780F"

# Set to True if your kernel BPF version is 5.4 (lower than 5.10)
USE_UI_8_TETHERING_APEX="True"

# Target device model
TARGET_DEVICE="SM-S901B"

# Target device CSC
TARGET_DEVICE_CSC="EUX"

# Target device IMEI
TARGET_DEVICE_IMEI="350330051234562"

# Output filesystem: erofs | ext4 | f2fs
OUTPUT_FILESYSTEM="erofs"

# Specific target firmware version (leave empty to download the latest)
TARGET_FW_VERSION=""

# Generate a flashable zip at the end of the build? (EXPERIMENTAL)
# If false, an images zip (raw .img + fastboot sh script) will be generated instead.
CREATE_FLASHABLE_ZIP="false"

# =============================================================================
#                      END OF CONFIGURATION AREA
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Base directories ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$SCRIPT_DIR/FW"
WORK_DIR="$SCRIPT_DIR/WORK"
OUT_DIR="$SCRIPT_DIR/OUT"

# ── --clean-all ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--clean-all" ]]; then
    echo -e "${BOLD}${RED}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║        ⚠  FULL ENVIRONMENT CLEANUP           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${RESET}"
    warn "This will remove the following directories: FW/, WORK/ and OUT/"
    read -rp "Are you sure? [y/N]: " _confirm
    if [[ "${_confirm,,}" == "y" ]]; then
        log "Removing FW/ ..."
        rm -rf "$FW_DIR"
        log "Removing WORK/ ..."
        rm -rf "$WORK_DIR"
        log "Removing OUT/ ..."
        rm -rf "$OUT_DIR"
        ok "Environment cleaned successfully."
    else
        log "Operation cancelled."
    fi
    exit 0
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║         QuantumROM Tools — Sixteen           ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Upload prompt — before anything else ─────────────────────────────────────
DO_UPLOAD="false"
read -rp "$(echo -e "${BOLD}Upload to GoFile and create a release after the build? [y/N]:${RESET} ")" _upload_ans
if [[ "${_upload_ans,,}" == "y" ]]; then
    DO_UPLOAD="true"
    if [[ -z "${GIT_TOKEN:-}" ]]; then
        warn "GIT_TOKEN environment variable is not set."
        warn "release.sh may fail if it requires it."
        warn "Export it before running: export GIT_TOKEN=your_token"
        read -rp "Continue anyway? [y/N]: " _tok_ans
        [[ "${_tok_ans,,}" == "y" ]] || die "Aborted by user."
    fi
    ok "Upload enabled at the end of the build."
else
    log "Upload disabled. The artifact will be saved to OUT/ only."
fi

echo ""

# ── Configuration summary ─────────────────────────────────────────────────────
echo -e "${BOLD}┌─────────────────────────────────────────────────────┐"
echo -e "│              Build Configuration                    │"
echo -e "└─────────────────────────────────────────────────────┘${RESET}"
echo -e "  ${BOLD}Stock device:${RESET}            $STOCK_DEVICE"
echo -e "  ${BOLD}Target device:${RESET}           $TARGET_DEVICE"
echo -e "  ${BOLD}Target CSC:${RESET}              $TARGET_DEVICE_CSC"
echo -e "  ${BOLD}Target IMEI:${RESET}             $TARGET_DEVICE_IMEI"
echo -e "  ${BOLD}Output filesystem:${RESET}       $OUTPUT_FILESYSTEM"
echo -e "  ${BOLD}UI 8 Tethering APEX:${RESET}     $USE_UI_8_TETHERING_APEX"
if [[ -n "$TARGET_FW_VERSION" ]]; then
    echo -e "  ${BOLD}Firmware version:${RESET}        $TARGET_FW_VERSION"
else
    echo -e "  ${BOLD}Firmware version:${RESET}        ${YELLOW}(latest)${RESET}"
fi
echo -e "  ${BOLD}Upload after build:${RESET}      $DO_UPLOAD"
echo -e "  ${BOLD}Create flashable zip:${RESET}    $CREATE_FLASHABLE_ZIP"
echo ""
echo -e "${YELLOW}  ⚠  Please make sure all settings above are correct before proceeding.${RESET}"
echo ""
read -rp "$(echo -e "${BOLD}  Press ENTER to continue or Ctrl+C to abort...${RESET}")" _

echo ""

# ── STOCK_DEVICE validation ───────────────────────────────────────────────────
log "Validating STOCK_DEVICE: $STOCK_DEVICE"
if [[ "$STOCK_DEVICE" != "None" ]]; then
    DEVICE_PATH="$SCRIPT_DIR/QuantumROM/Devices/$STOCK_DEVICE"
    if [[ ! -d "$DEVICE_PATH" ]]; then
        die "❌ $STOCK_DEVICE is not supported by this tool. (path not found: $DEVICE_PATH)"
    fi
fi
ok "STOCK_DEVICE validated."

# ── Check and install dependencies ───────────────────────────────────────────
#  Exact package list from the YML (Install Dependencies step)
APT_DEPS=(
    p7zip-full lz4 liblz4-1 liblz4-dev libzstd1 libzstd-dev
    build-essential android-sdk-libsparse-utils f2fs-tools
    fuse2fs fuse e2fsprogs python3 python3-pip
    zipalign unzip openjdk-21-jdk jq perl xxd kmod erofs-utils
    "linux-modules-extra-$(uname -r)"
)

log "Checking system dependencies..."
MISSING_PKGS=()
for pkg in "${APT_DEPS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Missing packages (${#MISSING_PKGS[@]}): ${MISSING_PKGS[*]}"
    log "Installing missing packages..."
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING_PKGS[@]}"
    ok "Packages installed."
else
    ok "All apt packages are already installed."
fi

log "Loading f2fs module..."
sudo modprobe f2fs || warn "Could not load f2fs module (may already be loaded)."

# Check samloader (pip)
log "Checking samloader..."
if ! python3 -c "import samloader" &>/dev/null 2>&1; then
    log "samloader not found — installing..."
    sudo pip3 install \
        git+https://github.com/SN-Abdullah-Al-Noman/samloader.git \
        --break-system-packages
    ok "samloader installed."
else
    ok "samloader is already installed."
fi

log "Creating work directories..."
mkdir -p "$FW_DIR" "$WORK_DIR" "$OUT_DIR"
ok "All dependencies OK."

# ── Check if firmware is already present ─────────────────────────────────────
#
#  Search order (broad → narrow):
#    1. .img anywhere inside FW/  (fully extracted)
#    2. .md5 anywhere inside FW/  (downloaded, not yet extracted)
#
#  This covers layouts like FW/SM-A346E/, FW/, or any sub-folder the
#  downloader may create.
#
FW_DEVICE_DIR="$FW_DIR/$TARGET_DEVICE"
FIRMWARE_READY="false"

log "Scanning for existing firmware under $FW_DIR ..."

# Look for .img files recursively inside FW/ (fully extracted)
if find "$FW_DIR" -type f -name "*.img" 2>/dev/null | grep -q .; then
    FIRMWARE_READY="true"
    warn "Extracted firmware (.img) already found under $FW_DIR — skipping download and extraction."

# Look for any known firmware archive format (downloaded but not yet extracted)
# Covers: .zip .md5 .enc2 .enc4 — all formats samloader/Samsung may produce
elif find "$FW_DIR" -type f \( -name "*.zip" -o -name "*.md5" -o -name "*.enc2" -o -name "*.enc4" \) 2>/dev/null | grep -q .; then
    log "Firmware archive found under $FW_DIR — skipping download, will extract."
    FIRMWARE_READY="skip_download"

else
    log "No existing firmware found — download required."
fi

# ── Stub GITHUB_ENV so QuantumRom.sh doesn't crash outside CI ────────────────
#  The script uses `>> $GITHUB_ENV` to export vars in GitHub Actions.
#  Locally we redirect those writes to /dev/null via a temp file.
if [[ -z "${GITHUB_ENV:-}" ]]; then
    GITHUB_ENV="$(mktemp)"
    export GITHUB_ENV
    trap 'rm -f "$GITHUB_ENV"' EXIT
fi

# ── Firmware download ─────────────────────────────────────────────────────────
if [[ "$FIRMWARE_READY" == "false" ]]; then
    log "Downloading firmware for $TARGET_DEVICE / CSC: $TARGET_DEVICE_CSC ..."
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/scripts/QuantumRom.sh"
    DOWNLOAD_FIRMWARE \
        "$TARGET_DEVICE" \
        "$TARGET_DEVICE_CSC" \
        "$TARGET_DEVICE_IMEI" \
        "$FW_DIR" \
        "$TARGET_FW_VERSION"
    ok "Download complete."
else
    [[ "$FIRMWARE_READY" == "true" ]] && ok "Download skipped (firmware already present)."
fi

# ── Firmware extraction ───────────────────────────────────────────────────────
if [[ "$FIRMWARE_READY" != "true" ]]; then
    log "Extracting firmware from $FW_DEVICE_DIR ..."
    # shellcheck source=/dev/null
    [[ "$FIRMWARE_READY" == "skip_download" ]] && source "$SCRIPT_DIR/scripts/QuantumRom.sh"
    EXTRACT_FIRMWARE "$FW_DEVICE_DIR"
    ok "Extraction complete."
else
    ok "Extraction skipped (firmware already present)."
fi

# ── Main build ────────────────────────────────────────────────────────────────
log "Starting ROM build: $STOCK_DEVICE → $TARGET_DEVICE ..."
sudo bash "$SCRIPT_DIR/sixteen.sh" \
    "$STOCK_DEVICE" \
    "$USE_UI_8_TETHERING_APEX" \
    "$TARGET_DEVICE" \
    "$TARGET_DEVICE_CSC" \
    "$TARGET_DEVICE_IMEI" \
    "$OUTPUT_FILESYSTEM"
ok "Build complete."

# ── Zip ───────────────────────────────────────────────────────────────────────
BUILD_TIME="$(TZ='Asia/Dhaka' date '+%Y-%m-%d %I:%M:%S %p UTC+6')"
ZIP_DATE="$(date '+%Y%m%d')"
log "Build time (UTC+6): $BUILD_TIME"

if [[ "$CREATE_FLASHABLE_ZIP" == "true" ]]; then
    log "Generating flashable zip..."
    FLASHABLE_SCRIPT="$SCRIPT_DIR/scripts/flashable_zip.sh"
    [[ -f "$FLASHABLE_SCRIPT" ]] || die "flashable_zip.sh not found at: $FLASHABLE_SCRIPT"
    export QT_DIR="$SCRIPT_DIR" DEVICES_DIR="$SCRIPT_DIR/QuantumROM/Devices" \
           OUT_DIR STOCK_DEVICE TARGET_DEVICE lpmake BUILD_TIME ZIP_DATE
    bash "$FLASHABLE_SCRIPT"
    ZIP_PATH="$OUT_DIR/QuantumROM-${STOCK_DEVICE}-${ZIP_DATE}.zip"
    ok "Flashable zip done."
else
    log "Generating images zip..."
    IMAGES_SCRIPT="$SCRIPT_DIR/scripts/images_zip.sh"
    [[ -f "$IMAGES_SCRIPT" ]] || die "images_zip.sh not found at: $IMAGES_SCRIPT"
    export QT_DIR="$SCRIPT_DIR" DEVICES_DIR="$SCRIPT_DIR/QuantumROM/Devices" \
           OUT_DIR STOCK_DEVICE TARGET_DEVICE BUILD_TIME ZIP_DATE
    bash "$IMAGES_SCRIPT"
    ZIP_PATH="$OUT_DIR/QuantumROM-${STOCK_DEVICE}-${ZIP_DATE}-IMAGES.zip"
    ok "Images zip done."
fi

# ── Upload / Release ──────────────────────────────────────────────────────────
if [[ "$DO_UPLOAD" == "true" ]]; then
    log "Starting GoFile upload and release creation..."
    export ZIP_PATH STOCK_DEVICE TARGET_DEVICE OUTPUT_FILESYSTEM \
           USE_UI_8_TETHERING_APEX BUILD_TIME
    bash "$SCRIPT_DIR/release.sh"
    ok "Upload and release complete."
else
    log "Upload skipped as chosen at startup."
fi

echo ""
echo -e "${BOLD}${GREEN}✅  All done! Check OUT dir for build artifact!"
