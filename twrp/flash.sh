#!/bin/sh
#
# flash.sh — run from a TWRP "Open Terminal" recovery shell to install the
# BegoTorch package into the system partition so it runs *already privileged*
# on the next boot.
#
# TWRP recovery runs as root, so this script can write the system partition
# even though the released app runs sandboxed. Nothing in this script is
# needed at runtime: after it runs, BegoTorch owns the torch capability
# declared in config/begotorch.cml and needs no su / Magisk / KernelSU.
#
# Usage (from the extracted zip, e.g. after `unzip -o begotorch-flashable.zip`):
#     sh scripts/flash.sh
#
set -e

# Layout this script is dropped into. Tune SYS_MOUNT if begonia mounts the
# system image somewhere other than /system (see TwrJSON).
PKG="begotorch"
SYS_MOUNT="${1:-/system}"

# Work regardless of where the zip was extracted / which dir this is called
# from: the payload paths below are relative to the package root, so cd there.
cd "$(dirname "$0")/.."

echo "== BegoTorch TWRP flash =="
echo "System mount : $SYS_MOUNT"
echo "Package      : $PKG"
echo "Package root : $(pwd)"

if [ ! -d "$SYS_MOUNT" ]; then
    echo "error: $SYS_MOUNT is not mounted." >&2
    echo "Mount the system partition first (TWRP auto-mounts, or 'mount /system')." >&2
    exit 1
fi

# Validate the tree looks right before copying anything.
for f in "system/$PKG/app.apk" "system/$PKG/begotorch.cml"; do
    if [ ! -f "$f" ]; then
        echo "error: missing $f — run this from the extracted package root." >&2
        exit 1
    fi
done

# Make sure the destination package dir exists on the system image.
DEST="$SYS_MOUNT/$PKG"
mkdir -p "$DEST"

# Install the payload (privileged) and the component manifest.
install -m 0644 "system/$PKG/app.apk"         "$DEST/app.apk"
install -m 0644 "system/$PKG/begotorch.cml"   "$DEST/begotorch.cml"
if [ -f "system/$PKG/begotorch.far" ]; then
    install -m 0644 "system/$PKG/begotorch.far" "$DEST/begotorch.far"
fi

# Signal to the boot path that the flash is complete so the package manager
# registers BegoTorch from the manifest on next boot.
: > "$DEST/.flashed"

sync

echo
echo "Installed BegoTorch to $DEST"
echo "Reboot into the system; BegoTorch is already privileged."
echo "You will NOT be asked to grant root for the torch control."
echo
exit 0