package com.ztransfer.frame

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import java.util.Locale

internal val PhotoFrameMetadata.useBrandLogo: Boolean
    get() = brandStyle == PhotoFrameBrandStyle.LOGO &&
        (normalizeCameraMake(make).equals("Nikon", true) ||
            BrandLogoPaths.vectors.containsKey(normalizeCameraMake(make).lowercase(Locale.ROOT)))

private val brandPrefix = Regex(
    "^(NIKON(?:\\s+CORPORATION)?|FUJIFILM|PANASONIC|SAMSUNG|MOTOROLA|ONEPLUS|HUAWEI|XIAOMI|HONOR|APPLE|GOOGLE|NOKIA|LEICA|SONY|OPPO|VIVO|DJI)(?=\\s|$)",
    RegexOption.IGNORE_CASE,
)

private data class IdentityLogo(
    val vector: BrandVector?, val remaining: String,
    val width: Float, val height: Float, val center: Float,
)

/** One geometry calculation shared by measurement, drawing and vertical layout. */
private fun Paint.identityLogo(text: String, enabled: Boolean, scale: Float): IdentityLogo? {
    if (!enabled) return null
    val prefix = brandPrefix.find(text)?.value ?: return null
    val nikon = prefix.startsWith("Nikon", true)
    val vector = if (nikon) null else (BrandLogoPaths.vectors[prefix.lowercase(Locale.ROOT)] ?: return null)
    val lettering = Rect().also { getTextBounds(prefix, 0, prefix.length, it) }
    var height = lettering.height().coerceAtLeast(1) * scale * (vector?.heightFactor ?: 1f)
    val aspect = vector?.let { it.bounds.width() / it.bounds.height() } ?: 1f
    var width = height * aspect
    // Existing frame fitters budget for brand lettering. Wide wordmarks must respect that budget.
    if (!nikon) {
        val maxWidth = measureText(prefix).coerceAtLeast(1f)
        if (width > maxWidth) { height *= maxWidth / width; width = maxWidth }
    }
    return IdentityLogo(vector, text.substring(prefix.length), width, height,
        (lettering.top + lettering.bottom) / 2f)
}

internal fun Canvas.drawFrameIdentity(text: String, x: Float, baseline: Float, paint: Paint, logo: Boolean, logoScale: Float = 1.35f) {
    val mark = paint.identityLogo(text, logo, logoScale)
    if (mark == null) { drawText(text, x, baseline, paint); return }
    val width = mark.width + paint.measureText(mark.remaining)
    val left = when (paint.textAlign) {
        Paint.Align.CENTER -> x - width / 2f
        Paint.Align.RIGHT -> x - width
        else -> x
    }
    val top = baseline + mark.center - mark.height / 2f
    val vector = mark.vector
    if (vector == null) {
        NikonBrandLogo.draw(this, left, top, mark.width, paint.alpha)
    } else {
        val save = save()
        translate(left, top)
        scale(mark.width / vector.bounds.width(), mark.height / vector.bounds.height())
        translate(-vector.bounds.left, -vector.bounds.top)
        // Monochrome variants follow the frame ink, retaining contrast on light and dark frames.
        drawPath(vector.path, Paint(paint).apply {
            style = Paint.Style.FILL
            shader = null
            pathEffect = null
            clearShadowLayer()
        })
        restoreToCount(save)
    }
    if (mark.remaining.isNotEmpty()) {
        drawText(mark.remaining, left + mark.width, baseline, Paint(paint).apply { textAlign = Paint.Align.LEFT })
    }
}

internal fun Paint.measureFrameIdentity(text: String, logo: Boolean, logoScale: Float = 1.35f): Float {
    val mark = identityLogo(text, logo, logoScale) ?: return measureText(text)
    return mark.width + measureText(mark.remaining)
}

internal fun frameIdentityVisualBounds(text: String, paint: Paint, logo: Boolean, logoScale: Float = 1.35f): FrameTextVisualBounds {
    val mark = paint.identityLogo(text, logo, logoScale)
    val visibleText = mark?.remaining ?: text
    val bounds = Rect().also { paint.getTextBounds(visibleText, 0, visibleText.length, it) }
    if (mark == null) return FrameTextVisualBounds(bounds.top.toFloat(), bounds.bottom.toFloat())
    val top = mark.center - mark.height / 2f
    val bottom = mark.center + mark.height / 2f
    return if (visibleText.isBlank()) FrameTextVisualBounds(top, bottom)
        else FrameTextVisualBounds(minOf(bounds.top.toFloat(), top), maxOf(bounds.bottom.toFloat(), bottom))
}

// Ratios are relative to visible brand lettering, not the font's em box.
internal fun PhotoFramePreset.brandLogoScale(): Float = when (this) {
    PhotoFramePreset.FILM_GALLERY -> 1.15f // Narrow strip above the perforations.
    PhotoFramePreset.FILM_EDGE -> 1.20f
    PhotoFramePreset.IMMERSIVE, PhotoFramePreset.COLOR_ARCHIVE -> 1.30f
    PhotoFramePreset.MIST, PhotoFramePreset.CINEMA, PhotoFramePreset.MINIMAL,
    PhotoFramePreset.FROSTED, PhotoFramePreset.PLAQUE -> 1.35f
    PhotoFramePreset.BRAND_INSET, PhotoFramePreset.GALLERY_MAT -> 1.45f
    PhotoFramePreset.CLASSIC_SIGNATURE, PhotoFramePreset.BRAND_GALLERY -> 1.55f
    PhotoFramePreset.PARAMETER_POSTER -> 1.65f
}
