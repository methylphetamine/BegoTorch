# Approach A: Register as LED Class Device

## Overview

Register the MT6360 flashlight as a standard Linux LED class device under `/sys/class/leds/`.

This gives the sysfs node the standard LED class SELinux labeling, which many ROMs
already allow system apps to write for legitimate LED control purposes.

## Why This Is The Preferred Approach

1. **Standard kernel framework** - LED class is a well-established subsystem
2. **Better labeling** - LED class devices often get labels the ROM treats more permissively
3. **Cleaner architecture** - A torch IS a type of LED
4. **The driver is already partially there** - Binary analysis shows `led_classdev` structs exist
5. **No app path issues** - Clean standard path like `/sys/class/leds/torch:flashlight/brightness`

## Kernel Source Changes

### File Structure (Hypothetical - Source Not in This Repo)

Assuming the driver is at something like:
- `drivers/leds/mediatek/mt6360-flashlight.c`
- Or `drivers/platform/mediatek/mt6360-pmu.c` with flashlight code

### Required Header Inclusions

```c
#include <linux/leds.h>
#include <linux/led-class.h>
#include <linux/led-class-flash.h>
#include <linux/regulator/consumer.h>
#include <linux/gpio/consumer.h>
#include <linux/of.h>
#include <linux/of_led.h>
```

### Data Structure

```c
/* In the driver's private data structure */
struct mt6360_flashlight {
    struct device *dev;
    
    /* Existing driver fields */
    struct regulator *vdd;
    struct regulator *vled;
    struct gpio_desc *enable_gpio;
    /* ... */
    
    /* LED class structures */
    struct led_classdev cdev;              /* Main brightness LED */
    struct led_classdev_flash flash_cdev;  /* Flash LED (if supported) */
    
    /* Private data */
    int current_level;
    bool torch_enabled;
};
```

### Brightness Set Callback

```c
/* Map LED class brightness (0 to LED_FULL, typically 255) to driver's internal range */
static int led_brightness_to_driver(enum led_brightness led_brightness)
{
    /* LED class uses 0 to LED_FULL (usually 255) */
    /* Driver uses 0 to 7 for torch levels */
    if (led_brightness == 0)
        return 0;
    
    /* Map 1-255 to 1-7 */
    return (led_brightness * 7) / LED_FULL;
}

/* Callback called when userspace writes to /sys/class/leds/.../brightness */
static void mt6360_led_brightness_set(struct led_classdev *led_cdev,
                                       enum led_brightness brightness)
{
    struct mt6360_flashlight *fl =
        container_of(led_cdev, struct mt6360_flashlight, cdev);
    
    int level = led_brightness_to_driver(brightness);
    
    if (level == 0) {
        /* Turn off torch */
        mt6360_disable_torch(fl);
        fl->torch_enabled = false;
    } else {
        /* Set torch to specified level (1-7) */
        mt6360_set_torch_level(fl, level);
        fl->torch_enabled = true;
    }
    
    fl->current_level = level;
    led_set_brightness_unlocked(led_cdev, brightness);
}
```

### Probe Function Modifications

```c
static int mt6360_flashlight_probe(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl;
    struct led_classdev *cdev;
    int ret;
    
    /* Allocate driver data */
    fl = devm_kzalloc(&pdev->dev, sizeof(*fl), GFP_KERNEL);
    if (!fl)
        return -ENOMEM;
    
    fl->dev = &pdev->dev;
    platform_set_drvdata(pdev, fl);
    
    /* Existing initialization: regulators, GPIOs, etc. */
    fl->vdd = devm_regulator_get(&pdev->dev, "vdd");
    if (IS_ERR(fl->vdd)) {
        dev_err(&pdev->dev, "Failed to get vdd regulator\n");
        return PTR_ERR(fl->vdd);
    }
    
    /* Set up LED class device */
    cdev = &fl->cdev;
    cdev->name = "torch:flashlight";
    cdev->max_brightness = LED_FULL;  /* 255 typically */
    cdev->brightness_set = mt6360_led_brightness_set;
    cdev->flags = LED_CORE_SUSPENDS_RESUMES;
    
    ret = led_classdev_register(&pdev->dev, cdev);
    if (ret) {
        dev_err(&pdev->dev, "Failed to register LED class: %d\n", ret);
        return ret;
    }
    
    /* Optional: Register flash LED class for flash/torch flash mode */
    /* ... */
    
    dev_info(&pdev->dev, "MT6360 flashlight driver registered\n");
    return 0;
}
```

### Remove Function Modifications

```c
static int mt6360_flashlight_remove(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl = platform_get_drvdata(pdev);
    
    /* Unregister LED class devices */
    led_classdev_unregister(&fl->cdev);
    /* led_classdev_flash_unregister(&fl->flash_cdev); */
    
    /* Existing cleanup */
    return 0;
}
```

### Device Tree Binding (Optional)

If using device tree, the flashlight can be defined as an LED sub-node:

```dts
/* In the device tree */
&pmu {
    /* Existing PMU nodes... */
    
    /* Flashlight as LED */
    flashlight@0 {
        compatible = "mediatek,mt6360-flashlight";
        reg = <0>;  /* Channel 0 */
        led-sources = <0>;
        max-microamp = <500000>;
        pinctrl-names = "default";
        pinctrl-0 = <&flash_led_pin>;
        enable-gpios = <&pmic_gpio 12 GPIO_ACTIVE_HIGH>;
        label = "torch:flashlight";
    };
};
```

With this DT binding, the kernel's `of_led_classdev_register()` can auto-register
the LED class device, further simplifying the driver code.

### Resulting Sysfs Paths

```
/sys/class/leds/torch:flashlight/
├── brightness      # Write to set torch level (0-255, maps to 0-7 internally)
├── max_brightness  # Shows max (255)
├── trigger         # LED trigger control
├── brightness_error  # (if applicable)
└── ...              # Other LED class attributes
```

## App Changes Required

The app needs to be updated to try LED class path as an option:

```dart
// In lib/main.dart or a device abstraction layer

const List<String> kTorchDeviceCandidates = [
  '/sys/class/leds/torch:flashlight/brightness',
  '/sys/devices/platform/flashlights_mt6360/torchbrightness',
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

## Testing

After flashing the modified kernel:

```sh
# Check LED class device exists
ls -l /sys/class/leds/torch:flashlight/brightness

# Check SELinux label
ls -lZ /sys/class/leds/torch:flashlight/brightness

# Test write from shell
adb shell 'echo 128 > /sys/class/leds/torch:flashlight/brightness'

# Check if it actually turned on the torch

# Check SELinux denials
adb shell 'dmesg | grep avc'
```

## SELinux Considerations

- LED class devices typically get labels like:
  - `led_class_t:object_r:sysfs_t:s0`
  - Or vendor-specific variants
- Check if the ROM's policy allows `system_app` to write to LED class sysfs:
  ```sh
  adb shell su -c 'sesearch --allow -s system_app -t led_class_t -c file -p write,open,getattr /sys/fs/selinux/policy'
  ```
- If not allowed, this approach also needs a SELinux policy change (but now it's for LED class, which is more justifiable)
EOF
echo 'Created Approach A documentation'
