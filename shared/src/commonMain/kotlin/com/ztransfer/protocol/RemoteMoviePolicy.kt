package com.ztransfer.protocol

data class RcMovieStartResult(
    val responseCode: Int,
    val prohibitCondition: Long?,
    val prohibitExtendedResponse: Int? = null,
    val applicationModeResponse: Int? = null,
    val applicationModePropertyResponse: Int? = null,
    val startCommandResponse: Int? = responseCode,
)

enum class RcMovieRecordingEvent { STARTED, FINISHED, OTHER }

const val REMOTE_MOVIE_LATE_START_WINDOW_MS = 2_000L

fun rcMovieRecordingEvent(eventCode: Int): RcMovieRecordingEvent = when (eventCode) {
    Lab.EVT_NK_MOVIE_REC_STARTED -> RcMovieRecordingEvent.STARTED
    Lab.EVT_NK_MOVIE_REC_COMPLETE, Lab.EVT_NK_MOVIE_REC_INTERRUPTED ->
        RcMovieRecordingEvent.FINISHED
    else -> RcMovieRecordingEvent.OTHER
}

fun rcRecordingAfterMovieEvent(
    recording: Boolean,
    eventCode: Int,
    eventTimeMs: Long,
    lastStopCommandAtMs: Long,
): Boolean = when (rcMovieRecordingEvent(eventCode)) {
    RcMovieRecordingEvent.STARTED ->
        if (eventTimeMs - lastStopCommandAtMs > REMOTE_MOVIE_LATE_START_WINDOW_MS) true else recording
    RcMovieRecordingEvent.FINISHED -> false
    RcMovieRecordingEvent.OTHER -> recording
}

fun shouldAdoptMovieRecording(result: RcMovieStartResult?): Boolean =
    result?.responseCode == Lab.OK || movieProhibitIndicatesRecording(result?.prohibitCondition)

fun movieStopNeedsFinalizationWait(
    applicationPropertySet: Boolean,
    applicationOperationSet: Boolean,
): Boolean = applicationPropertySet || applicationOperationSet

fun RcMovieStartResult.diagnosticSummary(): String = buildString {
    append("result=").append(responseCode.rcHex4())
    append(" startOp=")
    append(startCommandResponse?.rcHex4() ?: "not-sent")
    prohibitCondition?.let { append(" prohibit=").append(it.rcHex8()) }
    prohibitExtendedResponse?.let { append(" preEx=").append(it.rcHex4()) }
    applicationModeResponse?.let { append(" appOp=").append(it.rcHex4()) }
    applicationModePropertyResponse?.let { append(" appProp=").append(it.rcHex4()) }
}

private fun Int.rcHex4(): String =
    "0x" + (this and 0xFFFF).toString(16).uppercase().padStart(4, '0')

private fun Long.rcHex8(): String =
    "0x" + toULong().toString(16).uppercase().padStart(8, '0')

private const val MOVIE_PROHIBIT_NO_CARD = 1L shl 0
private const val MOVIE_PROHIBIT_CARD_ERROR = 1L shl 1
private const val MOVIE_PROHIBIT_CARD_UNFORMATTED = 1L shl 2
private const val MOVIE_PROHIBIT_CARD_FULL = 1L shl 3
private const val MOVIE_PROHIBIT_BUFFER_PENDING = 1L shl 9
private const val MOVIE_PROHIBIT_ALREADY_RECORDING = 1L shl 10
private const val MOVIE_PROHIBIT_CARD_PROTECTED = 1L shl 11
private const val MOVIE_PROHIBIT_ENLARGED_LIVE_VIEW = 1L shl 12
private const val MOVIE_PROHIBIT_NOT_APPLICATION_MODE = 1L shl 14
private const val MOVIE_PROHIBIT_STORAGE_MASK =
    MOVIE_PROHIBIT_NO_CARD or
        MOVIE_PROHIBIT_CARD_ERROR or
        MOVIE_PROHIBIT_CARD_UNFORMATTED or
        MOVIE_PROHIBIT_CARD_FULL or
        MOVIE_PROHIBIT_CARD_PROTECTED
private const val MOVIE_PROHIBIT_RESTARTABLE_MASK =
    MOVIE_PROHIBIT_ENLARGED_LIVE_VIEW or MOVIE_PROHIBIT_NOT_APPLICATION_MODE

fun movieProhibitIndicatesRecording(prohibitCondition: Long?): Boolean =
    prohibitCondition?.let { it and MOVIE_PROHIBIT_ALREADY_RECORDING != 0L } == true

fun movieProhibitRequiresApplicationMode(prohibitCondition: Long?): Boolean =
    prohibitCondition?.let { it and MOVIE_PROHIBIT_NOT_APPLICATION_MODE != 0L } == true

fun shouldFallbackToApplicationModeProperty(applicationModeResponse: Int): Boolean =
    applicationModeResponse == PtpConstants.OPERATION_NOT_SUPPORTED

/**
 * 开录失败后是否值得在已进入应用模式的前提下重建一次 Live View 再试。
 * 存储卡、写缓冲和已在录像不会被重启掩盖；有明确禁止位时只接受 LV/应用模式
 * 两类可恢复状态。无禁止信息时，仅 InvalidStatus/持续 Busy 允许一次恢复。
 */
fun movieStartNeedsLiveViewRestart(
    responseCode: Int,
    prohibitCondition: Long?
): Boolean {
    if (responseCode == Lab.OK) return false
    if (prohibitCondition != null && prohibitCondition and MOVIE_PROHIBIT_STORAGE_MASK != 0L) {
        return false
    }
    if (prohibitCondition != null &&
        prohibitCondition and
        (MOVIE_PROHIBIT_BUFFER_PENDING or MOVIE_PROHIBIT_ALREADY_RECORDING) != 0L
    ) {
        return false
    }
    if (prohibitCondition != null && prohibitCondition != 0L) {
        return prohibitCondition and MOVIE_PROHIBIT_RESTARTABLE_MASK != 0L
    }
    return responseCode == 0xA004 || responseCode == Lab.DEVICE_BUSY
}
