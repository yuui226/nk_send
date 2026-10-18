package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.R
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.SkinPreset
import kotlinx.coroutines.delay

private const val TIP_LIGHTBULB_TEXTURE_SEED = 0x1457A101

/** 小技巧提示统一入口；调用方只决定尺寸，材质、主题对比度和图标比例保持一致。 */
@Composable
internal fun TipLightbulbButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    attention: Boolean = false,
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val iconColor = remember(skin, dark, colors.accentOrange) {
        tipLightbulbIconColor(
            skin = skin,
            dark = dark,
            defaultColor = colors.accentOrange,
        )
    }
    val attentionScale = if (attention) {
        val transition = rememberInfiniteTransition(label = "tipLightbulbAttention")
        val scale by transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.09f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "tipLightbulbScale",
        )
        scale
    } else {
        1f
    }
    val attentionDot = if (attention) {
        val transition = rememberInfiniteTransition(label = "tipLightbulbUnreadDot")
        val scale by transition.animateFloat(
            initialValue = 0.72f,
            targetValue = 1.12f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "tipLightbulbUnreadDotScale",
        )
        val alpha by transition.animateFloat(
            initialValue = 0.58f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "tipLightbulbUnreadDotAlpha",
        )
        scale to alpha
    } else {
        1f to 1f
    }
    // Keep popup anchors independent from press/attention animation and touch expansion.
    Box(modifier = modifier, contentAlignment = Alignment.Center, propagateMinConstraints = true) {
        GlassButton(
            onClick = onClick,
            shape = RoundedCornerShape(12.dp),
            contentPadding = PaddingValues(0.dp),
            textureSeed = TIP_LIGHTBULB_TEXTURE_SEED,
            materialContentColor = iconColor,
            modifier = Modifier.graphicsLayer {
                scaleX = attentionScale
                scaleY = attentionScale
            },
        ) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Lightbulb,
                    contentDescription = contentDescription,
                    tint = iconColor,
                    modifier = Modifier.fillMaxSize(0.45f),
                )
                if (attention) {
                    // 一次性未读引导：红点补足单靠缩放不易察觉的问题；点击后由持久化状态移除。
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            // Keep the unread marker inside the rounded button surface. Placing it
                            // on the edge lets the button's corner clip the marker into a crescent.
                            .padding(top = 5.dp, end = 5.dp)
                            .size(7.dp)
                            .background(Color(0xFFFF4D3D), CircleShape)
                            .graphicsLayer {
                                scaleX = attentionDot.first
                                scaleY = attentionDot.first
                                alpha = attentionDot.second
                            },
                    )
                }
            }
        }
    }
}

/** 实体按钮上的灯泡改用材质印记色，避免暖黄色落在木纹上失去轮廓。 */
internal fun tipLightbulbIconColor(
    skin: SkinPreset,
    dark: Boolean,
    defaultColor: Color,
): Color = materialButtonForegroundColor(skin, dark, defaultColor)

/** One consistently styled row inside a lightbulb help bubble. */
internal data class TipBubbleItem(
    val text: String,
    val label: String? = null,
    val labelColor: Color? = null,
    val emphasized: Boolean = false,
    val questionExplanation: String? = null,
    val questionSuffix: String? = null,
    val trailingText: String? = null,
    val leading: (@Composable () -> Unit)? = null,
)

@Composable
private fun TipBubbleItemText(
    item: TipBubbleItem,
    textColor: Color,
    fontWeight: FontWeight?,
    inlineLabel: Boolean = false,
) {
    val colors = AppTheme.colors
    val hasQuestion = !item.questionExplanation.isNullOrBlank()
    var explanationVisible by rememberSaveable(item.questionExplanation) {
        mutableStateOf(false)
    }
    val textWithQuestion = buildAnnotatedString {
        if (inlineLabel && !item.label.isNullOrBlank()) {
            withStyle(SpanStyle(color = colors.onBackground, fontWeight = FontWeight.SemiBold)) {
                append(item.label)
            }
            append("  ")
        }
        append(item.text)
        if (hasQuestion) {
            // Keep the help button attached to the preceding phrase. A regular space lets the
            // inline placeholder wrap onto a line by itself, which looks like a detached control.
            append('\u00A0')
            appendInlineContent("tip_question", "?")
            append(item.questionSuffix.orEmpty())
        }
    }
    val inlineQuestion = if (hasQuestion) {
        mapOf(
            "tip_question" to InlineTextContent(
                placeholder = Placeholder(
                    width = 1.45.em,
                    height = 1.45.em,
                    placeholderVerticalAlign = PlaceholderVerticalAlign.TextCenter,
                )
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(1.dp)
                        .clip(CircleShape)
                        .background(
                            colors.accentYellow.copy(
                                alpha = if (explanationVisible) 1f else 0.82f,
                            )
                        )
                        .clickable(
                            role = Role.Button,
                            onClick = { explanationVisible = !explanationVisible },
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "?",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = colors.onAccent,
                    )
                }
            }
        )
    } else {
        emptyMap()
    }

    Column {
        Text(
            text = textWithQuestion,
            inlineContent = inlineQuestion,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = fontWeight,
            color = textColor,
        )

        AnimatedVisibility(
            visible = hasQuestion && explanationVisible,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Text(
                text = item.questionExplanation.orEmpty(),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }

        item.trailingText?.takeIf { it.isNotBlank() }?.let { trailingText ->
            Text(
                text = trailingText,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = fontWeight,
                color = textColor,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

internal data class TipBubbleSection(val title: String, val items: List<TipBubbleItem>)

/** Shared anchored shell for settings and monitor guides. */
@Composable
internal fun TipGuideBubble(
    anchorBounds: Rect?,
    title: String,
    sections: List<TipBubbleSection>,
    onDismiss: () -> Unit,
    introduction: String? = null,
    parentTopInset: Dp = 0.dp,
    panelAlignment: Alignment = Alignment.TopEnd,
) {
    val density = LocalDensity.current
    val panelTop = anchorBounds?.let {
        with(density) { it.bottom.toDp() } - parentTopInset + 8.dp
    } ?: 64.dp
    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = 18.dp, end = 18.dp, top = panelTop, bottom = 18.dp)
            .navigationBarsPadding()
            .widthIn(min = 260.dp, max = 420.dp)
            .heightIn(max = 560.dp),
        panelAlignment = panelAlignment,
        shape = RoundedCornerShape(18.dp),
        dim = false,
    ) { close ->
        TipBubbleGuide(title, sections, close, introduction = introduction)
    }
}

/** Show one guide section at a time; keep the title and close action visible while reading. */
@Composable
internal fun TipBubbleGuide(
    title: String,
    sections: List<TipBubbleSection>,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    introduction: String? = null,
) {
    val colors = AppTheme.colors
    var expandedSection by rememberSaveable(title) { mutableStateOf(sections.firstOrNull()?.title) }
    Column(modifier.padding(horizontal = 18.dp).padding(top = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Lightbulb, null, tint = colors.accentOrange, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                color = colors.onBackground, modifier = Modifier.weight(1f).semantics { heading() })
            IconButton(onClick = onClose, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Default.Close, stringResource(R.string.cd_close),
                    tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
            }
        }
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())
            .padding(top = 6.dp, bottom = 18.dp)) {
            introduction?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                Spacer(Modifier.height(14.dp))
            }
            sections.forEachIndexed { index, section ->
                if (index > 0) Spacer(Modifier.height(4.dp))
                key(section.title) {
                    TipGuideSection(section, expandedSection == section.title) {
                        expandedSection = section.title.takeUnless { it == expandedSection }
                    }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun TipGuideSection(section: TipBubbleSection, expanded: Boolean, onToggle: () -> Unit) {
    val colors = AppTheme.colors
    val reveal = remember { BringIntoViewRequester() }
    var revealRequested by remember { mutableStateOf(false) }
    val arrowRotation = animateFloatAsState(if (expanded) 180f else 0f,
        tween(220, easing = FastOutSlowInEasing), label = "guideSectionArrow")
    val actionLabel = stringResource(if (expanded) R.string.cd_collapse else R.string.cd_expand)
    // Reveal the selected heading after both height animations settle. Targeting
    // the heading also works when large text makes the section taller than the viewport.
    // Initial opening never triggers a scroll.
    LaunchedEffect(expanded, revealRequested) {
        if (expanded && revealRequested) {
            delay(240)
            reveal.bringIntoView()
            revealRequested = false
        }
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth()
                .bringIntoViewRequester(reveal)
                .clip(RoundedCornerShape(10.dp))
                .background(if (expanded) colors.accentBlue.copy(alpha = 0.07f) else Color.Transparent)
                .clickable(role = Role.Button, onClickLabel = actionLabel) {
                    revealRequested = !expanded
                    onToggle()
                }
                .heightIn(min = 48.dp)
                .padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(section.title, style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = if (expanded) colors.accentBlue else colors.onBackground,
                modifier = Modifier.weight(1f).semantics { heading() })
            Spacer(Modifier.width(8.dp))
            Icon(Icons.Default.KeyboardArrowDown, null, tint = colors.onSurfaceVariant,
                modifier = Modifier.size(18.dp).graphicsLayer { rotationZ = arrowRotation.value })
        }
        AnimatedVisibility(
            visible = expanded,
            enter = expandVertically(tween(240, easing = FastOutSlowInEasing), expandFrom = Alignment.Top) +
                fadeIn(tween(180)),
            exit = shrinkVertically(tween(240, easing = FastOutSlowInEasing), shrinkTowards = Alignment.Top) +
                fadeOut(tween(120)),
        ) {
            Column(Modifier.padding(start = 10.dp, end = 10.dp, bottom = 12.dp)) {
                section.items.forEach { item ->
                    Spacer(Modifier.height(10.dp))
                    if (item.leading != null) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalAlignment = Alignment.Top) {
                            item.leading.invoke()
                            Box(Modifier.weight(1f)) {
                                TipBubbleItemText(item, colors.onSurfaceVariant, null, inlineLabel = true)
                            }
                        }
                    } else {
                        TipBubbleItemText(item, colors.onSurfaceVariant, null, inlineLabel = true)
                    }
                }
            }
        }
    }
}

/** Shared STA-style content hierarchy for every lightbulb help bubble. */
@Composable
internal fun TipBubbleContent(
    title: String,
    items: List<TipBubbleItem>,
    modifier: Modifier = Modifier,
    bulleted: Boolean = false,
) {
    val colors = AppTheme.colors
    Column(modifier = modifier.padding(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Default.Lightbulb,
                contentDescription = null,
                tint = colors.accentOrange,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = colors.onBackground,
            )
        }
        items.forEachIndexed { index, item ->
            Spacer(Modifier.height(if (index == 0) 10.dp else 12.dp))
            val hasText = item.text.isNotBlank()
            item.label?.takeIf { it.isNotBlank() }?.let { label ->
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Medium,
                    color = item.labelColor ?: colors.accentBlue,
                )
                if (hasText) Spacer(Modifier.height(5.dp))
            }
            if (!hasText) return@forEachIndexed
            if (bulleted) {
                Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "·",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onSurfaceVariant,
                    )
                    Box(Modifier.weight(1f)) {
                        TipBubbleItemText(item, colors.onSurfaceVariant, null)
                    }
                }
            } else if (item.emphasized) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.onBackground.copy(alpha = 0.05f))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    TipBubbleItemText(
                        item = item,
                        textColor = colors.accentBlue,
                        fontWeight = FontWeight.Medium,
                    )
                }
            } else {
                TipBubbleItemText(
                    item = item,
                    textColor = colors.onSurfaceVariant,
                    fontWeight = null,
                )
            }
        }
    }
}
