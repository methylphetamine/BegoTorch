# BegoTorch — TWRP-flashable install

This archive installs **BegoTorch** onto a begonia (Redmi Note 8 Pro) device
**as a system priv-app**, so Android registers it automatically on the first
boot after flashing. Installing a privileged system app is the supported way to
ship an app without user interaction — no `su`, Magisk, KernelSU, or APatch is
involved at any point.

## What it installs

* `system/begotorch/app.apk` — the app binary. `flash.sh` copies it to
  `<system>/priv-app/BegoTorch/base.apk`, the location Android's package
  manager scans at boot.
* `scripts/flash.sh` — TWRP recovery installer (runs as root in the recovery
  shell). Detects the system mount layout automatically:
  * System-as-Root image mounted at `/system_root` → installs to
    `/system_root/system/priv-app/BegoTorch/`
  * Legacy layout mounted at `/system` → installs to `/system/priv-app/BegoTorch/`
  You can also pass an explicit mount point: `sh scripts/flash.sh /my_mount`.
* `scripts/install.sh` — post-flash verification hook (checks the APK landed).
* `scripts/uninstall.sh` — removes the app again (also cleans up the payload
  directory written by the first version of this package).
* `twrp.json` — machine-readable metadata (package name, install path, torch
  node path, root requirements).

## What this does NOT do

Flashing an app as priv-app removes the need for root **to install and run the
app**. Whether the app can actually write the torch sysfs node
(`/sys/devices/platform/flashlights_mt6360/torchbrightness`) is decided by the
ROM — by the node's ownership/permissions and its SELinux policy. If your ROM
protects that node from all apps, the app will report "Torch node not
writable"; that is a kernel/SELinux restriction, not a missing root grant, and
no installer can bypass it from an app sandbox.

## How to flash (TWRP)

1. Copy this zip onto the device (e.g. to `/tmp` of the TWRP environment).
2. Boot TWRP and open **Advanced → Open Terminal**.
3. Run:

   ```sh
   cd /tmp
   unzip -o begotorch-flashable.zip
   sh begotorch/scripts/flash.sh
   ```

4. Reboot into the system.

On the first boot Android scans `priv-app/` and registers BegoTorch as a
pre-installed privileged app. It can take a minute to appear in the launcher
after the first reboot.

## After flashing

* Open BegoTorch and drag the dial — brightness writes go straight to the torch
  node, with no `su` and no per-boot root approval.
* The same holds for the Quick Settings **Torch** tile.

## Uninstalling

From TWRP **Advanced → Open Terminal**, with the system partition mounted:

```sh
cd /tmp
unzip -o begotorch-flashable.zip
sh begotorch/scripts/uninstall.sh
```

This deletes `<system>/priv-app/BegoTorch/` (and any leftover
`<system>/begotorch/` payload directory from older versions). Reboot
afterwards.

## If the device names the torch node differently

BegoTorch talks to `/sys/devices/platform/flashlights_mt6360/torchbrightness`.
If your ROM uses a different node, update `kTorchDevice` in `lib/main.dart`,
`TORCH_DEVICE` in `android/app/src/main/kotlin/com/begonia/begotorch/TorchTileService.kt`,
and `torch_path` in `tools/make_twrp_zip.sh`, then rebuild and re-flash.