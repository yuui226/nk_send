package com.ztransfer.protocol

const val USB_LIVE_VIEW_WARMUP_MS = 750L
const val USB_LIVE_VIEW_STABLE_FRAMES = 8

fun liveViewWarmupRemainingMs(
    connectionType: CameraConnectionType,
    readyAtElapsedMs: Long,
    nowElapsedMs: Long,
): Long {
    if (connectionType != CameraConnectionType.USB || readyAtElapsedMs <= 0L) return 0L
    return (readyAtElapsedMs + USB_LIVE_VIEW_WARMUP_MS - nowElapsedMs).coerceAtLeast(0L)
}

fun shouldPollMovieModeDuringLiveViewRecovery(
    initialLoaded: Boolean,
    liveViewStable: Boolean,
    cameraBusy: Boolean,
): Boolean = initialLoaded && !liveViewStable && !cameraBusy

fun shouldPrepareUsbMovieSessionForRecord(
    connectionType: CameraConnectionType,
    remoteControlModeSet: Boolean,
): Boolean = connectionType == CameraConnectionType.USB && !remoteControlModeSet

fun shouldReturnUsbMovieSessionToStandby(
    connectionType: CameraConnectionType,
    remoteControlModeSet: Boolean,
): Boolean = connectionType == CameraConnectionType.USB && remoteControlModeSet

/**
 * Drops the startup property backlog or de-duplicates steady-state logical properties while
 * preserving every non-property event and the first concrete property event in original order.
 */
fun coalesceRemoteEvents(
    events: List<Pair<Int, Long>>,
    suppressPropertyChanges: Boolean,
): List<Pair<Int, Long>> = buildList {
    val changedProps = mutableSetOf<Int>()
    for (event in events) {
        if (event.first != Lab.EVT_DEVICE_PROP_CHANGED) {
            add(event)
            continue
        }
        if (suppressPropertyChanges) continue
        val canonicalProp = rcCanonicalExposureProp(event.second.toInt())
        if (changedProps.add(canonicalProp)) add(event)
    }
}

fun findLiveViewJpegStart(data: ByteArray): Int {
    for (index in 0 until data.size - 2) {
        if (
            data[index] == 0xFF.toByte() &&
            data[index + 1] == 0xD8.toByte() &&
            data[index + 2] == 0xFF.toByte()
        ) {
            return index
        }
    }
    return -1
}

fun preferredLiveViewImageOperation(advertisedOperations: Collection<Int>?): Int =
    if (advertisedOperations?.contains(Lab.NK_GET_LIVE_VIEW_IMG_EX) == true) {
        Lab.NK_GET_LIVE_VIEW_IMG_EX
    } else {
        Lab.NK_GET_LIVE_VIEW_IMG
    }

data class LiveViewEnhancedFrameDecision(
    val failureCount: Int,
    val fallbackToBasic: Boolean,
)

/** Preserves the two-consecutive-failure downgrade rule for Nikon enhanced Live View frames. */
fun liveViewEnhancedFrameDecision(
    operation: Int,
    responseCode: Int,
    jpegFound: Boolean,
    previousFailureCount: Int,
): LiveViewEnhancedFrameDecision {
    if (operation != Lab.NK_GET_LIVE_VIEW_IMG_EX) {
        return LiveViewEnhancedFrameDecision(previousFailureCount, fallbackToBasic = false)
    }
    if (responseCode == Lab.OK && jpegFound) {
        return LiveViewEnhancedFrameDecision(0, fallbackToBasic = false)
    }
    val failure =
        (responseCode != Lab.OK &&
            responseCode != Lab.DEVICE_BUSY &&
            responseCode != Lab.NK_NOT_LIVE_VIEW) ||
            (responseCode == Lab.OK && !jpegFound)
    if (!failure) {
        return LiveViewEnhancedFrameDecision(previousFailureCount, fallbackToBasic = false)
    }
    val failureCount = if (responseCode == PtpConstants.OPERATION_NOT_SUPPORTED) {
        2
    } else {
        previousFailureCount + 1
    }
    return LiveViewEnhancedFrameDecision(
        failureCount = failureCount,
        fallbackToBasic = failureCount >= 2,
    )
}

/** Completed retry count starts at zero after the initial command. */
fun remoteBusyRetryDelayMs(responseCode: Int, completedRetries: Int): Long? =
    if (responseCode == Lab.DEVICE_BUSY && completedRetries < 5) 200L else null

/** Live View start also retries Nikon InvalidStatus, using its original longer delay. */
fun liveViewStartRetryDelayMs(responseCode: Int, completedRetries: Int): Long? =
    if (
        (responseCode == Lab.DEVICE_BUSY || responseCode == Lab.NK_INVALID_STATUS) &&
        completedRetries < 5
    ) {
        300L
    } else {
        null
    }

fun isRemoteCaptureCompletionEvent(eventCode: Int): Boolean =
    eventCode == Lab.EVT_OBJECT_ADDED || eventCode == Lab.EVT_OBJECT_ADDED_SDRAM

fun isRemoteMovieCompletionEvent(eventCode: Int): Boolean =
    eventCode == Lab.EVT_NK_MOVIE_REC_COMPLETE ||
        eventCode == Lab.EVT_NK_MOVIE_REC_INTERRUPTED
