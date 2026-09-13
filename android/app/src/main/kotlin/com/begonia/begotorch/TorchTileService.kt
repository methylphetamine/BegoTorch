package com.begonia.begotorch

import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.util.concurrent.locks.ReentrantLock

/**
 * Quick Settings tile that toggles the torch between off (0) and full (MAX_VALUE).
 *
 * The torch is controlled by writing directly to the sysfs node. The kernel must
 * have the node labeled with a SELinux context that the ROM policy allows the
 * app domain to write (see docs/kernel/).
 *
 * Writes run on a worker thread; the tile never blocks the main thread.
 */
class TorchTileService : TileService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val writeLock = ReentrantLock()
    private val controller: TorchController by lazy { TorchController(this) }

    override fun onStartListening() {
        super.onStartListening()
        controller.findWorkingPath()
        runAsync {
            queryLevel()
        }
    }

    override fun onClick() {
        val assumed = lastLevel()
        val target = if (assumed == 0) ON_VALUE else OFF_VALUE

        updateTile(target)

        runAsync {
            val ok = writeTorch(target)
            if (ok) {
                rememberLevel(target)
            }
            if (ok) target else queryLevel()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        controller.release()
    }

    // --- state ---------------------------------------------------------------

    private fun queryLevel(): Int {
        return controller.currentLevel().coerceIn(MIN_VALUE, MAX_VALUE)
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

    private fun writeTorch(level: Int): Boolean {
        writeLock.lock()
        try {
            return controller.setLevel(level)
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
        const val MIN_VALUE = 0
        const val MAX_VALUE = 7
        const val OFF_VALUE = MIN_VALUE
        const val ON_VALUE = MAX_VALUE
    }
}
