// SPDX-License-Identifier: GPL-2.0-only
/*
 * MT6360 Flashlight Driver - LED Class Registration (Approach A)
 * 
 * This is EXAMPLE reference code showing how to register the MT6360
 * flashlight as a standard Linux LED class device. This gives the sysfs
 * node automatic SELinux labeling that many ROMs allow system_app to write.
 * 
 * The actual driver source is NOT in this repository - this is based on
 * binary analysis of kernel-pkg/Image.gz-dtb.
 * 
 * To use: locate the actual MT6360 flashlight driver in kernel source,
 * apply these patterns, rebuild for begonia (ARM64), and flash.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/leds.h>
#include <linux/regulator/consumer.h>
#include <linux/gpio/consumer.h>
#include <linux/mutex.h>
#include <linux/slab.h>

/* Platform device matching */
static const struct of_device_id mt6360_flashlight_of_match[] = {
    { .compatible = "mediatek,mt6360-flashlight" },
    { }
};
MODULE_DEVICE_TABLE(of, mt6360_flashlight_of_match);

/* Driver private data */
struct mt6360_flashlight {
    struct device *dev;
    struct regulator *vdd_reg;
    struct led_classdev cdev;
    int current_level;
    bool torch_enabled;
    struct mutex lock;
};

/* Map LED class brightness (0-255) to driver level (0-7) */
static int led_brightness_to_driver(enum led_brightness brightness)
{
    if (brightness == 0)
        return 0;
    return (brightness * 7) / 255;
}

/* Callback: set torch brightness from LED class sysfs write */
static void mt6360_led_brightness_set(struct led_classdev *led_cdev,
                                       enum led_brightness brightness)
{
    struct mt6360_flashlight *fl =
        container_of(led_cdev, struct mt6360_flashlight, cdev);
    int level;
    
    mutex_lock(&fl->lock);
    level = led_brightness_to_driver(brightness);
    
    if (level == 0) {
        /* Turn off torch - call existing driver function */
        /* mt6360_disable_torch(fl); */
        fl->torch_enabled = false;
    } else {
        /* Set torch level - call existing driver function */
        /* mt6360_set_torch_level(fl, level); */
        fl->torch_enabled = true;
    }
    fl->current_level = level;
    led_set_brightness_unlocked(led_cdev, brightness);
    mutex_unlock(&fl->lock);
}

/* Probe: register LED class device */
static int mt6360_flashlight_probe(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl;
    int ret;
    
    fl = devm_kzalloc(&pdev->dev, sizeof(*fl), GFP_KERNEL);
    if (!fl)
        return -ENOMEM;
    
    fl->dev = &pdev->dev;
    mutex_init(&fl->lock);
    platform_set_drvdata(pdev, fl);
    
    /* Configure LED class device - THIS IS THE KEY CHANGE */
    fl->cdev.name = "torch:flashlight";
    fl->cdev.max_brightness = 255;
    fl->cdev.brightness_set = mt6360_led_brightness_set;
    fl->cdev.flags = LED_CORE_SUSPENDS_RESUMES;
    
    ret = led_classdev_register(&pdev->dev, &fl->cdev);
    if (ret) {
        dev_err(&pdev->dev, "Failed to register LED class: %d\n", ret);
        return ret;
    }
    
    dev_info(&pdev->dev, "MT6360 flashlight registered as LED class\n");
    return 0;
}

static int mt6360_flashlight_remove(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl = platform_get_drvdata(pdev);
    led_classdev_unregister(&fl->cdev);
    mutex_destroy(&fl->lock);
    return 0;
}

static struct platform_driver mt6360_flashlight_driver = {
    .probe = mt6360_flashlight_probe,
    .remove = mt6360_flashlight_remove,
    .driver = {
        .name = "mt6360-flashlight",
        .of_match_table = mt6360_flashlight_of_match,
    },
};

module_platform_driver(mt6360_flashlight_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("MT6360 Flashlight LED Class Driver (Approach A)");
