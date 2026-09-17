#!/sbin/sh
#
# uninstall.sh — remove TorchBridge completely, including the policy change.
#
# Run from a TWRP "Open Terminal" shell:
#     sh scripts/uninstall.sh [mount-point]
#
# Removes, in this order:
#   1. the SELinux rule (restoring the ROM's original policy file byte-for-byte
#      from the backup the injector took), so no trace of the change survives;
#   2. the init snippet and the privileged-permission allowlist;
#   3. the component APK;
#   4. a leftover BegoTorch install from the older app design, if present.
#
# Until the reboot the currently running system keeps the injected policy in
# memory; that is unavoidable and harmless — after the reboot the ROM's own
# policy is back in force.
#
set -e

APP_NAME="TorchBridge"
PKG_DIR="torchbridge"
PACKAGE="com.begonia.torchbridge"
LEGACY_APP_NAME="BegoTorch"

say() {
    echo "$*"
}

die() {
    echo "error: $*" >&2
    exit 1
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

# Mounts the system image read-write; /system_root first, as in flash.sh.
mount_system_rw() {
    for target in /system_root /system; do
        [ -d "$target" ] || continue
        mount "$target" > /dev/null 2>&1 || true
        mount -o rw,remount "$target" > /dev/null 2>&1 || true
    done
}

# Mount read-write, then detect. /system_root first: see the note in flash.sh.
mount_system_rw

detect_system "$1"

say "== TorchBridge TWRP uninstall =="
say "System root  : ${SYS_ROOT:-<not detected>} (app base: /$SUB)"

if [ -z "$SYS_ROOT" ]; then
    die "no mounted system partition with priv-app found. In TWRP open Mount, tick System, then re-run."
fi

if [ -n "$SUB" ]; then SYS="$SYS_ROOT/$SUB"; else SYS="$SYS_ROOT"; fi

# 1) Policy first: this is the change that matters most to undo, and it fails
#    loudly (leaving the rest untouched) if the system partition went read-only.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/selinux_inject.sh" ]; then
    if sh "$SELF_DIR/selinux_inject.sh" revert "$SYS"; then
        say "Policy       : reverted"
    else
        say "warning: could not revert the policy. Re-run this script from the" >&2
        say "         extracted package with the system partition mounted." >&2
    fi
else
    say "note         : scripts/selinux_inject.sh not found next to this script;"
    say "               the policy change is left in place."
fi

# 2) Files.
for target in \
    "$SYS/priv-app/$APP_NAME" \
    "$SYS/etc/permissions/privapp-permissions-$PACKAGE.xml" \
    "$SYS/etc/init/torchbridge.rc" \
    "$SYS/priv-app/$LEGACY_APP_NAME"
do
    if [ -e "$target" ]; then
        rm -rf "$target"
        say "Removed      : $target"
    fi
done

# 3) The injector's backups, now that the original policy is restored. Kept only
#    if the revert above failed, since they are then the only copy of it.
if [ -f "$SYS/torchbridge-backup/plat_sepolicy.cil.orig" ]; then
    if grep -q 'TORCHBRIDGE' "$SYS/etc/selinux/plat_sepolicy.cil" 2>/dev/null; then
        say "Kept         : $SYS/torchbridge-backup (revert did not complete)"
    else
        rm -rf "$SYS/torchbridge-backup"
        say "Removed      : $SYS/torchbridge-backup"
    fi
fi

sync

say ""
say "TorchBridge removed. Reboot; the tiles disappear and the ROM's own torch"
say "behaviour (with its normal SELinux policy) returns."
say ""
exit 0
