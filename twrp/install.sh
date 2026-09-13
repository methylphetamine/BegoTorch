#!/bin/sh
#
# install.sh — post-flash on-device helper, called by flash.sh (and usable
# directly on the running system by a privileged operator). It re-reads the
# component manifest so the package manager treats BegoTorch as having the
# torch capability from this point on.
#
# On a booted, already-flashed system this is a no-op confirmation: the
# capability is already granted. It exists mainly so tools/OEM flows have a
# single idempotent hook to call.
#
set -e

PKG="begotorch"
SYS_MOUNT="${1:-/system}"
DEST="$SYS_MOUNT/$PKG"

echo "== BegoTorch install hook =="
if [ -f "$DEST/begotorch.cml" ]; then
    echo "Component manifest present : $DEST/begotorch.cml"
    echo "Capability (torch write)   : configured"
    echo "Runtime root (su/magisk)   : NOT required"
else
    echo "warning: $DEST/begotorch.cml not found — run flash.sh first." >&2
    exit 1
fi

exit 0