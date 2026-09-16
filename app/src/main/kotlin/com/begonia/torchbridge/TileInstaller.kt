package com.begonia.torchbridge

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/**
 * Puts the tiles into the Quick Settings panel with no user interaction.
 *
 * This is the piece that makes the flashed component feel like part of the ROM
 * rather than an app: after the first boot the tiles are simply there, so the
 * user never opens anything, never drags a tile, and never sees a permission
 * prompt.
 *
 * Two mechanisms, in order of preference:
 *
 *  1. **`sysui_qs_tiles`.** As a privileged system app holding
 *     `WRITE_SECURE_SETTINGS` (allowlisted in `/system/etc/permissions` by the
 *     TWRP package) the component may append its own components to the setting
 *     SystemUI reads the panel layout from. Silent, instant, and it works on
 *     every ROM that keeps this AOSP setting — which is all of them.
 *  2. **[android.app.StatusBarManager.requestAddTileService]** (API 33+) as a
 *     fallback. It needs the requesting app to be in the foreground, which a
 *     headless component is not, so it is attempted only when the secure-setting
 *     write is denied; if it also fails, the documentation tells the user to drag
 *     the tiles in manually, which always works.
 *
 * Existing tiles are never reordered and never dropped: the setting is only ever
 * appended to, and only when a component is missing from it.
 */
object TileInstaller {

    private const val TAG = "TorchBridge"

    /** The AOSP setting SystemUI reads the QS panel layout from. */
    private const val QS_TILES_SETTING = "sysui_qs_tiles"

    /** Components to ensure are present, in order. */
    private fun wanted(context: Context): List<String> = listOf(
        ComponentName(context, TorchTileService::class.java).flattenToShortString(),
        ComponentName(context, TorchStrengthTileService::class.java).flattenToShortString(),
    )

    /**
     * Ensures both tiles are in the panel.
     *
     * @return true when the panel layout already contained both, or was updated.
     */
    fun ensureTiles(context: Context): Boolean {
        val resolver = context.contentResolver
        val current = try {
            Settings.Secure.getString(resolver, QS_TILES_SETTING)
        } catch (t: Throwable) {
            Log.w(TAG, "cannot read $QS_TILES_SETTING: ${t.message}")
            null
        }

        // A ROM that ships no explicit layout uses its own default list; writing
        // an empty base here would *replace* that default with two tiles, so in
        // that case append to nothing and let SystemUI merge the result.
        val existing = current.orEmpty()
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toMutableList()

        // Custom tiles are stored either as a bare flattened component or wrapped
        // in custom(...) depending on the ROM's SystemUI generation. Follow
        // whatever the panel already uses; that keeps us consistent with the
        // tiles the user added by hand.
        val usesCustomWrapper = existing.any { it.startsWith(CUSTOM_PREFIX) }

        var added = 0
        for (component in wanted(context)) {
            val token = if (usesCustomWrapper) "$CUSTOM_PREFIX$component)" else component
            if (existing.none { it == token || it == component }) {
                existing.add(token)
                added++
            }
        }

        if (added == 0) {
            Log.i(TAG, "tiles already present in the QS panel")
            return true
        }

        val updated = existing.joinToString(",")
        return try {
            Settings.Secure.putString(resolver, QS_TILES_SETTING, updated)
            Log.i(TAG, "added $added tile(s) to the QS panel")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "not allowed to write $QS_TILES_SETTING: ${t.message}")
            requestAddViaStatusBar(context)
        }
    }

    /**
     * Last-resort fallback for ROMs that deny the secure-setting write. The
     * platform shows its own "add tile?" prompt; a headless component cannot
     * satisfy the foreground requirement, so this normally fails too and the
     * user adds the tiles by hand.
     */
    private fun requestAddViaStatusBar(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return try {
            val statusBar = context.getSystemService(Context.STATUS_BAR_SERVICE)
                as? android.app.StatusBarManager ?: return false
            val component = ComponentName(context, TorchStrengthTileService::class.java)
            val label = context.getString(R.string.tile_strength_label)
            val icon = android.graphics.drawable.Icon.createWithResource(
                context,
                R.drawable.ic_tile_strength,
            )
            Handler(Looper.getMainLooper()).post {
                @Suppress("DEPRECATION")
                statusBar.requestAddTileService(
                    component,
                    label,
                    icon,
                    { runnable -> runnable.run() },
                ) { result ->
                    Log.i(TAG, "requestAddTileService result=$result")
                }
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "requestAddTileService unavailable: ${t.message}")
            false
        }
    }

    private const val CUSTOM_PREFIX = "custom("
}
