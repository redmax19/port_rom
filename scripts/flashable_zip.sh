#!/usr/bin/env bash
# =============================================================================
#  QuantumROM — flashable_zip.sh
#  Generates a flashable zip using new.dat.br / transfer.list format.
#  Inspired by ArtisanROM/scripts/internal/build_flashable_zip.sh
#
#  Called by build_quantum.sh after a successful build.
#  Required exported vars:
#    QT_DIR        → root of the QuantumROM repo
#    DEVICES_DIR   → path to device configs
#    STOCK_DEVICE  → stock device model (e.g. SM-G980F)
#    TARGET_DEVICE → target device model (e.g. SM-A346E)
#    OUT_DIR       → build output directory
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${CYAN}[FLASH]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_DIR="${QT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEVICES_DIR="${DEVICES_DIR:-$QT_DIR/QuantumROM/Devices}"
OUT_DIR="${OUT_DIR:-$QT_DIR/OUT}"
lpmake="${lpmake:-$QT_DIR/bin/lp/lpmake}"

: "${STOCK_DEVICE:?  STOCK_DEVICE is not set.}"
: "${TARGET_DEVICE:? TARGET_DEVICE is not set.}"

DEVICE_DIR="$DEVICES_DIR/$STOCK_DEVICE"
EXTRA_DIR="$DEVICE_DIR/extra"
TODAY="${ZIP_DATE:-$(date '+%Y%m%d')}"
ZIP_NAME="QuantumROM-${STOCK_DEVICE}-${TODAY}.zip"
FINAL_ZIP="$OUT_DIR/$ZIP_NAME"

# Staging dir — META-INF must already exist here
STAGING="$QT_DIR/QuantumROM/flashable_zip"

# img2sdat from UN1CA/external_img2sdat (sixteen branch)
IMG2SDAT="$QT_DIR/bin/external_img2sdat/img2sdat"

# ── Cleanup on exit ───────────────────────────────────────────────────────────
trap 'echo -e "${YELLOW}[WARN]${RESET}  Interrupted — staging left as-is for inspection."' INT

# ── Check dependencies ────────────────────────────────────────────────────────
log "Checking dependencies..."
for cmd in python3 brotli 7z img2simg; do
    command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
done
[[ -x "$lpmake" ]] || die "lpmake not found or not executable: $lpmake"

# Clone external_img2sdat if not present
if [[ ! -f "$IMG2SDAT" ]]; then
    log "external_img2sdat not found — cloning UN1CA/external_img2sdat (sixteen branch)..."
    command -v git &>/dev/null || die "git is required to clone external_img2sdat."
    rm -rf "$QT_DIR/bin/external_img2sdat"
    git clone --depth=1 --branch sixteen \
        "https://github.com/UN1CA/external_img2sdat.git" \
        "$QT_DIR/bin/external_img2sdat" || \
        die "Failed to clone external_img2sdat."
    [[ -f "$IMG2SDAT" ]] || die "img2sdat not found after clone — check repo structure."
    ok "external_img2sdat cloned → $QT_DIR/bin/external_img2sdat"
else
    ok "external_img2sdat found."
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
log "Starting flashable zip generation..."
log "  Stock device  : $STOCK_DEVICE"
log "  Target device : $TARGET_DEVICE"
log "  Extra dir     : $EXTRA_DIR"
log "  Output        : $FINAL_ZIP"
echo ""

[[ -d "$DEVICE_DIR" ]] || die "Device directory not found: $DEVICE_DIR"
[[ -d "$EXTRA_DIR"  ]] || die "Extra directory not found: $EXTRA_DIR"
if [[ ! -d "$STAGING/META-INF" ]]; then
    die "META-INF not found in staging dir: $STAGING/META-INF"
fi

# ── Read device config ────────────────────────────────────────────────────────
DEVICE_CONFIG="$DEVICE_DIR/config"
[[ -f "$DEVICE_CONFIG" ]] || die "Device config not found: $DEVICE_CONFIG"

STOCK_FLASHABLE_ZIP_GROUP_NAME="$(grep -m1 '^STOCK_FLASHABLE_ZIP_GROUP_NAME=' "$DEVICE_CONFIG" | cut -d'=' -f2- | tr -d '"')"
STOCK_FLASHABLE_ZIP_GROUP_SIZE="$(grep -m1 '^STOCK_FLASHABLE_ZIP_GROUP_SIZE='  "$DEVICE_CONFIG" | cut -d'=' -f2- | tr -d '"')"

[[ -n "$STOCK_FLASHABLE_ZIP_GROUP_NAME" ]] || die "STOCK_FLASHABLE_ZIP_GROUP_NAME not found in $DEVICE_CONFIG"
[[ -n "$STOCK_FLASHABLE_ZIP_GROUP_SIZE" ]] || die "STOCK_FLASHABLE_ZIP_GROUP_SIZE not found in $DEVICE_CONFIG"

log "  Group name    : $STOCK_FLASHABLE_ZIP_GROUP_NAME"
log "  Group size    : $STOCK_FLASHABLE_ZIP_GROUP_SIZE"

# ── Locate partitions ─────────────────────────────────────────────────────────
SYSTEM_IMG="$OUT_DIR/system.img"
PRODUCT_IMG="$OUT_DIR/product.img"

ODM_IMG="$OUT_DIR/odm.img"
VENDOR_IMG="$OUT_DIR/vendor.img"

[[ -f "$SYSTEM_IMG"  ]] || { die "system.img not found at $SYSTEM_IMG"; }
[[ -f "$PRODUCT_IMG" ]] || { die "product.img not found at $PRODUCT_IMG"; }
[[ -f "$ODM_IMG"     ]] || { die "odm.img not found at $ODM_IMG"; }
[[ -f "$VENDOR_IMG"  ]] || { die "vendor.img not found at $VENDOR_IMG"; }

ok "system.img  → $SYSTEM_IMG"
ok "product.img → $PRODUCT_IMG"
ok "odm.img     → $ODM_IMG"
ok "vendor.img  → $VENDOR_IMG"

# ── Grab raw sizes BEFORE any conversion ─────────────────────────────────────
SZ_SYSTEM="$(stat  -c%s "$SYSTEM_IMG")"
SZ_PRODUCT="$(stat -c%s "$PRODUCT_IMG")"
SZ_ODM="$(stat    -c%s "$ODM_IMG")"
SZ_VENDOR="$(stat  -c%s "$VENDOR_IMG")"

log "Raw partition sizes:"
log "  system  : $SZ_SYSTEM bytes"
log "  product : $SZ_PRODUCT bytes"
log "  odm     : $SZ_ODM bytes"
log "  vendor  : $SZ_VENDOR bytes"

# Validate total fits inside the group (will be updated after alignment)
TOTAL=$(( SZ_SYSTEM + SZ_PRODUCT + SZ_ODM + SZ_VENDOR ))

# ── Prepare staging directory ─────────────────────────────────────────────────
log "Cleaning up leftover files from previous runs..."
mkdir -p "$STAGING"
# Remove old artifacts, preserve META-INF and unsparse_super_empty.img
find "$STAGING" -maxdepth 1 -type f -name "*.img" \
    ! -name "unsparse_super_empty.img" -delete
find "$STAGING" -maxdepth 1 -type f \( \
    -name "*.new.dat"    -o \
    -name "*.new.dat.br" -o \
    -name "*.patch.dat"  -o \
    -name "*.transfer.list" \
\) -delete
ok "Staging directory clean."

# ── Align sizes to 4096-block boundary (required by lpmake) ─────────────────
ALIGN=4096
align_up() { echo $(( (($1) + ALIGN - 1) / ALIGN * ALIGN )); }
SZ_SYSTEM_ALIGNED="$(align_up "$SZ_SYSTEM")"
SZ_PRODUCT_ALIGNED="$(align_up "$SZ_PRODUCT")"
SZ_ODM_ALIGNED="$(align_up "$SZ_ODM")"
SZ_VENDOR_ALIGNED="$(align_up "$SZ_VENDOR")"

log "Aligned partition sizes (block size $ALIGN):"
log "  system  : $SZ_SYSTEM → $SZ_SYSTEM_ALIGNED"
log "  product : $SZ_PRODUCT → $SZ_PRODUCT_ALIGNED"
log "  odm     : $SZ_ODM → $SZ_ODM_ALIGNED"
log "  vendor  : $SZ_VENDOR → $SZ_VENDOR_ALIGNED"

# Validate total fits inside the group (use aligned sizes)
TOTAL_ALIGNED=$(( SZ_SYSTEM_ALIGNED + SZ_PRODUCT_ALIGNED + SZ_ODM_ALIGNED + SZ_VENDOR_ALIGNED ))
if [[ "$TOTAL_ALIGNED" -gt "$STOCK_FLASHABLE_ZIP_GROUP_SIZE" ]]; then
    die "OS size ($TOTAL_ALIGNED) is bigger than the target group size ($STOCK_FLASHABLE_ZIP_GROUP_SIZE)"
fi
ok "Size check passed ($TOTAL_ALIGNED / $STOCK_FLASHABLE_ZIP_GROUP_SIZE bytes used)"

# ── Generate unsparse_super_empty.img via lpmake ──────────────────────────────
log "Generating unsparse_super_empty.img..."
"$lpmake" \
    --metadata-size 65536 \
    --super-name super \
    --metadata-slots 2 \
    --device "super:$STOCK_FLASHABLE_ZIP_GROUP_SIZE" \
    --group "$STOCK_FLASHABLE_ZIP_GROUP_NAME:$STOCK_FLASHABLE_ZIP_GROUP_SIZE" \
    --partition "system:readonly:${SZ_SYSTEM_ALIGNED}:${STOCK_FLASHABLE_ZIP_GROUP_NAME}" \
    --partition "vendor:readonly:${SZ_VENDOR_ALIGNED}:${STOCK_FLASHABLE_ZIP_GROUP_NAME}" \
    --partition "product:readonly:${SZ_PRODUCT_ALIGNED}:${STOCK_FLASHABLE_ZIP_GROUP_NAME}" \
    --partition "odm:readonly:${SZ_ODM_ALIGNED}:${STOCK_FLASHABLE_ZIP_GROUP_NAME}" \
    --output "$STAGING/unsparse_super_empty.img"
ok "unsparse_super_empty.img generated"

# ── Generate dynamic_partitions_op_list ───────────────────────────────────────
log "Generating dynamic_partitions_op_list..."
cat > "$STAGING/dynamic_partitions_op_list" << EOF
# Remove all existing dynamic partitions and groups before applying full OTA
remove_all_groups
# Add group ${STOCK_FLASHABLE_ZIP_GROUP_NAME} with maximum size ${STOCK_FLASHABLE_ZIP_GROUP_SIZE}
add_group ${STOCK_FLASHABLE_ZIP_GROUP_NAME} ${STOCK_FLASHABLE_ZIP_GROUP_SIZE}
# Add partition system to group ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
add system ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
# Add partition vendor to group ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
add vendor ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
# Add partition product to group ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
add product ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
# Add partition odm to group ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
add odm ${STOCK_FLASHABLE_ZIP_GROUP_NAME}
# Grow partition system from 0 to ${SZ_SYSTEM_ALIGNED}
resize system ${SZ_SYSTEM_ALIGNED}
# Grow partition vendor from 0 to ${SZ_VENDOR_ALIGNED}
resize vendor ${SZ_VENDOR_ALIGNED}
# Grow partition product from 0 to ${SZ_PRODUCT_ALIGNED}
resize product ${SZ_PRODUCT_ALIGNED}
# Grow partition odm from 0 to ${SZ_ODM_ALIGNED}
resize odm ${SZ_ODM_ALIGNED}
EOF
ok "dynamic_partitions_op_list generated"

# ── Helper: img → new.dat + transfer.list → new.dat.br + patch.dat ───────────
convert_partition() {
    local name="$1"
    local src_img="$2"

    log "Converting $name.img → $name.new.dat.br ..."

    local work_dir
    work_dir="$(mktemp -d)"

    # img2sdat: -o output dir, -B block map, TARGET_IMAGE
    python3 "$IMG2SDAT" \
        -o "$work_dir" \
        -B "$work_dir/${name}.map" \
        "$src_img"

    # Resolve output basename (tool names files after the input image)
    local base
    base="$(basename "$src_img" .img)"

    [[ -f "$work_dir/${base}.new.dat"       ]] || die "img2sdat did not produce ${base}.new.dat"
    [[ -f "$work_dir/${base}.transfer.list" ]] || die "img2sdat did not produce ${base}.transfer.list"

    # Rename to canonical partition name if basename differs
    if [[ "$base" != "$name" ]]; then
        mv "$work_dir/${base}.new.dat"       "$work_dir/${name}.new.dat"
        mv "$work_dir/${base}.transfer.list" "$work_dir/${name}.transfer.list"
    fi

    # Ensure LF line endings
    sed -i 's/\r//' "$work_dir/${name}.transfer.list"

    # Copy transfer.list to staging
    cp -f "$work_dir/${name}.transfer.list" "$STAGING/${name}.transfer.list"

    # Compress new.dat → new.dat.br (quality 6, keep source)
    brotli --quality=6 \
           --output="$STAGING/${name}.new.dat.br" \
           "$work_dir/${name}.new.dat"

    rm -rf "$work_dir"

    # Empty patch.dat required by updater-script for full OTA
    touch "$STAGING/${name}.patch.dat"

    ok "$name.new.dat.br + $name.transfer.list + $name.patch.dat ready"
}

# ── Convert all 4 partitions ──────────────────────────────────────────────────
convert_partition "system"  "$SYSTEM_IMG"
convert_partition "product" "$PRODUCT_IMG"
convert_partition "odm"     "$ODM_IMG"
convert_partition "vendor"  "$VENDOR_IMG"

# ── Generate updater-script ───────────────────────────────────────────────────
log "Generating updater-script..."
mkdir -p "$STAGING/META-INF/com/google/android"
SCRIPT_FILE="$STAGING/META-INF/com/google/android/updater-script"

cat > "$SCRIPT_FILE" << 'EOF'
ui_print(" ");
ui_print("****************************************************");
ui_print("Welcome to QuantumROM Port: $TARGET_DEVICE --> $STOCK_DEVICE");
ui_print("Initial QuantumROM build system coded by Abdullah Al Noman");
ui_print("Special thanks to all QuantumROM Maintainers, Contribuitors and Testers");
ui_print("****************************************************");
ui_print("One UI version: 8.5");
ui_print("****************************************************");
ui_print("After installation, it is highly recommended to FORMAT DATA as follows:");
ui_print("     Wipe -> Format Data");
ui_print("Hint: FORMAT, not WIPE or FACTORY RESET!");
ui_print(" ");
ui_print("If you decide to not format, unexpected issues may occur and given support will be limited.");
ui_print(" ");
ui_print("If you wish to proceed with the installer, please press the Volume UP button.");
ui_print("Otherwise, hold the Volume DOWN + POWER buttons for 7 seconds to force reboot.");

assert(run_program("/sbin/sh", "-c", "while true; do getevent -lc 1 | grep -q -m1 'KEY_VOLUMEUP' && exit 0; sleep 1; done"));

ui_print(" ");
ui_print("Please press Volume UP");
ui_print(" ");
ui_print("Proceeding...!");
ui_print(" ");
ui_print("****************************************************");
ui_print("       Q U A N T U M ---- R O M !");
ui_print("****************************************************");
EOF

# Append the dynamic parts (variables need to be expanded here)
cat >> "$SCRIPT_FILE" << EOF
# Update dynamic partition metadata
assert(update_dynamic_partitions(package_extract_file("dynamic_partitions_op_list"), package_extract_file("unsparse_super_empty.img")));
show_progress(1, 200);
# Patch partition system
ui_print("Patching system image unconditionally...");
block_image_update(map_partition("system"), package_extract_file("system.transfer.list"), "system.new.dat.br", "system.patch.dat") ||
  abort("E1001: Failed to update system image.");
# Patch partition product
ui_print("Patching product image unconditionally...");
block_image_update(map_partition("product"), package_extract_file("product.transfer.list"), "product.new.dat.br", "product.patch.dat") ||
  abort("E2001: Failed to update product image.");
# Patch partition vendor
ui_print("Patching vendor image unconditionally...");
block_image_update(map_partition("vendor"), package_extract_file("vendor.transfer.list"), "vendor.new.dat.br", "vendor.patch.dat") ||
  abort("E2001: Failed to update vendor image.");
# Patch partition odm
ui_print("Patching odm image unconditionally...");
block_image_update(map_partition("odm"), package_extract_file("odm.transfer.list"), "odm.new.dat.br", "odm.patch.dat") ||
  abort("E2001: Failed to update odm image.");
# --- End patching dynamic partitions ---
set_progress(0);
ui_print("Installing kernel...");
package_extract_file("dtbo.img", "/dev/block/by-name/dtbo");
package_extract_file("boot.img", "/dev/block/by-name/boot");
set_progress(1);
ui_print(" ");
ui_print("****************************************************");
ui_print(" ");
set_progress(1);
EOF

ok "updater-script generated"

# ── Copy boot and dtbo (no compression) ──────────────────────────────────────
log "Looking for boot-dtbo zip in $EXTRA_DIR ..."
BOOT_DTBO_ZIP="$(find "$EXTRA_DIR" -maxdepth 2 -type f -name "boot-dtbo.*.zip" | head -n1)"
[[ -n "$BOOT_DTBO_ZIP" ]] || die "No boot-dtbo.<codename>.zip found inside $EXTRA_DIR"
ok "Found: $(basename "$BOOT_DTBO_ZIP")"

log "Extracting boot.img and dtbo.img..."
BOOT_TMP="$(mktemp -d)"
trap 'rm -rf "$BOOT_TMP"' EXIT

7z e -y "$BOOT_DTBO_ZIP" -o"$BOOT_TMP" boot.img dtbo.img >/dev/null 2>&1 || \
    unzip -o "$BOOT_DTBO_ZIP" boot.img dtbo.img -d "$BOOT_TMP" >/dev/null 2>&1

[[ -f "$BOOT_TMP/boot.img" ]] || die "boot.img not found inside $(basename "$BOOT_DTBO_ZIP")"
[[ -f "$BOOT_TMP/dtbo.img" ]] || die "dtbo.img not found inside $(basename "$BOOT_DTBO_ZIP")"

cp -f "$BOOT_TMP/boot.img" "$STAGING/boot.img"
cp -f "$BOOT_TMP/dtbo.img" "$STAGING/dtbo.img"
ok "boot.img and dtbo.img copied (uncompressed)"

# ── Staging summary ───────────────────────────────────────────────────────────
echo ""
log "Flashable zip contents:"
for f in "$STAGING"/*; do
    sz="$(du -sh "$f" 2>/dev/null | cut -f1)"
    echo -e "  ${BOLD}$(basename "$f")${RESET}  ($sz)"
done
echo ""

# ── Pack into final zip (two passes, same as ArtisanROM) ─────────────────────
#  Pass 1 — store patch.dat + META-INF/com/android with no compression (mx=0)
#  Pass 2 — compress everything else with mx=3, excluding pass-1 files
log "Packing $ZIP_NAME ..."
mkdir -p "$OUT_DIR"
ROM_ZIP_TMP="$STAGING/rom.zip"
rm -f "$ROM_ZIP_TMP"

cd "$STAGING"
7z a -tzip -mx=0 -mmt="$(nproc)" "$ROM_ZIP_TMP" \
    -r "*.patch.dat" \
    -ir!"META-INF/com/google/android/*" 2>/dev/null || true

7z a -tzip -mx=3 -mmt="$(nproc)" "$ROM_ZIP_TMP" \
    -r "*" \
    -xr!"META-INF/com/google/android/*" \
    -x!"*.patch.dat" \
    -x!"rom.zip"
cd - >/dev/null

mv -f "$ROM_ZIP_TMP" "$FINAL_ZIP"

ok "Flashable zip ready → $FINAL_ZIP"
echo -e "${BOLD}${GREEN}✅  flashable_zip.sh done! → $FINAL_ZIP${RESET}"
