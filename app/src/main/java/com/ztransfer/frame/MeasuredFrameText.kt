package com.ztransfer.frame

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect

/** Measured in template coordinates. Positions include glyph overhang rather than advance only. */
internal data class FrameTextRun(
    val text: String,
    val paint: Paint,
    val logo: Boolean = false,
    val logoScale: Float = 1.35f,
    val watermark: PhotoFrameWatermark? = null,
    val effectPadding: Float = 0f,
    val measureInkOnly: Boolean = false,
) {
    private val ink = Rect().also { paint.getTextBounds(text, 0, text.length, it) }
    val left = if (logo) 0f else minOf(0f, ink.left.toFloat())
    val width = if (logo) paint.measureFrameIdentity(text, true, logoScale) else
        maxOf(paint.measureText(text), ink.right.toFloat()) - left
    val bounds = frameIdentityVisualBounds(text, paint, logo, logoScale).let {
        val extra = if (measureInkOnly) 0f else maxOf(effectPadding, if (watermark != null) maxOf(1f, paint.textSize * 0.2f) else paint.textSize * 0.035f)
        FrameTextVisualBounds(it.top - extra, it.bottom + extra)
    }
}

internal data class FrameTextRow(
    val runs: List<FrameTextRun>,
    val runGap: Float = 0f,
    val gapAfter: Float = 0f,
    val align: Paint.Align = Paint.Align.CENTER,
) {
    val width = runs.sumOf { it.width.toDouble() }.toFloat() + runGap * (runs.size - 1).coerceAtLeast(0)
    val top = runs.minOfOrNull { it.bounds.top } ?: 0f
    val bottom = runs.maxOfOrNull { it.bounds.bottom } ?: 0f
    val height = bottom - top
}

internal data class PositionedFrameText(val run: FrameTextRun, val x: Float, val baseline: Float)
internal data class MeasuredFrameTextPlan(val items: List<PositionedFrameText>)

internal fun frameRowsHeight(rows: List<FrameTextRow>): Float = rows.indices.sumOf {
    (rows[it].height + if (it < rows.lastIndex) rows[it].gapAfter else 0f).toDouble()
}.toFloat()

internal fun positionFrameRows(
    rows: List<FrameTextRow>, left: Float, top: Float, width: Float, height: Float,
): MeasuredFrameTextPlan {
    require(listOf(left, top, width, height).all(Float::isFinite) && width >= 0 && height >= 0)
    require(frameRowsHeight(rows) <= height + 0.01f) { "Frame information exceeds its band" }
    var y = top + (height - frameRowsHeight(rows)) / 2f
    val output = mutableListOf<PositionedFrameText>()
    rows.forEach { row ->
        require(row.width <= width + 0.01f) { "Frame information exceeds its column" }
        var x = left + when (row.align) {
            Paint.Align.LEFT -> 0f
            Paint.Align.RIGHT -> width - row.width
            else -> (width - row.width) / 2f
        }
        row.runs.forEach { run ->
            output += PositionedFrameText(run, x - run.left, y - row.top)
            x += run.width + row.runGap
        }
        y += row.height + row.gapAfter
    }
    return MeasuredFrameTextPlan(output)
}

internal fun drawMeasuredText(
    canvas: Canvas,
    plan: MeasuredFrameTextPlan,
    scale: Float,
    drawWatermark: (PositionedFrameText) -> Unit,
) {
    val save = canvas.save()
    try {
        canvas.scale(scale, scale)
        plan.items.forEach { item ->
            if (item.run.watermark != null) drawWatermark(item)
            else canvas.drawFrameIdentity(item.run.text, item.x, item.baseline,
                item.run.paint, item.run.logo, item.run.logoScale)
        }
    } finally {
        canvas.restoreToCount(save)
    }
}
