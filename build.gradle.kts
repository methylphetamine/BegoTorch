// TorchBridge — root build script.
//
// Pure Android/Kotlin project (no Flutter, no third-party runtime dependencies).
// The output APK is a *headless* system component: it has no launcher icon and
// nothing to open. Its only surface is Quick Settings tiles, which the TWRP
// package pairs with the flash-time system-side enablement (node permissions,
// an enforcing-safe SELinux rule and an init.rc snippet) so the tiles work on
// any ROM without root, without su/Magisk/KernelSU, and without setting
// SELinux to permissive.
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
