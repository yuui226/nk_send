package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

private data class QueuePillValueSnapshot(val text: String, val value: Long)

/** Shared count motion for the queue entrance and persistent status cards. */
@Composable
internal fun AnimatedQueuePillCount(
    count: Int,
    color: Color,
    label: String,
    modifier: Modifier = Modifier,
    animate: Boolean = true,
) {
    AnimatedQueuePillValue(
        text = count.toString(),
        value = count.toLong(),
        color = color,
        label = label,
        modifier = modifier,
        animate = animate,
    )
}

/** Numeric direction follows the raw value, while only a changed label starts a transition. */
@Composable
internal fun AnimatedQueuePillValue(
    text: String,
    value: Long,
    color: Color,
    label: String,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.labelLarge,
    fontWeight: FontWeight = FontWeight.Bold,
    animate: Boolean = true,
) {
    // Rounded speed labels can stay unchanged across samples. Keep their target identity stable.
    val target = remember(text) { QueuePillValueSnapshot(text, value) }
    AnimatedContent(
        modifier = modifier.clearAndSetSemantics {
            // Outgoing and incoming Text nodes coexist visually, but expose only the current value.
            this.text = AnnotatedString(text)
        },
        targetState = target,
        contentAlignment = Alignment.CenterEnd,
        transitionSpec = {
            val dir = if (targetState.value < initialState.value) 1 else -1
            val entering = if (animate) slideInVertically { it / 2 * dir } + fadeIn(tween(160))
                else androidx.compose.animation.EnterTransition.None
            val exiting = if (animate) slideOutVertically { -it / 2 * dir } + fadeOut(tween(120))
                else androidx.compose.animation.ExitTransition.None
            entering.togetherWith(exiting)
                .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
        },
        label = label,
    ) { displayed ->
        Text(
            text = displayed.text,
            style = style.copy(fontFeatureSettings = "tnum"),
            color = color,
            fontWeight = fontWeight,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
