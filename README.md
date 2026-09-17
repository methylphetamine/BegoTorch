# TorchBridge

Rootless torch **strength** control for begonia (Redmi Note 8 Pro / MT6785), living in
the Quick Settings panel. Flash one zip in TWRP, reboot, and two tiles are already
in the panel. No root, no su, no Magisk/KernelSU/APatch, no SELinux permissive, and
no app to open.

## What you actually get

| | |
|---|---|
| **Torch** tile | tap to toggle the torch on/off at your preferred strength (remembered) |
| **Torch strength** tile | tap to open an 8-stop picker (0–7) *inside* the QS panel |
| Install | TWRP "Open Terminal" → one script → reboot |
| Runtime privileges | none — SELinux stays enforcing, no su binary is involved |
| App to launch | none. The component has no launcher icon and no activity |

The tiles are inserted into the QS panel by the component itself on the first boot,
so there is no setup step and nothing to drag.

## Why this needed flash-time work at all

Three separate obstacles stand between an app and the torch knob on this device, and
they have to be solved in three different layers:

1. **DAC (kernel).** `powa_karnal` already exposes `dev_attr_torchbrightness` with
   mode `0666` (`drivers/misc/mediatek/flashlight/flashlights-mt6360-mt6785.c`), so an
   unprivileged process may open the node. On a stock kernel the attribute is `0644`
   and root-owned, where no app can write it whatever the policy says.
2. **SELinux (policy).** The attribute inherits the `sysfs` type from its platform
   device, and no ROM lets an application domain write `sysfs`. This one label is the
   entire reason torch apps on this device historically had to ask for root — and it is
   the piece that [a kernel patch cannot fix](docs/selinux-injection.md), because the
   kernel does not decide labels.
3. **Boot persistence (init).** Whatever the flash does has to still be true after the
   next reboot, and on every boot after that.

TorchBridge solves layer 2 with a **flash-time policy injection** and layer 3 with an
init snippet, which leaves layer 1 solved by the kernel it is flashed alongside. That
is why flashing — and not an app with more permissions — is the right shape for this
problem.

## Install

Download `torchbridge-flashable.zip` (CI builds it as the `torchbridge-flashable-zip`
artifact), then:

1. Copy the zip to the device — any storage TWRP can read.
2. **TWRP → Install → select the zip → swipe to confirm.** The installer reports its
   progress in the recovery UI; there is no terminal step and nothing to type.
3. Reboot.

Pull down the shade: the two tiles are already there.

Everything is written under `/system_root/system/…` — on a System-as-Root device
that is the system image's mount point and the only path that reliably accepts
writes; `/system` is a bind mount of the same image and is where EROFS errors come
from. See `twrp/README.md` for the full path table.

To remove it later, flash the uninstall package the same way. There are two
ways to get one:

* download `torchbridge-uninstall.zip` (CI ships it as the
  `torchbridge-flashable-zip` artifact's sibling); **or**
* **rename `torchbridge-flashable.zip` to anything containing `uninstall`**
  (e.g. `uninstall.zip` or `torchbridge-uninstall.zip`) and flash that — the
  same zip then uninstalls instead of installing.

Either way the ROM's original SELinux policy is restored byte-for-byte from the
backup the injector took on first flash.


There is also a terminal path with flags, for dry runs and for narrowing the policy
change (see `twrp/flash.sh --help`):

```sh
cd /tmp && unzip -o torchbridge-flashable.zip
sh torchbridge/scripts/flash.sh --dry-run            # show every step, write nothing
sh torchbridge/scripts/flash.sh --domains system_app # narrow the SELinux grant
sh torchbridge/scripts/flash.sh --no-selinux         # skip the policy change entirely
```

## Verify

From the recovery shell, before rebooting:

```sh
sh torchbridge/scripts/install.sh
```

From a normal booted system (the first two need no root):

```sh
ls -lZ /sys/devices/platform/flashlights-mt6360/torchbrightness
ls -lZ /sys/devices/platform/flashlights_mt6360/torchbrightness
#   -> mode 0666, label u:object_r:torchnode:s0
settings get secure sysui_qs_tiles
#   -> ends with com.begonia.torchbridge/.TorchTileService,...
```

The tile subtitle is the fastest diagnostic: it names the path in use
(`torch node`, `LED class`, `camera strength API` or `camera on/off`).

## Uninstall

```sh
cd /tmp && unzip -o torchbridge-flashable.zip
sh torchbridge/scripts/uninstall.sh
```

This restores the ROM's original policy file **byte-for-byte** from the backup the
injector took, then removes the APK, the allowlist and the init snippet.

## The one honest constraint

A Quick Settings tile cannot exist without a component APK: AOSP only accepts tiles
from a `TileService` declared with `BIND_QUICK_SETTINGS_TILE`, and only a real
package can declare one. There is no pure-policy or pure-shell route to a tile.

So TorchBridge ships the smallest possible one, and it is designed not to behave like
an app:

* no launcher activity, no icon in the drawer, nothing to open;
* its only surface is the two tiles and the in-panel dialog;
* no third-party libraries at all — it draws its own picker with `android.graphics`;
* the only privileged permission it holds is `WRITE_SECURE_SETTINGS`, used solely to
  put its own tiles into the panel.

## How the component picks a control path

Different ROMs expose different amounts of torch control, so the component walks a
capability ladder every time the QS panel opens and uses the best rung available:

| Rung | Path | Needs | Range |
|---|---|---|---|
| 1 | `CameraManager.turnOnTorchWithStrengthLevel()` | API 33+ **and** a ROM built with the torch-strength extension | 1..max |
| 2 | write `/sys/devices/platform/flashlights*mt6360/torchbrightness` | the flash-time rule + node permissions | 0..7 |
| 3 | write the LED-class node (`torch-light0` etc.) | same, LED-class spelling | 0..7 mapped to 0..255 |
| 4 | `CameraManager.setTorchMode()` | nothing beyond the camera permission | on/off |

Rung 1 is what the upstream device-tree commit enables ROM-side; rung 2 is what this
project's flash-time policy makes work on a ROM that was never modified. Rung 4 exists
so the tiles are never silently dead.

Rungs 2 and 3 are **probed by writing**, not by looking at the mode bits: a node can be
`0666` and still deny the write under policy, and the ladder has to notice that and fall
through instead of pretending to work.

After every write the level is **read back from the device**. `torchbrightness_store()`
clamps to the kernel's maximum (7 on begonia), so the tile reports what the hardware
actually holds rather than what was requested.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No tiles in the panel after reboot | the ROM ignores `sysui_qs_tiles` writes | add them by hand in the QS editor; report the ROM |
| Subtitle says `camera on/off` | both sysfs rungs failed | the policy rule did not take effect — see below |
| Subtitle says `camera strength API` but strength does nothing | ROM has neither the node access nor a strength-capable camera service | flash again without `--no-selinux` |
| `avc: denied` for `torchnode` | a domain outside the granted set is writing | re-flash with the right `--domains` (check `dmesg \| grep avc`) |
| Device does not boot after flashing | the policy injection is the only realistic cause | boot TWRP → `sh torchbridge/scripts/uninstall.sh` (or `selinux_inject.sh revert /system_root/system`) |

If the node is writable but the rule is missing, `sh twrp/selinux_inject.sh inject
<system-dir> --dry-run` prints exactly what would be injected without touching
anything.

## Repository layout

```
app/                         the headless component (Kotlin, no dependencies)
  src/main/kotlin/.../
    Torch.kt                 the capability ladder + all device IO
    TorchTileBase.kt         shared tile plumbing (worker thread, rendering)
    TorchTileService.kt      the Torch toggle tile
    TorchStrengthTileService.kt  the strength tile (opens the picker)
    TorchStrengthDialog.kt   the in-panel picker dialog
    TorchStrengthView.kt     the hand-drawn 8-stop slider
    TileInstaller.kt         puts the tiles in the panel, no user action
    TileInstallerReceiver.kt boot / update hook for the above
    Prefs.kt                 remembered strength and last level
twrp/
  flash.sh                   the installer
  selinux_inject.sh          apply / revert the policy rule
  torchbridge.cil            the rule block itself (audit this)
  torchbridge.rc             init snippet for node permissions
  privapp-permissions-*.xml  privileged-permission allowlist
  install.sh / uninstall.sh  verify / fully remove
  README.md                  flash-time details
tools/
  make_twrp_zip.sh           package the flashable zip
  cil_selftest.sh            functional test for the injector (runs in CI)
  diag_torch.sh              on-device diagnostic dump
docs/selinux-injection.md    the security analysis of the policy change
```

## Build and test

```sh
./gradlew :app:assembleRelease        # the APK
./gradlew :app:stageTwrpApk           # + build/outputs/twrp/torchbridge.apk
sh tools/cil_selftest.sh              # injector test (27 assertions)
tools/make_twrp_zip.sh                # dist/torchbridge-flashable.zip
```

CI (`.github/workflows/build.yml`) runs the injector test on every push and uploads
both the APK and the flashable zip.

## Security posture

* **SELinux stays enforcing.** No permissive domain, no `setenforce 0`, and the test
  suite fails the build if `(permissive ` ever appears in the injected block.
* **The grant is one node wide.** Only the torch attributes are relabelled; the rest
  of the flashlight device tree keeps the labels the vendor HAL expects.
* **Only system app domains are granted**, never `untrusted_app`, so the rule is
  reachable only from code already running as `/system` or `/system/priv-app`.
* **Fully reversible**, byte-for-byte, with the original kept in
  `<system>/torchbridge-backup/` before anything is written.
* The trade-off is stated plainly in [docs/selinux-injection.md](docs/selinux-injection.md):
  the grant covers the system app domains as a group, because Android has no
  per-package policy mechanism that can be added from recovery.

## Credits

* The torch-strength capability this project targets was defined by the upstream
  device-tree change `begonia: Implement torch light strength control`
  ([973a253](https://github.com/Saikrishna1504/device_redmi_begonia/commit/973a253c914786c46d2d4de6549d3911db1b4e43),
  co-authored by Badmaneers and Saikrishna1504) — it is where the 0–7 range, the
  default of 3 and the `torchbrightness` node come from.
* The world-writable node lives in
  [requiredroot/powa_karnal](https://github.com/requiredroot/powa_karnal)
  (`flashlights-mt6360-mt6785.c`), whose comments posed the original problem clearly.

### If you didn't keep the uninstall zip
Both zips share one entry point (`update-binary`): the install job is selected by
filename, so **renaming `torchbridge-flashable.zip` to anything containing
`uninstall` (e.g. `torchbridge-uninstall.zip`) makes it uninstall instead.**
You don't need a separate download — just rename the install zip and flash it.

To rebuild from source:
```sh
./gradlew :app:stageTwrpApk --no-daemon
tools/make_twrp_zip.sh
```
That writes both `dist/torchbridge-flashable.zip` and `dist/torchbridge-uninstall.zip`.

### If you want the zip on the device right now without copying
If your TWRP can read the workspace storage directly (for example you booted TWRP on this very machine's disk), then in TWRP **Install → navigate to `/workspaces/BegoTorch/dist/torchbridge-uninstall.zip` → swipe**. No copy needed.

If you can't mount the disk in TWRP for some reason, use the ordinary route: copy `torchbridge-uninstall.zip` out to any user storage that TWRP can see, then flash it there.

### How to verify you've got the right zip
```sh
unzip -l torchbridge-uninstall.zip | grep update-binary
# should show:
#         0  0               0  7020 2026-09-16 23:22  META-INF/com/google/android/update-binary
```
That `update-binary` is the uninstaller's own entry point (hour 2026-09-16 23:22, 7020 bytes). If you see that, you have the right file.

### If you'd like me to push both zips somewhere you can download from
I can:
- attach them here as files (if your environment lets you download attachments), or
- push a lightweight assets branch to `requiredroot/BegoTorch` so you can grab them from GitHub Releases-style links.

Which do you want?
