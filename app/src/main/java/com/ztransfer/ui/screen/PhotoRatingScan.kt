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

internal data class PhotoRatingScan(
    val values: Map<Int, Int?> = emptyMap(),
    val loading: Boolean = false,
    val completed: Int = 0,
    val total: Int = 0,
    val complete: Boolean = false,
    /** The user enabled the filter, but the recent-date boundary is not ready yet. */
    val waitingForRange: Boolean = false,
)

private val ratingStillExtensions = setOf(".jpg", ".jpeg", ".nef", ".nrw")

private data class RatingScanInput(
    val files: List<NikonCamera.FileInfo>,
    val paused: Boolean,
    val listLoading: Boolean,
    val scanComplete: Boolean,
    val thumbnailReadyDays: Int,
    val appliedPhotoLoadingDays: Int,
)

/** Reuse ratings captured during listing; only supplement missing photo headers while filtering. */
@Composable
internal fun rememberPhotoRatings(camera: NikonCamera?, enabled: Boolean,
    files: List<NikonCamera.FileInfo>, paused: Boolean, useObjectRating: Boolean,
    staConnection: Boolean,
    listLoading: Boolean,
    hasCompletedFileScan: Boolean,
    recentThumbnailReadyDays: Int,
    ratingDays: Int,
    photoLoadingDays: Int,
    appliedPhotoLoadingDays: Int): PhotoRatingScan {
    val generation = camera?.photoRatingGeneration?.collectAsState()?.value ?: 0
    var clearedGeneration by remember(camera) { mutableStateOf<Int?>(null) }
    var previousEnabled by remember(camera) { mutableStateOf<Boolean?>(null) }
    var result by remember(camera, enabled, generation, useObjectRating, staConnection, ratingDays, photoLoadingDays) {
        mutableStateOf(PhotoRatingScan(
            loading = enabled && camera != null,
            waitingForRange = enabled && camera != null,
        ))
    }
    val latestFiles by rememberUpdatedState(files)
    val latestPaused by rememberUpdatedState(paused)
    val latestListLoading by rememberUpdatedState(listLoading)
    val latestScanComplete by rememberUpdatedState(hasCompletedFileScan)
    val latestRecentThumbnailReadyDays by rememberUpdatedState(recentThumbnailReadyDays)
    val latestAppliedPhotoLoadingDays by rememberUpdatedState(appliedPhotoLoadingDays)
    LaunchedEffect(camera, enabled, generation, useObjectRating, staConnection, ratingDays, photoLoadingDays) {
        // Keep diagnostics opt-in with the filter itself. When disabled, note() returns before
        // locking or retaining any protocol text.
        RatingDiagnostics.setEnabled(enabled)
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
        // Thumbnail/header loading may have captured passive ratings while the filter was off.
        // Enabling the filter is an explicit fresh-snapshot request, so discard those values
        // before building the pending set. The generation restart is guarded by previousEnabled.
        if (enteringEnabled) {
            camera.invalidatePhotoRatings()
            // The generation change restarts this effect. Do not issue the first read from
            // this obsolete generation while its replacement is being scheduled.
            return@LaunchedEffect
        }
        val ratings = HashMap<Int, Int?>()
        var scanStarted = false
        // Before starting, observe one coherent authoritative catalog snapshot. After starting,
        // this scan owns a fixed request list until the user disables/re-enables or changes range.
        snapshotFlow {
            if (scanStarted) null else RatingScanInput(
                files = latestFiles,
                paused = latestPaused,
                listLoading = latestListLoading,
                scanComplete = latestScanComplete,
                thumbnailReadyDays = latestRecentThumbnailReadyDays,
                appliedPhotoLoadingDays = latestAppliedPhotoLoadingDays,
            )
        }.collect { input ->
            if (input == null || scanStarted) return@collect
            val pause = input.paused
            val plan = planPhotoRatings(
                files = input.files,
                ratingDays = ratingDays,
                photoLoadingDays = photoLoadingDays,
                appliedPhotoLoadingDays = input.appliedPhotoLoadingDays,
                hasCompletedFileScan = input.scanComplete,
                isLoadingFiles = input.listLoading,
                recentThumbnailReadyDays = input.thumbnailReadyDays,
            )
            if (!plan.ready) {
                result = PhotoRatingScan(
                    loading = true,
                    total = plan.files.size,
                    waitingForRange = true,
                )
                return@collect
            }
            val eligiblePhotos = plan.files
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
                    completed = visible.size,
                    total = eligiblePhotos.size,
                    complete = complete,
                )
            }
            val pending = uniqueSources.filterNot { ratings.containsKey(it.handle) }
            ratingDiagnostic("scan start generation=$generation files=${eligiblePhotos.size} sources=${uniqueSources.size} " +
                    "cached=${uniqueSources.size - pending.size} pending=${pending.size} " +
                    "cachedOrigins=${cachedOrigins.entries.joinToString(",") { "${it.key}:${it.value}" }} " +
                    "rangeDays=${plan.effectiveDays} " +
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
