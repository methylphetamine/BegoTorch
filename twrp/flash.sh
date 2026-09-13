#!/bin/sh
#
# flash.sh — run from a TWRP "Open Terminal" recovery shell to install
# BegoTorch as a privileged system app (priv-app).
#
# WHY THIS IS HOW IT WORKS
# ------------------------
# Android scans <system>/priv-app/<AppDir>/base.apk at boot and registers it
# as a pre-installed privileged app. That is the only supported way to ship an
# app without user interaction — copying an APK anywhere else on the system
# partition does NOT install it (nothing would appear after reboot).
#
# Being a priv-app removes the need for su/Magisk/KernelSU to install the app.
# NOTE: whether the torch sysfs node is writable by the app process is decided
# by the ROM's node ownership and SELinux policy; priv-app gets us the strongest
# standard install, not a magic bypass of kernel permissions.
#
# MOUNT LAYOUTS HANDLED
# ---------------------
#   SAR image at /system_root, apps in /system_root/system/priv-app   (typical)
#   legacy image at /system_root, apps in /system_root/priv-app
#   legacy image at /system,      apps in /system/priv-app
#   SAR image bind-mounted at /system, apps in /system/system/priv-app
# Or pass an explicit mount point as the first argument.
#
# Usage:
#     sh scripts/flash.sh [mount-point]
#
set -e

APP_NAME="BegoTorch"
PACKAGE="com.begonia.begotorch"
PKG_DIR="begotorch"          # payload dir inside the extracted zip
SELINUX_CTX="u:object_r:system_file:s0"

# --- locate the system image -------------------------------------------------
# Sets SYS_ROOT (mount point) and SUB ("" or "system" path prefix inside it).
detect_system() {
    if [ -d /system_root/system/priv-app ]; then
        SYS_ROOT=/system_root; SUB=system
    elif [ -d /system_root/priv-app ]; then
        SYS_ROOT=/system_root; SUB=""
    elif [ -d /system/priv-app ]; then
        SYS_ROOT=/system; SUB=""
    elif [ -d /system/system/priv-app ]; then
        SYS_ROOT=/system; SUB=system
    elif [ -n "$1" ] && [ -d "$1" ]; then
        # Explicit override: accept the mount point, auto-detect the subdir.
        if [ -d "$1/system/priv-app" ]; then
            SYS_ROOT="$1"; SUB=system
        elif [ -d "$1/priv-app" ]; then
            SYS_ROOT="$1"; SUB=""
        else
            echo "error: no priv-app directory under $1" >&2
            exit 1
        fi
    else
        SYS_ROOT=""; SUB=""
    fi
}

detect_system "$1"

echo "== BegoTorch TWRP flash =="
echo "Package      : $PACKAGE"
echo "Payload      : $PKG_DIR/system/$PKG_DIR/app.apk"

if [ -z "$SYS_ROOT" ]; then
    echo "error: could not find a mounted system partition with priv-app." >&2
    echo "In TWRP use Mount and tick System first, then re-run this script." >&2
    exit 1
fi
echo "System root  : $SYS_ROOT (app base: /$SUB)"

# Payload path is relative to the package root (this script lives in scripts/).
cd "$(dirname "$0")/.."
SRC_APK="system/$PKG_DIR/app.apk"
if [ ! -f "$SRC_APK" ]; then
    echo "error: missing $SRC_APK — run this from the extracted package root." >&2
    exit 1
fi

# --- make sure the image is writable ----------------------------------------
# Best-effort remount; TWRP usually mounts system rw already. If the image is
# EROFS (read-only) the install below will fail with a clear message.
mount -o remount,rw "$SYS_ROOT" 2>/dev/null || true

# --- install as priv-app ------------------------------------------------------
PRIV_APP="$SYS_ROOT/${SUB:+$SUB/}priv-app/$APP_NAME"
echo "Installing   : $PRIV_APP/base.apk"
mkdir -p "$PRIV_APP"
if ! install -m 0644 "$SRC_APK" "$PRIV_APP/base.apk"; then
    echo "error: could not write to $PRIV_APP." >&2
    echo "If 'mount' reports erofs/read-only for $SYS_ROOT, this ROM's system" >&2
    echo "image cannot be modified from recovery (EROFS), and this flash" >&2
    echo "method cannot be used on it." >&2
    exit 1
fi

# Correct ownership/SELinux context so the boot scan accepts the file.
# Both are best-effort: recoveries without the tools still work in most cases.
chown 0:0 "$PRIV_APP/base.apk" 2>/dev/null || true
chown 0:0 "$PRIV_APP" 2>/dev/null || true
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$PRIV_APP" 2>/dev/null || true
elif command -v chcon >/dev/null 2>&1; then
    chcon "$SELINUX_CTX" "$PRIV_APP/base.apk" "$PRIV_APP" 2>/dev/null || true
fi

sync

echo
echo "Installed. Reboot into the system; Android will register BegoTorch as a"
echo "pre-installed privileged app on the first boot (it may take a minute to"
echo "appear in the launcher). No su/Magisk/KernelSU is involved."
echo

exit 0