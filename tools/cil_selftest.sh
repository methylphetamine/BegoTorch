#!/bin/sh
#
# cil_selftest.sh — functional test for the flash-time SELinux injection.
#
# What this protects against
# --------------------------
# The injector rewrites the platform policy file, and a platform policy that does
# not compile does not boot. So this test does not merely check that the script
# runs: it builds a stand-in system partition, injects, and then asserts the
# properties that decide whether a real device survives:
#
#   1. the block is appended exactly once, even after repeated flashes;
#   2. only domains the policy actually declares are granted (referencing a type
#      a ROM does not have is what breaks the compile);
#   3. untrusted_app is never granted anything;
#   4. a policy that lacks a required type is refused outright, file untouched;
#   5. `revert` restores the file byte-for-byte;
#   6. the emitted block is balanced and labels both platform device spellings;
#   7. no permissive statement exists anywhere in what gets injected.
#
# It is POSIX sh on purpose: the same script runs in CI and in a phone's recovery
# shell, so what is tested here is what runs on the device.
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INJECT="$ROOT/twrp/selinux_inject.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    echo "  ok   : $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL : $1" >&2
}

assert_contains() {
    if grep -q -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 (missing '$2' in $1)"
    fi
}

assert_not_contains() {
    if grep -q -- "$2" "$1" 2>/dev/null; then
        fail "$3 (found '$2' in $1)"
    else
        pass "$3"
    fi
}

assert_count() {
    # `grep -c` prints 0 and exits non-zero on no match; masking the status keeps
    # the captured value a single number instead of "0" plus a fallback "0".
    actual="$(grep -c -- "$2" "$1" 2>/dev/null || true)"
    if [ "$actual" = "$3" ]; then
        pass "$4"
    else
        fail "$4 (expected $3 occurrence(s) of '$2', found $actual)"
    fi
}

assert_equal() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected '$2', got '$1')"
    fi
}

# --- fixture -----------------------------------------------------------------

new_fixture() {
    name="$1"
    sys="$WORK/$name/system_root/system"
    mkdir -p "$sys/etc/selinux"
    mkdir -p "$WORK/$name/system_root/vendor/etc/selinux"
    cat > "$sys/etc/selinux/plat_sepolicy.cil" <<'POLICY'
;; stand-in platform policy used by tools/cil_selftest.sh
(type sysfs)
(typeattribute file_type)
(typeattribute sysfs_type)
(type init)
(type priv_app)
(type system_app)
(type platform_app)
(type untrusted_app)
(genfscon sysfs / u:object_r:sysfs:s0)
POLICY
    # A precompiled policy, to exercise the "left in place" reporting path.
    : > "$WORK/$name/system_root/vendor/etc/selinux/precompiled_sepolicy"
    echo "$sys"
}

hash_of() {
    sha256sum "$1" | cut -d' ' -f1
}

echo "== TorchBridge SELinux injection self-test =="
echo

# --- 1. inject ---------------------------------------------------------------

SYS="$(new_fixture basic)"
POLICY="$SYS/etc/selinux/plat_sepolicy.cil"
ORIGINAL="$(hash_of "$POLICY")"

sh "$INJECT" inject "$SYS" > "$WORK/inject.log" 2>&1 ||
    fail "inject exited non-zero: $(tail -3 "$WORK/inject.log" | tr '\n' ' ')"

assert_contains "$POLICY" "TORCHBRIDGE BEGIN" "block appended with begin marker"
assert_contains "$POLICY" "TORCHBRIDGE END" "block terminated with end marker"
assert_count "$POLICY" "(type torchnode)" 1 "the new type is declared exactly once"
assert_contains "$POLICY" "(allow priv_app torchnode" "priv_app granted the node"
assert_contains "$POLICY" "(allow system_app torchnode" "system_app granted the node"
assert_contains "$POLICY" "(allow platform_app torchnode" "platform_app granted the node"
assert_not_contains "$POLICY" "allow untrusted_app torchnode" "untrusted_app is never granted the node"
assert_contains "$SYS/torchbridge-backup/plat_sepolicy.cil.orig" "(type sysfs)" "pristine original backed up"
assert_equal "$(hash_of "$SYS/torchbridge-backup/plat_sepolicy.cil.orig")" "$ORIGINAL" \
    "backup is byte-identical to the original"
assert_contains "$SYS/torchbridge-backup/manifest.txt" "bytes_before=" "manifest records the change"
assert_contains "$WORK/inject.log" "Precompiled" "precompiled policy reported"
HASH_AFTER_FIRST="$(hash_of "$POLICY")"

# --- 2. idempotency ----------------------------------------------------------

sh "$INJECT" inject "$SYS" > "$WORK/inject2.log" 2>&1 || fail "second inject exited non-zero"
assert_count "$POLICY" "TORCHBRIDGE BEGIN" 1 "re-flashing does not duplicate the block"
assert_count "$POLICY" "(type torchnode)" 1 "re-flashing does not duplicate the type"
assert_equal "$(hash_of "$POLICY")" "$HASH_AFTER_FIRST" \
    "re-flashing produces a byte-identical policy"
assert_equal "$(hash_of "$SYS/torchbridge-backup/plat_sepolicy.cil.orig")" "$ORIGINAL" \
    "re-flashing does not overwrite the pristine backup"

# --- 3. explicit domain narrowing -------------------------------------------

SYS_NARROW="$(new_fixture narrow)"
sh "$INJECT" inject "$SYS_NARROW" --domains system_app > /dev/null 2>&1 ||
    fail "inject --domains system_app exited non-zero"
POLICY_NARROW="$SYS_NARROW/etc/selinux/plat_sepolicy.cil"
assert_contains "$POLICY_NARROW" "(allow system_app torchnode" "explicit domain granted"
assert_not_contains "$POLICY_NARROW" "(allow priv_app torchnode" "other domains stay untouched"

# --- 4. refusal on an unsafe policy -----------------------------------------

SYS_BAD="$(new_fixture bad)"
BAD_POLICY="$SYS_BAD/etc/selinux/plat_sepolicy.cil"
# Drop the fs_type declaration the rule depends on.
sed -e '/^(type sysfs)/d' "$BAD_POLICY" > "$BAD_POLICY.tmp"
cat "$BAD_POLICY.tmp" > "$BAD_POLICY"
rm -f "$BAD_POLICY.tmp"
BAD_BEFORE="$(hash_of "$BAD_POLICY")"

if sh "$INJECT" inject "$SYS_BAD" > "$WORK/bad.log" 2>&1; then
    fail "inject accepted a policy without the 'sysfs' type"
else
    pass "inject refuses a policy missing a required type"
fi
assert_equal "$(hash_of "$BAD_POLICY")" "$BAD_BEFORE" "refused policy was left untouched"

if sh "$INJECT" inject "$WORK/does-not-exist" > /dev/null 2>&1; then
    fail "inject accepted a non-existent system directory"
else
    pass "inject refuses a non-existent system directory"
fi

# --- 5. dry run --------------------------------------------------------------

SYS_DRY="$(new_fixture dry)"
DRY_BEFORE="$(hash_of "$SYS_DRY/etc/selinux/plat_sepolicy.cil")"
sh "$INJECT" inject "$SYS_DRY" --dry-run > "$WORK/dry.log" 2>&1 || fail "dry run exited non-zero"
assert_equal "$(hash_of "$SYS_DRY/etc/selinux/plat_sepolicy.cil")" "$DRY_BEFORE" \
    "dry run writes nothing"
assert_contains "$WORK/dry.log" "(allow priv_app torchnode" "dry run prints the rules"

# --- 6. revert ---------------------------------------------------------------

sh "$INJECT" revert "$SYS" > "$WORK/revert.log" 2>&1 || fail "revert exited non-zero"
assert_equal "$(hash_of "$POLICY")" "$ORIGINAL" "revert restores the file byte-for-byte"
assert_not_contains "$POLICY" "TORCHBRIDGE" "revert removes every marker"

# --- 7. emitted block shape --------------------------------------------------

sh "$INJECT" emit "priv_app system_app" > "$WORK/block.cil" 2>&1 || fail "emit exited non-zero"
OPEN="$(tr -cd '(' < "$WORK/block.cil" | wc -c | tr -d ' ')"
CLOSE="$(tr -cd ')' < "$WORK/block.cil" | wc -c | tr -d ' ')"
assert_equal "$OPEN" "$CLOSE" "emitted block has balanced parentheses"
assert_contains "$WORK/block.cil" \
    "(genfscon sysfs /devices/platform/flashlights-mt6360/torchbrightness" \
    "emitted block labels the hyphenated platform device path"
assert_contains "$WORK/block.cil" \
    "(genfscon sysfs /devices/platform/flashlights_mt6360/torchbrightness" \
    "emitted block labels the underscored platform device path too"
assert_not_contains "$WORK/block.cil" "(permissive " "no permissive statement anywhere"

# --- summary -----------------------------------------------------------------

echo
echo "== $PASS passed, $FAIL failed =="

[ "$FAIL" = "0" ] || exit 1
exit 0
