package com.ztransfer.protocol

const val USB_LIVE_VIEW_WARMUP_MS = 750L
const val USB_LIVE_VIEW_STABLE_FRAMES = 8
const val LIVE_VIEW_READY_TIMEOUT_MS = 4_000L
const val LIVE_VIEW_READY_POLL_DELAY_MS = 20L
const val LIVE_VIEW_BUSY_RETRY_DELAY_MS = 40L
const val LIVE_VIEW_FRAME_ERROR_RETRY_DELAY_MS = 300L
const val LIVE_VIEW_SESSION_RESTART_DELAY_MS = 2_000L
const val LIVE_VIEW_START_FAILURE_RETRY_DELAY_MS = 3_000L

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

data class RemoteCommandRetryResult(
    val responseCode: Int,
    val completedRetries: Int,
)

private suspend fun runRemoteCommandWithRetry(
    retryDelayMs: (responseCode: Int, completedRetries: Int) -> Long?,
    command: suspend () -> Int,
    pause: suspend (Long) -> Unit,
): RemoteCommandRetryResult {
    var responseCode = command()
    var completedRetries = 0
    while (true) {
        val delayMs = retryDelayMs(responseCode, completedRetries) ?: break
        pause(delayMs)
        responseCode = command()
        completedRetries++
    }
    return RemoteCommandRetryResult(responseCode, completedRetries)
}

suspend fun runRemoteBusyCommand(
    command: suspend () -> Int,
    pause: suspend (Long) -> Unit,
): RemoteCommandRetryResult = runRemoteCommandWithRetry(
    retryDelayMs = ::remoteBusyRetryDelayMs,
    command = command,
    pause = pause,
)

suspend fun runLiveViewStartCommand(
    command: suspend () -> Int,
    pause: suspend (Long) -> Unit,
): RemoteCommandRetryResult = runRemoteCommandWithRetry(
    retryDelayMs = ::liveViewStartRetryDelayMs,
    command = command,
    pause = pause,
)

data class LiveViewReadyWaitResult(
    val responseCode: Int,
    val polls: Int,
    val elapsedMs: Long,
)

/**
 * Keeps the camera-compatibility rule used by Android before this migration: once StartLiveView is
 * accepted, DeviceReady is diagnostic and does not reject the session even when it stays busy.
 */
@Suppress("UNUSED_PARAMETER")
fun liveViewSessionAccepted(
    startResult: RemoteCommandRetryResult,
    readyResult: LiveViewReadyWaitResult?,
): Boolean = startResult.responseCode == Lab.OK

/**
 * Waits up to four seconds for DeviceReady. A final non-OK result is diagnostic only: the Android
 * adapter deliberately keeps the pre-migration behavior of treating a successful StartLiveView as
 * an active session.
 */
suspend fun runLiveViewReadyWait(
    startedAtMs: Long,
    currentTimeMs: () -> Long,
    command: suspend () -> Int,
    pause: suspend (Long) -> Unit,
): LiveViewReadyWaitResult {
    var responseCode = Lab.OK
    var polls = 0
    while (currentTimeMs() - startedAtMs < LIVE_VIEW_READY_TIMEOUT_MS) {
        responseCode = command()
        polls++
        if (responseCode != Lab.DEVICE_BUSY) break
        pause(LIVE_VIEW_READY_POLL_DELAY_MS)
    }
    return LiveViewReadyWaitResult(
        responseCode = responseCode,
        polls = polls,
        elapsedMs = currentTimeMs() - startedAtMs,
    )
}

enum class LiveViewFramePollOutcome { SUCCESS, BUSY, ERROR }

data class LiveViewFramePollDecision(
    val errorStreak: Int,
    val retryDelayMs: Long?,
    val restartSession: Boolean,
)

fun liveViewFramePollDecision(
    previousErrorStreak: Int,
    outcome: LiveViewFramePollOutcome,
): LiveViewFramePollDecision = when (outcome) {
    LiveViewFramePollOutcome.SUCCESS -> LiveViewFramePollDecision(
        errorStreak = 0,
        retryDelayMs = null,
        restartSession = false,
    )
    LiveViewFramePollOutcome.BUSY -> LiveViewFramePollDecision(
        errorStreak = previousErrorStreak,
        retryDelayMs = LIVE_VIEW_BUSY_RETRY_DELAY_MS,
        restartSession = false,
    )
    LiveViewFramePollOutcome.ERROR -> {
        val errorStreak = previousErrorStreak + 1
        LiveViewFramePollDecision(
            errorStreak = errorStreak,
            retryDelayMs = LIVE_VIEW_FRAME_ERROR_RETRY_DELAY_MS.takeIf { errorStreak < 3 },
            restartSession = errorStreak >= 3,
        )
    }
}

fun liveViewIsStableAfterSuccessfulFrames(
    connectionType: CameraConnectionType,
    successfulFrames: Int,
): Boolean = connectionType != CameraConnectionType.USB ||
    successfulFrames >= USB_LIVE_VIEW_STABLE_FRAMES

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
    rcMovieRecordingEvent(eventCode) == RcMovieRecordingEvent.FINISHED

class RcPendingCaptureConfirmation(
    val awaitObjectHandle: suspend () -> Long?,
    val cancel: () -> Unit,
)

data class RcCaptureResult(
    val responseCode: Int,
    val objectHandle: Long?,
)

/**
 * Creates the one-shot ObjectAdded waiter before invoking [capture]. The adapter owns the actual
 * subscription semantics and must convert command exceptions to a response code before returning.
 */
suspend fun runRemoteCapture(
    armConfirmation: () -> RcPendingCaptureConfirmation,
    capture: suspend () -> Int,
): RcCaptureResult {
    val confirmation = armConfirmation()
    val responseCode = capture()
    if (responseCode != Lab.OK) {
        confirmation.cancel()
        return RcCaptureResult(responseCode, null)
    }
    return RcCaptureResult(responseCode, confirmation.awaitObjectHandle())
}
