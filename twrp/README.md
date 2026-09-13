# BegoTorch — TWRP-flashable install

This archive installs **BegoTorch** onto a begonia device (Redmi Note 8 Pro,
Fuchsia) **already privileged**, so changing the torch intensity never needs a
root grant, `su`, Magisk, KernelSU, or APatch.

## What it installs

* `system/begotorch/app.apk` — the app binary.
* `system/begotorch/begotorch.cml` — the **component manifest** that grants the
  app the filesystem capability to write the torch brightness node. This is the
  "su access baked in" part: the authority lives in the installed package, not
  in a runtime tool.
* `system/begotorch/begotorch.far` — the Fuchsia package archive, when the CI
  build produces one.
* `scripts/flash.sh` — TWRP recovery installer (runs as root, places the files
  into the system partition).
* `scripts/install.sh` — idempotent post-flash hook.
* `scripts/uninstall.sh` — TWRP recovery uninstaller (removes everything
  `flash.sh` wrote).
* `TwrJSON` — machine-readable metadata (package name, system mount, torch
  path, root requirements).

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

## After flashing

* Open BegoTorch and drag the dial — brightness writes succeed directly,
  with no `su`, no Magisk/KernelSU, no per-boot root approval.
* The same holds for the Quick Settings **Torch** tile.

## Uninstalling

From TWRP **Advanced → Open Terminal**, with the system partition mounted:

```sh
cd /tmp
unzip -o begotorch-flashable.zip
sh begotorch/scripts/uninstall.sh
```

This removes the app binary, the component manifest, and the `.flashed`
marker from `/system`, so BegoTorch no longer launches and no longer holds the
torch capability grant. Reboot afterwards.

You can also remove it by hand from TWRP by deleting the `begotorch/`
directory under the system mount (everything `flash.sh` created lives there).

## If the device changes its node name

BegoTorch talks to `/sys/devices/platform/flashlights_mt6360/torchbrightness`.
If your begonia image names the node differently, update `torch_path` in
`TwrJSON`, the path in `config/begotorch.cml`, rebuild, and re-flash. The
app reads its target path from the same manifest, so keeping them in sync is
all that is required.