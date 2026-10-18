package com.ztransfer.ui.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.viewinterop.AndroidView
import com.ztransfer.lut.LutLayer
import com.ztransfer.lut.LutMonitorState
import com.ztransfer.lut.LutRenderWorker
import com.ztransfer.lut.LutTextureView

/** Inside the existing image transform: overlays, camera geometry and recorder input are unchanged. */
@Composable
internal fun RemoteLutImage(image: ImageBitmap, state: LutMonitorState, modifier: Modifier) {
    val current = state.active
    val candidate = state.candidate
    if (current == null && candidate == null) {
        Image(image, null, modifier, contentScale = ContentScale.Fit)
        return
    }
    val worker = remember { LutRenderWorker() }
    DisposableEffect(worker) { onDispose { worker.close() } }
    var displayed by remember { mutableStateOf<Pair<Long, Int>?>(null) }
    Box(modifier) {
        // The old image covers the candidate until TextureView reports an updated surface.
        listOfNotNull(candidate, current).forEach { layer -> key(layer.request, layer.retry) {
            LutImageLayer(image, worker, layer, Modifier.matchParentSize(),
                onReady = { displayed = layer.request to layer.retry; state.presented(layer.request) },
                onUnavailable = { if (displayed == (layer.request to layer.retry)) displayed = null },
                onFailure = { state.renderFailed(layer, it) })
        } }
        if (current == null || displayed != (current.request to current.retry)) {
            Image(image, null, Modifier.matchParentSize(), contentScale = ContentScale.Fit)
        }
    }
}

@Composable
private fun LutImageLayer(image: ImageBitmap, worker: LutRenderWorker, layer: LutLayer, modifier: Modifier,
    onReady: () -> Unit, onUnavailable: () -> Unit, onFailure: (Throwable) -> Unit) {
    val ready by rememberUpdatedState(onReady)
    val failure by rememberUpdatedState(onFailure)
    val unavailable by rememberUpdatedState(onUnavailable)
    AndroidView(modifier = modifier,
        factory = { context -> LutTextureView(context, worker, layer.table, { ready() }, { unavailable() }, { failure(it) }) },
        update = { it.offer(image.asAndroidBitmap()) }, onRelease = { it.release() })
}
