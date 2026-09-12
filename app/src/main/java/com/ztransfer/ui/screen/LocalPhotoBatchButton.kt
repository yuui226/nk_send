package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.snap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

@Composable
private fun AnimatedLocalPhotoBatchCount(
    count: Int,
    color: androidx.compose.ui.graphics.Color,
    label: String,
) {
    AnimatedContent(
        targetState = count,
        transitionSpec = {
            val dir = if (targetState < initialState) 1 else -1
            (slideInVertically { it / 2 * dir } + fadeIn(androidx.compose.animation.core.tween(160)))
                .togetherWith(
                    slideOutVertically { -it / 2 * dir } + fadeOut(androidx.compose.animation.core.tween(120)),
                )
                .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
        },
        label = label,
    ) { value ->
        Text(
            text = "$value",
            style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
            color = color,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
internal fun LocalPhotoBatchButton(
    batch: LocalPhotoBatchState,
    hasEffect: Boolean,
    onChoose: () -> Unit,
    onGenerate: () -> Unit,
    pageLabel: String? = null,
) {
    val colors = AppTheme.colors
    val empty = batch.photos.isEmpty()
    GlassButton(
        onClick = if (empty) onChoose else onGenerate,
        enabled = batch.phase == LocalPhotoBatchPhase.READY && (empty || hasEffect),
        active = batch.generating || (!empty && hasEffect),
        modifier = Modifier.fillMaxWidth().height(50.dp),
    ) {
        AnimatedContent(
            targetState = batch.phase,
            transitionSpec = { buttonStateTextTransition(targetState.ordinal >= initialState.ordinal) },
            contentAlignment = Alignment.Center,
            label = "localPhotoBatchState",
        ) { phase ->
            if (phase == LocalPhotoBatchPhase.GENERATING) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                ) {
                    Text(
                        text = stringResource(R.string.local_photo_batch_generating) + " ",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.onBackground,
                    )
                    AnimatedLocalPhotoBatchCount(
                        count = batch.progress.completed,
                        color = colors.onBackground,
                        label = "localPhotoBatchCount",
                    )
                    Text(
                        text = "/${batch.progress.total}",
                        style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                        fontWeight = FontWeight.Bold,
                        color = colors.onBackground,
                    )
                }
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (pageLabel != null && !empty && phase == LocalPhotoBatchPhase.READY) {
                        Text(
                            pageLabel,
                            style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Text(
                        text = when (phase) {
                            LocalPhotoBatchPhase.COMPLETE -> stringResource(R.string.local_photo_batch_saved, batch.progress.saved)
                            LocalPhotoBatchPhase.PARTIAL -> stringResource(R.string.local_photo_batch_partial, batch.progress.saved, batch.progress.total)
                            LocalPhotoBatchPhase.FAILED -> stringResource(R.string.local_photo_batch_failed)
                            else -> if (empty) stringResource(R.string.local_photo_choose_short)
                                else stringResource(R.string.local_photo_batch_generate, batch.photos.size)
                        },
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.onBackground,
                    )
                }
            }
        }
    }
}
