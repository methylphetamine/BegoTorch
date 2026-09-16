#!/usr/bin/env bash
#
# make_twrp_zip.sh — assemble the swipe-to-flash TWRP packages.
#
# Output:
#   dist/torchbridge-flashable.zip    install (reboot, tiles are in the panel)
#   dist/torchbridge-uninstall.zip    remove everything again, policy included
#
# Both are ordinary recovery-flashable zips: TWRP -> Install -> select the zip ->
# swipe to confirm. No terminal, no commands, no prompts. The installer reports its
# progress in the recovery UI and logs to /tmp/torchbridge-install.log.
#
# Zip layout (the standard flashable shape):
#
#   META-INF/com/google/android/update-binary   #!/sbin/sh installer TWRP executes
#   META-INF/com/google/android/updater-script  required to exist by the format
#   system/torchbridge/app.apk                  installed as priv-app base.apk
#   scripts/flash.sh                            the same logic a terminal install runs
#   scripts/selinux_inject.sh                   enforcing-safe policy injector
#   scripts/torchbridge.cil                     the rule block it appends
#   scripts/torchbridge.rc                      init snippet (node permissions)
#   scripts/privapp-permissions-*.xml           privileged-permission allowlist
#   scripts/install.sh / uninstall.sh           verify / remove
#   twrp.json / README.md                       metadata and notes
#
# Usage:
#   tools/make_twrp_zip.sh [--apk <path>] [--output-dir <dir>]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APK=""
PKG="torchbridge"
APP_NAME="TorchBridge"
PACKAGE="com.begonia.torchbridge"
META_DIR="META-INF/com/google/android"

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) APK="$2"; shift 2 ;;
        --output-dir) DIST="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# --- locate the APK ----------------------------------------------------------

APK_PATH=""
for candidate in \
    "$APK" \
    "$ROOT/app/build/outputs/twrp/torchbridge.apk" \
    "$ROOT/build/outputs/twrp/torchbridge.apk" \
    "$ROOT/app/build/outputs/apk/release/app-release.apk"
do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        APK_PATH="$(realpath "$candidate")"
        break
    fi
done

if [[ -z "$APK_PATH" ]]; then
    echo "No built APK found. Build one first (./gradlew :app:stageTwrpApk) or" >&2
    echo "pass --apk <path>." >&2
    exit 1
fi
echo "Using APK : $APK_PATH"

# --- shared staging ----------------------------------------------------------

# Everything both zips need: the installer/remover scripts and the policy data.
stage_scripts() {
    local stage="$1"
    mkdir -p "$stage/scripts" "$stage/$META_DIR"

    install -m 0644 "$ROOT/twrp/$META_DIR/updater-script" "$stage/$META_DIR/updater-script"

    for script in flash.sh install.sh uninstall.sh selinux_inject.sh; do
        install -m 0755 "$ROOT/twrp/$script" "$stage/scripts/$script"
    done

    for data in torchbridge.cil torchbridge.rc "privapp-permissions-$PACKAGE.xml"; do
        install -m 0644 "$ROOT/twrp/$data" "$stage/scripts/$data"
    done

    install -m 0755 "$ROOT/twrp/$META_DIR/update-binary" "$stage/$META_DIR/update-binary"
}

zip_dir() {
    local stage="$1" out="$2" name
    name="$(basename "$out")"
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    # Flashing order in the archive does not matter, but the entry point's execute
    # bit does: zip stores the mode, and TWRP refuses a non-executable
    # update-binary, so the file is staged 0755 above and verified here.
    ( cd "$stage" && zip -q -r -X "$out" . )
    if ! unzip -l "$out" "$META_DIR/update-binary" > /dev/null 2>&1; then
        echo "error: $name has no $META_DIR/update-binary; TWRP could not flash it" >&2
        exit 1
    fi
    echo "Wrote     : $out ($(wc -c < "$out" | tr -d ' ') bytes)"
    unzip -l "$out" "$META_DIR/update-binary" | sed -n '4p'
}

# --- install zip -------------------------------------------------------------

INSTALL_STAGE="$TMP/install"
stage_scripts "$INSTALL_STAGE"
mkdir -p "$INSTALL_STAGE/system/$PKG"
install -m 0644 "$APK_PATH" "$INSTALL_STAGE/system/$PKG/app.apk"

cat > "$INSTALL_STAGE/twrp.json" <<JSON
{
  "package": "$PACKAGE",
  "app_name": "$APP_NAME",
  "component": "headless quick-settings tiles (no launcher activity)",
  "install_as": "priv-app",
  "install_path": "system/priv-app/$APP_NAME/base.apk",
  "privileged_permissions": ["android.permission.WRITE_SECURE_SETTINGS"],
  "init_snippet": "system/etc/init/torchbridge.rc",
  "torch_nodes": [
    "/sys/devices/platform/flashlights-mt6360/torchbrightness",
    "/sys/devices/platform/flashlights_mt6360/torchbrightness",
    "/sys/class/leds/torch-light0/brightness"
  ],
  "selinux": {
    "mode": "enforcing (unchanged)",
    "type": "torchnode",
    "policy": "system/etc/selinux/plat_sepolicy.cil",
    "injector": "scripts/selinux_inject.sh",
    "revertible": true,
    "permissive": false
  },
  "flashable": "flash in TWRP (Install -> select zip -> swipe)",
  "terminal_alternative": "sh scripts/flash.sh [--no-selinux] [--domains system_app] [--dry-run]",
  "uninstall_zip": "torchbridge-uninstall.zip",
  "root_required_to_flash": true,
  "root_required_after_flash": false
}
JSON

install -m 0644 "$ROOT/twrp/README.md" "$INSTALL_STAGE/README.md"

zip_dir "$INSTALL_STAGE" "$DIST/torchbridge-flashable.zip"

# --- uninstall zip -----------------------------------------------------------

UNINSTALL_STAGE="$TMP/uninstall"
stage_scripts "$UNINSTALL_STAGE"
# Same layout, different entry point: the remover instead of the installer.
install -m 0755 "$ROOT/twrp/$META_DIR/update-binary-uninstall" \
    "$UNINSTALL_STAGE/$META_DIR/update-binary"

zip_dir "$UNINSTALL_STAGE" "$DIST/torchbridge-uninstall.zip"

# --- report ------------------------------------------------------------------

cat <<EOF

Both packages are ready:

  $DIST/torchbridge-flashable.zip
  $DIST/torchbridge-uninstall.zip

Flash them the normal way:

  1. Copy the zip to the device (any storage TWRP can read).
  2. TWRP -> Install -> select the zip -> swipe to confirm.
  3. Reboot to system.

No terminal is needed for either one, and the installer reports its progress in
the recovery UI. If something fails, its full log is at /tmp/torchbridge-install.log
on the device.

After the first boot, pull down the Quick Settings shade: the "Torch" and "Torch
strength" tiles are already there. Nothing to open, no root, SELinux enforcing.
EOF
