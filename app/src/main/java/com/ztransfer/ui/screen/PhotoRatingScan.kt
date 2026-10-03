package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.protocol.photoRatingSources
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest

internal data class PhotoRatingScan(val values: Map<Int, Int?> = emptyMap(), val loading: Boolean = false)

/** Reuse ratings captured during listing; only supplement missing photo headers while filtering. */
@Composable
internal fun rememberPhotoRatings(camera: NikonCamera?, enabled: Boolean,
    files: List<NikonCamera.FileInfo>, paused: Boolean, useObjectRating: Boolean,
    staConnection: Boolean): PhotoRatingScan {
    val generation = camera?.photoRatingGeneration?.collectAsState()?.value ?: 0
    var result by remember(camera, enabled, generation, useObjectRating) { mutableStateOf(PhotoRatingScan(loading = enabled && camera != null)) }
    val latestFiles by rememberUpdatedState(files)
    val latestPaused by rememberUpdatedState(paused)
    LaunchedEffect(camera, enabled, generation, useObjectRating) {
        if (!enabled || camera == null) return@LaunchedEffect
        val ratings = HashMap<Int, Int?>()
        // A rating snapshot belongs to one connection. Files appearing after the first
        // complete list are intentionally left for the next connection.
        val sessionHandles = HashSet<Int>()
        var sessionInitialized = false
        snapshotFlow { latestFiles to latestPaused }.collectLatest { (current, pause) ->
            if (current.isEmpty()) {
                sessionHandles.clear()
                sessionInitialized = false
                ratings.clear()
            } else if (!sessionInitialized && !pause) {
                sessionHandles += current.map { it.handle }
                sessionInitialized = true
            }
            val allPhotos = current.filter { it.extension in setOf(".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4") }
            val photos = allPhotos.filter { !sessionInitialized || it.handle in sessionHandles }
            // STA reads only the newest three actual shooting dates. The list is already
            // newest-first; once the third reliable date is present, older files are skipped.
            val eligiblePhotos = if (staConnection) {
                val dates = photos.asSequence().mapNotNull { it.captureDate?.take(8) }
                    .distinct().take(3).toList()
                val cutoff = dates.lastOrNull()
                if (cutoff == null) emptyList() else photos.filter {
                    it.captureDate?.take(8)?.let { date -> date >= cutoff } == true
                }
            } else photos
            val handles = eligiblePhotos.mapTo(HashSet()) { it.handle }
            ratings.keys.retainAll(handles)
            val sources = photoRatingSources(eligiblePhotos)
            val uniqueSources = sources.values.distinctBy { it.handle }
            fun publish(loading: Boolean) {
                val visible = HashMap<Int, Int?>()
                sources.forEach { (handle, source) ->
                    if (ratings.containsKey(source.handle)) visible[handle] = ratings[source.handle]
                }
                result = PhotoRatingScan(visible, loading)
            }
            val pending = uniqueSources.filterNot { ratings.containsKey(it.handle) }
            PhotoGenerationProbe.note(
                "RATING",
                "scan start generation=$generation files=${eligiblePhotos.size} sources=${uniqueSources.size} " +
                    "cached=0 pending=${pending.size} " +
                    "source=${if (useObjectRating) "object+header" else "header"} paused=$pause",
            )
            publish(pending.isNotEmpty())
            if (pause) return@collectLatest
            var confirmed = 0
            var unknown = 0
            try {
                pending.forEachIndexed { index, file ->
                    currentCoroutineContext().ensureActive()
                    val cached = camera.cachedPhotoRating(file.handle)
                    val resolvedRating = if (cached != null) {
                        ratings[file.handle] = cached
                        cached
                    } else {
                        var rating = if (useObjectRating) camera.readObjectRating(file) else null
                        val isPhoto = file.extension in setOf(".jpg", ".jpeg", ".nef", ".nrw")
                        // Videos use the verified Nikon container tag, not photo EXIF parsing.
                        if (rating == null) rating = if (isPhoto) camera.readPhotoRatingHeader(file) else camera.readVideoRating(file)
                        ratings[file.handle] = rating
                        rating
                    }
                    if (resolvedRating != null) confirmed++ else unknown++
                    if (index % 12 == 11) publish(true)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                PhotoGenerationProbe.note("RATING", "scan cancelled generation=$generation confirmed=$confirmed unknown=$unknown")
                throw e
            } catch (e: Exception) {
                // A broken transport must not crash Compose or trigger a whole-card retry loop.
                PhotoGenerationProbe.note(
                    "RATING",
                    "scan stopped generation=$generation confirmed=$confirmed unknown=$unknown " +
                        "error=${e.javaClass.simpleName}",
                )
            } finally {
                PhotoGenerationProbe.note(
                    "RATING",
                    "scan complete generation=$generation confirmed=$confirmed unknown=$unknown " +
                        "known=${ratings.size}",
                )
                publish(false)
            }
        }
    }
    return result
}
