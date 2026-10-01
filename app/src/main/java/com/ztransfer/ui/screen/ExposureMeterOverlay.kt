package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import java.util.Locale

// Shared geometry for the vertically stacked camera meters.
internal val MonitorMeterWidth = 22.dp
internal val MonitorMeterEndInset = 8.dp
internal val MonitorInfoTopInset = 10.dp
internal val MonitorExposureMeterHeight = 120.dp
internal val MonitorMeterStackGap = 6.dp

/** Display-only camera reading, independent of preview pixels, gamma and LUT. */
@Composable
internal fun ExposureMeterOverlay(ev: Float?, modifier: Modifier = Modifier) {
    val target = ev?.coerceIn(-3f, 3f) ?: 0f
    // A first/recovered sample starts at its real value, never sweeps out of a fake zero.
    val position = remember(ev != null) { Animatable(target) }
    val pointer = remember { Path() }
    LaunchedEffect(target, position) { position.animateTo(target, tween(160)) }
    val label = stringResource(R.string.remote_tool_meter)
    val value = ev?.let { String.format(Locale.ROOT, "%+.1f EV", if (it == 0f) 0f else it) } ?: "\u2014"
    Column(
        modifier.width(MonitorMeterWidth).height(MonitorExposureMeterHeight)
            .background(MonitorOverlayBackground, RoundedCornerShape(7.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(7.dp))
            .semantics { contentDescription = "$label: $value" }
            .padding(vertical = 3.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Canvas(Modifier.width(18.dp).weight(1f)) {
            val inset = 4.dp.toPx()
            val span = (size.height - 2 * inset).coerceAtLeast(0f)
            val right = size.width - 2.dp.toPx()
            for (tick in 0..18) {
                val y = inset + span * tick / 18f
                val length = if (tick == 9) 7.dp.toPx() else if (tick % 3 == 0) 6.dp.toPx() else 3.dp.toPx()
                drawLine(Color.White.copy(alpha = if (ev == null) 0.3f else 0.7f),
                    Offset(right - length, y), Offset(right, y),
                    (if (tick == 9) 2.dp else 1.dp).toPx(), StrokeCap.Round)
            }
            if (ev != null) {
                // Positive EV is above zero; negative EV is below it.
                val y = inset + span * (3f - position.value) / 6f
                val color = if (kotlin.math.abs(ev) < 1f / 12f) Color(0xFF6EE7B7) else Color.White
                pointer.reset()
                // A filled pointer clearly identifies the selected tick. Beyond the scale,
                // turn it toward the overflowing end instead of implying an exact endpoint.
                if (kotlin.math.abs(ev) > 3f) {
                    val direction = if (ev > 0f) -1f else 1f
                    pointer.moveTo(4.5.dp.toPx(), y + direction * 3.dp.toPx())
                    pointer.lineTo(2.dp.toPx(), y - direction * 2.dp.toPx())
                    pointer.lineTo(7.dp.toPx(), y - direction * 2.dp.toPx())
                } else {
                    pointer.moveTo(7.dp.toPx(), y)
                    pointer.lineTo(2.dp.toPx(), y - 3.dp.toPx())
                    pointer.lineTo(2.dp.toPx(), y + 3.dp.toPx())
                }
                pointer.close()
                drawPath(pointer, color)
            }
        }
    }
}
