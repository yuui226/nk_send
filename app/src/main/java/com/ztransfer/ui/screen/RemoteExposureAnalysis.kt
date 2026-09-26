package com.ztransfer.ui.screen

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.ln
import kotlin.math.roundToInt

/** Display-referred luma of the received JPEG, not calibrated scene exposure or RAW values. */
internal fun monitorLuma(argb: Int): Int =
    (77 * (argb ushr 16 and 255) + 150 * (argb ushr 8 and 255) + 29 * (argb and 255)) ushr 8

internal fun falseColorForLuma(luma: Int): Int = when {
    luma < 13 -> 0xFF6B39B8.toInt() // <5%
    luma < 38 -> 0xFF2874D7.toInt() // 5–15%
    luma < 102 -> 0xFF50555B.toInt() // 15–40%
    luma < 115 -> 0xFF5ABE87.toInt() // 40–45%
    luma < 140 -> 0xFFE792AE.toInt() // 45–55%
    luma < 204 -> 0xFFB9BDC2.toInt() // 55–80%
    luma < 242 -> 0xFFF0D55D.toInt() // 80–95%
    else -> 0xFFF14D4D.toInt() // >=95%
}

internal data class MonitorAnalysis(
    val falseColor: ImageBitmap?, val waveform: ImageBitmap?,
    val waveformMode: WaveformMode = WaveformMode.LUMA,
)

/** Decoder-owned cache: no Compose state writes for analysis bookkeeping. */
internal class MonitorAnalysisThrottle {
    private var cached: MonitorAnalysis? = null
    private var width = 0
    private var height = 0
    private var waveformRgb = false
    private var lastAt = 0L
    fun analyze(bitmap: Bitmap, falseColor: Boolean, waveform: Boolean, now: Long, rgb: Boolean = false): MonitorAnalysis? {
        if (!falseColor && !waveform) { cached = null; return null }
        val refreshWaveform = waveform && (cached?.waveform == null ||
            width != bitmap.width || height != bitmap.height || waveformRgb != rgb || now - lastAt >= 125L)
        // Reuse the entire scope-only result between updates, including after false color ends.
        if (!falseColor && !refreshWaveform && cached?.falseColor == null) return cached
        // False color replaces the picture: reusing it for 125ms caps apparent motion at 8fps.
        // Recompute it for each displayed frame; only the small scope retains its own cadence.
        val fresh = if (falseColor || refreshWaveform) {
            analyzeMonitorFrame(bitmap, falseColor, refreshWaveform, rgb)
        } else null
        cached = MonitorAnalysis(
            falseColor = fresh?.falseColor,
            waveform = if (!waveform) null else if (refreshWaveform) fresh?.waveform else cached?.waveform,
            waveformMode = if (rgb) WaveformMode.RGB else WaveformMode.LUMA,
        )
        if (refreshWaveform) lastAt = now
        width = bitmap.width
        height = bitmap.height
        waveformRgb = rgb
        return cached
    }
}

internal const val WaveformWidth = 256
internal const val WaveformHeight = 128

/** Bounded to 256×192 samples; both tools share sampling and never decode JPEG again. */
internal fun analyzeMonitorFrame(bitmap: Bitmap, falseColor: Boolean, waveform: Boolean, rgb: Boolean = false): MonitorAnalysis {
    if (!falseColor && !waveform) return MonitorAnalysis(null, null)
    val w = minOf(bitmap.width, 256)
    val h = minOf(bitmap.height, 192)
    // Downsample in native code, then cross JNI once rather than copying a full HD row
    // for every sampled scanline. Never recycle the source, which is owned by the renderer.
    val sampled = Bitmap.createScaledBitmap(bitmap, w, h, false)
    val pixels = IntArray(w * h)
    try {
        sampled.getPixels(pixels, 0, w, 0, 0, w, h)
    } finally {
        if (sampled !== bitmap) sampled.recycle()
    }
    val colors = if (falseColor) IntArray(w * h) else null
    val bins = if (waveform) List(if (rgb) 3 else 1) { IntArray(WaveformWidth * WaveformHeight) } else null
    for (y in 0 until h) {
        for (x in 0 until w) {
            val pixel = pixels[y * w + x]
            val luma = monitorLuma(pixel)
            colors?.set(y * w + x, falseColorForLuma(luma))
            if (bins != null) {
                for (channel in bins.indices) {
                    val value = if (rgb) (pixel ushr (16 - channel * 8)) and 255 else luma
                    bins[channel][(WaveformHeight - 1 - value * (WaveformHeight - 1) / 255) * WaveformWidth + x * WaveformWidth / w]++
                }
            }
        }
    }
    val heat = bins?.let { counts ->
        // Density controls trace intensity, not its height. Use one fixed scale for all RGB
        // channels to avoid pumping brightness or hiding relative channel density each frame.
        val denominator = ln(1.0 + h)
        val intensities = IntArray(h + 1) { (255 * ln(1.0 + it) / denominator).roundToInt().coerceIn(0, 255) }
        IntArray(WaveformWidth * WaveformHeight) { i ->
            if (!rgb) {
                val alpha = intensities[counts[0][i]]
                if (alpha == 0) 0 else (alpha shl 24) or 0x00DCEBE3
            } else {
                val r = intensities[counts[0][i]]; val g = intensities[counts[1][i]]; val b = intensities[counts[2][i]]
                val alpha = maxOf(r, g, b)
                if (alpha == 0) 0 else (alpha shl 24) or ((r * 255 / alpha) shl 16) or
                    ((g * 255 / alpha) shl 8) or (b * 255 / alpha)
            }
        }.let { Bitmap.createBitmap(it, WaveformWidth, WaveformHeight, Bitmap.Config.ARGB_8888).asImageBitmap() }
    }
    return MonitorAnalysis(colors?.let { Bitmap.createBitmap(it, w, h, Bitmap.Config.ARGB_8888).asImageBitmap() },
        heat, if (rgb) WaveformMode.RGB else WaveformMode.LUMA)
}

@Composable
internal fun FalseColorOverlay(image: ImageBitmap, imageAspectRatio: Float, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val rect = fitCenterRect(size.width, size.height, imageAspectRatio)
        drawImage(image, dstOffset = IntOffset(rect.left.roundToInt(), rect.top.roundToInt()),
            dstSize = IntSize(rect.width.roundToInt().coerceAtLeast(1), rect.height.roundToInt().coerceAtLeast(1)))
    }
}

@Composable
internal fun FalseColorLegend(modifier: Modifier = Modifier) {
    Column(modifier.background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(7.dp)).padding(horizontal = 4.dp, vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Y′%", color = Color.White.copy(alpha = 0.8f), fontSize = 7.sp, lineHeight = 9.sp, modifier = Modifier.width(20.dp))
            for (label in listOf("0", "5", "15", "40", "45", "55", "80", "95+")) {
                Text(label, color = Color.White.copy(alpha = 0.8f), fontSize = 7.sp, lineHeight = 9.sp, modifier = Modifier.width(24.5.dp))
            }
        }
        Canvas(Modifier.padding(start = 20.dp).width(196.dp).height(4.dp)) {
            val bounds = listOf(0, 13, 38, 102, 115, 140, 204, 242, 256)
            for (i in 0 until bounds.lastIndex) {
                drawRect(Color(falseColorForLuma(bounds[i])),
                    Offset(size.width * i / 8, 0f), Size(size.width / 8, size.height))
            }
        }
    }
}

@Composable
internal fun FalseColorMark(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        for (i in 0..2) drawRoundRect(Color(falseColorForLuma(listOf(25, 108, 250)[i])),
            topLeft = Offset(size.width * i / 3, size.height * (0.35f - i * 0.1f)),
            size = Size(size.width * 0.23f, size.height * (0.4f + i * 0.1f)),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()))
    }
}

@Composable
internal fun WaveformMark(modifier: Modifier = Modifier, rgb: Boolean = false) {
    val color = LocalContentColor.current
    Canvas(modifier) {
        val path = Path()
        listOf(0.7f, 0.3f, 0.6f, 0.15f, 0.8f, 0.4f, 0.65f).forEachIndexed { i, value ->
            if (i == 0) path.moveTo(0f, size.height * value) else path.lineTo(size.width * i / 6, size.height * value)
        }
        if (rgb) {
            for (i in 0..2) {
                val x = size.width * i / 3
                clipRect(x, 0f, x + size.width / 3, size.height) {
                    drawPath(path, ScopeRgbColors[i], style = Stroke(1.7.dp.toPx(), cap = StrokeCap.Round))
                }
            }
        } else drawPath(path, color, style = Stroke(1.7.dp.toPx(), cap = StrokeCap.Round))
    }
}
