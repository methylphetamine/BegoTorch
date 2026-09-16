#!/bin/sh
#
# selinux_inject.sh — apply or revert the TorchBridge SELinux rule.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The kernel half is already solved: powa_karnal's MT6360 driver registers
# `dev_attr_torchbrightness` with mode 0666, so an unprivileged process may open
# the node. What the kernel cannot do is change the node's SELinux label: the
# attribute inherits `sysfs` from its platform device, and `sysfs` is exactly the
# type that no ROM lets an app domain write. That one label is why torch apps on
# this device historically needed root.
#
# This script relabels the torch knobs with a dedicated `torchnode` type and
# grants that type to the system application domains. SELinux stays ENFORCING:
# there is no permissive domain, no `permissive` statement and no `setenforce 0`
# anywhere in this project. The result is a policy change one node wide, applied
# once at flash time, with no runtime privilege of any kind.
#
# USAGE
# -----
#   sh selinux_inject.sh inject <system-dir> [--domains a,b,c] [--dry-run]
#                                            [--drop-precompiled]
#   sh selinux_inject.sh revert <system-dir>
#   sh selinux_inject.sh emit   <domains> [cil-file]
#
# <system-dir> is the directory that holds `etc/selinux/`, i.e. the system
# partition's root (for a System-as-Root device: /system_root/system).
#
# `emit` prints the expanded rule block to stdout and is what the offline test in
# tools/cil_selftest.sh uses, so the shipped rules and the tested rules are
# literally the same text.
#
# SAFETY MODEL
# ------------
# A policy that does not compile does not boot, so every step is defensive:
#
#   * Refuse to touch a file that does not look like the platform policy.
#   * Only ever reference types that the target policy already declares
#     (a new type name, or a domain the ROM lacks, would break the compile).
#   * Back the file up byte-for-byte before writing, and record what was done.
#   * Never inject twice: the block is bounded by markers and replaced in place.
#   * `revert` restores the original file from that backup.
#
# See docs/selinux-injection.md for the security analysis of the rule itself.
#
set -e

BEGIN_MARK=";; ===> TORCHBRIDGE BEGIN (managed by twrp/selinux_inject.sh)"
END_MARK=";; <=== TORCHBRIDGE END"
BACKUP_DIR_NAME="torchbridge-backup"
MANIFEST="manifest.txt"

# Domains that shipped Android releases put system apps in, newest first. The
# script grants only those that actually exist in the target policy.
DOMAIN_CANDIDATES="priv_app system_app platform_app"

# Types the rule block references. Everything except `torchnode` (which the block
# defines itself) must already be declared by the ROM.
REQUIRED_TYPES="sysfs file_type sysfs_type init"

die() {
    echo "error: $*" >&2
    exit 1
}

say() {
    echo "$*"
}

# --- locating things ---------------------------------------------------------

# Prints the platform policy path for a system dir, or nothing.
find_policy() {
    for candidate in \
        "$1/etc/selinux/plat_sepolicy.cil" \
        "$1/system/etc/selinux/plat_sepolicy.cil" \
        "$1/etc/selinux/system_ext_sepolicy.cil"
    do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# True when the policy declares this type or attribute.
#
# Attributes matter as much as types here: the rule references `file_type` and
# `sysfs_type`, which a CIL policy declares with `(typeattribute ...)` rather than
# `(type ...)`. Matching only `(type ...)` would make the injector refuse every
# real ROM.
policy_has_type() {
    grep -qE "^\((type|typeattribute|typealias|typeinit)[[:space:]]+$2([[:space:]]|\))" \
        "$1" 2>/dev/null
}

# Prints the domains from $DOMAIN_CANDIDATES that the policy declares.
detect_domains() {
    found=""
    for domain in $DOMAIN_CANDIDATES; do
        if policy_has_type "$1" "$domain"; then
            found="$found $domain"
        fi
    done
    echo "$found"
}

# Prints the expanded rule block for the given domain list.
# Reads twrp/torchbridge.cil (this script's sibling) as the template.
emit_block() {
    domains="$1"
    template="$2"
    [ -f "$template" ] || die "missing rule template: $template"

    rules=""
    for domain in $domains; do
        rules="$rules(allow $domain torchnode (file (append getattr ioctl lock map open read write)))
"
        rules="$rules(allow $domain sysfs (dir (search)))
"
    done

    printf '%s\n' "$BEGIN_MARK"
    awk -v rules="$rules" '
        /;;@DOMAIN_RULES@/ { printf "%s", rules; next }
        { print }
    ' "$template" | sed '/;;@DOMAIN_RULES@/d'
    printf '%s\n' "$END_MARK"
}

script_dir() {
    echo "$(cd "$(dirname "$0")" && pwd)"
}

# --- injecting ---------------------------------------------------------------

# Removes a previously injected block, so injecting twice is harmless.
strip_block() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { skipping = 1; next }
        skipping && $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$1"
}

# Reports any precompiled policy found next to the vendor partition. Touching the
# CIL sources changes the platform policy hash, which is precisely what makes init
# ignore a precompiled policy and recompile from CIL — so this is informational
# unless --drop-precompiled was requested.
handle_precompiled() {
    sys_dir="$1"
    drop="$2"
    backup="$3"

    for candidate in \
        "$sys_dir/../vendor/etc/selinux/precompiled_sepolicy" \
        "$sys_dir/vendor/etc/selinux/precompiled_sepolicy" \
        "/vendor/etc/selinux/precompiled_sepolicy"
    do
        if [ -f "$candidate" ]; then
            if [ "$drop" = "yes" ]; then
                mkdir -p "$backup/precompiled"
                mv "$candidate" "$backup/precompiled/precompiled_sepolicy"
                echo "$candidate" > "$backup/precompiled_path.txt"
                say "Precompiled  : moved aside (init will rebuild from CIL)"
            else
                say "Precompiled  : $candidate"
                say "               left in place — the patched CIL no longer matches its"
                say "               recorded hash, so init recompiles from source anyway."
            fi
            return 0
        fi
    done
    say "Precompiled  : none found; init always compiles from CIL here"
    return 0
}

cmd_inject() {
    sys_dir="$1"
    domains="$2"
    dry_run="$3"
    drop_precompiled="$4"

    [ -n "$sys_dir" ] || die "inject needs the system directory"
    [ -d "$sys_dir" ] || die "not a directory: $sys_dir"

    if ! policy="$(find_policy "$sys_dir")"; then
        die "no platform policy under $sys_dir/etc/selinux — is the system partition mounted?"
    fi
    say "Policy       : $policy"

    grep -q '(type ' "$policy" ||
        die "$policy does not look like CIL policy text; refusing to touch it"

    # Referencing a type the ROM does not define makes the policy fail to
    # compile, and a policy that does not compile does not boot. Fail closed.
    for required in $REQUIRED_TYPES; do
        policy_has_type "$policy" "$required" ||
            die "policy does not declare '$required'; not injecting (unsafe)"
    done

    if [ -z "$domains" ]; then
        domains="$(detect_domains "$policy")"
    else
        domains="$(echo "$domains" | tr ',' ' ')"
    fi
    [ -n "$domains" ] ||
        die "policy declares none of [$DOMAIN_CANDIDATES]; no app domain could use the rule"
    say "Domains      : $(echo "$domains" | tr '\n' ' ')"

    for domain in $domains; do
        policy_has_type "$policy" "$domain" ||
            die "policy does not declare domain '$domain'; not injecting (unsafe)"
    done

    block="$(emit_block "$domains" "$(script_dir)/torchbridge.cil")"

    if [ "$dry_run" = "yes" ]; then
        say "--- dry run: this is the block that would be appended ---"
        printf '%s\n' "$block"
        return 0
    fi

    backup="$sys_dir/$BACKUP_DIR_NAME"
    mkdir -p "$backup"

    # Keep the pristine original exactly once, so re-flashing never overwrites the
    # only good copy with an already-patched file.
    if [ ! -f "$backup/plat_sepolicy.cil.orig" ]; then
        cp "$policy" "$backup/plat_sepolicy.cil.orig"
        say "Backup       : $backup/plat_sepolicy.cil.orig"
    else
        say "Backup       : already present, kept as is"
    fi

    staged="$policy.torchbridge.staged"
    # Trailing blank lines are trimmed before the block is appended, so that
    # re-flashing produces a byte-identical file instead of accumulating one blank
    # line per flash.
    strip_block "$policy" | awk '
        { line[NR] = $0 }
        END {
            last = NR
            while (last > 0 && line[last] == "") last--
            for (i = 1; i <= last; i++) print line[i]
        }
    ' > "$staged"
    printf '\n' >> "$staged"
    printf '%s\n' "$block" >> "$staged"

    # Cheap structural guard: a half-written block would be fatal, so verify the
    # staged policy is at least balanced before it goes anywhere near the device.
    opens="$(tr -cd '(' < "$staged" | wc -c | tr -d ' ')"
    closes="$(tr -cd ')' < "$staged" | wc -c | tr -d ' ')"
    [ "$opens" = "$closes" ] ||
        die "staged policy is unbalanced ($opens '(' vs $closes ')'); nothing written"
    grep -q 'torchnode' "$staged" || die "staged policy lost the injected type; nothing written"

    before="$(wc -c < "$policy" | tr -d ' ')"
    # Truncate in place instead of replacing the file: keeping the same inode
    # preserves the policy file's mode and SELinux label, which a freshly created
    # file would not inherit.
    cat "$staged" > "$policy"
    rm -f "$staged"
    after="$(wc -c < "$policy" | tr -d ' ')"
    sync

    handle_precompiled "$sys_dir" "$drop_precompiled" "$backup"

    {
        echo "policy=$policy"
        echo "bytes_before=$before"
        echo "bytes_after=$after"
        echo "domains=$(echo "$domains" | tr '\n' ',')"
        echo "date=$(date -u 2>/dev/null || echo unknown)"
    } > "$backup/$MANIFEST"

    say "Injected     : $before -> $after bytes"
    say "Recorded     : $backup/$MANIFEST"
    return 0
}

# --- reverting ---------------------------------------------------------------

cmd_revert() {
    sys_dir="$1"
    [ -n "$sys_dir" ] || die "revert needs the system directory"
    [ -d "$sys_dir" ] || die "not a directory: $sys_dir"

    if ! policy="$(find_policy "$sys_dir")"; then
        die "no platform policy under $sys_dir/etc/selinux — is the system partition mounted?"
    fi
    backup="$sys_dir/$BACKUP_DIR_NAME"

    if [ -f "$backup/plat_sepolicy.cil.orig" ]; then
        # The byte-for-byte original, so the policy returns to exactly its
        # ROM-shipped state (comments, whitespace and all).
        cat "$backup/plat_sepolicy.cil.orig" > "$policy"
        say "Restored     : $policy from $backup/plat_sepolicy.cil.orig"
    else
        # No backup (for example the flash was interrupted): the best that can be
        # done is to remove the block, which is still enough to disable the rule.
        staged="$policy.torchbridge.staged"
        strip_block "$policy" > "$staged"
        cat "$staged" > "$policy"
        rm -f "$staged"
        say "Restored     : no backup found, removed the injected block only"
    fi

    # Put back a precompiled policy if the flash moved one aside.
    if [ -f "$backup/precompiled_path.txt" ] && [ -f "$backup/precompiled/precompiled_sepolicy" ]; then
        original="$(cat "$backup/precompiled_path.txt")"
        if mkdir -p "$(dirname "$original")" 2>/dev/null; then
            mv "$backup/precompiled/precompiled_sepolicy" "$original"
            rm -f "$backup/precompiled_path.txt"
            say "Restored     : $original"
        fi
    fi

    sync
    say "Reverted. Reboot for the ROM's own policy to be back in force."
    return 0
}

# --- entry point -------------------------------------------------------------

usage() {
    sed -n '3,30p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

main() {
    [ $# -ge 1 ] || {
        usage
        exit 1
    }

    command="$1"
    shift

    if [ "$command" = "emit" ]; then
        emit_block "${1:-$DOMAIN_CANDIDATES}" "${2:-$(script_dir)/torchbridge.cil}"
        exit 0
    fi

    sys_dir=""
    domains=""
    dry_run="no"
    drop_precompiled="no"

    while [ $# -gt 0 ]; do
        case "$1" in
            --domains)
                [ $# -ge 2 ] || die "--domains needs a value"
                domains="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="yes"
                shift
                ;;
            --drop-precompiled)
                drop_precompiled="yes"
                shift
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                if [ -z "$sys_dir" ]; then
                    sys_dir="$1"
                else
                    die "unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    case "$command" in
        inject) cmd_inject "$sys_dir" "$domains" "$dry_run" "$drop_precompiled" ;;
        revert) cmd_revert "$sys_dir" ;;
        *)
            die "unknown command '$command' (expected: inject, revert or emit)"
            ;;
    esac
}

main "$@"
