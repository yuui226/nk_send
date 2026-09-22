package com.ztransfer.ui.screen

import com.ztransfer.util.HistogramMode

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal val ScopeRgbColors = listOf(Color(0xFFFF6268), Color(0xFF63E89A), Color(0xFF659BFF))

/** Keep the preview's original dimensions and luma drawing; only add the RGB selection. */
@Composable
internal fun SelectablePreviewHistogram(histogram: LuminanceHistogram, mode: HistogramMode, modifier: Modifier = Modifier) {
    Crossfade(mode, modifier = modifier.size(118.dp, 62.dp), animationSpec = tween(180), label = "previewHistogramMode") { selected ->
        if (selected == HistogramMode.RGB) MonitorHistogramOverlay(histogram, selected, Modifier.fillMaxSize())
        else HistogramOverlay(histogram, Modifier.fillMaxSize())
    }
}

/** Same geometry with one or two scopes. Each slot survives removal until its fade completes. */
@Composable
internal fun MonitorAnalysisOverlays(
    histogram: LuminanceHistogram?, waveform: ImageBitmap?, falseColor: Boolean,
    modifier: Modifier = Modifier,
    histogramMode: HistogramMode = HistogramMode.LUMA,
    waveformMode: WaveformMode = WaveformMode.LUMA,
    startInset: Dp = 8.dp,
) {
    var lastHistogram by remember { mutableStateOf(histogram) }
    var lastHistogramMode by remember { mutableStateOf(histogramMode) }
    var lastWaveform by remember { mutableStateOf(waveform) }
    var lastWaveformMode by remember { mutableStateOf(waveformMode) }
    SideEffect {
        if (histogram != null) { lastHistogram = histogram; lastHistogramMode = histogramMode }
        if (waveform != null) { lastWaveform = waveform; lastWaveformMode = waveformMode }
    }
    BoxWithConstraints(modifier) {
        val gap = 6.dp
        val usableWidth = (maxWidth - startInset - 8.dp).coerceAtLeast(2.dp)
        // Reserve two equal slots even with only one enabled, avoiding distracting resizes.
        val chartWidth = ((usableWidth - gap) / 2).coerceIn(1.dp, 138.dp)
        val chartHeight = (maxHeight * 0.29f).coerceIn(28.dp, 76.dp)
        val waveformX by animateDpAsState(
            if (histogram != null) chartWidth + gap else 0.dp,
            tween(300, easing = FastOutSlowInEasing), label = "waveformSlot",
        )
        Box(Modifier.align(Alignment.BottomStart).padding(start = startInset, bottom = 26.dp)
            .width(usableWidth).height(chartHeight)) {
            AnimatedVisibility(histogram != null,
                enter = fadeIn(tween(180)) + scaleIn(tween(220), initialScale = 0.96f),
                exit = fadeOut(tween(130)) + scaleOut(tween(160), targetScale = 0.96f)) {
                (histogram ?: lastHistogram)?.let {
                    MonitorHistogramOverlay(it, if (histogram != null) histogramMode else lastHistogramMode,
                        Modifier.size(chartWidth, chartHeight).testTag("monitor-histogram"))
                }
            }
            AnimatedVisibility(waveform != null, modifier = Modifier.offset(x = waveformX),
                enter = fadeIn(tween(180)) + scaleIn(tween(220), initialScale = 0.96f),
                exit = fadeOut(tween(130)) + scaleOut(tween(160), targetScale = 0.96f)) {
                (waveform ?: lastWaveform)?.let {
                    WaveformOverlay(it, Modifier.size(chartWidth, chartHeight).testTag("monitor-waveform"),
                        mode = if (waveform != null) waveformMode else lastWaveformMode)
                }
            }
        }
        if (falseColor) FalseColorLegend(Modifier.align(Alignment.TopCenter).padding(top = 22.dp))
    }
}

@Composable
private fun ScopeCard(label: String, range: String, modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(modifier.background(Color.Black.copy(alpha = 0.66f), RoundedCornerShape(7.dp))
        .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(7.dp))) {
        val compact = maxHeight < 42.dp
        Column(Modifier.fillMaxSize().padding(horizontal = 5.dp, vertical = 3.dp)) {
            if (!compact) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(label, color = Color.White.copy(alpha = 0.85f), fontFamily = FontFamily.Monospace, fontSize = 8.sp, lineHeight = 10.sp)
                Text(range, color = Color.White.copy(alpha = 0.4f), fontFamily = FontFamily.Monospace, fontSize = 7.sp, lineHeight = 10.sp)
            }
            content()
        }
    }
}

@Composable
internal fun MonitorHistogramOverlay(histogram: LuminanceHistogram, mode: HistogramMode, modifier: Modifier) {
    ScopeCard(if (mode == HistogramMode.RGB) "RGB" else "Y′", "0–255", modifier) {
        Crossfade(mode, animationSpec = tween(180), label = "histogramChannels", modifier = Modifier.fillMaxWidth().weight(1f)) { selected ->
            Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
                val height = (size.height - 2.dp.toPx()).coerceAtLeast(1f)
                for (fraction in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
                    drawLine(Color.White.copy(alpha = 0.07f), Offset(size.width * fraction, 0f), Offset(size.width * fraction, height), 0.5.dp.toPx())
                }
                val channels = if (selected == HistogramMode.RGB) histogram.rgb ?: listOf(histogram.bins) else listOf(histogram.bins)
                channels.forEachIndexed { channel, bins ->
                    val color = if (selected == HistogramMode.RGB && channels.size == 3) ScopeRgbColors[channel] else Color(0xFFE4EBE7)
                    val path = Path().apply {
                        moveTo(0f, height)
                        bins.forEachIndexed { i, value -> lineTo(size.width * i / 255f, height * (1f - value.coerceIn(0f, 1f))) }
                        lineTo(size.width, height); close()
                    }
                    drawPath(path, color.copy(alpha = 0.30f), blendMode = BlendMode.Plus)
                    drawPath(path, color.copy(alpha = 0.85f), style = Stroke(0.8.dp.toPx()), blendMode = BlendMode.Plus)
                }
                drawLine(Color.White.copy(alpha = 0.22f), Offset(0f, height), Offset(size.width, height), 0.5.dp.toPx())
            }
        }
    }
}

@Composable
internal fun WaveformOverlay(image: ImageBitmap, modifier: Modifier = Modifier, compact: Boolean = false, mode: WaveformMode = WaveformMode.LUMA) {
    ScopeCard(if (mode == WaveformMode.RGB) "RGB" else "Y′", "0–100%", modifier) {
        BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
            val showLabels = !compact && maxHeight >= 34.dp
            val plotInset = if (showLabels) 15.dp else 0.dp
            if (showLabels) {
                for ((label, alignment) in listOf("100" to Alignment.TopStart, "50" to Alignment.CenterStart, "0" to Alignment.BottomStart)) {
                    Text(label, color = Color.White.copy(alpha = 0.42f), fontFamily = FontFamily.Monospace,
                        fontSize = 6.sp, lineHeight = 7.sp, modifier = Modifier.align(alignment))
                }
            }
            Box(Modifier.fillMaxSize().padding(start = plotInset)) {
                Canvas(Modifier.matchParentSize()) {
                    for (fraction in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) drawLine(
                        Color.White.copy(alpha = if (fraction == 0.5f) 0.18f else 0.10f),
                        Offset(0f, fraction * (size.height - 1)), Offset(size.width, fraction * (size.height - 1)), 0.5.dp.toPx())
                }
                Image(image, null, contentScale = ContentScale.FillBounds, filterQuality = FilterQuality.Medium,
                    modifier = Modifier.matchParentSize())
            }
        }
    }
}
