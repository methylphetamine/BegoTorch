package com.begonia.torchbridge

import android.content.Context

/**
 * Persisted tile state.
 *
 * Stored in the owner (credential-encrypted) store, which is where a boot
 * completed receiver and the SystemUI-bound tile service both live. Tiles run
 * in this component's own process, so no cross-process synchronisation is
 * needed.
 */
object Prefs {

    private const val FILE = "torchbridge"
    private const val KEY_LEVEL = "last_level"
    private const val KEY_ON_LEVEL = "on_level"
    private const val KEY_BINARY_ON = "binary_on"

    private fun sp(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Last level written, whatever it was (0 when the torch is off). */
    fun lastLevel(context: Context): Int =
        sp(context).getInt(KEY_LEVEL, Torch.OFF).coerceIn(Torch.MIN_LEVEL, Torch.MAX_LEVEL)

    fun setLastLevel(context: Context, level: Int) {
        sp(context).edit()
            .putInt(KEY_LEVEL, level.coerceIn(Torch.MIN_LEVEL, Torch.MAX_LEVEL))
            .apply()
    }

    /** The strength a toggle turns *on* to. Defaults to the upstream default. */
    fun onLevel(context: Context): Int =
        sp(context).getInt(KEY_ON_LEVEL, Torch.DEFAULT_ON)
            .coerceIn(1, Torch.MAX_LEVEL)

    fun setOnLevel(context: Context, level: Int) {
        sp(context).edit()
            .putInt(KEY_ON_LEVEL, level.coerceIn(1, Torch.MAX_LEVEL))
            .apply()
    }

    fun isBinaryOn(context: Context): Boolean = sp(context).getBoolean(KEY_BINARY_ON, false)

    fun setBinaryOn(context: Context, on: Boolean) {
        sp(context).edit().putBoolean(KEY_BINARY_ON, on).apply()
    }
}
