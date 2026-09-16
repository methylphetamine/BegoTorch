package com.begonia.torchbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.util.concurrent.Executors

/**
 * Re-asserts the Quick Settings layout at boot and after an update.
 *
 * Runs the work through [goAsync] on a worker thread: touching `Settings.Secure`
 * and the system services from `onReceive` risks an ANR in a receiver that the
 * system starts for every boot, and a boot-time ANR costs far more than the extra
 * thread.
 *
 * Only the panel *layout* is touched here. The board's own state (torch on/off)
 * is never changed at boot — a component that switches a flashlight on by itself
 * after a reboot would be a bug, not a feature.
 */
class TileInstallerReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }

        val appContext = context.applicationContext
        val pending = goAsync()
        try {
            WORKER.execute {
                try {
                    TileInstaller.ensureTiles(appContext)
                } catch (t: Throwable) {
                    Log.w(TAG, "tile install failed: ${t.message}")
                } finally {
                    pending.finish()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "cannot dispatch tile install: ${t.message}")
            pending.finish()
        }
    }

    private companion object {
        const val TAG = "TorchBridge"
        val WORKER = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "torchbridge-tiles").apply { isDaemon = true }
        }
    }
}
