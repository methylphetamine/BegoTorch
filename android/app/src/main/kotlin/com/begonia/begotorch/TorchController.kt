package com.begonia.begotorch

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Torch controller using Android Camera2 framework API (non-root path).
 * Falls back to sysfs /sys/devices/platform/flashlights_mt6360/torchbrightness
 * when the framework path is unavailable.
 */
class TorchController(private val context: Context) {

    companion object {
        private const val TAG = "TorchController"
        private const val SYSFS_TORCH_DEVICE =
            "/sys/devices/platform/flashlights_mt6360/torchbrightness"
        const val MIN_VALUE = 0
        const val MAX_VALUE = 7
        const val OFF_VALUE = MIN_VALUE
        const val ON_VALUE = MAX_VALUE
    }

    private val cameraManager: CameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private val frameworkAvailable = AtomicBoolean(false)
    private var lastCameraId: String? = null
    private val executor = Executors.newSingleThreadExecutor { r ->
        thread(start = true, name = "torch-ctrl", isDaemon = true) { r.run() }
    }

    private var torchOn = false
    private var pendingLevel = OFF_VALUE

    fun isFrameworkAvailable(): Boolean = frameworkAvailable.get()

    fun setLevel(level: Int): Boolean {
        val l = level.coerceIn(MIN_VALUE, MAX_VALUE)
        val target = if (l > 0) ON_VALUE else OFF_VALUE
        return if (frameworkAvailable.get() && lastCameraId != null) {
            setFwTorch(target)
        } else {
            writeSysfs(l)
        }
    }

    fun toggleFrom(current: Int): Int {
        val target = if (current == OFF_VALUE) ON_VALUE else OFF_VALUE
        setLevel(target)
        return target
    }

    fun currentLevel(): Int {
        if (frameworkAvailable.get() && lastCameraId != null) {
            return if (torchOn) pendingLevel else OFF_VALUE
        }
        return readSysfs()
    }

    @SuppressLint("MissingPermission")
    fun probeCameras() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            Log.v(TAG, "Camera2 not available")
            return
        }
        try {
            for (id in cameraManager.cameraIdList) {
                val chars = cameraManager.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true) {
                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                        ?: CameraCharacteristics.LENS_FACING_BACK
                    if (facing == CameraCharacteristics.LENS_FACING_BACK
                        || lastCameraId == null
                    ) {
                        lastCameraId = id
                        frameworkAvailable.set(true)
                        Log.v(TAG, "Torch camera: $id")
                        return
                    }
                }
            }
            Log.v(TAG, "No torch camera; sysfs fallback")
        } catch (e: SecurityException) {
            Log.w(TAG, "CAMERA permission missing", e)
        } catch (e: Exception) {
            Log.w(TAG, "Probe failed", e)
        }
    }

    private fun setFwTorch(on: Boolean) {
        if (on == torchOn) {
            pendingLevel = if (on) ON_VALUE else OFF_VALUE
            return
        }
        torchOn = on
        pendingLevel = if (on) ON_VALUE else OFF_VALUE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                cameraManager.setTorchMode(lastCameraId!!, on)
            } catch (e: Exception) {
                Log.w(TAG, "setTorchMode failed: ${e.message}")
                writeSysfs(pendingLevel)
            }
        } else {
            Log.w(TAG, "setTorchMode requires API 28; sysfs fallback")
            writeSysfs(pendingLevel)
        }
    }

    private fun writeSysfs(level: Int): Boolean {
        return try {
            File(SYSFS_TORCH_DEVICE).writeText("$level\n")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Sysfs write failed: ${e.message}")
            false
        }
    }

    private fun readSysfs(): Int {
        return try {
            File(SYSFS_TORCH_DEVICE).readText().trim().toIntOrNull() ?: OFF_VALUE
        } catch (_: Exception) {
            OFF_VALUE
        }
    }

    fun release() {
        executor.shutdownNow()
    }
}
