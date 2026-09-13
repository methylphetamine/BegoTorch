# Kernel Approaches for Torch Sysfs SELinux Issue

## Problem

The MT6360 flashlight driver creates a sysfs node that the app needs to write to,
but the ROM's SELinux policy blocks app domains from writing to sysfs nodes.

## Documents

- `01-problem-statement.md` - Problem description and overview
- `02-approach-A-led-class.md` - Register as LED class device (recommended)
- `03-approach-B-label-existing-node.md` - Label the existing custom node
- `04-comparison.md` - Comparison and recommendation

## Current Status

The kernel source code is NOT available in this repository.
Only a pre-compiled ARM64 kernel image (`kernel-pkg/Image.gz-dtb`) is present.

The CI environment is x86_64 and cannot build ARM64 kernels.

## What CAN Be Done Here

1. **Document the approaches** - Done (see above)
2. **Create example kernel driver code** - Can create reference implementations
3. **Update the app** to support multiple torch paths - Can do
4. **Analyze the kernel binary** - Can do (strings, symbols)

## What CANNOT Be Done Here

1. Build a modified kernel - need ARM64 cross-compilation environment
2. Flash the modified kernel - need device access
3. Test kernel changes on device - need device access

## Next Steps (When Kernel Source is Available)

1. Locate the MT6360 flashlight driver source
2. Implement Approach A (LED class registration)
3. Build and test the modified kernel
4. Update the app to use the LED class path if needed
5. Test end-to-end

## App Changes Needed Regardless

The app should support multiple torch sysfs paths for maximum compatibility:
- `/sys/class/leds/torch:flashlight/brightness` (LED class)
- `/sys/devices/platform/flashlights_mt6360/torchbrightness` (original)

See the app documentation for implementation.
EOF
echo 'Created README'
