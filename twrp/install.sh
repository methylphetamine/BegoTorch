#!/bin/sh
#
# install.sh — post-flash verification hook. After flash.sh has placed
# BegoTorch in priv-app, this checks the APK is present. Usable on a booted
# system too (no root needed to verify).
#
set -e

APP_NAME="BegoTorch"

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
APK="$SYS_ROOT/${SUB:+$SUB/}priv-app/$APP_NAME/base.apk"

echo "== BegoTorch install hook =="
echo "System root  : ${SYS_ROOT:-<not detected>} (app base: /$SUB)"

if [ -f "$APK" ]; then
    echo "Priv-app APK present : $APK"
    echo "Install status       : system priv-app (auto-registered at boot)"
    echo "Runtime root         : NOT required"
else
    echo "warning: $APK not found — run scripts/flash.sh first." >&2
    exit 1
fi

exit 0