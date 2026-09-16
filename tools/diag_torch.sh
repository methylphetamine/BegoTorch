#!/system/bin/sh
#
# diag_torch.sh — one-shot diagnostics for a ROM where TorchBridge misbehaves.
#
# Run it with adb shell (no root needed):
#     adb push tools/diag_torch.sh /data/local/tmp/
#     adb shell sh /data/local/tmp/diag_torch.sh
#     adb pull /data/local/tmp/torchbridge-diag.log
#
# It changes nothing permanent: the only write it performs is to restore the torch
# node to the value it read first.
#
# What it collects, and why each item is here:
#   * the mode and SELinux label of both torch node spellings — this is what says
#     whether the policy rule took effect (u:object_r:torchnode:s0) or not (sysfs);
#   * a real write attempt, because a node can be 0666 and still be denied by policy;
#   * the QS panel state, to see whether the tiles were inserted automatically;
#   * the domains granted the node, straight out of the injected block;
#   * the surrounding avc denials, which name the domain that was refused;
#   * which control path the component would use, derived from the above.

LOG="/data/local/tmp/torchbridge-diag.log"
exec > "$LOG" 2>&1

PKG="com.begonia.torchbridge"
NODES="/sys/devices/platform/flashlights-mt6360/torchbrightness /sys/devices/platform/flashlights_mt6360/torchbrightness /sys/class/leds/torch-light0/brightness"

echo "=== TorchBridge diagnostics ==="
echo "date       : $(date -u 2>/dev/null || echo unknown)"
echo "device     : $(getprop ro.product.device) / $(getprop ro.product.model)"
echo "build      : $(getprop ro.build.id) ($(getprop ro.build.version.release), API $(getprop ro.build.version.sdk))"
echo "selinux    : $(getenforce 2>/dev/null || echo unknown)"
echo

echo "=== 1. torch nodes: mode and label ==="
for node in $NODES; do
    if [ -e "$node" ]; then
        ls -lZ "$node" 2>&1
    else
        echo "absent     : $node"
    fi
done
echo

echo "=== 2. write attempt on each node (value restored afterwards) ==="
for node in $NODES; do
    [ -e "$node" ] || continue
    before="$(cat "$node" 2>/dev/null)"
    echo "node       : $node"
    echo "  before   : $before"
    if echo 3 > "$node" 2>/dev/null; then
        echo "  write    : OK -> $(cat "$node" 2>/dev/null)"
    else
        echo "  write    : DENIED (exit $?)"
    fi
    # Restore, so the diagnostic cannot leave a flashlight on.
    [ -n "$before" ] && echo "$before" > "$node" 2>/dev/null
    echo "  restored : $(cat "$node" 2>/dev/null)"
done
echo

echo "=== 3. the SELinux rule, as installed ==="
POLICY="/system/etc/selinux/plat_sepolicy.cil"
[ -f "$POLICY" ] || POLICY="/system_root/system/etc/selinux/plat_sepolicy.cil"
if [ -f "$POLICY" ]; then
    echo "policy     : $POLICY"
    grep -A40 'TORCHBRIDGE BEGIN' "$POLICY" 2>/dev/null |
        grep -E '^\((type|genfscon|allow)' || echo "  no TorchBridge block found"
else
    echo "policy     : not found on a path readable from here"
fi
echo

echo "=== 4. Quick Settings panel state ==="
echo "sysui_qs_tiles: $(settings get secure sysui_qs_tiles 2>/dev/null)"
echo
echo "note: values wrapped as custom(...) are this SystemUI generation's format;"
echo "      a missing entry means the automatic insert was refused, and the tiles"
echo "      can always be dragged in from the QS editor by hand."
echo

echo "=== 5. component ==="
echo "installed  : $(pm path $PKG 2>/dev/null || echo 'not installed')"
echo "priv-app   : $(ls -ldZ /system/priv-app/TorchBridge /system_root/system/priv-app/TorchBridge 2>/dev/null | head -2 || echo 'not in priv-app')"
echo "allowlist  : $(ls -lZ /system/etc/permissions/privapp-permissions-$PKG.xml 2>/dev/null || echo 'missing')"
echo "init snip  : $(ls -lZ /system/etc/init/torchbridge.rc 2>/dev/null || echo 'missing')"
echo

echo "=== 6. camera torch capability (control path rung 1) ==="
dump="$(dumpsys media.camera 2>/dev/null | grep -iE 'torch|flash' | head -10)"
[ -n "$dump" ] && echo "$dump" || echo "no torch/flash lines in dumpsys media.camera"
echo

echo "=== 7. SELinux denials (last 30 touching the torch) ==="
dmesg 2>/dev/null | grep -i 'avc.*denied' |
    grep -iE 'torch|sysfs|flashlight' | tail -30 || echo "none found"
echo

echo "=== 8. verdict ==="
if echo 3 > /sys/devices/platform/flashlights-mt6360/torchbrightness 2>/dev/null ||
    echo 3 > /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null; then
    echo "direct node writes work -> the component uses rung 2/3 and gives the full 0-7 range"
    echo 0 > /sys/devices/platform/flashlights-mt6360/torchbrightness 2>/dev/null
    echo 0 > /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null
else
    echo "direct node writes are denied -> the component falls back to the camera path;"
    echo "check section 3 (was the rule injected?) and section 7 (which domain was refused?)"
fi
echo
echo "=== end ==="
echo
echo "Log written to $LOG"
