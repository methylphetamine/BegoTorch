package com.begonia.begotorch

import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.io.File
import java.util.concurrent.locks.ReentrantLock

/**
 * Quick Settings tile that toggles the torch between off (0) and full (7) by
 * writing the level straight to the sysfs node:
 *
 *     /sys/devices/platform/flashlights_mt6360/torchbrightness
 *
 * No `su` (Magisk/KernelSU/APatch) is involved. The write privilege is granted
 * statically by the component manifest (config/begotorch.cml) that is fused
 * into the flashed package, so the tile needs no root grant at runtime.
 *
 * Writes run on a worker thread; the tile never blocks the main thread.
 */
class TorchTileService : TileService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val writeLock = ReentrantLock()

    override fun onStartListening() {
        super.onStartListening()
        runAsync {
            // Refresh state from the device (or last known level) so the tile
            // reflects changes made by the app between panel opens.
            queryLevel()
        }
    }

    override fun onClick() {
        // Main thread: decide from the cheap cached level only — never perform
        // I/O on the torch node here. The worker thread verifies and corrects.
        val assumed = lastLevel()
        val target = if (assumed == 0) ON_VALUE else OFF_VALUE

        // Optimistic update so the tile feels instant; corrected after the
        // write completes (or fails).
        updateTile(target)

        runAsync {
            val ok = writeTorch(target)
            if (ok) {
                rememberLevel(target)
            }
            if (ok) target else queryLevel()
        }
    }

    // --- state ---------------------------------------------------------------

    /** Best-effort current brightness: real node value, else last known. */
    private fun queryLevel(): Int {
        try {
            val level = File(TORCH_DEVICE).readText().trim().toIntOrNull()
            if (level != null && level in MIN_VALUE..MAX_VALUE) {
                return level
            }
        } catch (_: Exception) {
            // Node not readable by the app — fall through to the cached level.
        }
        return lastLevel()
    }

    private fun lastLevel(): Int =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_LEVEL, OFF_VALUE)

    private fun rememberLevel(level: Int) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_LEVEL, level)
            .apply()
    }

    // --- device writes -------------------------------------------------------

    /**
     * Writes the brightness level to the torch node. This is allowed because
     * the flashed package owns the filesystem capability declared in
     * config/begotorch.cml. A short lock keeps concurrent taps serialized.
     */
    private fun writeTorch(level: Int): Boolean {
        writeLock.lock()
        try {
            File(TORCH_DEVICE).writeText("$level\n")
            return true
        } catch (_: Exception) {
            return false
        } finally {
            writeLock.unlock()
        }
    }

    // --- tile rendering ------------------------------------------------------

    private fun updateTile(level: Int) {
        val tile = qsTile ?: return
        tile.state = if (level == 0) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.label = getString(R.string.tile_label)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_torch)
        if (level > 0) {
            val description = getString(R.string.tile_state_level, level)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                tile.subtitle = description
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tile.stateDescription = description
            }
        }
        tile.updateTile()
    }

    private fun runAsync(block: () -> Int) {
        Thread {
            val level = try {
                block()
            } catch (_: Exception) {
                lastLevel()
            }
            mainHandler.post { updateTile(level) }
        }.start()
    }

    private companion object {
        const val PREFS = "begotorch_tile"
        const val KEY_LEVEL = "last_level"

        const val TORCH_DEVICE =
            "/sys/devices/platform/flashlights_mt6360/torchbrightness"

        const val MIN_VALUE = 0
        const val MAX_VALUE = 7
        const val OFF_VALUE = MIN_VALUE
        const val ON_VALUE = MAX_VALUE
    }
}
