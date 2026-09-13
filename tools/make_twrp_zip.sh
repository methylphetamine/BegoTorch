#!/usr/bin/env bash
#
# make_twrp_zip.sh — assemble the TWRP-flashable package for BegoTorch.
#
# Output:  dist/begotorch-flashable.zip  (plus README explaining it)
#
# What this zip contains
# ----------------------
# The point of "flashable" is that BegoTorch is installed *already privileged*:
#
#   * config/begotorch.cml  — the component manifest that grants the app the
#     filesystem capability to write the torch brightness node. This is the
#     "has su access baked in" part: no su, no Magisk, no KernelSU, no runtime
#     root grant.
#   * build/app.far         — the built Fuchsia package binary (includes the
#     APK and the fused manifest). If only the Android APK was produced, the
#     APK is used instead.
#   * build/...apk          — the Flutter output APK.
#   * twrp/flash.sh         — run by the TWRP "Open Terminal" step to drop the
#     package into the system partition (TWRP recovery runs privileged, so it
#     can place the file even though the released app runs sandboxed).
#   * twrp/install.sh       — post-flash on-device helper used by flash.sh.
#   * TwrJSON  / README     — human- and tool-readable instructions.
#
# Usage
# -----
#   CI:    tools/make_twrp_zip.sh --apk build/app/outputs/flutter-apk/app-release.apk
#   Local: build with `flutter build apk --release` first, then run the above.
#
# The device-specific system mount point defaults to /system; override with
#   --sys-mount /system   (begonia packages conventionally live under /system)
# The torch node and the package name are read from config; override with:
#   --pkg begotorch
#   --torch-path /sys/devices/platform/flashlights_mt6360/torchbrightness
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APK=""
SYS_MOUNT="/system"
PKG="begotorch"
TORCH_PATH="/sys/devices/platform/flashlights_mt6360/torchbrightness"

usage() {
    sed -n '2,70p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) APK="$2"; shift 2 ;;
        --sys-mount) SYS_MOUNT="$2"; shift 2 ;;
        --pkg) PKG="$2"; shift 2 ;;
        --torch-path) TORCH_PATH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# --- locate build artifacts ---------------------------------------------------
APK_PATH=""
if [[ -n "$APK" && -f "$APK" ]]; then
    APK_PATH="$(realpath "$APK")"
elif [[ -f "$ROOT/build/app/outputs/flutter-apk/app-release.apk" ]]; then
    APK_PATH="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
elif [[ -f "$ROOT/build/app/outputs/flutter-apk/app.apk" ]]; then
    APK_PATH="$ROOT/build/app/outputs/flutter-apk/app.apk"
fi
if [[ -z "$APK_PATH" ]]; then
    echo "No built APK found. Build first (flutter build apk --release) or" >&2
    echo "pass --apk <path>." >&2
    exit 1
fi

FAR_PATH="$(find "$ROOT/build" -name '*.far' 2>/dev/null | head -n1 || true)"

echo "Using APK : $APK_PATH"
echo "Using FAR : ${FAR_PATH:-<none, APK-only package>}"

# --- stage --------------------------------------------------------------------
STAGE="$TMP/$PKG"
mkdir -p "$STAGE/system/$PKG" "$STAGE/scripts"

# 1. The privileged component manifest ("the su access, baked in").
install -m 0644 "$ROOT/config/begotorch.cml" "$STAGE/system/$PKG/begotorch.cml"

# 2. The package / APK payload.
install -m 0644 "$APK_PATH" "$STAGE/system/$PKG/app.apk"
if [[ -n "$FAR_PATH" ]]; then
    install -m 0644 "$FAR_PATH" "$STAGE/system/$PKG/begotorch.far"
fi

# 3. TWRP flash + install/uninstall scripts (TWRP runs these from a privileged recovery shell).
install -m 0755 "$ROOT/twrp/flash.sh" "$STAGE/scripts/flash.sh"
install -m 0755 "$ROOT/twrp/install.sh" "$STAGE/scripts/install.sh"
install -m 0755 "$ROOT/twrp/uninstall.sh" "$STAGE/scripts/uninstall.sh"

# 4. Metadata the installer needs.
cat > "$STAGE/TwrJSON" <<JSON
{
  "package": "$PKG",
  "system_mount": "$SYS_MOUNT",
  "torch_path": "$TORCH_PATH",
  "apk": "system/$PKG/app.apk",
  "component_manifest": "system/$PKG/begotorch.cml",
  "flash_script": "scripts/flash.sh",
  "uninstall_script": "scripts/uninstall.sh",
  "root_required_to_flash": true,
  "root_required_after_flash": false
}
JSON

install -m 0644 "$ROOT/twrp/README.md" "$STAGE/README.md"

# --- zip ----------------------------------------------------------------------
mkdir -p "$DIST"
ZIP="$DIST/begotorch-flashable.zip"
( cd "$TMP" && zip -q -r "$ZIP" "$PKG" )
echo "Wrote $ZIP"
echo
echo "Copy $ZIP to the device, then in TWRP -> Open Terminal run:"
echo "    cd /tmp && unzip -o begotorch-flashable.zip && sh $PKG/scripts/flash.sh"
echo
echo "To uninstall later:"
echo "    sh $PKG/scripts/uninstall.sh"
echo "(assumes the zip was copied to /tmp of the booted TWRP environment)"