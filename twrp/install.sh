#!/sbin/sh
#
# install.sh — post-flash verification hook.
#
# Checks that every piece flash.sh is supposed to have installed is actually in
# place, and reports the state in a form that makes a partial install obvious.
# Safe to run at any time, including after a reboot (read-only operations only).
#
#     sh scripts/install.sh [mount-point]
#
set -e

APP_NAME="TorchBridge"
PACKAGE="com.begonia.torchbridge"
PKG_DIR="torchbridge"
STATUS=0

say() {
    echo "$*"
}

check() {
    # check <label> <path>
    if [ -e "$2" ]; then
        say "  present : $1"
    else
        say "  MISSING : $1 ($2)"
        STATUS=1
    fi
}

detect_system() {
    if [ -d /system_root/system/priv-app ]; then
        SYS_ROOT=/system_root
        SUB=system
        return 0
    fi
    if [ -d /system_root/priv-app ]; then
        SYS_ROOT=/system_root
        SUB=""
        return 0
    fi
    if [ -n "$1" ] && [ -d "$1" ]; then
        if [ -d "$1/system/priv-app" ]; then
            SYS_ROOT="$1"
            SUB=system
            return 0
        fi
        if [ -d "$1/priv-app" ]; then
            SYS_ROOT="$1"
            SUB=""
            return 0
        fi
    fi
    if [ -d /system/priv-app ]; then
        SYS_ROOT=/system
        SUB=""
        return 0
    fi
    if [ -d /system/system/priv-app ]; then
        SYS_ROOT=/system
        SUB=system
        return 0
    fi
    SYS_ROOT=""
    SUB=""
}

# Mounting read-only is enough to verify, but mounting the image at all is not a
# given in recovery, so this runs before detection.
mount_system() {
    for target in /system_root /system; do
        [ -d "$target" ] || continue
        mount "$target" > /dev/null 2>&1 || true
    done
}

detect_system "$1"

say "== TorchBridge verification =="
say "System root  : ${SYS_ROOT:-<not detected>} (app base: /$SUB)"

if [ -z "$SYS_ROOT" ]; then
    say "error: system partition not found. Mount it in TWRP and re-run." >&2
    exit 1
fi

if [ -n "$SUB" ]; then SYS="$SYS_ROOT/$SUB"; else SYS="$SYS_ROOT"; fi
POLICY="$SYS/etc/selinux/plat_sepolicy.cil"

check "component APK (priv-app)" "$SYS/priv-app/$APP_NAME/base.apk"
check "privileged-permission allowlist" "$SYS/etc/permissions/privapp-permissions-$PACKAGE.xml"
check "init snippet (node permissions)" "$SYS/etc/init/torchbridge.rc"
check "policy backup" "$SYS/torchbridge-backup/plat_sepolicy.cil.orig"

if [ -f "$POLICY" ] && grep -q 'TORCHBRIDGE BEGIN' "$POLICY" 2>/dev/null; then
    say "  applied : SELinux rule injected into $POLICY"
    say "            domains: $(grep -o '(allow [a-z_]* torchnode' "$POLICY" | awk '{print $2}' | tr '\n' ' ')"
    if grep -q '(permissive ' "$POLICY"; then
        say "  FAIL    : the policy contains a permissive statement" >&2
        STATUS=1
    fi
else
    say "  ABSENT  : SELinux rule (run scripts/selinux_inject.sh inject $SYS)"
    STATUS=1
fi

if [ "$STATUS" = "0" ]; then
    say ""
    say "All pieces present. Runtime root required: NO."
else
    say ""
    say "Something is missing — see above. Partial installs are recoverable by"
    say "re-running scripts/flash.sh with the system partition mounted."
fi

exit "$STATUS"
