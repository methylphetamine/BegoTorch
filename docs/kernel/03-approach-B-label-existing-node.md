# Approach B: Label the Existing Custom Node

## Overview

Keep the existing node at `/sys/devices/platform/flashlights_mt6360/torchbrightness`
but assign it a SELinux context/type that the ROM's policy allows the app domain to write.

## Why Consider This Approach

1. Keeps existing sysfs path - no app changes needed
2. More targeted - only affects this one node
3. If you can find a label the ROM already allows for system_app, no policy changes needed

## Challenges

1. The driver's current sysfs creation doesn't set custom SELinux contexts
2. Finding a label the ROM allows without modifying the policy is difficult
3. Creating a new SELinux type requires BOTH kernel AND sepolicy changes
4. More invasive changes to the driver for minimal benefit over Approach A

## Kernel Source Changes

### Option 1: Use Existing Label from LED Class Framework

If the driver has `led_classdev` structures, the simplest path is to properly
register them as LED class devices (see Approach A). The LED class framework
handles labeling automatically.

### Option 2: Set SELinux Context on Kobject

```c
#include <linux/kobject.h>
#include <linux/device.h>

/* In probe, before creating sysfs attributes */
static int mt6360_flashlight_probe(struct platform_device *pdev)
{
    struct mt6360_flashlight *fl;
    struct device *dev = &pdev->dev;
    int ret;
    
    /* ... allocation and existing init ... */
    
    /* 
     * Set SELinux context on the device's kobject.
     * This is the key change - it causes sysfs files created
     * under this kobject to get the specified context.
     *
     * The context string must match a file context rule in
     * the ROM's sepolicy, OR you need to add one.
     */
    
    /* 
     * IMPORTANT: The context must be defined in the kernel's
     * SELinux configuration and the ROM's sepolicy must have
     * appropriate rules for it.
     *
     * If you use a context the policy doesn't know about,
     * the file will get a default context, which may not help.
     */
    
    /* Example (HYPOTHETICAL - needs matching sepolicy): */
    /*
     * if (dev_set_selinux_stack_node(dev, "flashlight_sysfs")) {
     *     dev_warn(dev, "Failed to set SELinux context\n");
     * }
     */
    
    /* 
     * Alternative: Use device_set_secid to set the security ID
     * that determines the SELinux context.
     */
    
    /* Most practical: Find out what context the ROM assigns to
     * LED class devices, and try to make this node get the same
     * context. This usually means using the LED class framework
     * (see Approach A).
     */
    
    /* ... rest of probe ... */
    return 0;
}
```

### Option 3: Add File Context Rule in Kernel (Requires Sepolicy Change)

```c
/* 
 * In the kernel's SELinux support or device declaration:
 * This is incomplete without the corresponding sepolicy change.
 */

/* The kernel doesn't typically define file context rules directly.
 * File contexts are defined in the sepolicy source and compiled
 * into the policy binary that gets loaded at boot.
 *
 * What the kernel CAN do:
 * - Set the security ID (secid) on a kobject/device
 * - The secid maps to a context via the SELinux policy's
 *   initial context labeling rules
 *
 * So the kernel change would be to ensure the device/kobject
 * gets the right secid, and the sepolicy must have a rule
 * that maps that secid to an appropriate context.
 */
```

### The Sepolicy Side (Required for New Types)

If you create a new SELinux type for the torch node, you need to add to the
ROM's sepolicy (not just the kernel):

```te
# In the ROM's sepolicy source (NOT kernel source)

# Define the type
type torch_sysfs, file_type, sysfs_type;

# Allow system_app to write to it
allow system_app torch_sysfs:file { write open getattr create };

# Or more specific
allow system_app torch_sysfs:file { write open getattr };

# For the init context to label the file at creation
# (in file_contexts file)
/sys/devices/platform/flashlights_mt6360/torchbrightness    u:object_r:torch_sysfs:s0
```

**This requires full ROM build capabilities, not just kernel changes.**

## Practical Assessment

**Approach B is less practical than Approach A because:**

1. **Finding a suitable existing label** - The ROM must already have a type that:
   - System_app can write to
   - Is appropriate for a torch sysfs node
   - The kernel can assign to this node
   
   This is rare unless the ROM already has similar device sysfs nodes.

2. **Creating a new type** - Requires sepolicy changes, which means:
   - Access to the ROM's sepolicy source
   - Ability to build and flash the ROM
   - This is effectively a ROM modification, not just a kernel modification

3. **Driver refactoring** - To assign a custom context, the driver may need
   significant changes to how it creates sysfs entries.

## When Approach B Makes Sense

Approach B makes sense if:
1. The ROM already has a similar custom sysfs node that system_app can write
2. You can identify the label it uses and replicate it for the torch node
3. You have access to modify the kernel driver (but not necessarily the sepolicy)

## App Changes Required

**None** - if the labeling works, the app continues using:
```
/sys/devices/platform/flashlights_mt6360/torchbrightness
```

No changes needed to the app if Approach B succeeds.
EOF
echo 'Created Approach B documentation'
