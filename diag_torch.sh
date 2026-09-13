#!/system/bin/sh
LOG=/data/local/tmp/torch_diag.log
exec > "$LOG" 2>&1

echo "=== BegoTorch torch node diag ==="
echo "date: $(date -u)"
echo "hostname: $(cat /system/build.prop 2>/dev/null | grep -E 'ro.product.model|ro.build.id' || echo '')"
echo

echo "=== SELinux mode ==="
getenforce 2>&1 || echo "getenforce failed"
echo

echo "=== node perms/context ==="
ls -lZ /sys/devices/platform/flashlights_mt6360/torchbrightness 2>&1 || echo "node not found"
echo

echo "=== shell write test ==="
VAL=$(cat /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null)
echo "before: $VAL"
if echo 7 > /sys/devices/platform/flashlights_mt6360/torchbrightness 2>&1; then
  echo "shell-write: OK -> $(cat /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null)"
else
  echo "shell-write: FAILED ($?)"
fi
echo "$VAL" > /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null
echo "restored: $(cat /sys/devices/platform/flashlights_mt6360/torchbrightness 2>/dev/null)"
echo

echo "=== app package path ==="
pm path com.begonia.begotorch 2>&1 || echo "pm path failed"
echo

echo "=== app install location / context ==="
ls -lZ /system/priv-app/BegoTorch 2>&1 || echo "/system/priv-app/BegoTorch: not found"
ls -lZ /data/app/*/com.begonia.begotorch* 2>&1 | head -5 || echo "/data/app begotorch: not found"
echo

echo "=== app process context (may be empty if app not running) ==="
ps -A -o pid,uid,comm,context 2>/dev/null | grep -i begotorch || echo "no begotorch process found"
echo

echo "=== recent SELinux denials mentioning torch/sysfs/flashlights (last 20) ==="
dmesg 2>/dev/null | grep -iE 'avc.*denied' | grep -iE 'torch|sysfs|flashlight|flashlights_mt6360' | tail -20 || echo "none found"
echo

echo "=== recent dmesg lines mentioning torchbrightness / flashlights_mt6360 (last 20) ==="
dmesg 2>/dev/null | grep -iE 'torchbrightness|flashlights_mt6360' | tail -20 || echo "none found"
echo

echo "=== raw node contents (current) ==="
cat /sys/devices/platform/flashlights_mt6360/torchbrightness 2>&1
echo
echo "=== end ==="
