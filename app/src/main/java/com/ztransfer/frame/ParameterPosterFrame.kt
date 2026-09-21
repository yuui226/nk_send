package com.ztransfer.frame

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import com.ztransfer.util.formatDegreesMinutesLatitude
import com.ztransfer.util.formatDegreesMinutesLongitude
import java.util.Locale
import kotlin.math.roundToInt

/** Portrait: information left, photograph right. Landscape/square: photograph above two columns. */
internal fun calculateOriginalParameterPosterLayout(width: Int, height: Int): PhotoFrameLayout {
    require(width > 0 && height > 0)
    fun px(ratio: Float) = (width * ratio).roundToInt().coerceAtLeast(1)
    val portrait = height > width
    val left = if (portrait) px(1.10f) else px(0.10f)
    val top = px(0.11f)
    val right = if (portrait) px(0.22f) else px(0.10f)
    val bottom = if (portrait) px(0.11f) else px(0.48f)
    return PhotoFrameLayout(
        canvasWidth = Math.addExact(Math.addExact(width, left), right),
        canvasHeight = Math.addExact(Math.addExact(height, top), bottom),
        photoLeft = left.toFloat(), photoTop = top.toFloat(),
        photoRight = left + width.toFloat(), photoBottom = top + height.toFloat(),
        metadataTop = top + height.toFloat(),
    )
}

internal fun parameterPosterCornerRadius(layout: PhotoFrameLayout): Float =
    minOf(layout.photoRight - layout.photoLeft, layout.photoBottom - layout.photoTop) * 0.018f

private data class PosterRow(
    val text: String,
    val size: Float,
    val label: String? = null,
    val bold: Boolean = false,
    val medium: Boolean = false,
    val italic: Boolean = false,
    val alpha: Int = 255,
    val gapAfter: Float = 0f,
)

/** Metadata is already filtered by the shared switches; never infer a hidden brand from a model. */
internal fun drawParameterPosterMetadata(canvas: Canvas, layout: PhotoFrameLayout, metadata: PhotoFrameMetadata) {
    val width = layout.photoRight - layout.photoLeft
    val height = layout.photoBottom - layout.photoTop
    val portrait = height > width
    val bodySize = width * if (portrait) 0.034f else 0.025f
    val identity = buildList {
        normalizeCameraMake(metadata.make).takeIf(String::isNotBlank)?.let {
            add(PosterRow(it, width * if (portrait) 0.112f else 0.078f, bold = true, italic = true, gapAfter = width * 0.012f))
        }
        normalizeCameraModel(metadata.make, metadata.model).takeIf(String::isNotBlank)?.let {
            // Treat the model as a secondary headline; keep lens details visually quieter.
            add(PosterRow(it, width * if (portrait) 0.068f else 0.047f,
                medium = true, alpha = 245, gapAfter = width * 0.016f))
        }
        metadata.lensModel?.takeIf(String::isNotBlank)?.let {
            add(PosterRow(it, bodySize * 0.88f, alpha = 205))
        }
    }
    val exposure = buildList {
        val size = width * if (portrait) 0.052f else 0.038f
        metadata.focalLength?.takeIf(String::isNotBlank)?.let {
            add(PosterRow(it, size, label = "FL", bold = true, italic = true))
        }
        metadata.aperture?.takeIf(String::isNotBlank)?.let {
            add(PosterRow(it.replace(Regex("(?i)^f/?"), ""), size, label = "F", bold = true, italic = true))
        }
        metadata.iso?.takeIf(String::isNotBlank)?.let {
            add(PosterRow(it.replace(Regex("(?i)^ISO\\s*"), ""), size, label = "ISO", bold = true, italic = true))
        }
        metadata.shutter?.takeIf(String::isNotBlank)?.let {
            add(PosterRow(it, size, label = "S", bold = true, italic = true))
        }
    }
    val location = buildList {
        metadata.dateTime?.takeIf(String::isNotBlank)?.let { add(PosterRow(it, bodySize * 0.9f, alpha = 215)) }
        listOfNotNull(metadata.city, metadata.region).filter(String::isNotBlank).distinct()
            .joinToString(" · ").takeIf(String::isNotBlank)?.let {
                add(PosterRow(it, bodySize, alpha = 235, gapAfter = width * 0.006f))
            }
        if (validFrameCoordinates(metadata.latitude, metadata.longitude)) {
            add(PosterRow(formatDegreesMinutesLatitude(checkNotNull(metadata.latitude)), bodySize * 0.88f, alpha = 205))
            add(PosterRow(formatDegreesMinutesLongitude(checkNotNull(metadata.longitude)), bodySize * 0.88f, alpha = 205))
        }
        metadata.altitudeMeters?.takeIf { it.isFinite() && it != 0.0 }?.let {
            add(PosterRow(String.format(Locale.US, "%.0f m", it), bodySize * 0.88f, alpha = 205))
        }
    }
    fun joined(vararg groups: List<PosterRow>): List<PosterRow> = buildList {
        groups.filter { it.isNotEmpty() }.forEach { group ->
            if (isNotEmpty()) {
                val previous = removeAt(lastIndex)
                add(previous.copy(gapAfter = previous.gapAfter + width * if (portrait) 0.10f else 0.035f))
            }
            addAll(group)
        }
    }
    if (portrait) {
        drawPosterRows(canvas, joined(identity, exposure, location), RectF(
            width * 0.36f, layout.photoTop + height * 0.06f,
            layout.photoLeft - width * 0.18f, layout.photoBottom - height * 0.06f,
        ))
    } else {
        val top = layout.photoBottom + width * 0.045f
        val bottom = layout.canvasHeight - width * 0.05f
        val leftRows = joined(identity, location)
        val left = layout.photoLeft + width * 0.025f
        if (leftRows.isEmpty() || exposure.isEmpty()) {
            val rows = if (leftRows.isEmpty()) exposure else leftRows
            drawPosterRows(canvas, rows, RectF(left, top, left + width * 0.60f, bottom))
        } else {
            drawPosterRows(canvas, leftRows, RectF(left, top, left + width * 0.48f, bottom))
            drawPosterRows(canvas, exposure, RectF(layout.photoLeft + width * 0.61f, top, layout.photoRight - width * 0.025f, bottom))
        }
    }
}

private fun posterPaint(row: PosterRow) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    alpha = row.alpha
    textSize = row.size
    typeface = Typeface.create(when {
        row.bold -> "sans-serif-black"
        row.medium -> "sans-serif-medium"
        else -> "sans-serif"
    }, when {
        row.bold && row.italic -> Typeface.BOLD_ITALIC
        row.bold -> Typeface.BOLD
        else -> Typeface.NORMAL
    })
}

/** Wrap descriptive text; fit exposure values on one line and leave every enabled field visible. */
private fun drawPosterRows(canvas: Canvas, rows: List<PosterRow>, area: RectF) {
    if (rows.isEmpty() || area.width() <= 0 || area.height() <= 0) return
    val wrapped = rows.flatMap { row ->
        if (row.label != null) listOf(row) else if (row.bold || row.medium) {
            val measured = posterPaint(row).measureText(row.text)
            listOf(row.copy(size = row.size * minOf(1f, area.width() * 0.96f / measured.coerceAtLeast(1f))))
        } else {
            val paint = posterPaint(row)
            val lines = mutableListOf<String>()
            var rest = row.text.trim()
            while (rest.isNotEmpty()) {
                val count = paint.breakText(rest, true, area.width() * 0.96f, null).coerceAtLeast(1)
                val boundary = if (count < rest.length) {
                    rest.lastIndexOf(' ', count).takeIf { it > count / 2 } ?: count
                } else rest.length
                lines += rest.take(boundary).trimEnd()
                rest = rest.drop(boundary).trimStart()
            }
            lines.mapIndexed { index, text -> row.copy(text = text, gapAfter = if (index == lines.lastIndex) row.gapAfter else 0f) }
        }
    }
    fun rowHeight(row: PosterRow): Float = if (row.label != null) row.size * 2.65f else {
        val fm = posterPaint(row).fontMetrics
        (fm.descent - fm.ascent) * 1.16f
    }
    val total = wrapped.sumOf { (rowHeight(it) + it.gapAfter).toDouble() }.toFloat() - wrapped.last().gapAfter
    val scale = minOf(1f, area.height() / total)
    canvas.save()
    canvas.translate(area.left, area.top + (area.height() - total * scale) / 2f)
    canvas.scale(scale, scale)
    val availableWidth = area.width() / scale
    var y = 0f
    for (row in wrapped) {
        val paint = posterPaint(row)
        val rowHeight = rowHeight(row)
        if (row.label == null) {
            canvas.drawText(row.text, 0f, y - paint.fontMetrics.ascent, paint)
        } else {
            val boxWidth = minOf(availableWidth * 0.42f, row.size * 3.65f)
            val boxHeight = row.size * 1.88f
            val boxTop = y + (rowHeight - boxHeight) / 2f
            val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = row.size * 0.085f
            }
            canvas.drawRoundRect(RectF(outline.strokeWidth, boxTop, boxWidth, boxTop + boxHeight), row.size * 0.22f, row.size * 0.22f, outline)
            val labelPaint = posterPaint(row).apply { textSize *= 0.86f; textAlign = Paint.Align.CENTER }
            canvas.drawText(row.label, boxWidth / 2, boxTop + (boxHeight - labelPaint.fontMetrics.ascent - labelPaint.fontMetrics.descent) / 2, labelPaint)
            val valueX = boxWidth + row.size * 0.85f
            val valueWidth = (availableWidth - valueX).coerceAtLeast(1f)
            if (paint.measureText(row.text) > valueWidth) paint.textSize *= valueWidth / paint.measureText(row.text)
            canvas.drawText(row.text, valueX, boxTop + (boxHeight - paint.fontMetrics.ascent - paint.fontMetrics.descent) / 2, paint)
        }
        y += rowHeight + row.gapAfter
    }
    canvas.restore()
}
