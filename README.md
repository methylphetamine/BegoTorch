# BegoTorch

Torch brightness control app for begonia (Redmi Note 8 Pro).

## What it does

A round 8-stop slider (brightness 0–7) that sets the torch level by writing
straight to the device node:

    /sys/devices/platform/flashlights_mt6360/torchbrightness

## No root required at runtime

BegoTorch runs **without root escalation** – no `su`, no Magisk, no KernelSU,
no APatch, and no per-boot root grant.

The write authority is **baked into the installed package** by the component
manifest at `config/begotorch.cml`. When that manifest is flashed onto the
device, BegoTorch already owns the filesystem capability to write the torch
node, so changing intensity just works.

You do not need a rooted system or any root manager installed.

## Quick Settings tile

`TorchTileService` (Kotlin, `android/app/src/main/kotlin/`) adds a "Torch"
tile that toggles brightness 0 ⇄ 7 with a single tap. It writes the node
directly using the same capability as the app (no su), on a worker thread, and
syncs its state from the node when the panel opens.

Add it from the QS editor (drag the "Torch" tile into the panel). It needs no
root either.

## Install (TWRP-flashable zip)

The CI build produces `begotorch-flashable.zip` (the `begotorch-flashable-zip`
artifact). It installs the app *already privileged*.

1. Copy `begotorch-flashable.zip` onto the device.
2. Boot TWRP → **Advanced → Open Terminal**.
3. Run:

   ```sh
   cd /tmp
   unzip -o begotorch-flashable.zip
   sh begotorch/scripts/flash.sh
   ```

4. Reboot into the system.

Once flashed, BegoTorch has the torch capability from the fused component
manifest — no root setup, ever.

See `twrp/README.md` for details on the archive layout and how to rebuild if
your device names the torch node differently.

### Uninstalling

From TWRP **Advanced → Open Terminal**:

```sh
cd /tmp
unzip -o begotorch-flashable.zip
sh begotorch/scripts/uninstall.sh
```

This deletes the app, its component manifest, and the flash marker from the
system partition, so BegoTorch stops launching and loses the torch capability
grant (see `twrp/README.md`).

## Build

GitHub Actions builds a release APK and the TWRP-flashable zip on every push
to `main` (`.github/workflows/build.yml`).

Locally:

    flutter pub get
    flutter analyze
    flutter test
    flutter build apk --release
    tools/make_twrp_zip.sh --apk build/app/outputs/flutter-apk/app-release.apk

