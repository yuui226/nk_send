package com.ztransfer.ui.screen

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
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
import androidx.compose.ui.layout.ContentScale
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

internal data class MonitorAnalysis(val falseColor: ImageBitmap?, val waveform: ImageBitmap?)

/** Decoder-owned cache: no Compose state writes for analysis bookkeeping. */
internal class MonitorAnalysisThrottle {
    private var cached: MonitorAnalysis? = null
    private var key: List<Int> = emptyList()
    private var lastAt = 0L
    fun analyze(bitmap: Bitmap, falseColor: Boolean, waveform: Boolean, now: Long): MonitorAnalysis? {
        if (!falseColor && !waveform) { cached = null; key = emptyList(); return null }
        val nextKey = listOf(bitmap.width, bitmap.height, if (falseColor) 1 else 0, if (waveform) 1 else 0)
        if (cached == null || key != nextKey || now - lastAt >= 125L) {
            cached = analyzeMonitorFrame(bitmap, falseColor, waveform)
            key = nextKey
            lastAt = now
        }
        return cached
    }
}

/** Bounded to 256×192 samples; both tools share sampling and never decode JPEG again. */
internal fun analyzeMonitorFrame(bitmap: Bitmap, falseColor: Boolean, waveform: Boolean): MonitorAnalysis {
    if (!falseColor && !waveform) return MonitorAnalysis(null, null)
    val w = minOf(bitmap.width, 256)
    val h = minOf(bitmap.height, 192)
    val row = IntArray(bitmap.width)
    val colors = if (falseColor) IntArray(w * h) else null
    val bins = if (waveform) IntArray(128 * 64) else null
    for (y in 0 until h) {
        bitmap.getPixels(row, 0, bitmap.width, 0, y * bitmap.height / h, bitmap.width, 1)
        for (x in 0 until w) {
            val luma = monitorLuma(row[x * bitmap.width / w])
            colors?.set(y * w + x, falseColorForLuma(luma))
            if (bins != null) bins[(63 - luma * 63 / 255) * 128 + x * 128 / w]++
        }
    }
    val heat = bins?.let { counts ->
        val max = counts.maxOrNull()?.coerceAtLeast(1) ?: 1
        IntArray(counts.size) { i ->
            if (counts[i] == 0) 0 else {
                val alpha = (60 + 195 * ln(1.0 + counts[i]) / ln(1.0 + max)).roundToInt().coerceIn(0, 255)
                (alpha shl 24) or 0x00A3E8BA
            }
        }.let { Bitmap.createBitmap(it, 128, 64, Bitmap.Config.ARGB_8888).asImageBitmap() }
    }
    return MonitorAnalysis(colors?.let { Bitmap.createBitmap(it, w, h, Bitmap.Config.ARGB_8888).asImageBitmap() }, heat)
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
internal fun WaveformOverlay(image: ImageBitmap, modifier: Modifier = Modifier, compact: Boolean = false) {
    Column(modifier.size(154.dp, 78.dp).background(Color.Black.copy(alpha = 0.68f), RoundedCornerShape(8.dp)).padding(4.dp)) {
        if (!compact) Text("Y′  0–100%", color = Color.White.copy(alpha = 0.7f), fontSize = 9.sp, lineHeight = 10.sp)
        Box(Modifier.fillMaxWidth().weight(1f)) {
            Canvas(Modifier.matchParentSize()) {
                for (fraction in listOf(0f, 0.5f, 1f)) drawLine(Color.White.copy(alpha = 0.14f),
                    Offset(0f, fraction * size.height), Offset(size.width, fraction * size.height), 1.dp.toPx())
            }
            Image(image, null, contentScale = ContentScale.FillBounds, modifier = Modifier.matchParentSize())
        }
    }
}

/** New analyses share one compact bottom row, leaving the left meter and bottom FPS clear. */
@Composable
internal fun MonitorAnalysisOverlays(
    histogram: LuminanceHistogram?, waveform: ImageBitmap?, falseColor: Boolean, modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier) {
        val chartHeight = (maxHeight * 0.27f).coerceIn(24.dp, 62.dp)
        val usableWidth = (maxWidth - 60.dp).coerceAtLeast(1.dp)
        Row(Modifier.align(Alignment.BottomStart).padding(start = 48.dp, bottom = 26.dp)
            .widthIn(max = usableWidth), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            val count = (if (histogram != null) 1 else 0) + (if (waveform != null) 1 else 0)
            val chartWidth = ((usableWidth - 4.dp * (count - 1).coerceAtLeast(0)) / count.coerceAtLeast(1)).coerceAtMost(134.dp)
            if (histogram != null) HistogramOverlay(histogram, Modifier.size(chartWidth, chartHeight))
            if (waveform != null) WaveformOverlay(waveform, Modifier.size(chartWidth, chartHeight), compact = chartHeight < 42.dp)
        }
        if (falseColor) FalseColorLegend(Modifier.align(Alignment.TopCenter).padding(top = 22.dp))
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
internal fun WaveformMark(modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Canvas(modifier) {
        val path = Path()
        listOf(0.7f, 0.3f, 0.6f, 0.15f, 0.8f, 0.4f, 0.65f).forEachIndexed { i, value ->
            if (i == 0) path.moveTo(0f, size.height * value) else path.lineTo(size.width * i / 6, size.height * value)
        }
        drawPath(path, color, style = Stroke(1.7.dp.toPx(), cap = StrokeCap.Round))
    }
}
