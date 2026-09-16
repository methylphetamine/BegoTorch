#!/bin/sh
#
# flash.sh — install TorchBridge from a TWRP "Open Terminal" shell.
#
# WHAT THIS INSTALLS
# ------------------
# Four pieces, and no root is needed to *use* any of them afterwards:
#
#   1. the component APK, as a privileged system app
#      (<system>/priv-app/TorchBridge/base.apk). Android's package manager scans
#      priv-app at boot, so the app is registered with no user interaction. It has
#      no launcher icon and no activity: its whole surface is Quick Settings.
#
#   2. the privileged-permission allowlist
#      (<system>/etc/permissions/privapp-permissions-com.begonia.torchbridge.xml).
#      Without this the WRITE_SECURE_SETTINGS request is *rejected* and — on
#      Android 9+ — a priv-app asking for a privilege that is not allowlisted can
#      make the device fail to boot. So this file is not optional decoration; it
#      is part of what makes the tile appear in the panel by itself.
#
#   3. an init snippet (<system>/etc/init/torchbridge.rc) that applies the DAC
#      half of the permission the kernel cannot: powa_karnal publishes the torch
#      node with mode 0666 already, but a ROM whose kernel is stock leaves it 0644
#      and root-owned. Two chmod/chown lines at boot fix that, every boot, without
#      any runtime root.
#
#   4. the SELinux half, via twrp/selinux_inject.sh: the torch node is relabelled
#      `torchnode` and that type is granted to the system app domains. SELinux
#      stays ENFORCING. No permissive domain, no su, no Magisk/KernelSU/APatch.
#
# The pairing is the point: the kernel provides world-writable DAC permissions,
# flash-time policy provides the label, and the init snippet makes it hold on
# every boot.
#
# MOUNT LAYOUTS HANDLED
# ---------------------
#   SAR image at /system_root, apps in /system_root/system/priv-app   (common)
#   legacy image at /system_root, apps in /system_root/priv-app
#   legacy image at /system,      apps in /system/priv-app
#   SAR image bind-mounted at /system, apps in /system/system/priv-app
# Or pass an explicit mount point as the first argument.
#
# USAGE
# -----
#   sh scripts/flash.sh [mount-point] [--no-selinux] [--domains a,b,c]
#                                     [--dry-run] [--drop-precompiled]
#
# OPTIONS
# -------
#   --no-selinux        install the app and init snippet, skip the policy change
#                       (the tile then falls back to the camera framework path)
#   --domains a,b,c     narrow the SELinux grant, e.g. --domains system_app
#   --dry-run           report every step without writing anything
#   --drop-precompiled  also move aside /vendor/etc/selinux/precompiled_sepolicy
#
set -e

APP_NAME="TorchBridge"
PACKAGE="com.begonia.torchbridge"
PKG_DIR="torchbridge"
LEGACY_APP_NAME="BegoTorch"
SELINUX_CTX="u:object_r:system_file:s0"

DO_SELINUX="yes"
DOMAINS=""
DRY_RUN="no"
DROP_PRECOMPILED="no"
MOUNT_POINT=""

say() {
    echo "$*"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# --- locate the system image -------------------------------------------------

# Locates the partition the component is installed on.
#
# In TWRP the answer is always /system_root. On a System-as-Root device that is the
# mount point of the system image and the files live under /system_root/system; the
# /system path TWRP also exposes is a bind mount of the same image, and writing
# through a bind mount is precisely where "read-only file system" and EROFS errors
# come from. So /system_root wins whenever it exists, and /system is used only when
# these scripts run on a booted system (where /system_root does not exist).
#
# Sets SYS_ROOT (mount point) and SUB ("" or "system" prefix inside it).
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
    # Booted system: verifying an install without booting into recovery.
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

# Mounts the system image read-write before anything is detected, so a run with the
# partition unmounted still works. /system_root is tried first for the same reason
# it is preferred above.
mount_system_rw() {
    for target in /system_root /system; do
        [ -d "$target" ] || continue
        mount "$target" > /dev/null 2>&1 || true
        mount -o rw,remount "$target" > /dev/null 2>&1 || true
    done
}

# --- argument parsing --------------------------------------------------------

usage() {
    sed -n '3,50p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-selinux) DO_SELINUX="no"; shift ;;
        --domains)
            [ $# -ge 2 ] || die "--domains needs a value"
            DOMAINS="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN="yes"; shift ;;
        --drop-precompiled) DROP_PRECOMPILED="yes"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            [ -z "$MOUNT_POINT" ] || die "unexpected argument: $1"
            MOUNT_POINT="$1"
            shift
            ;;
    esac
done

# Mount before detecting: TWRP frequently has the image present but unmounted, and
# the detection below is what decides where every file will be written.
if [ "$DRY_RUN" = "no" ]; then
    mount_system_rw
fi

detect_system "$MOUNT_POINT"

say "== TorchBridge TWRP install =="
say "Package      : $PACKAGE"

if [ -z "$SYS_ROOT" ]; then
    die "no mounted system partition with priv-app found. In TWRP open Mount, tick System, then re-run this script."
fi

if [ -n "$SUB" ]; then SYS="$SYS_ROOT/$SUB"; else SYS="$SYS_ROOT"; fi
say "System root  : $SYS_ROOT (app base: /$SUB)"

# Payload paths are relative to the package root (this script lives in scripts/).
cd "$(dirname "$0")/.."
SRC_APK="system/$PKG_DIR/app.apk"
SRC_INJECT="scripts/selinux_inject.sh"
SRC_CIL="scripts/torchbridge.cil"
SRC_RC="scripts/torchbridge.rc"
SRC_PERMS="scripts/privapp-permissions-$PACKAGE.xml"

[ -f "$SRC_APK" ] || die "missing $SRC_APK — run this from the extracted package root."
[ -f "$SRC_INJECT" ] || die "missing $SRC_INJECT — run this from the extracted package root."
[ -f "$SRC_CIL" ] || die "missing $SRC_CIL — run this from the extracted package root."
[ -f "$SRC_RC" ] || die "missing $SRC_RC — run this from the extracted package root."
[ -f "$SRC_PERMS" ] || die "missing $SRC_PERMS — run this from the extracted package root."

# Reports the command instead of running it under --dry-run.
do_step() {
    if [ "$DRY_RUN" = "yes" ]; then
        say "would run    : $*"
    else
        "$@"
    fi
}

# --- stage 1: files on the system partition ----------------------------------

# The system image was already mounted read-write by mount_system_rw above; the
# install below writes through $SYS_ROOT (which is /system_root in TWRP) rather
# than through the /system bind mount.

PRIV_APP="$SYS/priv-app/$APP_NAME"
say "App          : $PRIV_APP/base.apk"
do_step mkdir -p "$PRIV_APP"
if [ "$DRY_RUN" = "no" ]; then
    install -m 0644 "$SRC_APK" "$PRIV_APP/base.apk" || {
        say "error: could not write to $PRIV_APP." >&2
        say "If 'mount' reports erofs/read-only for $SYS_ROOT, this ROM's system image" >&2
        say "cannot be modified from recovery and this install method cannot be used." >&2
        exit 1
    }
fi

PERMS_DIR="$SYS/etc/permissions"
PERMS_FILE="$PERMS_DIR/privapp-permissions-$PACKAGE.xml"
say "Allowlist    : $PERMS_FILE"
do_step mkdir -p "$PERMS_DIR"
[ "$DRY_RUN" = "yes" ] || install -m 0644 "$SRC_PERMS" "$PERMS_FILE"

INIT_DIR="$SYS/etc/init"
INIT_FILE="$INIT_DIR/torchbridge.rc"
say "Init snippet : $INIT_FILE"
do_step mkdir -p "$INIT_DIR"
[ "$DRY_RUN" = "yes" ] || install -m 0644 "$SRC_RC" "$INIT_FILE"

# A previous BegoTorch install (the old app) would still be scanned at boot and
# would fight this component over the same node; remove it as part of the upgrade.
if [ -d "$SYS/priv-app/$LEGACY_APP_NAME" ]; then
    say "Removing     : $SYS/priv-app/$LEGACY_APP_NAME (superseded)"
    do_step rm -rf "$SYS/priv-app/$LEGACY_APP_NAME"
fi

# Ownership and label so the boot-time package scan accepts the files. Both are
# best effort: a recovery without these tools still works for most ROMs.
if [ "$DRY_RUN" = "no" ]; then
    chown 0:0 "$PRIV_APP/base.apk" "$PRIV_APP" "$PERMS_FILE" "$INIT_FILE" 2>/dev/null || true
    if command -v restorecon > /dev/null 2>&1; then
        restorecon -R "$PRIV_APP" "$PERMS_FILE" "$INIT_FILE" 2>/dev/null || true
    elif command -v chcon > /dev/null 2>&1; then
        chcon "$SELINUX_CTX" "$PRIV_APP/base.apk" "$PRIV_APP" \
            "$PERMS_FILE" "$INIT_FILE" 2>/dev/null || true
    fi
fi

# --- stage 2: the SELinux rule -----------------------------------------------

say ""
if [ "$DO_SELINUX" = "yes" ]; then
    set -- inject "$SYS"
    [ -n "$DOMAINS" ] && set -- "$@" --domains "$DOMAINS"
    [ "$DRY_RUN" = "yes" ] && set -- "$@" --dry-run
    [ "$DROP_PRECOMPILED" = "yes" ] && set -- "$@" --drop-precompiled

    if sh "$SRC_INJECT" "$@"; then
        say "SELinux      : rule applied (enforcing, unchanged mode)"
    else
        say "warning: the SELinux rule was not applied; the tiles will still work" >&2
        say "         through the camera framework path, but strength steps may be" >&2
        say "         limited by the ROM's camera service." >&2
    fi
else
    say "SELinux      : skipped (--no-selinux)"
fi

if [ "$DRY_RUN" = "no" ]; then
    sync
fi

# --- report ------------------------------------------------------------------

say ""
say "Installed. Reboot into the system."
say ""
say "  * TorchBridge has no launcher icon and nothing to open — that is intended."
say "  * On the first boot the component adds its two tiles to the Quick Settings"
say "    panel by itself. Pull the shade down and they are already there:"
say "      'Torch'           tap to toggle on/off at your preferred strength"
say "      'Torch strength'  tap to open the 0-7 picker inside the panel"
say "  * If a ROM ignores the automatic insert, drag them in from the QS editor."
say ""
say "To verify from a terminal (no root needed for the first two):"
say "    ls -lZ /sys/devices/platform/flashlights-mt6360/torchbrightness"
say "    ls -lZ /sys/devices/platform/flashlights_mt6360/torchbrightness"
say "      -> 0666, and labelled u:object_r:torchnode:s0"
say "    settings get secure sysui_qs_tiles"
say "      -> should list $PACKAGE/.TorchStrengthTileService"
say ""
say "To undo everything:"
say "    sh $PKG_DIR/scripts/uninstall.sh"
say ""
exit 0
