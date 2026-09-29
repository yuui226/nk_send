package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import com.ztransfer.protocol.photoRatingSources
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest

internal data class PhotoRatingScan(val values: Map<Int, Int?> = emptyMap(), val loading: Boolean = false)

/** Reuse ratings captured during listing; only supplement missing photo headers while filtering. */
@Composable
internal fun rememberPhotoRatings(camera: NikonCamera?, enabled: Boolean,
    files: List<NikonCamera.FileInfo>, paused: Boolean, useObjectRating: Boolean): PhotoRatingScan {
    val generation = camera?.photoRatingGeneration?.collectAsState()?.value ?: 0
    var result by remember(camera, enabled, generation, useObjectRating) { mutableStateOf(PhotoRatingScan(loading = enabled && camera != null)) }
    val latestFiles by rememberUpdatedState(files)
    val latestPaused by rememberUpdatedState(paused)
    LaunchedEffect(camera, enabled, generation, useObjectRating) {
        if (!enabled || camera == null) return@LaunchedEffect
        val ratings = HashMap<Int, Int?>()
        snapshotFlow { latestFiles to latestPaused }.collectLatest { (current, pause) ->
            val photos = current.filter { it.extension in setOf(".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4") }
            val handles = photos.mapTo(HashSet()) { it.handle }
            ratings.keys.retainAll(handles)
            val sources = photoRatingSources(photos)
            val uniqueSources = sources.values.distinctBy { it.handle }
            uniqueSources.forEach { file -> camera.cachedPhotoRating(file.handle)?.let { ratings[file.handle] = it } }
            fun publish(loading: Boolean) {
                val visible = HashMap<Int, Int?>()
                sources.forEach { (handle, source) ->
                    if (ratings.containsKey(source.handle)) visible[handle] = ratings[source.handle]
                }
                result = PhotoRatingScan(visible, loading)
            }
            val pending = uniqueSources.filterNot { ratings.containsKey(it.handle) }
            publish(pending.isNotEmpty())
            if (pause) return@collectLatest
            try {
                pending.forEachIndexed { index, file ->
                    currentCoroutineContext().ensureActive()
                    val cached = camera.cachedPhotoRating(file.handle)
                    if (cached != null) {
                        ratings[file.handle] = cached
                    } else {
                        var rating = if (useObjectRating) camera.readObjectRating(file) else null
                        val isPhoto = file.extension in setOf(".jpg", ".jpeg", ".nef", ".nrw")
                        // Videos use the verified Nikon container tag, not photo EXIF parsing.
                        if (rating == null) rating = if (isPhoto) camera.readPhotoRatingHeader(file) else camera.readVideoRating(file)
                        ratings[file.handle] = rating
                    }
                    if (index % 12 == 11) publish(true)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // A broken transport must not crash Compose or trigger a whole-card retry loop.
            } finally {
                publish(false)
            }
        }
    }
    return result
}
