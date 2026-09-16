# The SELinux injection, explained and audited

This document is the honest accounting of the one privileged change TorchBridge
makes to a device: a small append to the platform SELinux policy at flash time.

## The problem in one paragraph

`powa_karnal` already publishes the torch knob with mode `0666`
(`dev_attr_torchbrightness` in `flashlights-mt6360-mt6785.c`), so the DAC layer is
solved: any process may `open()` the node for writing. The node's SELinux label,
however, is inherited from its platform device and is `sysfs` — and no Android ROM
permits an application domain to write `sysfs`. That single label is why torch
control on this device has historically meant root. A kernel patch cannot fix it:
**the kernel does not decide labels**, the policy does. So the label has to be
changed where the policy lives, once, at flash time.

## What is injected

`twrp/torchbridge.cil` (audit this file — it is short) contributes exactly:

```cil
(type torchnode)
(typeattributeset file_type (torchnode))
(typeattributeset sysfs_type (torchnode))

(genfscon sysfs /devices/platform/flashlights-mt6360/torchbrightness u:object_r:torchnode:s0)
(genfscon sysfs /devices/platform/flashlights_mt6360/torchbrightness u:object_r:torchnode:s0)
... the LED-class brightness files, both device-name spellings ...

(allow init      torchnode (file (getattr setattr open read write)))
(allow <domain>  torchnode (file (append getattr ioctl lock map open read write)))
(allow <domain>  sysfs     (dir (search)))
```

where `<domain>` is substituted at flash time with **only those domains the target
ROM's policy actually declares**, from `priv_app`, `system_app`, `platform_app`.
Referencing a type a ROM does not define would break the policy compile, and a
policy that does not compile does not boot, so that filtering is a safety
requirement rather than a nicety.

## What it does and does not grant

| | |
|---|---|
| **Grants** | read/write on the torch brightness files, to system application domains, plus directory *search* on `sysfs` so the path can be traversed |
| **Does not grant** | anything to `untrusted_app` (never, in any configuration); any capability on the rest of `sysfs`; any ability to relabel anything; any permissive mode; any root |
| **Enforcement** | unchanged. There is no `(permissive ...)`, no permissive domain, no `setenforce 0`. `tools/cil_selftest.sh` fails the build if `(permissive ` ever appears in the injected block |
| **Blast radius** | one attribute on one platform device, plus its three LED-class children |

Because the rule labels *specific file paths* rather than the whole
`flashlights*` device tree, the flash/strobe attributes that the vendor flashlight
HAL reaches keep their original labels and their original access.

## The trade-off, stated plainly

The grant covers the **system app domains as a group**, because the domains are
fixed at policy build time and Android offers no per-package policy mechanism that
can be added from recovery. In practice this means: any app installed in
`/system/priv-app` or `/system` can now set torch brightness without root, and
nothing more than that — the node clamps writes to `0..7` in the driver
(`torchbrightness_store()`), so the worst an attacker gains is control of the
flashlight.

Alternatives and where they land:

| Approach | Root needed | Enforcing kept | Blast radius |
|---|---|---|---|
| **This injection** | only to flash | yes | one node, system app domains |
| `setenforce 0` / permissive domain | no | **no** | entire device |
| su / Magisk / KernelSU module | yes | yes | arbitrary code as root |
| ROM-side camera provider extension ([upstream 973a253](https://github.com/Saikrishna1504/device_redmi_begonia/commit/973a253c914786c46d2d4de6549d3911db1b4e43)) | no | yes | one process (`cameraserver`) |
| Dedicated per-app domain | n/a | yes | narrowest, but needs a `seapp_contexts` entry matched to a signature, which cannot be added safely from recovery |

## Why it is safe to apply with a swipe

1. **Fail closed.** Before writing anything the injector requires the target file to
   look like CIL and to declare `sysfs`, `file_type`, `sysfs_type` and `init`. If
   any is missing it refuses and touches nothing.
2. **Backup first.** The pristine file is copied to
   `<system>/torchbridge-backup/plat_sepolicy.cil.orig` before the first write, and
   is never overwritten by later flashes — so re-flashing cannot destroy the only
   good copy.
3. **Structural check.** The staged policy must have balanced parentheses and must
   still contain the injected type, or nothing is written.
4. **In-place write.** The patched content is written into the existing inode with
   `cat > file` rather than replacing the file, so the policy file keeps its mode
   and its SELinux label.
5. **Idempotent.** The block is bounded by markers and replaced in place, so
   flashing repeatedly cannot accumulate duplicate type declarations — a duplicate
   `(type torchnode)` would be a compile error.
6. **Reversible.** `revert` (and the uninstall zip) restores the file byte-for-byte
   and removes the backup directory.

If a device ever fails to boot after flashing, recovery is either:

```sh
sh torchbridge/scripts/selinux_inject.sh revert /system_root/system
```

from the recovery terminal, or flashing `torchbridge-uninstall.zip`.

On the `precompiled_sepolicy` question: a vendor partition may ship a
pre-compiled policy, and init prefers it when its recorded hash matches the
platform policy files. Because the injection *changes* `plat_sepolicy.cil`, that
hash no longer matches and init recompiles from the CIL sources instead, which is
where the new rules are. The installer reports whether a precompiled policy exists,
and `--drop-precompiled` is available for the rare ROM where the hash file is
absent and init's behaviour is unclear.

## Auditing a running device

```sh
# The label and mode the rule produces (no root needed):
ls -lZ /sys/devices/platform/flashlights-mt6360/torchbrightness
#   -> -rw-rw-rw-  ...  u:object_r:torchnode:s0

# Every rule the injection added:
grep -A40 'TORCHBRIDGE BEGIN' /system/etc/selinux/plat_sepolicy.cil

# Confirm enforcement is still on:
getenforce                 # -> Enforcing

# Any denied write attempts, whatever the cause:
dmesg | grep -i 'avc.*torchnode'
```

An `avc: denied` naming `torchnode` means some domain outside the granted set is
writing. `tools/diag_torch.sh` captures the node's mode and label, the granted
domains, the QS panel state and the surrounding denials in one file, which is the
fastest way to report a ROM-specific problem.

## What was verified, and what was not

**Verified automatically** by `tools/cil_selftest.sh` (27 assertions, run by CI on
every push):

* the block is appended exactly once, and re-flashing cannot duplicate it;
* only domains the policy declares are granted;
* `untrusted_app` is never granted, in any configuration;
* a policy missing a required type is refused, with the file left untouched;
* a non-existent system directory is refused;
* `--dry-run` writes nothing;
* `revert` restores the file byte-for-byte and removes every marker;
* the emitted block is balanced, labels both platform-device spellings, and
  contains no permissive statement.

**Not verified automatically:** that a full ROM policy still *compiles* with the
block appended. That needs `secilc` plus a complete matching platform policy, and
neither exists in a recovery environment — the structural and reference checks
above are the strongest guard that can run there. The first boot after flashing is
the definitive test, which is exactly why the backup is taken before the first
write and why `revert` exists.
