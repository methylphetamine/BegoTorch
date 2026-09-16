# TorchBridge — the flashable package

This archive is an ordinary recovery-flashable zip: **TWRP → Install → select the
zip → swipe to confirm**. No terminal, no commands, no prompts. The installer
reports progress in the recovery UI and writes its full log to
`/tmp/torchbridge-install.log` on the device.

Removal is the same shape: flash `torchbridge-uninstall.zip`.

## What the installer writes

| Path | What it is |
|---|---|
| `/system_root/system/priv-app/TorchBridge/base.apk` | the component. Scanned by the package manager at boot, so it is registered with no user interaction. No launcher icon, no activity. |
| `/system_root/system/etc/permissions/privapp-permissions-com.begonia.torchbridge.xml` | the privileged-permission allowlist. Required, not decorative: from Android 9 a priv-app declaring a privileged permission without an allowlist entry can fail to boot. |
| `/system_root/system/etc/init/torchbridge.rc` | boot-time `chmod 0666` / `chown system` for the torch node, so the DAC half holds on every boot even on a stock kernel. |
| `/system_root/system/etc/selinux/plat_sepolicy.cil` | the SELinux rule is appended here (and `/system_root/system/torchbridge-backup/` keeps the pristine original). |

**`/system_root` is used, always.** On a System-as-Root device that is the mount
point of the system image and the only path that reliably accepts writes; the
`/system` path TWRP also exposes is a bind mount of the same image, which is where
"read-only file system" and EROFS errors come from. The scripts fall back to
`/system` only when `/system_root` does not exist, which means they were run on an
already-booted system.

## Terminal alternative (not required)

The same logic the swipe-to-flash installer runs is available directly, which is
useful for dry runs and for narrowing the policy change:

```sh
cd /tmp
unzip -o torchbridge-flashable.zip
sh torchbridge/scripts/flash.sh --dry-run             # show every step, write nothing
sh torchbridge/scripts/flash.sh                       # install
sh torchbridge/scripts/flash.sh --domains system_app  # narrow the SELinux grant
sh torchbridge/scripts/flash.sh --no-selinux          # skip the policy change
sh torchbridge/scripts/install.sh                     # verify
sh torchbridge/scripts/uninstall.sh                   # remove everything
```

## Verify after flashing

From the recovery shell (`sh torchbridge/scripts/install.sh`), or from a booted
system — the first two need no root:

```sh
ls -lZ /system_root/system/etc/selinux/plat_sepolicy.cil | grep -c TORCHBRIDGE  # recovery
ls -lZ /sys/devices/platform/flashlights-mt6360/torchbrightness
ls -lZ /sys/devices/platform/flashlights_mt6360/torchbrightness
#   -> mode 0666 and label u:object_r:torchnode:s0 (whichever spelling this kernel created)
settings get secure sysui_qs_tiles
#   -> should list com.begonia.torchbridge/.TorchTileService
getenforce          # -> Enforcing
```

The tile subtitle is the fastest signal: it names the path in use — `torch node`,
`LED class`, `camera strength API` or `camera on/off`.

## If the flash fails

| Message | Meaning |
|---|---|
| `no system partition with a priv-app directory is mounted` | mount System in TWRP (Mount → System) and flash again |
| `could not write to ...` + EROFS/read-only | the ROM's system image is read-only and cannot be modified from recovery; this install method cannot be used on it |
| `the SELinux rule was not applied` (a warning, not a failure) | the app is installed and the tiles will work through the camera framework path; re-flash with the system partition mounted read-write to get full 0–7 strength |
| `! The installer failed (exit N)` | read `/tmp/torchbridge-install.log`; the failing step is named there |

## If the device does not boot afterwards

The only change that can plausibly cause that is the policy injection, and it is
reversible:

```sh
# from TWRP -> Advanced -> Open Terminal
sh torchbridge/scripts/selinux_inject.sh revert /system_root/system
```

or simply flash `torchbridge-uninstall.zip`. `revert` restores the file
byte-for-byte from `/system_root/system/torchbridge-backup/`, which is taken before
the first write and never overwritten by later flashes.
