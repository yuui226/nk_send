package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.newestCaptureDaysRange

internal val ratingPhotoExtensions = setOf(".jpg", ".jpeg", ".nef", ".nrw", ".mov", ".mp4")

internal data class PhotoRatingPlan(
    val files: List<NikonCamera.FileInfo>,
    val ready: Boolean,
    val effectiveDays: Int,
)

/** One transport-independent boundary for the request list and its progress total. */
internal fun planPhotoRatings(
    files: List<NikonCamera.FileInfo>,
    ratingDays: Int,
    photoLoadingDays: Int,
    appliedPhotoLoadingDays: Int,
    hasCompletedFileScan: Boolean,
    isLoadingFiles: Boolean,
    recentThumbnailReadyDays: Int,
): PhotoRatingPlan {
    // Zero means all. The photo loading range remains the upper bound for rating work.
    val effectiveDays = when {
        ratingDays <= 0 -> photoLoadingDays.coerceAtLeast(0)
        photoLoadingDays <= 0 -> ratingDays
        else -> minOf(ratingDays, photoLoadingDays)
    }
    // The settings flow can arrive before the camera has applied its new catalog range.
    // Never lock the old completed catalog (or advertise its count) during that handoff.
    if (appliedPhotoLoadingDays.coerceAtLeast(0) != photoLoadingDays.coerceAtLeast(0)) {
        return PhotoRatingPlan(files = emptyList(), ready = false, effectiveDays = effectiveDays)
    }
    val photos = files.filter { it.extension in ratingPhotoExtensions }
    // Use the same shooting-day universe as the photo loader/readiness counter, including
    // days containing unsupported formats. Filtering formats first could move the boundary.
    val range = newestCaptureDaysRange(files, effectiveDays)
    val selected = if (effectiveDays == 0) {
        photos
    } else {
        // Object handles and dual-card batches need not arrive in capture-date order.
        if (range == null) emptyList() else photos.filter { range.containsCaptureDate(it.captureDate) }
    }
    val catalogComplete = hasCompletedFileScan && !isLoadingFiles
    val ready = catalogComplete || (effectiveDays > 0 &&
        recentThumbnailReadyDays >= effectiveDays &&
        range != null && files.asSequence()
            .filter { range.containsCaptureDate(it.captureDate) }
            .map { it.captureDate!!.take(8) }.distinct().count() >= effectiveDays)
    return PhotoRatingPlan(
        files = selected,
        ready = ready,
        effectiveDays = effectiveDays,
    )
}
