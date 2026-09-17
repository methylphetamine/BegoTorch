package com.begonia.torchbridge

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Torch strength controller.
 *
 * Levels are 0..7 where 0 is off — the range the MT6360 flashlight driver
 * exposes on this device family, and the range the vendor camera extension in
 * the upstream device tree advertises (`getTorchMaxStrengthLevelExt() == 7`,
 * `getTorchDefaultStrengthLevelExt() == 3`).
 *
 * The controller walks a capability ladder and uses the first rung that works,
 * so the same APK behaves correctly on every ROM:
 *
 *  1. [Mode.CAMERA_STRENGTH] — `CameraManager.turnOnTorchWithStrengthLevel()`
 *     (API 33+). The platform camera service writes the torch node from its own
 *     SELinux domain, so this rung needs no permission on the node at all. This
 *     is what the upstream `CameraProviderExtension.cpp` commit enables.
 *  2. [Mode.SYSFS_LEVEL] — direct write of the level to the MT6360
 *     `torchbrightness` node, which already speaks 0..7. Works because the TWRP
 *     package gives that node the ownership and the enforcing-safe SELinux rule
 *     it needs (see twrp/selinux_inject.sh).
 *  3. [Mode.SYSFS_LED] — the driver's LED-class devices, with 0..7 mapped onto
 *     the LED-class 0..255 brightness scale.
 *  4. [Mode.CAMERA_BINARY] — `setTorchMode()`. On/off only; the last resort
 *     that exists on every ROM.
 *
 * Nothing here escalates privileges: no `su`, no Magisk/KernelSU/APatch, and no
 * `setenforce 0`.
 */
object Torch {

    private const val TAG = "TorchBridge"

    const val MIN_LEVEL = 0
    const val MAX_LEVEL = 7
    const val OFF = MIN_LEVEL
    const val DEFAULT_ON = 3 // matches the upstream extension's default

    /** Where the level comes from on the current ROM. */
    enum class Mode { NONE, CAMERA_STRENGTH, SYSFS_LEVEL, SYSFS_LED, CAMERA_BINARY }

    /**
     * A candidate sysfs node.
     *
     * @param path absolute sysfs path
     * @param ledScale true when the node expects the LED-class 0..255 range and
     *   the 0..7 level must therefore be scaled; false when the node already
     *   speaks 0..7 (the MT6360 `torchbrightness` attributes).
     */
    private class Node(val path: String, val ledScale: Boolean)

    /**
     * Candidate nodes, most preferred first.
     *
     * The `torchbrightness` attribute speaks the native 0..7 level so it is
     * tried before the LED-class devices that need scaling. Both platform-device
     * spellings are listed — the upstream device tree uses the hyphen form
     * `flashlights-mt6360` while MTK's platform device / init.project.rc use
     * the underscore form `flashlights_mt6360`; the SELinux block labels
     * whichever one the kernel actually exposes. The LED paths are listed in
     * both their class view and their canonical `/devices/virtual` view, since
     * which one a given kernel exposes depends on how the driver registered the
     * LED (`led_classdev_register(NULL, ...)` puts it under virtual, a real
     * parent device puts it under that device).
     */
    private val NODES = listOf(
        Node("/sys/devices/platform/flashlights-mt6360/torchbrightness", ledScale = false),
        Node("/sys/devices/platform/flashlights_mt6360/torchbrightness", ledScale = false),
        Node("/sys/devices/platform/flashlights_mt6360/leds/torch-light0/brightness", ledScale = true),
        Node("/sys/class/leds/torch-light0/brightness", ledScale = true),
        Node("/sys/devices/virtual/leds/torch-light0/brightness", ledScale = true),
        Node("/sys/class/leds/torch:flashlight/brightness", ledScale = true),
        Node("/sys/class/leds/flashlight/brightness", ledScale = true),
    )

    // --- capability detection -------------------------------------------------

    private var cachedMode: Mode? = null
    private var cachedNode: Node? = null
    private var cachedCameraId: String? = null
    private var cachedCameraMaxLevel: Int = MAX_LEVEL

    /** Forget the cached capability decision (called when a tile resumes). */
    fun invalidate() {
        cachedMode = null
        cachedNode = null
        cachedCameraId = null
    }

    fun mode(context: Context): Mode = cachedMode ?: detect(context).also { cachedMode = it }

    /** Highest level the current mode can actually reach. */
    fun maxLevel(context: Context): Int = when (mode(context)) {
        Mode.CAMERA_STRENGTH -> cachedCameraMaxLevel
        Mode.CAMERA_BINARY -> MAX_LEVEL
        Mode.SYSFS_LED, Mode.SYSFS_LEVEL -> MAX_LEVEL
        Mode.NONE -> MAX_LEVEL
    }

    private fun detect(context: Context): Mode {
        if (detectCameraStrength(context)) return Mode.CAMERA_STRENGTH
        val node = detectWritableNode()
        if (node != null) {
            cachedNode = node
            return if (node.ledScale) Mode.SYSFS_LED else Mode.SYSFS_LEVEL
        }
        if (detectTorchCamera(context) != null) return Mode.CAMERA_BINARY
        return Mode.NONE
    }

    // --- camera rungs ---------------------------------------------------------

    /**
     * Rung 1: does the ROM's camera service expose torch strength control?
     *
     * `FLASH_INFO_STRENGTH_MAXIMUM_LEVEL` is only present in the camera
     * characteristics when the ROM ships torch strength support — exactly what
     * the upstream begonia commit adds through `CameraProviderExtension.cpp`.
     * When it is absent the framework ignores a strength request silently, so
     * this must be a characteristics check and not a build-version check.
     */
    @SuppressLint("NewApi")
    private fun detectCameraStrength(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val id = detectTorchCamera(context) ?: return false
        return try {
            val chars = cameraManager(context)?.getCameraCharacteristics(id) ?: return false
            val max = chars.get(CameraCharacteristics.FLASH_INFO_STRENGTH_MAXIMUM_LEVEL)
                ?: return false
            // A reported maximum of 1 is on/off only, not real strength control.
            // Accepting it would shadow the sysfs torchbrightness rung (rung 2)
            // that the flash-time policy enables for the full 0..7 range,
            // collapsing the picker to just 0/1. Only honour the camera rung when
            // it actually offers multi-level control.
            if (max < 2) return false
            cachedCameraMaxLevel = max.coerceIn(1, MAX_LEVEL)
            Log.i(TAG, "camera $id supports torch strength, ROM max=$max")
            true
        } catch (t: Throwable) {
            Log.d(TAG, "camera strength probe failed: ${t.message}")
            false
        }
    }

    private fun detectTorchCamera(context: Context): String? {
        cachedCameraId?.let { return it }
        return try {
            val cm = cameraManager(context) ?: return null
            for (id in cm.cameraIdList) {
                val chars = cm.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true) {
                    cachedCameraId = id
                    return id
                }
            }
            null
        } catch (t: Throwable) {
            Log.d(TAG, "no torch camera: ${t.message}")
            null
        }
    }

    private fun cameraManager(context: Context): CameraManager? = try {
        context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
    } catch (t: Throwable) {
        null
    }

    // --- sysfs rungs ----------------------------------------------------------

    /**
     * Rungs 2/3: find a node that can really be written.
     *
     * The probe performs a real write and restores the previous value, because
     * existence — and even mode 0666 — says nothing about whether the ROM's
     * SELinux policy permits this domain to write. A node that exists but is
     * denied is skipped in favour of a lower rung, which is what keeps the
     * component behaving sensibly on a ROM the flash-time rule could not patch.
     */
    private fun detectWritableNode(): Node? {
        for (node in NODES) {
            val file = File(node.path)
            if (!file.exists()) continue
            val previous = try {
                file.readText().trim()
            } catch (t: Throwable) {
                null
            }
            val writable = try {
                file.writeText(previous?.ifEmpty { null } ?: "0")
                true
            } catch (t: Throwable) {
                Log.d(TAG, "node ${node.path} not writable: ${t.message}")
                false
            }
            if (writable) {
                Log.i(TAG, "using node ${node.path} (ledScale=${node.ledScale})")
                return node
            }
        }
        Log.w(TAG, "no writable torch node; falling back to the camera path")
        return null
    }

    /** Read the level straight from a node (used to cross-check the cameras). */
    private fun readNodeLevel(): Int {
        val node = cachedNode ?: return OFF
        return try {
            val raw = File(node.path).readText().trim().toIntOrNull() ?: OFF
            when {
                !node.ledScale -> raw.coerceIn(MIN_LEVEL, MAX_LEVEL)
                raw <= 0 -> OFF
                // 0..255 -> 1..7: any non-zero value means "on".
                else -> (((raw - 1) * MAX_LEVEL) / 254 + 1).coerceIn(1, MAX_LEVEL)
            }
        } catch (t: Throwable) {
            OFF
        }
    }

    private fun setViaNode(level: Int): Boolean {
        val node = cachedNode ?: return false
        val value = when {
            !node.ledScale -> level.coerceIn(MIN_LEVEL, MAX_LEVEL)
            level <= OFF -> 0
            // 0..7 -> 0..255: level 1 must be visibly on, level 7 must be 255.
            else -> (((level - 1) * 254) / (MAX_LEVEL - 1) + 1).coerceIn(1, 255)
        }
        return try {
            File(node.path).writeText("$value")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "node write($value) failed: ${t.message}")
            false
        }
    }

    // --- level IO -------------------------------------------------------------

    /**
     * Read the current level, or [OFF] when it cannot be determined.
     *
     * The camera rung is authoritative when available: the platform camera
     * service owns the torch there, and a node read would report what the
     * service last wrote, not what the user asked for.
     */
    @SuppressLint("NewApi")
    fun getLevel(context: Context): Int = when (mode(context)) {
        Mode.CAMERA_STRENGTH -> try {
            val id = cachedCameraId ?: return readNodeLevel()
            val cm = cameraManager(context) ?: return readNodeLevel()
            cm.getTorchStrengthLevel(id).coerceIn(MIN_LEVEL, cachedCameraMaxLevel)
        } catch (t: Throwable) {
            readNodeLevel()
        }

        Mode.SYSFS_LEVEL, Mode.SYSFS_LED -> readNodeLevel()

        Mode.CAMERA_BINARY -> if (Prefs.isBinaryOn(context)) Prefs.onLevel(context) else OFF

        Mode.NONE -> OFF
    }

    /**
     * Set the torch to [level] (0 = off).
     *
     * @return true when the ROM accepted the change.
     */
    fun setLevel(context: Context, level: Int): Boolean {
        val target = level.coerceIn(MIN_LEVEL, maxLevel(context))
        val ok = when (mode(context)) {
            Mode.CAMERA_STRENGTH -> setViaCameraStrength(context, target)
            Mode.SYSFS_LEVEL, Mode.SYSFS_LED -> setViaNode(target)
            Mode.CAMERA_BINARY -> setViaCameraBinary(context, target)
            Mode.NONE -> false
        }
        if (ok) {
            Prefs.setLastLevel(context, target)
            if (target > OFF) Prefs.setOnLevel(context, target)
            Prefs.setBinaryOn(context, target > OFF)
            Log.i(TAG, "level=$target via ${modeLabel(context)}")
        }
        return ok
    }

    @SuppressLint("NewApi")
    private fun setViaCameraStrength(context: Context, level: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val id = cachedCameraId ?: return false
        val cm = cameraManager(context) ?: return false
        return try {
            if (level == OFF) {
                cm.setTorchMode(id, false)
            } else {
                cm.turnOnTorchWithStrengthLevel(id, level.coerceIn(1, cachedCameraMaxLevel))
            }
            true
        } catch (t: Throwable) {
            Log.d(TAG, "camera strength set($level) failed: ${t.message}")
            false
        }
    }

    private fun setViaCameraBinary(context: Context, level: Int): Boolean {
        val id = cachedCameraId ?: detectTorchCamera(context) ?: return false
        val cm = cameraManager(context) ?: return false
        return try {
            cm.setTorchMode(id, level > OFF)
            true
        } catch (t: Throwable) {
            Log.d(TAG, "camera binary set($level) failed: ${t.message}")
            false
        }
    }

    // --- public helpers -------------------------------------------------------

    /** Off -> last used strength, on -> off. Returns the level that was set. */
    fun toggle(context: Context): Int {
        val current = getLevel(context)
        val target = if (current == OFF) Prefs.onLevel(context) else OFF
        return if (setLevel(context, target)) target else current
    }

    /** Next level up, wrapping back to off after the ROM's maximum. */
    fun cycle(context: Context): Int {
        val max = maxLevel(context)
        val current = getLevel(context)
        val next = if (current >= max) OFF else current + 1
        return if (setLevel(context, next)) next else current
    }

    /** Human-readable description of how the torch is currently driven. */
    fun modeLabel(context: Context): String = when (mode(context)) {
        Mode.CAMERA_STRENGTH -> "camera strength API"
        Mode.SYSFS_LEVEL -> "torch node"
        Mode.SYSFS_LED -> "LED class"
        Mode.CAMERA_BINARY -> "camera on/off"
        Mode.NONE -> "unavailable"
    }
}
