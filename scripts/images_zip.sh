#!/usr/bin/env bash
# =============================================================================
#  QuantumROM — images_zip.sh
#  Packages raw .img files + a fastboot flash script into a zip.
#
#  Called by build_quantum.sh when CREATE_FLASHABLE_ZIP="false".
#  Required exported vars:
#    QT_DIR        → root of the QuantumROM repo
#    DEVICES_DIR   → path to device configs
#    STOCK_DEVICE  → stock device model (e.g. SM-G980F)
#    TARGET_DEVICE → target device model (e.g. SM-A346E)
#    OUT_DIR       → build output directory
#
#  Output zip structure:
#    QuantumROM-SM-G980F-20260628-IMAGES.zip
#    ├── system.img          (always)
#    ├── product.img         (always)
#    ├── vendor.img          (optional)
#    ├── odm.img             (optional)
#    ├── boot.img            (optional, paired with dtbo)
#    ├── dtbo.img            (optional, paired with boot)
#    ├── bin/                (Windows fastboot binaries, if present)
#    ├── flash.sh            (Linux/Mac — only includes present partitions)
#    ├── flash.bat           (Windows — only includes present partitions)
#    └── extras/             (everything else from device extra/)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${CYAN}[IMAGES]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}     $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}   $*"; }
die()   { echo -e "${RED}[ERROR]${RESET}  $*" >&2; exit 1; }

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_DIR="${QT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEVICES_DIR="${DEVICES_DIR:-$QT_DIR/QuantumROM/Devices}"
OUT_DIR="${OUT_DIR:-$QT_DIR/OUT}"

: "${STOCK_DEVICE:?  STOCK_DEVICE is not set.}"
: "${TARGET_DEVICE:? TARGET_DEVICE is not set.}"

DEVICE_DIR="$DEVICES_DIR/$STOCK_DEVICE"
EXTRA_DIR="$DEVICE_DIR/extra"
TODAY="${ZIP_DATE:-$(date '+%Y%m%d')}"
ZIP_NAME="QuantumROM-${STOCK_DEVICE}-${TODAY}-IMAGES.zip"
FINAL_ZIP="$OUT_DIR/$ZIP_NAME"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

log "Starting images zip generation..."
log "  Stock device : $STOCK_DEVICE"
log "  Target device: $TARGET_DEVICE"
log "  Output       : $FINAL_ZIP"
echo ""

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ -d "$DEVICE_DIR" ]] || die "Device directory not found: $DEVICE_DIR"
[[ -d "$EXTRA_DIR"  ]] || die "Extra directory not found: $EXTRA_DIR"

# ── Locate partitions ─────────────────────────────────────────────────────────
# Required
SYSTEM_IMG="$OUT_DIR/system.img"
PRODUCT_IMG="$OUT_DIR/product.img"
[[ -f "$SYSTEM_IMG"  ]] || die "system.img not found at $SYSTEM_IMG"
[[ -f "$PRODUCT_IMG" ]] || die "product.img not found at $PRODUCT_IMG"

# Optional — independent
HAS_VENDOR=false
HAS_ODM=false
HAS_BOOT=false   # boot and dtbo are treated as a pair

VENDOR_IMG="$OUT_DIR/vendor.img"
ODM_IMG="$OUT_DIR/odm.img"

[[ -f "$VENDOR_IMG" ]] && HAS_VENDOR=true || warn "vendor.img not found — skipping"
[[ -f "$ODM_IMG"    ]] && HAS_ODM=true    || warn "odm.img not found — skipping"

# Boot + dtbo — independent
HAS_BOOT=false
HAS_DTBO=false

BOOT_TMP="$(mktemp -d)"
BOOT_DTBO_ZIP="$(find "$EXTRA_DIR" -maxdepth 2 -type f -name "boot-dtbo.*.zip" | head -n1)"
if [[ -n "$BOOT_DTBO_ZIP" ]]; then
    log "Found boot-dtbo zip: $(basename "$BOOT_DTBO_ZIP")"
    7z e -y "$BOOT_DTBO_ZIP" -o"$BOOT_TMP" boot.img dtbo.img >/dev/null 2>&1 || \
        unzip -o "$BOOT_DTBO_ZIP" boot.img dtbo.img -d "$BOOT_TMP" >/dev/null 2>&1
    [[ -f "$BOOT_TMP/boot.img" ]] && HAS_BOOT=true && ok "boot.img extracted from zip." \
        || warn "boot.img not found inside $(basename "$BOOT_DTBO_ZIP") — skipping"
    [[ -f "$BOOT_TMP/dtbo.img" ]] && HAS_DTBO=true && ok "dtbo.img extracted from zip." \
        || warn "dtbo.img not found inside $(basename "$BOOT_DTBO_ZIP") — skipping"
else
    warn "No boot-dtbo.<codename>.zip found — scanning extras/ for .img files..."

    # Scan all .img files in extras/ and identify them by magic bytes
    while IFS= read -r -d '' img; do
        fname="$(basename "$img")"

        # Read magic: Android boot image starts with "ANDROID!" (0x414e44524f494421)
        magic="$(xxd -p -l 8 "$img" 2>/dev/null | tr -d ' \n')"

        if [[ "$magic" == "414e44524f494421"* ]]; then
            # Determine if it's boot or dtbo by checking header type at offset 0x28
            # boot header version >= 2 has dtbo fields; but simplest heuristic:
            # if filename contains dtbo, treat as dtbo — otherwise treat as boot
            case "${fname,,}" in
                *dtbo*)
                    cp -f "$img" "$BOOT_TMP/dtbo.img"
                    HAS_DTBO=true
                    ok "Found dtbo.img via magic scan: $fname"
                    ;;
                *)
                    if ! $HAS_BOOT; then
                        cp -f "$img" "$BOOT_TMP/boot.img"
                        HAS_BOOT=true
                        ok "Found boot.img via magic scan: $fname"
                    fi
                    ;;
            esac
        fi
    done < <(find "$EXTRA_DIR" -maxdepth 1 -type f -name "*.img" -print0)

    $HAS_BOOT || warn "No valid boot.img found in extras/ — skipping boot flash"
    $HAS_DTBO || warn "No valid dtbo.img found in extras/ — skipping dtbo flash"
fi

# ── Copy partitions to staging ────────────────────────────────────────────────
log "Copying partition images..."
cp -f "$SYSTEM_IMG"  "$STAGING/system.img"  && ok "system.img  copied"
cp -f "$PRODUCT_IMG" "$STAGING/product.img" && ok "product.img copied"
$HAS_VENDOR && cp -f "$VENDOR_IMG" "$STAGING/vendor.img" && ok "vendor.img  copied"
$HAS_ODM    && cp -f "$ODM_IMG"    "$STAGING/odm.img"    && ok "odm.img     copied"
$HAS_BOOT   && cp -f "$BOOT_TMP/boot.img" "$STAGING/boot.img" && ok "boot.img copied"
$HAS_DTBO   && cp -f "$BOOT_TMP/dtbo.img" "$STAGING/dtbo.img" && ok "dtbo.img copied"
rm -rf "$BOOT_TMP"

# ── Copy fastboot binaries for Windows ────────────────────────────────────────
IMAGES_ZIP_DIR="$QT_DIR/QuantumROM/images_zip"
BIN_DIR="$IMAGES_ZIP_DIR/bin"
if [[ -d "$BIN_DIR" ]]; then
    log "Copying fastboot binaries (Windows)..."
    cp -r "$BIN_DIR" "$STAGING/bin"
    ok "bin/ copied."
else
    warn "bin/ not found at $BIN_DIR — Windows flash.bat will not work."
fi

# ── Generate flash.sh ─────────────────────────────────────────────────────────
log "Generating flash.sh..."

# Build super flash lines
SUPER_LINES_SH='fastboot flash system  "$SCRIPT_DIR/system.img"  && ok "system  flashed"
fastboot flash product "$SCRIPT_DIR/product.img" && ok "product flashed"'
$HAS_VENDOR && SUPER_LINES_SH+='
fastboot flash vendor  "$SCRIPT_DIR/vendor.img"  && ok "vendor  flashed"'
$HAS_ODM    && SUPER_LINES_SH+='
fastboot flash odm     "$SCRIPT_DIR/odm.img"     && ok "odm     flashed"'

# Build kernel flash lines
KERNEL_SECTION_SH=""
if $HAS_BOOT || $HAS_DTBO; then
    KERNEL_SECTION_SH='
log "Flashing kernel partitions..."'
    $HAS_BOOT && KERNEL_SECTION_SH+='
fastboot flash boot    "$SCRIPT_DIR/boot.img"    && ok "boot    flashed"'
    $HAS_DTBO && KERNEL_SECTION_SH+='
fastboot flash dtbo    "$SCRIPT_DIR/dtbo.img"    && ok "dtbo    flashed"'
fi

cat > "$STAGING/flash.sh" << EOF
#!/usr/bin/env bash
# =============================================================================
#  QuantumROM — flash.sh
#  Port: $TARGET_DEVICE -> $STOCK_DEVICE | Built: $TODAY
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()  { echo -e "\${CYAN}[FLASH]\${RESET} \$*"; }
ok()   { echo -e "\${GREEN}[OK]\${RESET}    \$*"; }
die()  { echo -e "\${RED}[ERROR]\${RESET} \$*" >&2; exit 1; }

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
command -v fastboot &>/dev/null || die "fastboot not found. Install android-tools-fastboot."

echo ""
echo -e "\${BOLD}================================================="
echo -e "  QuantumROM Image Flasher"
echo -e "  Port: $TARGET_DEVICE -> $STOCK_DEVICE"
echo -e "=================================================\${RESET}"
echo ""

log "Checking fastboot device..."
fastboot devices | grep -q "fastboot" || die "No device found in fastboot mode."

log "Wiping data and cache..."
fastboot -w && ok "Wipe complete" || die "Wipe failed."

log "Flashing super partitions..."
$SUPER_LINES_SH
$KERNEL_SECTION_SH

echo ""
echo -e "\${BOLD}\${GREEN}All done! Rebooting...\${RESET}"
fastboot reboot
EOF
chmod +x "$STAGING/flash.sh"
ok "flash.sh generated."

# ── Generate flash.bat ────────────────────────────────────────────────────────
log "Generating flash.bat..."

# Build super flash lines for bat
SUPER_LINES_BAT='!FB! flash system  "%~dp0system.img"  && echo [OK] system  flashed
!FB! flash product "%~dp0product.img" && echo [OK] product flashed'
$HAS_VENDOR && SUPER_LINES_BAT+='
!FB! flash vendor  "%~dp0vendor.img"  && echo [OK] vendor  flashed'
$HAS_ODM    && SUPER_LINES_BAT+='
!FB! flash odm     "%~dp0odm.img"     && echo [OK] odm     flashed'

# Build kernel flash lines for bat
KERNEL_SECTION_BAT=""
if $HAS_BOOT || $HAS_DTBO; then
    KERNEL_SECTION_BAT='
echo [FLASH] Flashing kernel partitions...'
    $HAS_BOOT && KERNEL_SECTION_BAT+='
!FB! flash boot    "%~dp0boot.img"    && echo [OK] boot    flashed'
    $HAS_DTBO && KERNEL_SECTION_BAT+='
!FB! flash dtbo    "%~dp0dtbo.img"    && echo [OK] dtbo    flashed'
fi

cat > "$STAGING/flash.bat" << EOF
@echo off
setlocal enabledelayedexpansion
title QuantumROM Image Flasher

echo =================================================
echo   QuantumROM Image Flasher
echo   Port: $TARGET_DEVICE -^> $STOCK_DEVICE
echo   Built: $TODAY
echo =================================================
echo.

set "FB=%~dp0bin\\fastboot.exe"

echo [FLASH] Checking fastboot device...
!FB! devices | findstr "fastboot" >nul
if errorlevel 1 ( echo [ERROR] No device in fastboot mode. & pause & exit /b 1 )

echo [FLASH] Wiping data and cache...
!FB! -w
if errorlevel 1 ( echo [ERROR] Wipe failed. & pause & exit /b 1 )

echo [FLASH] Flashing super partitions...
$SUPER_LINES_BAT
$KERNEL_SECTION_BAT

echo.
echo [OK] Flash complete, press ENTER to reboot...
pause >nul
!FB! reboot
endlocal
EOF
ok "flash.bat generated."

# ── Staging summary ───────────────────────────────────────────────────────────
echo ""
log "Images zip contents:"
find "$STAGING" | sed "s|$STAGING||" | sort | while read -r f; do
    [[ -z "$f" ]] && continue
    sz="$(du -sh "$STAGING$f" 2>/dev/null | cut -f1)"
    echo -e "  ${BOLD}$f${RESET}  ($sz)"
done
echo ""

# ── Pack zip ──────────────────────────────────────────────────────────────────
log "Packing $ZIP_NAME ..."
mkdir -p "$OUT_DIR"
cd "$STAGING"
7z a -tzip "$FINAL_ZIP" ./* -mx=0 >/dev/null
cd - >/dev/null

ok "Images zip ready → $FINAL_ZIP"
echo -e "${BOLD}${GREEN}✅  images_zip.sh done! → $FINAL_ZIP${RESET}"
