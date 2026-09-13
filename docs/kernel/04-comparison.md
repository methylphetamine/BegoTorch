# Approach Comparison and Recommendation

## Comparison Table

| Criteria | Approach A: LED Class | Approach B: Label Existing Node |
|----------|----------------------|--------------------------------|
| **Sysfs Path** | Changes to `/sys/class/leds/torch:flashlight/brightness` | Unchanged `
| **App Changes** | Need to update path | None needed if successful |
| **Kernel Changes** | Moderate (add LED class reg) | Complex (custom labeling) |
| **Sepolicy Changes** | Maybe (if LED class not allowed) | Likely required (new type) |
| **Architecture** | Clean, standard, proper | Ad-hoc, custom |
| **Driver Refactoring** | Moderate | Significant |
| **Chance of Success** | Higher (LED class is common) | Lower (custom labeling is rare) |
| **Maintainability** | Good | Poor |

## Recommendation: Start with Approach A

**Approach A (LED class device) is the recommended starting point because:**

1. **Standard framework** - LED class is a well-established Linux kernel subsystem
2. **Better labeling** - LED class devices often get labels the ROM handles more permissively
3. **Cleaner implementation** - The driver already has `led_classdev` structures
4. **More testable** - Can test LED class path independently
5. **Better long-term** - Proper hardware abstraction

### Implementation Priority

1. **First:** Implement Approach A in the kernel driver
2. **Build and flash** the modified kernel
3. **Test** the LED class path:
   - Check if `/sys/class/leds/torch:flashlight/brightness` exists
   - Check its SELinux label
   - Test write from shell
   - Test write from app
4. **If Approach A fails** (label still not writable), then consider:
   - Checking if LED class labeling needs a sepolicy tweak
   - As a last resort, trying Approach B or other options

## App-Side Preparation

Regardless of the kernel approach, the app should support multiple torch paths:

```dart
// In Flutter app
const List<String> kTorchDeviceCandidates = [
  '/sys/class/leds/torch:flashlight/brightness',    // LED class
  '/sys/devices/platform/flashlights_mt6360/torchbrightness',  // Original
];

Future<String?> findWorkingTorchDevice() async {
  for (final path in kTorchDeviceCandidates) {
    try {
      final file = File(path);
      if (await file.exists()) {
        // Test write
        await file.writeAsString('0\n');
        return path;
      }
    } catch (e) {
      continue;
    }
  }
  return null;
}
```

## If Neither Kernel Approach Works

If both kernel approaches fail to produce a writable node for the app:

1. **The issue is the ROM's SELinux policy** - it denies system_app from writing to sysfs generally
2. **Options:**
   - Find a ROM that allows it
   - Accept that this ROM/kernel combination needs a sepolicy change
   - Use a targeted sepolicy module (requires Magisk or similar)

This is a policy limitation, not an app or kernel limitation.
EOF
echo 'Created comparison document'
