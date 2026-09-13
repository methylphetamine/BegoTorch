# Kernel Implementation Approaches for BegoTorch

## Problem Summary

The BegoTorch app needs to write brightness levels (0-7) to the MT6360 flashlight
sysfs node at `/sys/devices/platform/flashlights_mt6360/torchbrightness`.

The node has mode `0666` but SELinux label `u:object_r:sysfs:s0`.

The ROM's SELinux policy denies app domains (including `system_app` for priv-app
install) from writing to `sysfs:s0` labeled files under enforcing.

This document outlines two kernel-side approaches to solve this without root at
runtime, without Magisk/KernelSU/APatch, and without system-wide permissive.

---

## Approach A: Register as LED Class Device (Recommended)

### Concept

Register the MT6360 flashlight as a standard Linux LED class device. This creates
the sysfs node under `/sys/class/leds/torch:flashlight/brightness` with the LED
class's standard SELinux labeling.

Many Android ROMs allow `system_app` (and sometimes `platform_app`) to write to
LED class brightness for legitimate notification/screen LED control. If the ROM
allows this, the app can control the torch via the LED class path.

### Files

- `mt6360-flashlight-led-class.c` - Example LED class driver implementation

### Changes Required

1. Add LED class framework headers and structures to the driver
2. Implement `led_classdev` with brightness set/get callbacks
3. Register the LED class device in probe
4. Unregister in remove
5. Optionally add device tree binding

### Pros

- Standard kernel framework (LED class)
- Automatic SELinux labeling (often more permissive)
- Cleaner architecture (torch is an LED)
- The driver already has `led_classdev` structures (seen in binary analysis)
- Well-tested path

### Cons

- Changes sysfs path (app needs to try LED class path)
- Still depends on ROM policy for LED class writes
- Requires mapping brightness ranges (0-255 to 0-7)

### Resulting Sysfs Path

```
/sys/class/leds/torch:flashlight/brightness
```

---

## Approach B: Label the Existing Custom Node

### Concept

Keep the existing node at `/sys/devices/platform/flashlights_mt6360/torchbrightness`
but assign it a SELinux context/type that the ROM policy allows system_app to write.

This requires setting the SELinux context on the kobject/device BEFORE creating
the sysfs attribute, so the resulting file inherits the desired context.

### Files

- `mt6360-flashlight-label-node.c` - Example custom labeling implementation

### Changes Required

1. Understand current sysfs creation in the driver
2. Set SELinux context on the kobject/device before attribute creation
3. Determine what SELinux type the ROM allows system_app to write
4. May require sepolicy changes (defeats the purpose)

### Pros

- Keeps existing sysfs path (no app changes needed if successful)
- More targeted (only affects this one node)

### Cons

- Requires knowing what label the ROM allows (hard without ROM source)
- May require sepolicy changes anyway (kernel + userspace)
- More complex driver refactoring
- Harder to maintain

### Resulting Sysfs Path

Unchanged: `/sys/devices/platform/flashlights_mt6360/torchbrightness`

---

## Comparison

| Criteria | Approach A (LED Class) | Approach B (Label Node) |
|----------|----------------------|------------------------|
| Sysfs path changes | Yes (to /sys/class/leds/) | No |
| App changes needed | Try multiple paths | None if successful |
| Kernel complexity | Moderate | High |
| Sepolicy changes needed | Maybe (if LED class denied) | Likely |
| Chance of success | Higher | Lower |
| Architecture quality | Clean, standard | Ad-hoc |

---

## Recommendation

**Start with Approach A.** It's the standard kernel framework, has better chances
of working with ROM SELinux policies, and is cleaner architecture.

Only attempt Approach B if:
1. Approach A's LED class label is also denied by the ROM, AND
2. You can identify a SELinux type the ROM allows system_app to write, AND
3. You can set that type from the kernel without sepolicy changes

---

## App-Side Changes (Both Approaches)

The app has been updated to support multiple torch sysfs paths:

```dart
const List<String> kTorchDeviceCandidates = [
  '/sys/class/leds/torch:flashlight/brightness',      // Approach A
  '/sys/devices/platform/flashlights_mt6360/torchbrightness',  // Original
];
```

The app tries each path and uses the first one that works.

---

## Testing Procedure

1. Build the modified kernel for begonia (ARM64)
2. Flash the kernel (AnyKernel3 or fastboot)
3. Boot the device
4. Check sysfs:
   ```sh
   ls -lZ /sys/class/leds/torch:flashlight/brightness  # Approach A
   ls -lZ /sys/devices/platform/flashlights_mt6360/torchbrightness  # Approach B
   ```
5. Test write from shell:
   ```sh
   adb shell 'echo 4 > /sys/class/leds/torch:flashlight/brightness'
   ```
6. Install app as priv-app (TWRP flash)
7. Test in-app brightness control
8. Check SELinux denials: `adb shell dmesg | grep avc`

---

## Important Notes

- The kernel source code is NOT in this repository
- The CI environment is x86_64 and cannot build ARM64 kernels
- These are EXAMPLE implementations based on binary analysis
- Actual implementation requires the real kernel source tree
- The exact kernel APIs may vary by kernel version
- SELinux labeling behavior depends on kernel config and ROM policy
