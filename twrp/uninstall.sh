#!/bin/sh
#
# uninstall.sh — reverse of flash.sh: removes BegoTorch from the system
# partition so it stops launching and loses the torch capability grant.
#
# Run from a TWRP "Open Terminal" recovery shell (privileged), after mounting
# the system partition, e.g.:
#     sh scripts/uninstall.sh
#
# What it deletes (everything flash.sh installed):
#     $SYS_MOUNT/$PKG/{app.apk,begotorch.cml,begotorch.far,.flashed}
#
set -e

PKG="begotorch"
SYS_MOUNT="${1:-/system}"
DEST="$SYS_MOUNT/$PKG"

# Be CWD-independent: paths below are not used for the payload, but keep the
# same convention so behaviour matches flash.sh.
cd "$(dirname "$0")/.."

echo "== BegoTorch TWRP uninstall =="
echo "System mount : $SYS_MOUNT"
echo "Package dir  : $DEST"

if [ ! -d "$SYS_MOUNT" ]; then
    echo "error: $SYS_MOUNT is not mounted." >&2
    echo "Mount the system partition first (TWRP auto-mounts, or 'mount /system')." >&2
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo "BegoTorch is not installed at $DEST — nothing to remove."
    exit 0
fi

# Remove the flash marker first so a reboot into the system does not try to
# re-register the package from a half-removed manifest.
rm -f "$DEST/.flashed"

# Remove the payload and the manifest that granted the torch capability.
rm -f "$DEST/app.apk"
rm -f "$DEST/begotorch.cml"
rm -f "$DEST/begotorch.far"

# Drop the now-empty package directory (ignore failure if something else is
# using it).
rmdir "$DEST" 2>/dev/null || true

sync

echo
echo "BegoTorch removed. Reboot into the system; the app and its torch"
echo "capability grant are gone."
echo
exit 0