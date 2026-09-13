#!/bin/sh
#
# uninstall.sh — remove BegoTorch from the system partition (reverse of
# flash.sh). Also cleans up the payload directory left by older versions of
# this package (system/begotorch/).
#
# Run from a TWRP "Open Terminal" recovery shell:
#     sh scripts/uninstall.sh [mount-point]
#
set -e

APP_NAME="BegoTorch"
PKG_DIR="begotorch"

# Same layout detection as flash.sh.
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

echo "== BegoTorch TWRP uninstall =="
echo "System root  : ${SYS_ROOT:-<not detected>} (app base: /$SUB)"

if [ -z "$SYS_ROOT" ]; then
    echo "error: could not find a mounted system partition with priv-app." >&2
    echo "In TWRP use Mount and tick System first, then re-run this script." >&2
    exit 1
fi

mount -o remount,rw "$SYS_ROOT" 2>/dev/null || true

# 1) The priv-app installed by flash.sh.
PRIV_APP="$SYS_ROOT/${SUB:+$SUB/}priv-app/$APP_NAME"
if [ -d "$PRIV_APP" ]; then
    rm -rf "$PRIV_APP"
    echo "Removed priv-app : $PRIV_APP"
else
    echo "Not present      : $PRIV_APP"
fi

# 2) Cleanup for packages flashed by the original (broken) script layout.
OLD_DIR="$SYS_ROOT/${SUB:+$SUB/}$PKG_DIR"
if [ -d "$OLD_DIR" ]; then
    rm -rf "$OLD_DIR"
    echo "Removed legacy   : $OLD_DIR"
fi

sync

echo
echo "BegoTorch removed. Reboot into the system; the app is gone."
echo
exit 0