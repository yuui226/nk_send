package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontFamily
import com.ztransfer.R
import java.util.Locale

/** Display-only camera reading, independent of preview pixels, gamma and LUT. */
@Composable
internal fun ExposureMeterOverlay(ev: Float?, modifier: Modifier = Modifier) {
    val target = ev?.coerceIn(-3f, 3f) ?: 0f
    // A first/recovered sample starts at its real value, never sweeps out of a fake zero.
    val position = remember(ev != null) { Animatable(target) }
    LaunchedEffect(target, position) { position.animateTo(target, tween(160)) }
    val label = stringResource(R.string.remote_tool_meter)
    val value = ev?.let { String.format(Locale.ROOT, "%+.1f EV", if (it == 0f) 0f else it) } ?: "\u2014"
    Column(
        modifier.width(32.dp).height(120.dp)
            .background(Color.Black.copy(alpha = 0.14f), RoundedCornerShape(4.dp))
            .semantics { contentDescription = "$label: $value" }
            .padding(vertical = 3.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("+3", color = Color.White.copy(alpha = 0.7f), fontSize = 8.sp, maxLines = 1)
        Canvas(Modifier.width(24.dp).weight(1f)) {
            val inset = 3.dp.toPx()
            val span = (size.height - 2 * inset).coerceAtLeast(0f)
            val right = size.width - 2.dp.toPx()
            for (tick in 0..18) {
                val y = inset + span * tick / 18f
                val length = if (tick == 9) 10.dp.toPx() else if (tick % 3 == 0) 6.dp.toPx() else 3.dp.toPx()
                drawLine(Color.White.copy(alpha = if (ev == null) 0.3f else 0.7f),
                    Offset(right - length, y), Offset(right, y), 1.dp.toPx(), StrokeCap.Round)
            }
            if (ev != null) {
                // Positive EV is above zero; negative EV is below it.
                val y = inset + span * (3f - position.value) / 6f
                val color = if (kotlin.math.abs(ev) < 1f / 12f) Color(0xFF6EE7B7) else Color.White
                drawLine(color, Offset(2.dp.toPx(), y), Offset(8.dp.toPx(), y), 2.dp.toPx(), StrokeCap.Round)
                // Keep the unclamped reading; a chevron distinguishes an out-of-range endpoint.
                if (kotlin.math.abs(ev) > 3f) {
                    val insideY = y + (if (ev > 0f) 4.dp.toPx() else -4.dp.toPx())
                    drawLine(color, Offset(2.dp.toPx(), insideY), Offset(5.dp.toPx(), y), 1.dp.toPx())
                    drawLine(color, Offset(5.dp.toPx(), y), Offset(8.dp.toPx(), insideY), 1.dp.toPx())
                }
            }
        }
        Text("\u22123", color = Color.White.copy(alpha = 0.7f), fontSize = 8.sp, maxLines = 1)
        Text(value.removeSuffix(" EV"), color = Color.White, fontSize = 9.sp,
            fontFamily = FontFamily.Monospace, maxLines = 1)
    }
}
