package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/** Decimal places remain stable when the label gains/loses a leading digit. */
internal data class QueueNumericLabel(
    val integer: String,
    val fraction: String,
    val separator: String,
    val suffix: String,
) {
    // 0 = units, 1 = tens; -1 = tenths, -2 = hundredths.
    fun digit(place: Int): String = if (place >= 0) {
        integer.getOrNull(integer.lastIndex - place)?.toString().orEmpty()
    } else {
        fraction.getOrNull(-place - 1)?.toString().orEmpty()
    }
}

/** Our labels use ungrouped numbers. Accept localized decimal separators in history too. */
internal fun queueNumericLabel(text: String): QueueNumericLabel? {
    val numberEnd = text.indexOfFirst { !it.isDigit() && it !in ".,\u066b" }
        .let { if (it < 0) text.length else it }
    val number = text.substring(0, numberEnd)
    if (number.isEmpty() || !number.first().isDigit() || !number.last().isDigit()) return null
    val decimalIndex = number.indexOfFirst { !it.isDigit() }
    if (decimalIndex >= 0 && number.substring(decimalIndex + 1).any { !it.isDigit() }) return null
    return QueueNumericLabel(
        integer = if (decimalIndex < 0) number else number.substring(0, decimalIndex),
        fraction = if (decimalIndex < 0) "" else number.substring(decimalIndex + 1),
        separator = if (decimalIndex < 0) "" else number[decimalIndex].toString(),
        suffix = text.substring(numberEnd),
    )
}

private data class QueuePillValueSnapshot(
    val text: String,
    val value: Long,
    val number: QueueNumericLabel?,
)

/** Shared digit motion for the queue entrance and persistent status cards. */
@Composable
internal fun AnimatedQueuePillCount(
    count: Int,
    color: Color,
    label: String,
    modifier: Modifier = Modifier,
    animate: Boolean = true,
) {
    AnimatedQueuePillValue(
        text = count.toString(), value = count.toLong(), color = color,
        label = label, modifier = modifier, animate = animate,
    )
}

/** Only changed places roll; changing units replaces the whole label with the same motion. */
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
    // Round-off can leave the displayed label unchanged across many speed samples.
    val target = remember(text) { QueuePillValueSnapshot(text, value, queueNumericLabel(text)) }
    AnimatedContent(
        modifier = modifier.clearAndSetSemantics { this.text = AnnotatedString(text) },
        targetState = target,
        contentKey = { it.number?.suffix ?: it.text },
        contentAlignment = Alignment.CenterEnd,
        transitionSpec = {
            val direction = if (targetState.value < initialState.value) 1 else -1
            queueValueEnter(animate, direction).togetherWith(queueValueExit(animate, direction))
                .using(SizeTransform(clip = false, sizeAnimationSpec = { _, _ -> snap() }))
        },
        label = label,
    ) { displayed ->
        if (displayed.number == null) {
            QueueValueText(displayed.text, color, style, fontWeight)
        } else {
            QueueValueDigits(displayed, color, style, fontWeight, animate, label)
        }
    }
}

@Composable
private fun QueueValueDigits(
    snapshot: QueuePillValueSnapshot,
    color: Color,
    style: TextStyle,
    fontWeight: FontWeight,
    animate: Boolean,
    label: String,
) {
    val number = requireNotNull(snapshot.number)
    val transition = updateTransition(snapshot, label = "${label}Digits")
    // Keep departing places until their exit finishes, including interrupted 99 -> 100 -> 9.
    // Their target width is zero immediately; the enclosing pill owns the width animation.
    var retainedIntegers by remember { mutableIntStateOf(number.integer.length) }
    var retainedFractions by remember { mutableIntStateOf(number.fraction.length) }
    val integers = maxOf(retainedIntegers, number.integer.length)
    val fractions = maxOf(retainedFractions, number.fraction.length)
    val settled = !transition.isRunning && transition.currentState == transition.targetState
    SideEffect {
        retainedIntegers = if (settled) number.integer.length else integers
        retainedFractions = if (settled) number.fraction.length else fractions
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        val places = remember(integers, fractions) {
            (integers - 1 downTo 0).toList() +
                if (fractions > 0) listOf(Int.MIN_VALUE) + (1..fractions).map { -it } else emptyList()
        }
        places.forEach { place ->
            key(place) {
                fun QueuePillValueSnapshot.character(): String = if (place == Int.MIN_VALUE) {
                    this.number?.separator.orEmpty()
                } else this.number?.digit(place).orEmpty()
                transition.AnimatedContent(
                    contentKey = { it.character() },
                    contentAlignment = Alignment.CenterEnd,
                    // Clip vertically while a removed leading digit can still depart just to
                    // the left of its zero-width target. The pill clips its own outer bounds.
                    modifier = Modifier.drawWithContent {
                        clipRect(left = -size.height, right = size.width + size.height) {
                            this@drawWithContent.drawContent()
                        }
                    },
                    transitionSpec = {
                        val direction = if (targetState.value < initialState.value) 1 else -1
                        queueValueEnter(animate, direction).togetherWith(queueValueExit(animate, direction))
                            .using(SizeTransform(clip = false, sizeAnimationSpec = { _, _ -> snap() }))
                    },
                ) { displayed ->
                    QueueValueText(displayed.character(), color, style, fontWeight)
                }
            }
        }
        QueueValueText(number.suffix, color, style, fontWeight)
    }
}

private fun queueValueEnter(animate: Boolean, direction: Int): EnterTransition = if (animate) {
    slideInVertically(tween(180, easing = FastOutSlowInEasing)) { it / 2 * direction } + fadeIn(tween(160))
} else EnterTransition.None

private fun queueValueExit(animate: Boolean, direction: Int): ExitTransition = if (animate) {
    slideOutVertically(tween(180, easing = FastOutSlowInEasing)) { -it / 2 * direction } + fadeOut(tween(120))
} else ExitTransition.None

@Composable
private fun QueueValueText(text: String, color: Color, style: TextStyle, fontWeight: FontWeight) {
    Text(
        text = text,
        style = style.copy(fontFeatureSettings = "tnum"),
        color = color,
        fontWeight = fontWeight,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Ellipsis,
    )
}
