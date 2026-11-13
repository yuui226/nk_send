package com.ztransfer.ui.screen

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion

/** Uses the monitor host's coordinates, including when that host is rotated. */
@Composable
internal fun RemoteSelfTimerPanel(
    anchorBounds: Rect?,
    selectedSeconds: Int,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
    landscape: Boolean = false,
    closeRequested: Boolean = false,
) {
    val colors = AppTheme.colors
    val labels = remoteSelfTimerOptions.associateWith { seconds ->
        if (seconds == 0) stringResource(R.string.setting_off)
        else stringResource(R.string.remote_self_timer_seconds, seconds)
    }
    val density = LocalDensity.current
    val measurer = rememberTextMeasurer()
    val style = MaterialTheme.typography.bodyMedium
    val width = remember(labels, density, measurer, style) {
        with(density) { labels.values.maxOf { measurer.measure(it, style).size.width }.toDp() } + 24.dp
    }
    RemoteChoicePopup(
        anchor = anchorBounds,
        landscape = landscape,
        width = width.coerceIn(80.dp, 240.dp),
        closeRequested = closeRequested,
        onDismiss = onDismiss,
        verticalContentPadding = 0.dp,
    ) { close, closing ->
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
            remoteSelfTimerOptions.forEach { seconds ->
                val selected = seconds == selectedSeconds
                Text(
                    text = labels.getValue(seconds),
                    color = if (selected) colors.accentBlue else colors.onBackground,
                    style = style,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    modifier = Modifier.fillMaxWidth()
                        .background(if (selected) colors.accentBlue.copy(alpha = .08f) else Color.Transparent)
                        .selectable(selected, enabled = !closing, role = Role.RadioButton) {
                            onSelect(seconds)
                            close()
                        }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

/** The parent toolbar supplies tint and accessibility text, as for its other marks. */
@Composable
internal fun RemoteSelfTimerMark(seconds: Int) {
    if (seconds > 0) {
        Text(
            stringResource(R.string.remote_self_timer_seconds, seconds),
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            softWrap = false,
        )
    } else {
        val color = LocalContentColor.current
        Canvas(Modifier.size(19.dp)) {
            val unit = size.width / 19f
            val stroke = 1.6f * unit
            fun point(x: Float, y: Float) = Offset(x * unit, y * unit)
            drawCircle(color, radius = 6.3f * unit, center = point(9.5f, 10.7f), style = Stroke(stroke))
            drawLine(color, point(7.4f, 1.5f), point(11.6f, 1.5f), stroke, StrokeCap.Round)
            drawLine(color, point(9.5f, 1.5f), point(9.5f, 3.3f), stroke, StrokeCap.Round)
            drawLine(color, point(14.6f, 5.6f), point(16.1f, 4.1f), stroke, StrokeCap.Round)
            drawLine(color, point(9.5f, 10.7f), point(9.5f, 6.9f), stroke, StrokeCap.Round)
        }
    }
}

/** Same per-digit motion as the speed pill, sized to the shutter in either orientation. */
@Composable
internal fun RemoteSelfTimerCountdown(
    secondsRemaining: Int,
    diameter: Dp,
    color: Color,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    // The two digits must fit the physical circle even at large accessibility font sizes.
    val style = MaterialTheme.typography.headlineMedium.copy(
        fontSize = with(density) { (diameter * .40f).toSp() },
        lineHeight = with(density) { (diameter * .48f).toSp() },
    )
    AnimatedQueuePillValue(
        text = secondsRemaining.toString(),
        value = secondsRemaining.toLong(),
        color = color,
        style = style,
        fontWeight = FontWeight.SemiBold,
        label = "remote-self-timer-countdown",
        modifier = modifier
            .animateContentSize(animationSpec = Motion.bouncy(), alignment = Alignment.Center)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}
