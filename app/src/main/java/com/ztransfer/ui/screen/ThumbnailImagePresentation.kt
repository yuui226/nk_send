package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.ImageBitmap
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge

internal class ThumbnailImagePresentation(
    val image: State<ImageBitmap?>,
    val alpha: State<Float>,
    val showPlaceholder: State<Boolean>,
    // Fixed for this cell's lifetime: removing a layer mid-fade would change its draw structure.
    val needsFadeLayer: Boolean = true,
)

private class FixedThumbnailState<T>(override val value: T) : State<T>
private val cachedThumbnailAlpha: State<Float> = FixedThumbnailState(1f)
private val cachedThumbnailPlaceholder: State<Boolean> = FixedThumbnailState(false)

/**
 * Cached cells draw immediately; only a newly loaded image fades over its existing placeholder.
 * Read [ThumbnailImagePresentation.alpha] in graphicsLayer, not composition. No second image or
 * additional decode is retained for the transition. Loading and fading have separate lifetimes:
 * pausing remote reads or collapsing a date cancels pending reads without interrupting a ready image.
 */
@Composable
internal fun rememberThumbnailImagePresentation(
    handle: Int,
    transfersBusy: Boolean,
    loadEnabled: Boolean,
    allowRemote: Boolean,
    cachedThumbnail: () -> ImageBitmap?,
    loadThumbnail: suspend (allowRemote: Boolean) -> ImageBitmap?,
    thumbnailReadyEvents: Flow<Int> = emptyFlow(),
): ThumbnailImagePresentation {
    // Choose this path only when the cell first enters composition. Cache hits need neither
    // loading coroutines nor animation state; a later cache fill must still finish its fade.
    val cached = remember(handle) {
        cachedThumbnail()?.let { image ->
            ThumbnailImagePresentation(
                FixedThumbnailState(image), cachedThumbnailAlpha, cachedThumbnailPlaceholder,
                needsFadeLayer = false,
            )
        }
    }
    if (cached != null) return cached

    val image = remember(handle) { mutableStateOf<ImageBitmap?>(null) }
    val opacity = remember(handle) { Animatable(0f) }
    val latestLoadThumbnail by rememberUpdatedState(loadThumbnail)
    LaunchedEffect(handle, transfersBusy, loadEnabled, allowRemote, thumbnailReadyEvents) {
        if (loadEnabled && image.value == null) {
            // Subscribe before the first read finishes: background fill can make a new photo
            // available after an initial miss. Only that handle wakes this cell, only local
            // cache is read on notification, and the subscription ends once the image is ready.
            merge(
                flowOf(true),
                thumbnailReadyEvents.filter { it == handle }.map { false },
            ).firstOrNull { initialRead ->
                image.value = latestLoadThumbnail(allowRemote && initialRead)
                image.value != null
            }
        }
    }
    val ready = image.value != null
    LaunchedEffect(handle, ready) {
        if (ready && opacity.value < 1f) opacity.animateTo(1f, tween(180))
    }
    // A single recomposition removes the placeholder after fading, not one per animation frame.
    val showPlaceholder = remember(handle) { derivedStateOf { opacity.value < 1f } }
    return remember(handle) {
        ThumbnailImagePresentation(image, opacity.asState(), showPlaceholder)
    }
}
