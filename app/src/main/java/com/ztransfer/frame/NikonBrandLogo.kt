package com.ztransfer.frame

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Shader
import androidx.core.graphics.PathParser

/** Native vector adapted from Nikon's official brand asset; no bitmap scaling or network access.
 * Source: https://www.nikon-image.com/common2/img/mod-header/logo_01.svg (2026-09-24).
 * Coordinates and gradients retain the source's 400 × 400 viewport.
 */
internal object NikonBrandLogo {
    private data class Shape(val path: android.graphics.Path, val shader: Shader?, val color: Int)
    private val shapes = listOf(
        Shape(checkNotNull(PathParser.createPathFromPathData("M303.055,283.241c-88.936,15.696-177.988,36.567-266.773,62.811C24.138,349.643,12.042,353.323,0,357.088 v31.352c15.009-4.127,30.018-8.408,45.018-12.84C133.797,349.347,219.883,318.437,303.055,283.241z")), LinearGradient(-232.37078f, 441.54325f, 314.15783f, 279.96727f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.34f, 0.66f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M328.305,224.411c-85.362,18.158-170.783,40.988-255.911,68.666C48.045,300.992,23.91,309.243,0,317.822 v26.398c27.002-7.795,53.987-16.072,80.944-24.836C166.069,291.706,248.589,259.927,328.305,224.411z")), LinearGradient(-185.44591f, 391.44673f, 339.28345f, 220.85090f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.355f, 0.645f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M352.505,168.243c-82.116,20.282-164.225,44.924-245.993,74.075C70.501,255.156,34.991,268.711,0,282.959 V304.5c38.423-11.694,76.809-24.36,115.12-38.015C196.888,237.331,276.073,204.477,352.505,168.243z")), LinearGradient(-141.32136f, 344.28204f, 363.32607f, 164.38788f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.37f, 0.63f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M375.6,114.373c-79.037,22.419-158.02,48.891-236.619,79.533C91.72,212.332,45.383,231.964,0,252.73v15.81 c49.29-15.909,98.515-33.415,147.6-52.548C226.19,185.347,302.257,151.368,375.6,114.373z")), LinearGradient(-99.51753f, 299.61600f, 386.22380f, 110.23010f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.385f, 0.615f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M397.862,62.404c-76.136,24.571-152.172,52.898-227.795,85.076C111.877,172.242,55.165,198.754,0,226.894 v9.334c59.685-20.549,119.273-43.419,178.613-68.665C254.23,135.384,327.37,100.228,397.862,62.404z")), LinearGradient(-59.42329f, 256.98444f, 408.50267f, 57.88248f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.4f, 0.6f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M400,23.069V19.19c-66.824,24.93-133.52,52.75-199.866,83.501C131.206,134.646,64.45,168.936,0,205.332 v2.218c69.723-25.748,139.323-54.632,208.545-86.716C274.383,90.312,338.232,57.655,400,23.069z")), LinearGradient(-21.06959f, 216.24814f, 430.15495f, 7.08201f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.415f, 0.585f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M25.517,172.214c70.84-28.989,141.541-61.179,211.831-96.617C285.268,51.431,332.101,26.198,377.795,0 h-23.881c-41.695,18.654-83.307,38.428-124.771,59.334C158.864,94.773,90.939,132.491,25.517,172.214z")), LinearGradient(15.55904f, 177.22917f, 451.19611f, -42.44207f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.43f, 0.57f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M60.879,134.162c68.341-31.261,136.559-65.454,204.378-102.608C284.179,21.185,302.921,10.665,321.49,0 h-32.454c-10.568,5.635-21.131,11.346-31.682,17.13C189.537,54.286,124.001,93.382,60.879,134.162z")), LinearGradient(51.25939f, 139.43244f, 471.90464f, -91.05333f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.445f, 0.555f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M272.151,0h-27.883C193.448,31.192,143.995,63.353,95.987,96.363C154.851,66.382,213.641,34.264,272.151,0z ")), LinearGradient(86.50333f, 102.15401f, 491.80864f, -138.98386f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.46f, 0.54f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M231.041,0h-17.579c-27.88,19.273-55.307,38.793-82.272,58.539C164.504,39.694,197.803,20.182,231.041,0z")), LinearGradient(122.11085f, 64.65897f, 512.43207f, -187.36305f, intArrayOf(Color.rgb(255, 228, 25), Color.WHITE, Color.WHITE, Color.rgb(255, 228, 25)), floatArrayOf(0.0f, 0.475f, 0.525f, 1.0f), Shader.TileMode.CLAMP), Color.rgb(21, 3, 1)),
        Shape(checkNotNull(PathParser.createPathFromPathData("M144.981,385.399l21.598-97.315l26.617,0.003l-11.603,51.759l21.499-25.953h29.761l-26.706,32.446 l11.01,39.061H190.6l-10.976-37.009l-8.693,37.009H144.981z M48.872,336.484l18.754,48.914h25.509l21.983-97.315l-26.273,0.003 l-11.121,49.501L59.32,288.055H32.683l-21.718,97.344h26.788C40.794,369.802,44.864,353.329,48.872,336.484z M132.235,385.399 l15.935-71.467h-26.144l-15.932,71.467H132.235z M123.366,298.275c0,2.243,0.527,10.172,14.835,10.172 c11.885,0,16.468-7.616,16.468-13.302c0-3.828-3.129-10.471-14.841-10.471C129.04,284.675,123.366,291.888,123.366,298.275z M374.819,312.968c-11.178-3.329-25.03,2.194-31.867,11.657c0.664-2.933,1.374-6.344,2.177-10.272H318.6l-15.525,71.046h26.401 l8.807-40.296c1.619-7.416,7.582-10.585,12.863-9.22c2.277,0.616,5.409,2.337,4.372,8.516l-8.961,40.999h26.09l11.959-54.717 C387.14,318.622,377.236,313.692,374.819,312.968z M286.046,378.954c11.461-9.372,17.129-25.218,16.947-40.127 c-0.194-14.33-12.33-27.923-33.443-27.923c-40.247,0-46.101,31.371-47.264,37.097c-2.947,14.484,0.331,33.284,19.236,38.266 C253.996,389.56,273.502,389.203,286.046,378.954z M256.521,337.533c1.892-5.213,7.043-6.367,9.371-6.39 c5.769-0.049,7.348,3.372,6.846,6.595c-1.388,8.935-4.483,20.273-5.626,23.887c-0.014,0.048-0.023,0.094-0.037,0.134 c-1.257,3.947-4.976,6.245-9.354,6.245c-4.432,0-7.111-2.787-6.729-6.339C251.642,355.669,255.438,340.512,256.521,337.533z")), null, Color.rgb(21, 3, 1)),
    )

    fun draw(canvas: Canvas, left: Float, top: Float, side: Float, alpha: Int) {
        if (side <= 0f || alpha == 0) return
        val save = canvas.save()
        canvas.translate(left, top)
        canvas.scale(side / 400f, side / 400f)
        canvas.clipRect(0f, 0f, 400f, 400f)
        val layer = if (alpha < 255) canvas.saveLayerAlpha(0f, 0f, 400f, 400f, alpha) else null
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(255, 225, 0) }
        canvas.drawRect(0f, 0f, 400f, 400f, paint)
        shapes.forEach { shape ->
            paint.shader = shape.shader
            paint.color = shape.color
            canvas.drawPath(shape.path, paint)
        }
        if (layer != null) canvas.restoreToCount(layer)
        canvas.restoreToCount(save)
    }
}

internal val PhotoFrameMetadata.useNikonLogo: Boolean
    get() = brandStyle == PhotoFrameBrandStyle.LOGO && normalizeCameraMake(make).equals("Nikon", true)

private val nikonIdentityPrefix = Regex("^NIKON(?:\\s+CORPORATION)?(?=\\s|$)", RegexOption.IGNORE_CASE)

/** Replace only the brand prefix of an identity row, never arbitrary metadata/watermark text. */
internal fun Canvas.drawFrameIdentity(text: String, x: Float, baseline: Float, paint: Paint, logo: Boolean) {
    val prefix = if (logo) nikonIdentityPrefix.find(text)?.value else null
    if (prefix == null) { drawText(text, x, baseline, paint); return }
    val bounds = Rect().also { paint.getTextBounds(prefix, 0, prefix.length, it) }
    val side = bounds.height().toFloat().coerceAtLeast(1f)
    val remaining = text.substring(prefix.length)
    val width = side + paint.measureText(remaining)
    val left = when (paint.textAlign) {
        Paint.Align.CENTER -> x - width / 2f
        Paint.Align.RIGHT -> x - width
        else -> x
    }
    NikonBrandLogo.draw(this, left, baseline + bounds.top, side, paint.alpha)
    if (remaining.isNotEmpty()) {
        drawText(remaining, left + side, baseline, Paint(paint).apply { textAlign = Paint.Align.LEFT })
    }
}

internal fun Paint.measureFrameIdentity(text: String, logo: Boolean): Float {
    val prefix = if (logo) nikonIdentityPrefix.find(text)?.value else null
    if (prefix == null) return measureText(text)
    val bounds = Rect().also { getTextBounds(prefix, 0, prefix.length, it) }
    return bounds.height().toFloat().coerceAtLeast(1f) + measureText(text.substring(prefix.length))
}
