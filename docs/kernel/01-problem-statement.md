# Problem: SELinux Blocking App Writes to Torch Sysfs Node

## Current State

The MT6360 flashlight driver creates:
- Path: `/sys/devices/platform/flashlights_mt6360/torchbrightness`
- Mode: `0666` (world-readable/writable)
- SELinux label: `u:object_r:sysfs:s0`

## The Issue

The ROM's SELinux policy denies `system_app` (and all app domains) from writing
files labeled `sysfs:s0`.

- Shell domain (`u:r:shell:s0`) CAN write
- App domains (including `system_app` as priv-app) CANNOT write

This is why the app fails with "Torch node not writable" even when installed as priv-app.

## The Goal

Make the torch sysfs node writable by the app without:
- System-wide `setenforce 0`
- Magisk/KernelSU/APatch
- Broadening SELinux permissions beyond what's needed

## Two Kernel Approaches

See the following documents for detailed implementation:
- `02-approach-A-led-class.md` - Register as LED class device
- `03-approach-B-label-existing-node.md` - Label the existing custom node
- `04-comparison.md` - Comparison and recommendation
