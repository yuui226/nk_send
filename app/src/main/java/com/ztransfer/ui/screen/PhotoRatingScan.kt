package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import android.os.SystemClock
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.diagnostics.RatingDiagnostics
import com.ztransfer.protocol.photoRatingSources
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged

internal data class PhotoRatingScan(
    val values: Map<Int, Int?> = emptyMap(),
    val loading: Boolean = false,
    val completed: Int = 0,
    val total: Int = 0,
    val complete: Boolean = false,
    /** The user enabled the filter, but the recent-date boundary is not ready yet. */
    val waitingForRange: Boolean = false,
)

private val ratingPhotoExtensions = setOf(".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4")
private val ratingStillExtensions = setOf(".jpg", ".jpeg", ".nef", ".nrw")

/** Reuse ratings captured during listing; only supplement missing photo headers while filtering. */
@Composable
internal fun rememberPhotoRatings(camera: NikonCamera?, enabled: Boolean,
    files: List<NikonCamera.FileInfo>, paused: Boolean, useObjectRating: Boolean,
    staConnection: Boolean,
    listLoading: Boolean,
    recentThumbnailReadyDays: Int,
    ratingDays: Int,
    photoLoadingDays: Int): PhotoRatingScan {
    val generation = camera?.photoRatingGeneration?.collectAsState()?.value ?: 0
    var clearedGeneration by remember(camera) { mutableStateOf<Int?>(null) }
    var previousEnabled by remember(camera) { mutableStateOf<Boolean?>(null) }
    var result by remember(camera, enabled, generation, useObjectRating, staConnection) {
        mutableStateOf(PhotoRatingScan(
            loading = enabled && camera != null,
            waitingForRange = enabled && camera != null && staConnection,
        ))
    }
    val latestFiles by rememberUpdatedState(files)
    val latestPaused by rememberUpdatedState(paused)
    val latestListLoading by rememberUpdatedState(listLoading)
    val latestRecentThumbnailReadyDays by rememberUpdatedState(recentThumbnailReadyDays)
    LaunchedEffect(camera, enabled, generation, useObjectRating, staConnection, ratingDays, photoLoadingDays) {
        val enteringEnabled = enabled && previousEnabled != true
        previousEnabled = enabled
        if (!enabled) {
            // Toggling the filter is an explicit fresh-snapshot boundary. Do not retain
            // ratings read before the user turned it off; reopening must observe the camera
            // again so changes made on-camera can be picked up.
            if (camera != null && clearedGeneration != generation) {
                // invalidatePhotoRatings increments generation; remember the value it will
                // produce so the dependency restart below cannot clear repeatedly.
                clearedGeneration = generation + 1
                camera.invalidatePhotoRatings()
            }
            result = PhotoRatingScan()
            return@LaunchedEffect
        }
        if (camera == null) return@LaunchedEffect
        // The photo boundary is an upper bound for rating work: if photos are configured for
        // one day and ratings for three, the first day is enough to start rating. Zero means all.
        val effectiveDays = when {
            ratingDays == 0 -> photoLoadingDays
            photoLoadingDays == 0 -> ratingDays
            else -> minOf(ratingDays, photoLoadingDays)
        }
        // Thumbnail/header loading may have captured passive ratings while the filter was off.
        // Enabling the filter is an explicit fresh-snapshot request, so discard those values
        // before building the pending set. The generation restart is guarded by previousEnabled.
        if (enteringEnabled) {
            camera.invalidatePhotoRatings()
        }
        val ratings = HashMap<Int, Int?>()
        // A rating snapshot belongs to one connection. Files appearing after the first
        // complete list are intentionally left for the next connection.
        val sessionHandles = HashSet<Int>()
        var sessionInitialized = false
        var scanStarted = false
        // Once the selected date snapshot is locked, thumbnail/cache updates must not restart
        // the rating pass. A new camera generation or an explicit enable/disable transition
        // creates a new effect and therefore a new snapshot.
        snapshotFlow {
            val current = latestFiles
            Triple(
                if (sessionInitialized) 0 else current.asSequence()
                    .map { it.handle to it.captureDate?.take(8) }
                    .toList().hashCode(),
                latestPaused,
                Pair(
                    if (sessionInitialized) false else latestListLoading,
                    latestRecentThumbnailReadyDays,
                ),
            )
        }.distinctUntilChanged().collect {
            // The connection snapshot is immutable after the first pass starts. Later thumbnail
            // or catalog emissions must not re-enter the setup path (or print another start line).
            if (scanStarted) return@collect
            val current = latestFiles
            val pause = latestPaused
            val thumbnailRangeReady = if (effectiveDays == 0) {
                val knownDates = datesForRating(current).size
                !latestListLoading && (knownDates == 0 || latestRecentThumbnailReadyDays >= knownDates)
            } else {
                latestRecentThumbnailReadyDays >= effectiveDays || (!latestListLoading && datesForRating(current).size < effectiveDays)
            }
            if (staConnection && !thumbnailRangeReady) {
                result = PhotoRatingScan(
                    loading = true,
                    total = ratingFileCount(current),
                    waitingForRange = true,
                )
                return@collect
            }
            if (current.isEmpty()) {
                sessionHandles.clear()
                sessionInitialized = false
                ratings.clear()
            } else if (!sessionInitialized && !pause) {
                sessionHandles += current.map { it.handle }
                val dates = current.asSequence().mapNotNull { it.captureDate?.take(8) }
                    .distinct().count()
                // Keep collecting handles while the catalog is still arriving. Lock at the
                // selected range; a completed catalog may lock an actually shorter range.
                sessionInitialized = effectiveDays == 0 || dates >= effectiveDays || !latestListLoading
            }
            val allPhotos = current.filter { it.extension in ratingPhotoExtensions }
            val photos = allPhotos.filter { !sessionInitialized || it.handle in sessionHandles }
            // STA reads only the newest selected actual shooting dates. The list is already
            // newest-first; older files are skipped after the selected boundary.
            val eligiblePhotos = if (staConnection) {
                val dates = photos.asSequence().mapNotNull { it.captureDate?.take(8) }
                    .distinct().let { sequence ->
                        if (effectiveDays == 0) sequence.toList() else sequence.take(effectiveDays).toList()
                    }
                val cutoff = dates.lastOrNull()
                if (cutoff == null) emptyList() else photos.filter {
                    it.captureDate?.take(8)?.let { date -> date >= cutoff } == true
                }
            } else photos
            // During STA enumeration, do not start a partial rating pass. The list grows in
            // several batches; wait for the selected date count (or the authoritative end of
            // a shorter catalog) first.
            if (staConnection && effectiveDays > 0 && datesForRating(photos).size < effectiveDays && latestListLoading) {
                result = PhotoRatingScan(
                    loading = true,
                    total = ratingFileCount(photos),
                    waitingForRange = true,
                )
                return@collect
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
                    // One camera read can serve a JPEG/RAW pair, but the UI represents both
                    // visible files. Count every file while retaining source de-duplication for
                    // the actual reads.
                    completed = sources.count { (_, source) -> ratings.containsKey(source.handle) },
                    total = eligiblePhotos.count { it.extension in ratingPhotoExtensions },
                    complete = complete,
                )
            }
            val pending = uniqueSources.filterNot { ratings.containsKey(it.handle) }
            ratingDiagnostic("scan start generation=$generation files=${eligiblePhotos.size} sources=${uniqueSources.size} " +
                    "cached=${uniqueSources.size - pending.size} pending=${pending.size} " +
                    "cachedOrigins=${cachedOrigins.entries.joinToString(",") { "${it.key}:${it.value}" }} " +
                    "source=${if (useObjectRating) "object" else "header"} paused=$pause",
            )
            if (pending.isEmpty()) {
                scanStarted = true
                publish(loading = false, complete = uniqueSources.isNotEmpty())
                ratingDiagnostic(
                    "complete=${uniqueSources.size}/${uniqueSources.size} " +
                        "confirmed=${uniqueSources.size} unknown=0 elapsed=0ms source=cache",
                )
                return@collect
            }
            publish(pending.isNotEmpty())
            if (pause) return@collect
            // The thumbnail pipeline owns camera thumbnail requests and already prioritizes
            // selected newest dates. Do not prefetch them serially here: doing so made the
            // rating scan wait for every thumbnail (including invisible/background items).
            // Once the selected date boundary is known, rating reads start immediately and the
            // two pipelines arbitrate through the existing camera request scheduler.
            var confirmed = 0
            var unknown = 0
            var activeFile = ""
            scanStarted = true
            val readStartedAt = SystemClock.elapsedRealtime()
            var cancelled = false
            var ratingPhaseStarted = false
            try {
                // Keep the old transfer/thumbnail FIFO outside the scan. While this scan is
                // active, only remote thumbnail requests move behind its short RATING tickets;
                // transfers and interactive work retain their existing priority.
                camera.beginRatingPhase()
                ratingPhaseStarted = true
                // Each reader submits one RATING transaction. Do not reserve the channel for the
                // whole scan: interactive work and transfer chunk boundaries must be able to run
                // between files, while the scheduler still gives each rating read its priority.
                pending.forEachIndexed { index, file ->
                    currentCoroutineContext().ensureActive()
                    activeFile = file.fileName
                    // Never reuse the camera's cross-flow rating map here: this scan is a
                    // fresh snapshot for the current connection. The local map above is the
                    // only source of already-completed values for this scan.
                    // AP/USB use the object property for JPEG. A RAW-only source probes that
                    // property once, then falls back to the verified NEF/NRW header path for the
                    // current and subsequent RAW files in this connection.
                    val resolvedRating = if (useObjectRating) {
                        camera.readObjectOrRawHeaderRating(file)
                    } else {
                        val isPhoto = file.extension in ratingStillExtensions
                        if (isPhoto) camera.readPhotoRatingHeader(file) else camera.readVideoRating(file)
                    }
                    ratings[file.handle] = resolvedRating
                    if (resolvedRating != null) confirmed++ else unknown++
                    // The progress control must advance after every file. Batching this
                    // publication made the UI appear frozen at 1/52 while reads continued.
                    publish(true)
                    if (index % 12 == 11) {
                        ratingDiagnostic(
                            "progress=${ratings.size}/${uniqueSources.size} " +
                                "active=$activeFile " +
                                "elapsed=${SystemClock.elapsedRealtime() - readStartedAt}ms",
                        )
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled = true
                ratingDiagnostic("scan cancelled generation=$generation progress=${ratings.size}/${uniqueSources.size} active=$activeFile")
                throw e
            } catch (e: Exception) {
                // A broken transport must not crash Compose or trigger a whole-card retry loop.
                ratingDiagnostic("scan stopped generation=$generation confirmed=$confirmed unknown=$unknown " +
                        "error=${e.javaClass.simpleName}",
                )
            } finally {
                if (ratingPhaseStarted) camera.endRatingPhase()
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

private fun datesForRating(files: List<NikonCamera.FileInfo>, limit: Int = 0): List<String> =
    files.asSequence().mapNotNull { it.captureDate?.take(8) }.distinct()
        .let { if (limit <= 0) it.toList() else it.take(limit).toList() }

private fun ratingFileCount(files: List<NikonCamera.FileInfo>): Int =
    files.count { it.extension in ratingPhotoExtensions }
