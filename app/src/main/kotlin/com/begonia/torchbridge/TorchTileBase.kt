package com.begonia.torchbridge

import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Shared Quick Settings plumbing for the two torch tiles.
 *
 * Two rules shape this class:
 *
 *  * **Never touch a sysfs node on the main thread.** Probing nodes and writing
 *    levels is blocking IO (and on a cold page cache a sysfs write can take a
 *    moment), so every device interaction happens on a single worker thread and
 *    only the tile rendering returns to the main looper.
 *  * **A tile must never block on a broken ROM.** If the write fails, the level
 *    reported back is whatever the device actually says, so the tile shows the
 *    truth instead of an optimistic lie.
 */
abstract class TorchTileBase : TileService() {

    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "torchbridge-tile").apply { isDaemon = true }
    }

    /** Label shown under the tile. */
    protected abstract fun tileLabel(): String

    /** Icon shown on the tile. */
    protected abstract fun tileIconRes(): Int

    override fun onStartListening() {
        super.onStartListening()
        // The QS panel is the only place the state is shown, so the capability
        // probe is re-run every time it opens: the user may have rebooted into a
        // different mode (camera service restarted, node relabelled by the
        // flash-time rule, and so on).
        Torch.invalidate()
        refreshTile()
    }

    override fun onTileAdded() {
        super.onTileAdded()
        Torch.invalidate()
        refreshTile()
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    /** Reads the current level off the main thread and renders it. */
    protected fun refreshTile() {
        runLevelWork { Torch.getLevel(this) }
    }

    /**
     * Applies [block] on the worker thread, then renders the level it returns.
     * Exceptions are contained: a tile that throws is a tile SystemUI may stop
     * bound, and a torch control that survives a broken ROM is more useful than
     * one that is merely correct.
     */
    protected fun runLevelWork(block: () -> Int) {
        try {
            worker.execute {
                val level = try {
                    block()
                } catch (t: Throwable) {
                    Log.w(TAG, "tile work failed: ${t.message}")
                    Torch.OFF
                }
                main.post { renderTile(level) }
            }
        } catch (e: RejectedExecutionException) {
            // The service is being torn down; nothing to render.
            Log.d(TAG, "ignoring work after shutdown")
        }
    }

    /** Renders [level] into the tile. Must run on the main thread. */
    protected fun renderTile(level: Int) {
        val tile = qsTile ?: return
        val clamped = level.coerceIn(Torch.MIN_LEVEL, Torch.MAX_LEVEL)
        tile.label = tileLabel()
        tile.icon = Icon.createWithResource(this, tileIconRes())
        tile.state = if (clamped > Torch.OFF) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE

        val description = describe(clamped)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = description
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            tile.stateDescription = description
        }
        tile.updateTile()
    }

    /**
     * The tile text. The active mode is included because it is the single most
     * useful piece of information when torch strength "does not work" on a ROM:
     * it says whether the flash-time rule took effect (camera strength API),
     * whether the sysfs rule worked (torch node / LED class), or whether the
     * component fell back to the on/off camera path.
     */
    private fun describe(level: Int): String {
        val mode = Torch.modeLabel(this)
        return if (level == Torch.OFF) {
            getString(R.string.tile_state_off, mode)
        } else {
            getString(R.string.tile_state_level, level, Torch.maxLevel(this).coerceAtLeast(level))
        }
    }

    private companion object {
        const val TAG = "TorchBridge"
    }
}
