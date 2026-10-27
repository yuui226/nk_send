package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal const val CAMERA_CATALOG_REFLOW_DURATION_MS = 280
internal const val CAMERA_CATALOG_ENTER_DURATION_MS = 180
internal const val CAMERA_CATALOG_EXIT_DURATION_MS = 160

@Stable
internal class PhotoCatalogPresentation(initialFiles: List<NikonCamera.FileInfo>) {
    var files by mutableStateOf(initialFiles)
        internal set
    var motionActive by mutableStateOf(false)
        internal set
    var affectedDates by mutableStateOf<Set<String>>(emptySet())
        internal set
}

private data class CatalogInput(val files: List<NikonCamera.FileInfo>, val ready: Boolean)

/** A short UI snapshot only: authoritative camera data and transfer bookkeeping never wait. */
@Composable
internal fun rememberPhotoCatalogPresentation(
    files: List<NikonCamera.FileInfo>,
    catalogReady: Boolean,
): PhotoCatalogPresentation {
    val presentation = remember { PhotoCatalogPresentation(files) }
    val latest by rememberUpdatedState(CatalogInput(files, catalogReady))
    LaunchedEffect(presentation) {
        var previousReady = false
        var scanRevision = 0L
        var endJob: Job? = null
        fun resetMotion() {
            endJob?.cancel()
            endJob = null
            presentation.motionActive = false
            presentation.affectedDates = emptySet()
        }
        try {
            // Conflate pending snapshots, without canceling an in-flight preparation window.
            // Fast burst publications must not postpone visible updates indefinitely.
            snapshotFlow { latest }.onEach { input ->
                // Preserve a brief scan/disconnect boundary even when pending file snapshots
                // are conflated. A new ready snapshot must establish a fresh baseline.
                if (!input.ready) {
                    previousReady = false
                    scanRevision++
                }
            }.conflate().collect { input ->
                if (!input.ready || !latest.ready) {
                    previousReady = false
                    resetMotion()
                    presentation.files = latest.files
                    return@collect
                }
                val animateChanges = previousReady
                val inputRevision = scanRevision
                previousReady = true
                val previous = presentation.files
                val changes = if (animateChanges && previous !== input.files) {
                    withContext(Dispatchers.Default) {
                        publishedCameraChanges(previous, input.files).affectedDates
                    }
                } else emptySet()
                if (changes.isNotEmpty()) {
                    endJob?.cancel()
                    endJob = null
                    presentation.affectedDates = presentation.affectedDates + changes
                    presentation.motionActive = true
                    // LazyGrid subcomposes during measurement. Let the old stable keys observe
                    // their animation specs for a complete frame before changing the model.
                    withFrameNanos { }
                    withFrameNanos { }
                    if (!latest.ready || inputRevision != scanRevision) {
                        previousReady = false
                        resetMotion()
                        presentation.files = latest.files
                        return@collect
                    }
                    presentation.files = input.files
                    endJob = launch {
                        delay((CAMERA_CATALOG_REFLOW_DURATION_MS + 48).toLong())
                        presentation.motionActive = false
                        presentation.affectedDates = emptySet()
                        endJob = null
                    }
                } else {
                    presentation.files = input.files
                    // Keep an existing exit animation alive for metadata-only updates.
                    if (endJob == null) resetMotion()
                }
            }
        } finally {
            endJob?.cancel()
        }
    }
    return presentation
}
