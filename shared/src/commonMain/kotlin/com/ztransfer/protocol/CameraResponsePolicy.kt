package com.ztransfer.protocol

/**
 * FHD capability evidence. Busy, stale handles, empty data and vendor errors remain recoverable;
 * only an explicit unsupported response may permanently disable the capability.
 */
enum class FhdResponseDisposition {
    SUCCESS,
    TRANSIENT_FAILURE,
    UNSUPPORTED,
}

fun classifyFhdResponse(
    responseCode: Int,
    hasPayload: Boolean,
): FhdResponseDisposition = when {
    responseCode == PtpConstants.RESPONSE_OK && hasPayload -> FhdResponseDisposition.SUCCESS
    responseCode == PtpConstants.OPERATION_NOT_SUPPORTED -> FhdResponseDisposition.UNSUPPORTED
    else -> FhdResponseDisposition.TRANSIENT_FAILURE
}

fun updateFhdSupport(
    current: Boolean?,
    disposition: FhdResponseDisposition,
): Boolean? = when (disposition) {
    FhdResponseDisposition.SUCCESS -> true
    FhdResponseDisposition.UNSUPPORTED -> if (current == true) true else false
    FhdResponseDisposition.TRANSIENT_FAILURE -> current
}
