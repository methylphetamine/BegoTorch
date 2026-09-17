#!/bin/sh
#
# test_dual_mode.sh — verify the single-update-binary dual-mode flash logic.
#
#   1. install  : flash torchbridge-flashable.zip            -> installs
#   2. rename   : rename flashable.zip to uninstall.zip, flash -> uninstalls
#   3. canonical : flash torchbridge-uninstall.zip            -> uninstalls
#
# Runs under /bin/sh (dash here, /sbin/sh on device).
#
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

ZIP_INSTALL="dist/torchbridge-flashable.zip"
ZIP_UNINSTALL="dist/torchbridge-uninstall.zip"
BINARY="twrp/META-INF/com/google/android/update-binary"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   : $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL : $*"; }

mock_system() {
    sudo rm -rf /system_root
    sudo mkdir -p /system_root/system/priv-app /system_root/system/etc/selinux /system_root/system/etc/permissions /system_root/system/etc/init /system_root/vendor/etc/selinux
    sudo sh -c 'cat > /system_root/system/etc/selinux/plat_sepolicy.cil' <<'CIL'
;; stand-in platform policy for the dual-mode test
(type sysfs)
(typeattribute file_type)
(typeattribute sysfs_type)
(type init)
(type priv_app)
(type system_app)
(type platform_app)
(type untrusted_app)
(genfscon sysfs / u:object_r:sysfs:s0)
CIL
    sudo touch /system_root/vendor/etc/selinux/precompiled_sepolicy
    sha256sum /system_root/system/etc/selinux/plat_sepolicy.cil | cut -d' ' -f1
}

run_update_binary() {
    zipfile="$1"
    ui_log="$2"
    sudo sh -c 'cd "$1" && : >"$2" && exec 3>"$2" && sh "$3" 3 3 "$4" >/dev/null 2>&1; rc=$?; exec 3>&-; exit $rc' \
        _ "$REPO" "$ui_log" "$BINARY" "$zipfile"
    return $?
}

capture_ui() { sed -n 's/^ui_print //p' "$1" 2>/dev/null; }

cleanup() { sudo rm -rf /system_root /tmp/ui.log /tmp/uninstall.zip 2>/dev/null || true; }
trap cleanup EXIT

test -f "$ZIP_INSTALL" || { echo "ERROR: $ZIP_INSTALL missing — run tools/make_twrp_zip.sh first"; exit 2; }

echo "=== 1. Default install (flashable.zip) ==="
ORIG_HASH="$(mock_system)"
set +e; run_update_binary "$ZIP_INSTALL" /tmp/ui.log; rc=$?; set -e
echo "exit=$rc"; tail -12 /tmp/ui.log || true
[ "$rc" -eq 0 ] || fail "install exit $rc"
capture_ui /tmp/ui.log | grep -q 'Mode: install' || fail "not detected as install"
capture_ui /tmp/ui.log | grep -qi Done || fail "did not report Done"
sudo test -f /system_root/system/priv-app/TorchBridge/base.apk || fail "APK not installed"
sudo grep -q 'TORCHBRIDGE BEGIN' /system_root/system/etc/selinux/plat_sepolicy.cil || fail "policy not injected"
sudo test -f /system_root/system/torchbridge-backup/plat_sepolicy.cil.orig || fail "backup not created"
[ "$FAIL" -eq 0 ] && ok "install mode" || true

echo ""
echo "=== 2. Rename flashable.zip -> uninstall.zip ==="
cp "$ZIP_INSTALL" /tmp/uninstall.zip
set +e; run_update_binary /tmp/uninstall.zip /tmp/ui.log; rc=$?; set -e
echo "exit=$rc"; tail -12 /tmp/ui.log || true
[ "$rc" -eq 0 ] || fail "renamed uninstall exit $rc"
capture_ui /tmp/ui.log | grep -q 'Mode: uninstall' || fail "renamed zip not detected as uninstall"
capture_ui /tmp/ui.log | grep -qi Removed || fail "renamed zip did not report Removed"
sudo test ! -e /system_root/system/priv-app/TorchBridge/base.apk || fail "APK still present"
sudo test ! -e /system_root/system/torchbridge-backup || fail "backup still present"
NEW_HASH="$(sudo sha256sum /system_root/system/etc/selinux/plat_sepolicy.cil | cut -d' ' -f1)" 2>/dev/null || NEW_HASH=""
[ "$NEW_HASH" = "$ORIG_HASH" ] || fail "policy not restored byte-for-byte"
sudo grep -q 'TORCHBRIDGE' /system_root/system/etc/selinux/plat_sepolicy.cil && fail "TORCHBRIDGE markers remain" || true
[ "$FAIL" -eq 0 ] && ok "renamed uninstall (install -> uninstall -> restored)" || true

echo ""
echo "=== 3. Canonical torchbridge-uninstall.zip ==="
mock_system >/dev/null 2>&1; ORIG2="$(mock_system)"
set +e; run_update_binary "$ZIP_INSTALL" /tmp/ui.log; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "canonical install exit $rc"
sudo test -f /system_root/system/priv-app/TorchBridge/base.apk || fail "install did not place APK"
set +e; run_update_binary "$ZIP_UNINSTALL" /tmp/ui.log; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "canonical uninstall exit $rc"
capture_ui /tmp/ui.log | grep -q 'Mode: uninstall' || fail "canonical not uninstall"
capture_ui /tmp/ui.log | grep -qi Removed || fail "canonical did not report Removed"
sudo test ! -e /system_root/system/priv-app/TorchBridge/base.apk || fail "canonical left APK"
sudo test ! -e /system_root/system/torchbridge-backup || fail "canonical left backup"
NEW_HASH2="$(sudo sha256sum /system_root/system/etc/selinux/plat_sepolicy.cil | cut -d' ' -f1)" 2>/dev/null || NEW_HASH2=""
[ "$NEW_HASH2" = "$ORIG2" ] || fail "canonical did not restore policy byte-for-byte"
[ "$FAIL" -eq 0 ] && ok "canonical uninstall.zip" || true

echo ""
echo "========================================="
echo " PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL DUAL-MODE / RENAME-UNINSTALL TESTS PASSED" || echo "SOME TESTS FAILED"
echo "========================================="
exit "$FAIL"
