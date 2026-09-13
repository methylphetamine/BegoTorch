// SPDX-License-Identifier: GPL-2.0-only
/*
 * MT6360 Flashlight Driver - Custom Node Labeling (Approach B)
 * 
 * This is EXAMPLE reference code showing how to keep the existing custom
 * sysfs node at /sys/devices/platform/flashlights_mt6360/torchbrightness
 * but assign it a SELinux context that the ROM policy allows system_app to write.
 * 
 * This approach is more complex and less recommended than Approach A because:
 * 1. It requires knowing what SELinux type the ROM allows
 * 2. It may need sepolicy changes in addition to kernel changes
 * 3. It's more invasive to the existing driver
 * 
 * The actual driver source is NOT in this repository.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/mutex.h>
#include <linux/slab.h>

/*
 * To change the SELinux context of a sysfs node from the kernel, you need to
 * set the security context on the kobject/device BEFORE creating the sysfs
 * attribute. The sysfs file will then inherit that context.
 *
 * NOTE: The exact API depends on kernel version and SELinux configuration.
 * This shows the general pattern.
 */

/* Platform device matching */
static const struct of_device_id mt6360_flashlight_of_match[] = {
    { .compatible = "mediatek,mt6360-flashlight" },
    { }
};
MODULE_DEVICE_TABLE(of, mt6360_flashlight_of_match);

/* Driver private data */
struct mt6360_flashlight {
    struct device *dev;
    struct kobject *torch_kobj;
    int current_level;
    bool torch_enabled;
    struct mutex lock;
};

/*
 * Approach B Option 1: Create sysfs under a custom kobject with specific context
 *
 * Instead of using the default platform device sysfs, create a custom kobject
 * hierarchy and set its security context before creating attributes.
 */
static int mt6360_create_labeled_sysfs(struct mt6360_flashlight *fl)
{
    int ret;
    
    /* Create a custom kobject for the torch device */
    fl->torch_kobj = kobject_create_and_add("torch", &fl->dev->kobj);
    if (!fl->torch_kobj)
        return -ENOMEM;
    
    /*
     * Set SELinux context on the kobject.
     * The sysfs files created under this kobject will inherit this context.
     * 
     * The context string MUST match a type that:
     * 1. Exists in the ROM's sepolicy
     * 2. The ROM policy allows system_app to write
     * 3. Is appropriate for a torch device
     * 
     * Common candidates to try:
     * - LED class type (if kernel uses LED framework labeling)
     * - Vendor-specific flashlight type
     * - Existing device type the ROM allows
     */
    
    /* 
     * Setting the context requires kernel SELinux support.
     * The exact function varies by kernel version.
     * 
     * For kernels with selinux_kobject_setattr or similar:
     * 
     * ret = selinux_kobject_set_context(fl->torch_kobj, 
     *                                  "u:object_r:torch_sysfs:s0");
     * 
     * For kernels where you set the security ID (secid):
     * 
     * u32 secid;
     * security_secctx_to_secid("u:object_r:torch_sysfs:s0", 
     *                          strlen("u:object_r:torch_sysfs:s0"), &secid);
     * security_kobj_set_secid(fl->torch_kobj, secid);
     */
    
    /* Create the brightness attribute under the labeled kobj */
    ret = sysfs_create_file(fl->torch_kobj, &dev_attr_brightness.attr);
    if (ret) {
        kobject_put(fl->torch_kobj);
        return ret;
    }
    
    return 0;
}

/*
 * Approach B Option 2: Modify the existing attribute creation to set context
 * 
 * If the driver uses device_create_file() or sysfs_create_group(), you may
 * be able to influence the context by setting attributes on the device
 * before creating the sysfs files.
 */
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
    
    /*
     * Before creating sysfs attributes, try to set the device's
     * SELinux context to something the ROM allows.
     */
    
    /* 
     * Method 1: Set device security attributes
     * (if the kernel supports it)
     */
    #ifdef CONFIG_SECURITY_SELINUX
    /* Set a custom secid on the device - exact API varies */
    /* dev_set_secid(&pdev->dev, desired_secid); */
    #endif
    
    /* 
     * Method 2: Use a custom kobject (see mt6360_create_labeled_sysfs above)
     */
    ret = mt6360_create_labeled_sysfs(fl);
    if (ret) {
        dev_err(&pdev->dev, "Failed to create labeled sysfs: %d\n", ret);
        return ret;
    }
    
    dev_info(&pdev->dev, "MT6360 flashlight registered with custom labeling\n");
    return 0;
}

static int mt6360_flashlight_remove(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl = platform_get_drvdata(pdev);
    
    if (fl->torch_kobj) {
        sysfs_remove_file(fl->torch_kobj, &dev_attr_brightness.attr);
        kobject_put(fl->torch_kobj);
    }
    
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
MODULE_DESCRIPTION("MT6360 Flashlight Custom Node Labeling (Approach B)");
