package com.begonia.torchbridge

/**
 * Quick Settings tile: the torch strength widget.
 *
 * Tapping it opens the strength picker as a dialog **inside the QS panel** via
 * [android.service.quicksettings.TileService.showDialog], which has been part of
 * the platform since API 24. That is the whole reason this component needs no
 * activity and nothing exported: the slider is rendered by our own view, shown
 * on the SystemUI panel window token, and writes the level directly.
 *
 * The tile itself always renders the live level and the mode the ROM is actually
 * using, so the panel shows the current strength at a glance and the picker is
 * one tap away.
 */
class TorchStrengthTileService : TorchTileBase() {

    override fun tileLabel(): String = getString(R.string.tile_strength_label)

    override fun tileIconRes(): Int = R.drawable.ic_tile_strength

    override fun onClick() {
        // showDialog() must be called on the main thread and only while the QS
        // panel is open; onClick() is exactly that, so no thread hop here.
        //
        // On a locked device the platform declines to present the dialog (see
        // TileService#showDialog) — in that case, and on any ROM that refuses
        // the dialog, fall back to stepping the level so the tap always does
        // something useful instead of nothing.
        val dialog = TorchStrengthDialog(this) { level ->
            renderTile(level)
        }
        try {
            showDialog(dialog)
        } catch (t: Throwable) {
            dialog.dismissQuietly()
            runLevelWork {
                Torch.invalidate()
                Torch.cycle(this)
            }
        }
    }
}
