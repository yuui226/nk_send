package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.snap
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
            style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
            color = color,
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
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        AnimatedVisibility(
            visible = !empty,
            enter = expandHorizontally(tween(240), expandFrom = Alignment.Start) + fadeIn(tween(180)),
            exit = shrinkHorizontally(tween(240), shrinkTowards = Alignment.Start) + fadeOut(tween(140)),
        ) {
            GlassButton(
                onClick = onChoose,
                enabled = !batch.generating,
                contentPadding = PaddingValues(0.dp),
                modifier = Modifier.padding(end = 10.dp).size(50.dp),
            ) {
                Icon(
                    Icons.Outlined.PhotoLibrary,
                    contentDescription = stringResource(R.string.local_photo_reselect, batch.photos.size),
                    tint = colors.onBackground,
                    modifier = Modifier.size(23.dp),
                )
            }
        }
        GlassButton(
            onClick = if (empty) onChoose else onGenerate,
            enabled = batch.phase == LocalPhotoBatchPhase.READY && (empty || hasEffect),
            active = batch.generating || (!empty && hasEffect),
            modifier = Modifier.weight(1f).height(50.dp),
        ) {
            AnimatedContent(
                targetState = batch.phase to empty,
                transitionSpec = { buttonStateTextTransition(targetState.first.ordinal >= initialState.first.ordinal) },
                contentAlignment = Alignment.Center,
                label = "localPhotoBatchState",
                modifier = Modifier.fillMaxWidth(),
            ) { (phase, showChoose) ->
                if (phase == LocalPhotoBatchPhase.GENERATING) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Row(
                            modifier = Modifier.align(Alignment.CenterStart),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            AnimatedLocalPhotoBatchCount(
                                count = batch.progress.completed,
                                color = colors.onSurfaceVariant,
                                label = "localPhotoBatchCount",
                            )
                            Text(
                                text = " / ${batch.progress.total}",
                                style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                                color = colors.onSurfaceVariant,
                            )
                        }
                        Text(
                            text = stringResource(R.string.local_photo_batch_generating),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground,
                        )
                    }
                } else {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        if (pageLabel != null && !empty && phase == LocalPhotoBatchPhase.READY) {
                            Text(
                                pageLabel,
                                style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                                color = colors.onSurfaceVariant,
                                modifier = Modifier.align(Alignment.CenterStart),
                            )
                        }
                        Text(
                            text = when (phase) {
                                LocalPhotoBatchPhase.COMPLETE -> stringResource(R.string.local_photo_batch_saved, batch.progress.saved)
                                LocalPhotoBatchPhase.PARTIAL -> stringResource(R.string.local_photo_batch_partial, batch.progress.saved, batch.progress.total)
                                LocalPhotoBatchPhase.FAILED -> stringResource(R.string.local_photo_batch_failed)
                                else -> if (showChoose) stringResource(R.string.local_photo_choose_short)
                                    else stringResource(R.string.local_photo_generate)
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
}
