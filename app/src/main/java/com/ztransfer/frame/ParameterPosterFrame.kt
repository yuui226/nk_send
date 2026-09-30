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

internal data class PosterRow(
    val text: String,
    val size: Float,
    val label: String? = null,
    val bold: Boolean = false,
    val medium: Boolean = false,
    val italic: Boolean = false,
    val alpha: Int = 255,
    val gapAfter: Float = 0f,
    val brandLogo: Boolean = false,
)

private data class PosterGroups(
    val identity: List<PosterRow>,
    val exposure: List<PosterRow>,
    val location: List<PosterRow>,
)

/** Semantic groups feed the single measured layout at every border width. */
private fun posterGroups(width: Float, portrait: Boolean, metadata: PhotoFrameMetadata): PosterGroups {
    val bodySize = width * if (portrait) 0.034f else 0.025f
    val identity = buildList {
        normalizeCameraMake(metadata.make).takeIf(String::isNotBlank)?.let {
            add(PosterRow(it, width * if (portrait) 0.112f else 0.078f, bold = true, italic = true, gapAfter = width * 0.012f, brandLogo = metadata.useBrandLogo))
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
    return PosterGroups(identity, exposure, location)
}

private fun joinedPosterGroups(width: Float, portrait: Boolean, vararg groups: List<PosterRow>): List<PosterRow> = buildList {
    groups.filter { it.isNotEmpty() }.forEach { group ->
        if (isNotEmpty()) {
            val previous = removeAt(lastIndex)
            add(previous.copy(gapAfter = previous.gapAfter + width * if (portrait) 0.10f else 0.035f))
        }
        addAll(group)
    }
}

/** Metadata is already filtered by switches; do not infer a hidden brand from the model. */
internal fun drawParameterPosterMetadata(canvas: Canvas, layout: PhotoFrameLayout) {
    val plan = checkNotNull(layout.posterLayout)
    val save = canvas.save()
    canvas.scale(layout.posterLayoutScale, layout.posterLayoutScale)
    plan.columns.forEach { drawPosterRows(canvas, it) }
    canvas.restoreToCount(save)
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

/** Measured once: drawing must not independently wrap or choose another text size. */
internal data class PosterRowsLayout(
    val rows: List<PosterRow>,
    val heights: List<Float>,
    val valueSizes: List<Float>,
    val naturalHeight: Float,
    val scale: Float,
    val area: RectF,
)

private fun measurePosterRows(rows: List<PosterRow>, area: RectF): PosterRowsLayout? {
    if (rows.isEmpty() || area.width() <= 0 || area.height() <= 0) return null
    val wrapped = rows.flatMap { row ->
        if (row.label != null || row.brandLogo) listOf(row) else {
            wrapFrameDescription(row.text, posterPaint(row), area.width() * 0.96f).mapIndexed { index, text ->
                row.copy(text = text, gapAfter = 0f)
            }.let { lines -> lines.mapIndexed { index, line ->
                if (index == lines.lastIndex) line.copy(gapAfter = row.gapAfter) else line
            } }
        }
    }
    fun rowHeight(row: PosterRow): Float = if (row.label != null) row.size * 2.65f else {
        val fm = posterPaint(row).fontMetrics
        val bounds = frameIdentityVisualBounds(row.text, posterPaint(row), row.brandLogo,
            PhotoFramePreset.PARAMETER_POSTER.brandLogoScale())
        maxOf((fm.descent - fm.ascent) * 1.16f, bounds.bottom - bounds.top + row.size * 0.16f)
    }
    val heights = wrapped.map(::rowHeight)
    val total = wrapped.indices.sumOf { (heights[it] + wrapped[it].gapAfter).toDouble() }.toFloat() - wrapped.last().gapAfter
    val scale = 1f
    val valueSizes = wrapped.map { it.size }
    return PosterRowsLayout(wrapped, heights, valueSizes, total, scale, RectF(area))
}

/** Keep the current presentation while separating measurement from canvas operations. */
private fun drawPosterRows(canvas: Canvas, plan: PosterRowsLayout) {
    val area = plan.area
    val total = plan.naturalHeight
    val scale = plan.scale
    canvas.save()
    canvas.translate(area.left, area.top + (area.height() - total * scale) / 2f)
    canvas.scale(scale, scale)
    val availableWidth = area.width() / scale
    var y = 0f
    for ((index, row) in plan.rows.withIndex()) {
        val paint = posterPaint(row)
        val rowHeight = plan.heights[index]
        if (row.label == null) {
            val bounds = frameIdentityVisualBounds(row.text, paint, row.brandLogo,
                PhotoFramePreset.PARAMETER_POSTER.brandLogoScale())
            val baseline = if (row.brandLogo) y + (rowHeight - bounds.bottom + bounds.top) / 2f - bounds.top
                else y - paint.fontMetrics.ascent
            canvas.drawFrameIdentity(row.text, 0f, baseline, paint, row.brandLogo,
                PhotoFramePreset.PARAMETER_POSTER.brandLogoScale())
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
            paint.textSize = plan.valueSizes[index]
            canvas.drawText(row.text, valueX, boxTop + (boxHeight - paint.fontMetrics.ascent - paint.fontMetrics.descent) / 2, paint)
        }
        y += rowHeight + row.gapAfter
    }
    canvas.restore()
}

/** A small immutable drawing plan, in 1000-unit photo-width coordinates. */
internal data class MeasuredPosterComposition(val columns: List<PosterRowsLayout>)

/**
 * Content drives the side/bottom band before bitmap allocation. The photo itself is never scaled.
 * All width settings share these typography and placement rules.
 */
internal fun calculateMeasuredParameterPosterLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    percent: Int,
    metadata: PhotoFrameMetadata,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(percent in MIN_PHOTO_FRAME_WIDTH_PERCENT..MAX_PHOTO_FRAME_WIDTH_PERCENT)
    val width = 1000f
    val height = sourceHeight.toDouble().div(sourceWidth).times(width).toFloat()
    val portrait = sourceHeight > sourceWidth
    val ratio = percent / 100f
    // Typography stays stable; the width control adjusts surrounding space.
    val groups = posterGroups(width, portrait, metadata)
    fun rows(vararg source: List<PosterRow>): List<PosterRow> =
        joinedPosterGroups(width, portrait, *source).map {
            it.copy(gapAfter = it.gapAfter * minOf(ratio, 1f))
        }
    fun minimumWidth(rows: List<PosterRow>): Float = rows.maxOfOrNull { row ->
        val paint = posterPaint(row)
        when {
            row.brandLogo -> paint.measureFrameIdentity(row.text, true, PhotoFramePreset.PARAMETER_POSTER.brandLogoScale()) / 0.96f
            row.label != null -> row.size * (3.65f + 0.85f) + paint.measureText(row.text) + row.size * 0.1f
            else -> minOf(paint.measureText(row.text) / 0.96f, row.size * 6f)
                // Short identities need only their measured width; long descriptions may wrap.
        }
    } ?: 0f
    fun measure(rows: List<PosterRow>, availableWidth: Float): PosterRowsLayout? =
        measurePosterRows(rows, RectF(0f, 0f, availableWidth, Float.MAX_VALUE / 4f))
    val plans = mutableListOf<PosterRowsLayout>()
    var left: Float
    var top = 110f * ratio
    val right: Float
    var bottom: Float
    if (portrait) {
        val content = rows(groups.identity, groups.exposure, groups.location)
        val outer = 360f * ratio
        val inner = 180f * ratio
        val columnWidth = maxOf(560f * ratio, minimumWidth(content))
        val measured = measure(content, columnWidth)
        left = if (measured == null) {
            // Release the unused column progressively, without a jump immediately below 100%.
            val minRatio = MIN_PHOTO_FRAME_WIDTH_PERCENT / 100f
            val remainingColumn = ((ratio - minRatio) / (1f - minRatio)).coerceIn(0f, 1f)
            220f * ratio + 880f * remainingColumn
        } else outer + columnWidth + inner
        right = 220f * ratio
        bottom = 110f * ratio
        if (measured != null) {
            val requiredHeight = measured.naturalHeight + height * 0.12f
            val extra = (requiredHeight - height).coerceAtLeast(0f) / 2f
            top += extra
            bottom += extra
            plans += measured.copy(area = RectF(outer, top + height / 2f - measured.naturalHeight / 2f,
                outer + columnWidth, top + height / 2f + measured.naturalHeight / 2f))
        }
    } else {
        left = 100f * ratio
        right = left
        val first = rows(groups.identity, groups.location)
        val second = rows(groups.exposure)
        val hasBoth = first.isNotEmpty() && second.isNotEmpty()
        val inset = 25f
        val gap = 105f * ratio
        val secondWidth = maxOf(365f, minimumWidth(second))
        val requiredWidth = if (hasBoth) minimumWidth(first) + gap + secondWidth + inset * 2 else
            minimumWidth(if (first.isEmpty()) second else first) + inset * 2
        // Unusually long indivisible parameter values may require wider outside margins.
        val extraSide = (requiredWidth - width).coerceAtLeast(0f) / 2f
        left += extraSide
        val bandWidth = width + extraSide * 2
        val startX = left - extraSide + inset
        val usable = bandWidth - inset * 2
        val a = measure(if (first.isEmpty()) second else first,
            if (hasBoth) usable - gap - secondWidth else usable)
        val b = if (hasBoth) measure(second, secondWidth) else null
        val contentHeight = maxOf(a?.naturalHeight ?: 0f, b?.naturalHeight ?: 0f)
        val padding = 47.5f * ratio
        bottom = maxOf(480f * ratio, contentHeight + padding * 2)
        val bandTop = top + height
        a?.let { plans += it.copy(area = RectF(startX, bandTop + (bottom - it.naturalHeight) / 2,
            startX + it.area.width(), bandTop + (bottom + it.naturalHeight) / 2)) }
        b?.let { plans += it.copy(area = RectF(startX + usable - secondWidth, bandTop + (bottom - it.naturalHeight) / 2,
            startX + usable, bandTop + (bottom + it.naturalHeight) / 2)) }
        // Account for both expanded margins without moving the photo twice.
        return measuredPosterPixelLayout(sourceWidth, sourceHeight, left, top, right + extraSide, bottom, plans)
    }
    return measuredPosterPixelLayout(sourceWidth, sourceHeight, left, top, right, bottom, plans)
}

private fun measuredPosterPixelLayout(
    width: Int, height: Int, left: Float, top: Float, right: Float, bottom: Float,
    columns: List<PosterRowsLayout>,
): PhotoFrameLayout {
    val scale = width / 1000f
    fun padding(value: Float): Int {
        val pixels = kotlin.math.ceil(value.toDouble() * scale)
        require(pixels.isFinite() && pixels >= 0 && pixels <= Int.MAX_VALUE) { "Frame content is too large" }
        return pixels.toInt()
    }
    val x = padding(left)
    val y = padding(top)
    return PhotoFrameLayout(
        canvasWidth = Math.addExact(Math.addExact(width, x), padding(right)),
        canvasHeight = Math.addExact(Math.addExact(height, y), padding(bottom)),
        photoLeft = x.toFloat(), photoTop = y.toFloat(),
        photoRight = x + width.toFloat(), photoBottom = y + height.toFloat(),
        metadataTop = y + height.toFloat(),
        posterLayout = MeasuredPosterComposition(columns), posterLayoutScale = scale,
    )
}
