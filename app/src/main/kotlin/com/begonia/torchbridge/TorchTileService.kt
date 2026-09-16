package com.begonia.torchbridge

import android.annotation.SuppressLint

/**
 * Quick Settings tile: the torch toggle.
 *
 * Tap → torch on at the last used strength, or off. The strength it turns on to
 * is remembered (see [Prefs.onLevel]), so the toggle is a "restore my preferred
 * brightness" button rather than a blind jump to maximum.
 *
 * Bluetooth-headset-style tile state comes from the device itself: after every
 * write the level is read back, so if the ROM clamped what we asked for, the
 * tile shows the clamped value rather than the requested one.
 */
class TorchTileService : TorchTileBase() {

    override fun tileLabel(): String = getString(R.string.tile_torch_label)

    override fun tileIconRes(): Int = R.drawable.ic_tile_torch

    @SuppressLint("NewApi")
    override fun onClick() {
        // Render the intent immediately so the tap feels instant, then let the
        // worker thread produce the authoritative level (which may differ if the
        // ROM clamped it).
        val predicted = if (Torch.getLevel(this) == Torch.OFF) {
            Prefs.onLevel(this)
        } else {
            Torch.OFF
        }
        renderTile(predicted)

        runLevelWork {
            Torch.invalidate()
            Torch.setLevel(this, predicted)
            Torch.getLevel(this)
        }
    }
}
