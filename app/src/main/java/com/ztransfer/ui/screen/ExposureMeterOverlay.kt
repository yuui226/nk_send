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
        modifier.widthIn(max = 168.dp)
            .background(Color.Black.copy(alpha = 0.42f), RoundedCornerShape(8.dp))
            .semantics { contentDescription = "$label: $value" }
            .padding(horizontal = 10.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("\u22123", color = Color.White.copy(alpha = 0.7f), fontSize = 9.sp)
            Text(value, color = Color.White, fontSize = 10.sp)
            Text("+3", color = Color.White.copy(alpha = 0.7f), fontSize = 9.sp)
        }
        Canvas(Modifier.fillMaxWidth().height(15.dp)) {
            val inset = 3.dp.toPx()
            val span = (size.width - 2 * inset).coerceAtLeast(0f)
            for (tick in 0..18) {
                val x = inset + span * tick / 18f
                val height = if (tick % 3 == 0) 6.dp.toPx() else 3.dp.toPx()
                drawLine(Color.White.copy(alpha = if (ev == null) 0.3f else 0.7f),
                    Offset(x, 0f), Offset(x, height), 1.dp.toPx(), StrokeCap.Round)
            }
            if (ev != null) {
                val x = inset + span * (position.value + 3f) / 6f
                val color = if (kotlin.math.abs(ev) < 1f / 12f) Color(0xFF6EE7B7) else Color.White
                drawLine(color, Offset(x, 8.dp.toPx()), Offset(x, size.height), 2.dp.toPx(), StrokeCap.Round)
                // An end marker plus the unclamped numeric value makes over-range readings explicit.
                if (kotlin.math.abs(ev) > 3f) {
                    val direction = if (ev > 0f) -1 else 1
                    drawLine(color, Offset(x, 10.dp.toPx()), Offset(x + direction * 4.dp.toPx(), size.height), 1.dp.toPx())
                }
            }
        }
    }
}
