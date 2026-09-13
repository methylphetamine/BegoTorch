# BegoTorch

Torch brightness control app for begonia (Redmi Note 8 Pro).

## What it does

A round 8-stop slider (brightness 0–7) that sets the torch level by writing
straight to the device node:

    /sys/devices/platform/flashlights_mt6360/torchbrightness

## No root required at runtime

BegoTorch runs **without root escalation** – no `su`, no Magisk, no KernelSU,
no APatch, and no per-boot root grant.

Instead of escalating, BegoTorch writes the torch node directly. Installed as
a system priv-app (via the TWRP-flashable zip), it runs as a pre-installed
system app — the strongest standard install position an app can have. Whether
the torch node is writable then depends only on the ROM's sysfs ownership and
SELinux policy (see `twrp/README.md`), not on any su binary being present.

## Quick Settings tile

`TorchTileService` (Kotlin, `android/app/src/main/kotlin/`) adds a "Torch"
tile that toggles brightness 0 ⇄ 7 with a single tap. It writes the node
directly using the same capability as the app (no su), on a worker thread, and
syncs its state from the node when the panel opens.

Add it from the QS editor (drag the "Torch" tile into the panel). It needs no
root either.

## Install (TWRP-flashable zip)

The CI build produces `begotorch-flashable.zip` (the `begotorch-flashable-zip`
artifact). It installs BegoTorch **as a system priv-app**, so Android
registers it automatically on the first boot after flashing — no su/Magisk/
KernelSU involved in the install.

1. Copy `begotorch-flashable.zip` onto the device.
2. Boot TWRP → **Advanced → Open Terminal**.
3. Run:

   ```sh
   cd /tmp
   unzip -o begotorch-flashable.zip
   sh begotorch/scripts/flash.sh
   ```

4. Reboot into the system. BegoTorch appears as a pre-installed app.

See `twrp/README.md` for details (which mount layouts the installer detects,
and the honest limits: priv-app placement does not by itself override the
ROM's sysfs/SELinux restrictions on the torch node — the powa_karnal kernel
handles that by shipping the node world-writable).

### Uninstalling

From TWRP **Advanced → Open Terminal**:

```sh
cd /tmp
unzip -o begotorch-flashable.zip
sh begotorch/scripts/uninstall.sh
```

This deletes `<system>/priv-app/BegoTorch/`, so BegoTorch is gone after reboot
(see `twrp/README.md`).

## Build

GitHub Actions builds a release APK and the TWRP-flashable zip on every push
to `main` (`.github/workflows/build.yml`).

Locally:

    flutter pub get
    flutter analyze
    flutter test
    flutter build apk --release
    tools/make_twrp_zip.sh --apk build/app/outputs/flutter-apk/app-release.apk

