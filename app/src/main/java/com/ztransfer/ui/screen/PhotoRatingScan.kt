package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import android.os.SystemClock
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.protocol.photoRatingSources
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged

internal data class PhotoRatingScan(
    val values: Map<Int, Int?> = emptyMap(),
    val loading: Boolean = false,
    val completed: Int = 0,
    val total: Int = 0,
    val complete: Boolean = false,
)

/** Reuse ratings captured during listing; only supplement missing photo headers while filtering. */
@Composable
internal fun rememberPhotoRatings(camera: NikonCamera?, enabled: Boolean,
    files: List<NikonCamera.FileInfo>, paused: Boolean, useObjectRating: Boolean,
    staConnection: Boolean,
    listLoading: Boolean): PhotoRatingScan {
    val generation = camera?.photoRatingGeneration?.collectAsState()?.value ?: 0
    var result by remember(camera, enabled, generation, useObjectRating, staConnection) { mutableStateOf(PhotoRatingScan(loading = enabled && camera != null)) }
    val latestFiles by rememberUpdatedState(files)
    val latestPaused by rememberUpdatedState(paused)
    val latestListLoading by rememberUpdatedState(listLoading)
    LaunchedEffect(camera, enabled, generation, useObjectRating, staConnection) {
        if (!enabled || camera == null) return@LaunchedEffect
        val ratings = HashMap<Int, Int?>()
        // A rating snapshot belongs to one connection. Files appearing after the first
        // complete list are intentionally left for the next connection.
        val sessionHandles = HashSet<Int>()
        var sessionInitialized = false
        // Once the three-date snapshot is locked, thumbnail/cache updates must not restart
        // the rating pass. Only a pause/list-enumeration transition may restart it.
        snapshotFlow {
            val current = latestFiles
            Triple(
                if (sessionInitialized) 0 else current.asSequence().map { it.handle }.toList().hashCode(),
                latestPaused,
                if (sessionInitialized) false else latestListLoading,
            )
        }.distinctUntilChanged().collectLatest {
            val current = latestFiles
            val pause = latestPaused
            if (current.isEmpty()) {
                sessionHandles.clear()
                sessionInitialized = false
                ratings.clear()
            } else if (!sessionInitialized && !pause) {
                sessionHandles += current.map { it.handle }
                val dates = current.asSequence().mapNotNull { it.captureDate?.take(8) }
                    .distinct().take(3).count()
                // Keep collecting handles while the catalog is still arriving. Once three
                // dates are known, lock the connection snapshot immediately; if this camera
                // has fewer than three dates, lock when the authoritative list ends.
                sessionInitialized = dates >= 3 || !latestListLoading
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
            // During STA enumeration, do not start a partial rating pass. The list grows in
            // several batches; starting at one or two dates only causes cancellation and
            // makes passive header values look like completed progress. Wait for the third
            // date (or the authoritative end of a shorter catalog) first.
            if (staConnection && datesForRating(photos).size < 3 && latestListLoading) {
                result = PhotoRatingScan(loading = false)
                return@collectLatest
            }
            val handles = eligiblePhotos.mapTo(HashSet()) { it.handle }
            ratings.keys.retainAll(handles)
            val sources = photoRatingSources(eligiblePhotos)
            val uniqueSources = sources.values.distinctBy { it.handle }
            // Headers already captured by the current connection can provide a free
            // passive result. loadFiles() invalidates this map when a new connection scan starts.
            val cachedOrigins = linkedMapOf<String, Int>()
            uniqueSources.forEach { file ->
                camera.cachedPhotoRating(file.handle)?.let {
                    ratings[file.handle] = it
                    val origin = camera.cachedPhotoRatingOrigin(file.handle) ?: "unknown"
                    cachedOrigins[origin] = (cachedOrigins[origin] ?: 0) + 1
                }
            }
            fun publish(loading: Boolean, complete: Boolean = false) {
                val visible = HashMap<Int, Int?>()
                sources.forEach { (handle, source) ->
                    if (ratings.containsKey(source.handle)) visible[handle] = ratings[source.handle]
                }
                result = PhotoRatingScan(
                    values = visible,
                    loading = loading,
                    completed = ratings.size,
                    total = uniqueSources.size,
                    complete = complete,
                )
            }
            val pending = uniqueSources.filterNot { ratings.containsKey(it.handle) }
            ratingDiagnostic("scan start generation=$generation files=${eligiblePhotos.size} sources=${uniqueSources.size} " +
                    "cached=${uniqueSources.size - pending.size} pending=${pending.size} " +
                    "cachedOrigins=${cachedOrigins.entries.joinToString(",") { "${it.key}:${it.value}" }} " +
                    "source=${if (useObjectRating) "object+header" else "header"} paused=$pause",
            )
            publish(pending.isNotEmpty())
            if (pause) return@collectLatest
            // The thumbnail pipeline owns camera thumbnail requests and already prioritizes
            // the newest three dates. Do not prefetch them serially here: doing so made the
            // rating scan wait for every thumbnail (including invisible/background items).
            // Once the three-date boundary is known, rating reads start immediately and the
            // two pipelines arbitrate through the existing camera request scheduler.
            var confirmed = 0
            var unknown = 0
            val readStartedAt = SystemClock.elapsedRealtime()
            var cancelled = false
            try {
                pending.forEachIndexed { index, file ->
                    currentCoroutineContext().ensureActive()
                    // Never reuse the camera's cross-flow rating map here: this scan is a
                    // fresh snapshot for the current connection. The local map above is the
                    // only source of already-completed values for this scan.
                    var resolvedRating = if (useObjectRating) camera.readObjectRating(file) else null
                    val isPhoto = file.extension in setOf(".jpg", ".jpeg", ".nef", ".nrw")
                    // Videos use the verified Nikon container tag, not photo EXIF parsing.
                    if (resolvedRating == null) {
                        resolvedRating = if (isPhoto) camera.readPhotoRatingHeader(file) else camera.readVideoRating(file)
                    }
                    ratings[file.handle] = resolvedRating
                    if (resolvedRating != null) confirmed++ else unknown++
                    if (index % 12 == 11) {
                        publish(true)
                        ratingDiagnostic(
                            "progress=${ratings.size}/${uniqueSources.size} " +
                                "elapsed=${SystemClock.elapsedRealtime() - readStartedAt}ms",
                        )
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled = true
                throw e
            } catch (e: Exception) {
                // A broken transport must not crash Compose or trigger a whole-card retry loop.
                ratingDiagnostic("scan stopped generation=$generation confirmed=$confirmed unknown=$unknown " +
                        "error=${e.javaClass.simpleName}",
                )
            } finally {
                if (!cancelled) {
                    ratingDiagnostic("complete=${ratings.size}/${uniqueSources.size} " +
                            "confirmed=$confirmed unknown=$unknown " +
                            "elapsed=${SystemClock.elapsedRealtime() - readStartedAt}ms",
                    )
                }
                publish(false, complete = ratings.size >= uniqueSources.size && uniqueSources.isNotEmpty())
            }
        }
    }
    return result
}

internal fun ratingDiagnostic(message: String) {
    PhotoGenerationProbe.note("RATING", message)
    RatingDiagnostics.note(message)
}

private fun datesForRating(files: List<NikonCamera.FileInfo>): List<String> =
    files.asSequence().mapNotNull { it.captureDate?.take(8) }.distinct().take(3).toList()
