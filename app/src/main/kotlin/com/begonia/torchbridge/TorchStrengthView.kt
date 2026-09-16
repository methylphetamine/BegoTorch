package com.begonia.torchbridge

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View

/**
 * The torch strength picker: an eight-stop horizontal slider drawn from scratch.
 *
 * Zero dependencies on purpose. This component is flashed into the system
 * partition and rendered inside the Quick Settings panel, so everything it draws
 * comes from `android.graphics` rather than a UI toolkit: no AppCompat, no
 * Material, no AndroidX, nothing that could version-skew against an arbitrary
 * ROM's resources or inflate the APK.
 *
 * The interaction model is what people expect from a torch slider — press and
 * drag across the stops for continuous adjustment, tap a stop to jump to it, and
 * tap the left-most stop to switch the torch off.
 */
class TorchStrengthView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    /** Called on every level change, including mid-drag. */
    var onLevelChanged: ((Int) -> Unit)? = null

    /** Called once the level stops changing (finger up, or a tap). */
    var onLevelSettled: ((Int) -> Unit)? = null

    private val density = resources.displayMetrics.density

    private var maxLevel = Torch.MAX_LEVEL
    private var level = Torch.OFF

    // Colours are resolved from resources (see res/values/colors.xml) so a ROM
    // themer can override them with an RRO without touching this code. They are
    // declared before the paints because paint initializers read them.
    private val colorPanel = context.getColor(R.color.torch_panel)
    private val colorPanelEdge = context.getColor(R.color.torch_panel_edge)
    private val colorStop = context.getColor(R.color.torch_stop)
    private val colorAccent = context.getColor(R.color.torch_accent)
    private val colorMuted = context.getColor(R.color.torch_muted)

    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colorPanel }

    private val stopPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private val stopEdgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)
        color = colorPanelEdge
    }

    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = colorMuted
        textSize = sp(12f)
    }

    private val valuePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = colorAccent
        textSize = sp(12f)
        isFakeBoldText = true
    }

    private val stopTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = sp(13f)
    }

    private val panelBounds = RectF()
    private val stopBounds = RectF()

    init {
        isClickable = true
        isFocusable = true
        contentDescription = context.getString(R.string.tile_strength_label)
    }

    /** Sets the ROM's maximum level and the level to display. */
    fun setLevels(value: Int, maximum: Int) {
        maxLevel = maximum.coerceIn(1, Torch.MAX_LEVEL)
        level = value.coerceIn(Torch.OFF, maxLevel)
        invalidate()
    }

    fun level(): Int = level

    // --- geometry -------------------------------------------------------------

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            resolveSize(dp(MIN_WIDTH_DP).toInt(), widthMeasureSpec),
            dp(HEIGHT_DP).toInt(),
        )
    }

    private fun contentLeft() = dp(PAD_DP)

    private fun contentRight() = width - dp(PAD_DP)

    private fun stopCount() = maxLevel + 1

    private fun stopWidth() = (contentRight() - contentLeft()) / stopCount()

    private fun stopLeft(index: Int) = contentLeft() + index * stopWidth() + dp(3f)

    private fun stopRight(index: Int) = contentLeft() + (index + 1) * stopWidth() - dp(3f)

    private fun dp(value: Float) = value * density

    private fun sp(value: Float) = value * resources.displayMetrics.scaledDensity

    // --- drawing --------------------------------------------------------------

    override fun onDraw(canvas: Canvas) {
        panelBounds.set(0f, 0f, width.toFloat(), height.toFloat())
        canvas.drawRoundRect(panelBounds, dp(20f), dp(20f), backgroundPaint)

        val titleBaseline = dp(PAD_DP) + titlePaint.textSize
        canvas.drawText(
            context.getString(R.string.picker_title),
            contentLeft(),
            titleBaseline,
            titlePaint,
        )

        val valueText = if (level == Torch.OFF) {
            context.getString(R.string.picker_off)
        } else {
            context.getString(R.string.picker_value, level, maxLevel)
        }
        canvas.drawText(
            valueText,
            contentRight() - valuePaint.measureText(valueText),
            titleBaseline,
            valuePaint,
        )

        val top = titleBaseline + dp(14f)
        val bottom = top + dp(STOP_HEIGHT_DP)
        for (index in 0 until stopCount()) {
            stopBounds.set(stopLeft(index), top, stopRight(index), bottom)
            val selected = index == level
            stopPaint.color = if (selected) colorAccent else colorStop
            canvas.drawRoundRect(stopBounds, dp(12f), dp(12f), stopPaint)
            if (!selected) {
                canvas.drawRoundRect(stopBounds, dp(12f), dp(12f), stopEdgePaint)
            }
            stopTextPaint.color = if (selected) colorPanel else colorMuted
            val text = if (index == Torch.OFF) {
                context.getString(R.string.picker_stop_off)
            } else {
                index.toString()
            }
            val textY = stopBounds.centerY() -
                (stopTextPaint.descent() + stopTextPaint.ascent()) / 2f
            canvas.drawText(text, stopBounds.centerX(), textY, stopTextPaint)
        }
    }

    // --- touch ----------------------------------------------------------------

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // The QS panel is a scroll container; without this the drag would
                // be stolen by the panel as soon as the finger moves sideways.
                parent?.requestDisallowInterceptTouchEvent(true)
                applyFromX(event.x)
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                applyFromX(event.x)
                return true
            }

            MotionEvent.ACTION_UP -> {
                applyFromX(event.x)
                parent?.requestDisallowInterceptTouchEvent(false)
                performClick()
                onLevelSettled?.invoke(level)
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                parent?.requestDisallowInterceptTouchEvent(false)
                onLevelSettled?.invoke(level)
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    private fun applyFromX(x: Float) {
        val index = ((x - contentLeft()) / stopWidth()).toInt().coerceIn(0, stopCount() - 1)
        if (index == level) return
        level = index
        invalidate()
        onLevelChanged?.invoke(level)
    }

    private companion object {
        const val MIN_WIDTH_DP = 260f
        const val HEIGHT_DP = 118f
        const val PAD_DP = 18f
        const val STOP_HEIGHT_DP = 46f
    }
}
