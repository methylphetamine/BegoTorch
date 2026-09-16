package com.begonia.torchbridge

import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The strength picker, shown *inside* the Quick Settings panel.
 *
 * [android.service.quicksettings.TileService.showDialog] presents this dialog on
 * the SystemUI panel window token, which is why the component needs no activity:
 * nothing is started, nothing is exported, and the shade stays open.
 *
 * Writing the level is deliberately off the main thread — a dialog that stutters
 * the shade while it writes sysfs is a worse experience than one that is a
 * frame late — and the level is read back after every commit so the tile and the
 * picker can never disagree with the hardware.
 */
class TorchStrengthDialog(
    context: Context,
    private val onLevelApplied: (Int) -> Unit,
) : Dialog(context, android.R.style.Theme_DeviceDefault_Dialog_NoActionBar) {

    private val picker = TorchStrengthView(context)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "torchbridge-picker").apply { isDaemon = true }
    }

    init {
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(picker)

        window?.let { window ->
            // The picker draws its own panel, so the dialog window itself must be
            // fully transparent — otherwise a ROM's dialog background would show
            // as a second, differently-coloured rectangle behind it.
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            window.setLayout(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            window.setGravity(Gravity.BOTTOM)
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            val attributes = window.attributes
            attributes.dimAmount = 0.45f
            window.attributes = attributes
        }

        setCanceledOnTouchOutside(true)

        // Probe fresh every time the picker opens: the ROM may have restarted
        // its camera service or reloaded a different policy since last time.
        Torch.invalidate()
        picker.setLevels(Torch.getLevel(context), Torch.maxLevel(context))
        picker.onLevelChanged = { level -> apply(level) }
        picker.onLevelSettled = { level -> apply(level) }

        setOnDismissListener { worker.shutdownNow() }
    }

    private fun apply(level: Int) {
        val appContext = context.applicationContext
        try {
            worker.execute {
                val written = try {
                    Torch.setLevel(appContext, level)
                } catch (t: Throwable) {
                    Log.w(TAG, "picker write failed: ${t.message}")
                    false
                }
                // Always report what the device actually holds, clamped by the
                // driver (torchbrightness_store clamps to the kernel's maximum,
                // which is 7 on begonia) rather than what was requested.
                val effective = Torch.getLevel(appContext)
                main.post {
                    picker.setLevels(effective, Torch.maxLevel(appContext))
                    if (written) onLevelApplied(effective)
                }
            }
        } catch (e: RejectedExecutionException) {
            Log.d(TAG, "picker already dismissed")
        }
    }

    /** Dismisses without ever throwing, for the tile's fallback path. */
    fun dismissQuietly() {
        try {
            if (isShowing) dismiss()
        } catch (t: Throwable) {
            Log.d(TAG, "dismiss failed: ${t.message}")
        }
    }

    override fun dismiss() {
        try {
            super.dismiss()
        } catch (t: Throwable) {
            // A tile dialog can be torn down by SystemUI while it is closing;
            // that is not an error worth propagating to the tile.
            Log.d(TAG, "dismiss failed: ${t.message}")
        }
    }

    private companion object {
        const val TAG = "TorchBridge"
    }
}
