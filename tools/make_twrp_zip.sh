#!/usr/bin/env bash
#
# make_twrp_zip.sh — assemble the TWRP-flashable package for BegoTorch.
#
# Output:  dist/begotorch-flashable.zip
#
# What this zip contains
# ----------------------
# BegoTorch is installed as a privileged system app (priv-app), so Android
# registers it automatically at boot and no su/Magisk/KernelSU grant is needed
# to use it:
#
#   * system/begotorch/app.apk   — the Flutter release APK (installed by
#     flash.sh as <system>/priv-app/BegoTorch/base.apk).
#   * twrp/flash.sh              — run from TWRP "Open Terminal"; detects the
#     system mount (SAR /system_root or legacy /system) and installs the APK.
#   * twrp/install.sh            — post-flash verification hook.
#   * twrp/uninstall.sh          — removes the app again from recovery.
#   * twrp.json / README.md      — machine- and human-readable metadata.
#
# Usage
# -----
#   tools/make_twrp_zip.sh --apk build/app/outputs/flutter-apk/app-release.apk
#
# The torch node path is recorded in twrp.json for tooling/documentation:
#   --torch-path /sys/devices/platform/flashlights_mt6360/torchbrightness
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APK=""
PKG="begotorch"
APP_NAME="BegoTorch"
TORCH_PATH="/sys/devices/platform/flashlights_mt6360/torchbrightness"

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) APK="$2"; shift 2 ;;
        --pkg) PKG="$2"; shift 2 ;;
        --app-name) APP_NAME="$2"; shift 2 ;;
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

echo "Using APK : $APK_PATH"

# --- stage --------------------------------------------------------------------
STAGE="$TMP/$PKG"
mkdir -p "$STAGE/system/$PKG" "$STAGE/scripts"

# 1. The APK payload (installed by flash.sh as priv-app/<APP_NAME>/base.apk).
install -m 0644 "$APK_PATH" "$STAGE/system/$PKG/app.apk"

# 2. TWRP scripts (run from the privileged recovery shell).
install -m 0755 "$ROOT/twrp/flash.sh"     "$STAGE/scripts/flash.sh"
install -m 0755 "$ROOT/twrp/install.sh"   "$STAGE/scripts/install.sh"
install -m 0755 "$ROOT/twrp/uninstall.sh" "$STAGE/scripts/uninstall.sh"

# 3. Metadata (machine-readable) — mirrors the layout flash.sh installs.
cat > "$STAGE/twrp.json" <<JSON
{
  "package": "$PKG",
  "app_name": "$APP_NAME",
  "install_as": "priv-app",
  "install_path": "system/priv-app/$APP_NAME/base.apk",
  "torch_path": "$TORCH_PATH",
  "apk": "system/$PKG/app.apk",
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
rm -f "$ZIP"
( cd "$TMP" && zip -q -r "$ZIP" "$PKG" )
echo "Wrote $ZIP"
echo
echo "Copy $ZIP to the device, then in TWRP -> Advanced -> Open Terminal run:"
echo "    cd /tmp && unzip -o begotorch-flashable.zip && sh $PKG/scripts/flash.sh"
echo
echo "Reboot. BegoTorch installs as a system priv-app on the first boot."
echo "To uninstall later:"
echo "    sh $PKG/scripts/uninstall.sh"