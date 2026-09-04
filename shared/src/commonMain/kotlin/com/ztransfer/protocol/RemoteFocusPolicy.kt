package com.ztransfer.protocol

/** Current focus mode reported by the camera. */
data class RcFocusMode(
    val label: String,
    val manual: Boolean,
    val prop: Int,
    val raw: Long,
)

/** AF drive result; [polls] is the number of DeviceReady queries. */
data class RcAfResult(
    val responseCode: Int,
    val polls: Int,
    val elapsedMs: Long,
    val timedOut: Boolean,
)

data class RcTapFocusResult(
    val endTrackingResponseCode: Int?,
    /** Null when StartTracking accepted the coordinates directly or old tracking could not end. */
    val moveResponseCode: Int?,
    val trackingResponseCode: Int?,
    val trackingStarted: Boolean,
    val afResult: RcAfResult?,
)

/** Result of the atomic tracking/move + AF-start segment, before DeviceReady polling. */
data class RcTapFocusStartResult(
    val moveResponseCode: Int?,
    val trackingResponseCode: Int?,
    val afStartResponseCode: Int?,
)

fun rcFocusModeCandidateProps(): IntArray =
    intArrayOf(Lab.PROP_FOCUS_MODE, Lab.PROP_NK_AF_MODE)

/** Only scalar widths accepted by the pre-migration Android focus-mode reader. */
fun rcDecodeFocusModeRaw(data: ByteArray): Long? {
    if (data.size !in setOf(1, 2, 4, 8)) return null
    return data.indices.fold(0L) { value, index ->
        value or ((data[index].toLong() and 0xFFL) shl (8 * index))
    }
}

/** Maps only confirmed standard/Nikon focus enums; unknown raw values remain diagnostic-only. */
fun rcFocusModeFromRaw(prop: Int, raw: Long): RcFocusMode? {
    if (prop != Lab.PROP_FOCUS_MODE && prop != Lab.PROP_NK_AF_MODE) return null
    val label = (rcDetailedValuePresentation(prop, raw) as? RcValuePresentation.Text)?.value
        ?: return null
    if (label.startsWith("0x")) return null
    return RcFocusMode(
        label = label,
        manual = prop == Lab.PROP_FOCUS_MODE && raw == 1L,
        prop = prop,
        raw = raw,
    )
}

fun rcTimedOutAfResult(startedAt: Long, now: Long, polls: Int = 0) = RcAfResult(
    responseCode = Lab.DEVICE_BUSY,
    polls = polls,
    elapsedMs = now - startedAt,
    timedOut = true,
)

/**
 * Starts subject tracking when supported, otherwise performs the exact one-shot AF fallback.
 * Camera I/O and the 80 ms adoption pause are injected so Android and iOS share one ordering rule.
 */
suspend fun runTapFocusStart(
    trackingX: Int,
    trackingY: Int,
    focusX: Int,
    focusY: Int,
    tryTracking: Boolean,
    command: suspend (code: Int, params: IntArray) -> Int?,
    pause: suspend (Long) -> Unit,
): RcTapFocusStartResult {
    if (tryTracking) {
        val trackingResponse = command(
            Lab.NK_START_TRACKING,
            intArrayOf(trackingX, trackingY),
        ) ?: return RcTapFocusStartResult(null, Lab.DEVICE_BUSY, null)
        if (trackingResponse == Lab.OK) {
            pause(80L)
            return RcTapFocusStartResult(
                moveResponseCode = null,
                trackingResponseCode = trackingResponse,
                afStartResponseCode = command(Lab.NK_AF_DRIVE, intArrayOf()),
            )
        }
        if (trackingResponse != PtpConstants.OPERATION_NOT_SUPPORTED) {
            return RcTapFocusStartResult(null, trackingResponse, null)
        }
    }

    val trackingUnsupported = if (tryTracking) {
        PtpConstants.OPERATION_NOT_SUPPORTED
    } else {
        null
    }
    val moveResponse = command(
        Lab.NK_CHANGE_AF_AREA,
        intArrayOf(focusX, focusY),
    ) ?: return RcTapFocusStartResult(Lab.DEVICE_BUSY, trackingUnsupported, null)
    if (moveResponse != Lab.OK) {
        return RcTapFocusStartResult(moveResponse, trackingUnsupported, null)
    }

    pause(80L)
    return RcTapFocusStartResult(
        moveResponseCode = moveResponse,
        trackingResponseCode = trackingUnsupported,
        afStartResponseCode = command(Lab.NK_AF_DRIVE, intArrayOf()),
    )
}

/** Continues a previously started AF by polling DeviceReady with the shared deadline semantics. */
suspend fun runAfReadyWait(
    startedAt: Long,
    deadlineMs: Long,
    startResponseCode: Int,
    elapsedRealtime: () -> Long,
    command: suspend (Int) -> Int?,
    pause: suspend (Long) -> Unit,
): RcAfResult {
    if (startResponseCode != Lab.OK) {
        return RcAfResult(startResponseCode, 0, elapsedRealtime() - startedAt, false)
    }

    var polls = 0
    while (true) {
        if (elapsedRealtime() >= deadlineMs) {
            return rcTimedOutAfResult(startedAt, elapsedRealtime(), polls)
        }
        val readyResponse = command(Lab.NK_DEVICE_READY)
            ?: return rcTimedOutAfResult(startedAt, elapsedRealtime(), polls)
        polls++
        if (readyResponse != Lab.DEVICE_BUSY) {
            return RcAfResult(
                responseCode = readyResponse,
                polls = polls,
                elapsedMs = elapsedRealtime() - startedAt,
                timedOut = false,
            )
        }
        if (elapsedRealtime() >= deadlineMs) {
            return rcTimedOutAfResult(startedAt, elapsedRealtime(), polls)
        }
        pause(150L)
    }
}

/** Sends AfDrive exactly once, then polls DeviceReady until a non-busy response or the deadline. */
suspend fun runAfDriveAndWait(
    startedAt: Long,
    deadlineMs: Long,
    elapsedRealtime: () -> Long,
    command: suspend (Int) -> Int?,
    pause: suspend (Long) -> Unit,
): RcAfResult {
    if (elapsedRealtime() >= deadlineMs) {
        return rcTimedOutAfResult(startedAt, elapsedRealtime())
    }
    val startResponse = command(Lab.NK_AF_DRIVE)
        ?: return rcTimedOutAfResult(startedAt, elapsedRealtime())
    return runAfReadyWait(
        startedAt = startedAt,
        deadlineMs = deadlineMs,
        startResponseCode = startResponse,
        elapsedRealtime = elapsedRealtime,
        command = command,
        pause = pause,
    )
}

/** Camera-frame motion is evidence only after three frames and roughly 1.5% frame travel. */
fun trackingMotionDetected(frames: List<LiveViewFocusFrame>): Boolean {
    if (frames.size < 3) return false
    val xRange = frames.maxOf { it.centerX } - frames.minOf { it.centerX }
    val yRange = frames.maxOf { it.centerY } - frames.minOf { it.centerY }
    return xRange >= 0.015f || yRange >= 0.015f
}
