package com.begonia.begotorch

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Torch controller supporting multiple sysfs paths.
 * 
 * The app tries each candidate path until one works. The kernel driver
 * registers LED class devices (torch-light0/1/2) which get standard LED
 * class SELinux labeling that the ROM policy allows system_app to write.
 * 
 * See docs/kernel/ for details on the kernel-side implementation.
 */
class TorchController(private val context: Context) {

    companion object {
        private const val TAG = "TorchController"
        
        /** LED class path (kernel registers torch-light0/1/2) */
        private const val SYSFS_LED_CLASS =
            "/sys/class/leds/torch-light0/brightness"
        
        /** Original custom path (MT6360 flashlight driver) */
        private const val SYSFS_CUSTOM =
            "/sys/devices/platform/flashlights_mt6360/torchbrightness"
        
        /** Ordered list of candidate paths to try */
        private val CANDIDATE_PATHS = listOf(SYSFS_LED_CLASS, SYSFS_CUSTOM)
        
        const val MIN_VALUE = 0
        const val MAX_VALUE = 7
        const val OFF_VALUE = MIN_VALUE
        const val ON_VALUE = MAX_VALUE
    }

    private var currentPath: String? = null

    /**
     * Find which path is currently usable.
     * Tries each candidate path until one works.
     */
    fun findWorkingPath(): String? {
        for (path in CANDIDATE_PATHS) {
            try {
                val file = File(path)
                if (file.exists()) {
                    // Test write
                    file.writeText("0\n")
                    currentPath = path
                    Log.d(TAG, "Found working path: $path")
                    return path
                }
            } catch (e: Exception) {
                Log.d(TAG, "Path $path not accessible: ${e.message}")
            }
        }
        Log.w(TAG, "No accessible torch path found")
        return null
    }

    fun setLevel(level: Int): Boolean {
        val l = level.coerceIn(MIN_VALUE, MAX_VALUE)
        val path = currentPath ?: findWorkingPath()
        
        if (path == null) {
            Log.w(TAG, "No torch path available")
            return false
        }
        
        return try {
            File(path).writeText("$l\n")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Write failed: ${e.message}")
            false
        }
    }

    fun toggleFrom(current: Int): Int {
        val target = if (current == OFF_VALUE) ON_VALUE else OFF_VALUE
        setLevel(target)
        return target
    }

    fun currentLevel(): Int {
        val path = currentPath ?: return OFF_VALUE
        return try {
            File(path).readText().trim().toIntOrNull() ?: OFF_VALUE
        } catch (e: Exception) {
            Log.w(TAG, "Read failed: ${e.message}")
            OFF_VALUE
        }
    }

    fun release() {
        // Cleanup if needed
    }
}
