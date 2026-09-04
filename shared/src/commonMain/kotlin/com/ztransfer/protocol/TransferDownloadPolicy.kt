package com.ztransfer.protocol

const val TRANSFER_RESUME_CHUNK_SIZE: Long = 4L * 1024 * 1024
const val TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD: Long = 128L * 1024 * 1024
const val TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE: Long = 64L * 1024 * 1024
const val TRANSFER_LARGE_FILE_THRESHOLD: Long = 512L * 1024 * 1024
const val TRANSFER_LARGE_FILE_CHUNK_SIZE: Long = 32L * 1024 * 1024

fun isKnownTransferSize(size: Long): Boolean =
    size > 0L && size != PtpConstants.SIZE_UNKNOWN

fun shouldQueryTransferSize(declaredSize: Long): Boolean =
    !isKnownTransferSize(declaredSize)

fun resolvedTransferSize(declaredSize: Long, queriedSize: Long?): Long =
    if (shouldQueryTransferSize(declaredSize) && queriedSize != null && queriedSize > 0L) {
        queriedSize
    } else {
        declaredSize
    }

fun shouldUsePartialObjectDownload(
    partialObjectSupported: Boolean?,
    effectiveSize: Long,
    resumeOffset: Long = 0L,
    isUsbConnection: Boolean = false,
    preferHighThroughput: Boolean = false,
    forcePartial: Boolean = false,
): Boolean = partialObjectSupported != false &&
    isKnownTransferSize(effectiveSize) &&
    (
        forcePartial ||
            !(isUsbConnection || preferHighThroughput) ||
            resumeOffset > 0L ||
            effectiveSize > TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD
        )

fun downloadChunkSize(
    effectiveSize: Long,
    isUsbConnection: Boolean = false,
    preferHighThroughput: Boolean = false,
): Long =
    if (isUsbConnection || preferHighThroughput) {
        TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE
    } else if (effectiveSize > TRANSFER_LARGE_FILE_THRESHOLD) {
        TRANSFER_LARGE_FILE_CHUNK_SIZE
    } else {
        TRANSFER_RESUME_CHUNK_SIZE
    }

fun endToEndBytesPerSecond(
    transferredBytes: Long,
    elapsedMs: Long,
): Long {
    if (transferredBytes <= 0L || elapsedMs <= 0L) return 0L
    return (transferredBytes.toDouble() * 1_000.0 / elapsedMs.toDouble())
        .toLong()
        .coerceAtLeast(0L)
}

fun transferredBytesThisAttempt(downloaded: Long, resumeOffset: Long): Long =
    (downloaded - resumeOffset).coerceAtLeast(0L)

fun isResumeUnavailable(resumeOffset: Long, usePartialObject: Boolean): Boolean =
    resumeOffset > 0L && !usePartialObject

enum class PartialObjectResponseAction {
    ACCEPT,
    FALLBACK_TO_FULL_OBJECT,
    FAIL,
}

fun classifyPartialObjectResponse(
    responseCode: Int,
    isFirstChunk: Boolean,
    receivedBytes: Long,
    resumeOffset: Long,
): PartialObjectResponseAction = when {
    responseCode == PtpConstants.RESPONSE_OK -> PartialObjectResponseAction.ACCEPT
    isFirstChunk && receivedBytes == 0L && resumeOffset == 0L &&
        responseCode == PtpConstants.OPERATION_NOT_SUPPORTED ->
        PartialObjectResponseAction.FALLBACK_TO_FULL_OBJECT

    else -> PartialObjectResponseAction.FAIL
}

fun isPartialChunkLengthComplete(receivedBytes: Long, declaredBytes: Long): Boolean =
    declaredBytes <= 0L || receivedBytes == declaredBytes

fun hasPartialChunkProgress(receivedBytes: Long): Boolean = receivedBytes > 0L

fun isPartialDownloadComplete(downloadedBytes: Long, effectiveSize: Long): Boolean =
    downloadedBytes == effectiveSize

fun isFullObjectLengthComplete(downloadedBytes: Long, declaredBytes: Long): Boolean =
    declaredBytes <= 0L || declaredBytes == PtpConstants.SIZE_UNKNOWN ||
        downloadedBytes == declaredBytes

enum class ExistingPartAction {
    FINALIZE_COMPLETE_PART,
    RESUME_FROM_PART,
    DISCARD_PART,
}

data class ExistingPartPlan(
    val action: ExistingPartAction,
    val resumeOffset: Long = 0L,
)

/** Decides what to do with a matching partial file without performing platform file I/O. */
fun planExistingPart(
    objectSize: Long,
    partSize: Long,
): ExistingPartPlan {
    val sizeKnown = isKnownTransferSize(objectSize)
    return when {
        sizeKnown && partSize == objectSize -> ExistingPartPlan(
            ExistingPartAction.FINALIZE_COMPLETE_PART,
        )

        partSize >= TRANSFER_RESUME_CHUNK_SIZE &&
            (!sizeKnown || partSize < objectSize) -> ExistingPartPlan(
            action = ExistingPartAction.RESUME_FROM_PART,
            resumeOffset = (partSize / TRANSFER_RESUME_CHUNK_SIZE) *
                TRANSFER_RESUME_CHUNK_SIZE,
        )

        else -> ExistingPartPlan(ExistingPartAction.DISCARD_PART)
    }
}

enum class FailedPartAction {
    KEEP_FOR_RETRY,
    DELETE_BEFORE_FRESH_RETRY,
}

fun failedPartAction(resumeUnavailable: Boolean): FailedPartAction =
    if (resumeUnavailable) {
        FailedPartAction.DELETE_BEFORE_FRESH_RETRY
    } else {
        FailedPartAction.KEEP_FOR_RETRY
    }

enum class TransferFailurePresentation {
    GENERIC,
    CONNECTION_LOST,
    DIRECTORY_INVALID,
    PASSTHROUGH_MESSAGE,
}

private val CONNECTION_FAILURE_MESSAGE_MARKERS = listOf(
    "connection abort",
    "connection reset",
    "broken pipe",
    "socket",
    "econn",
    "etimedout",
    "network is unreachable",
)

/** Platform exceptions are normalized to two flags; localized strings remain platform-owned. */
fun classifyTransferFailurePresentation(
    message: String?,
    isConnectionException: Boolean,
    isDirectoryException: Boolean,
): TransferFailurePresentation {
    if (message == null) return TransferFailurePresentation.GENERIC
    val connectionLost = isConnectionException || CONNECTION_FAILURE_MESSAGE_MARKERS.any { marker ->
        message.contains(marker, ignoreCase = true)
    }
    return when {
        connectionLost -> TransferFailurePresentation.CONNECTION_LOST
        isDirectoryException -> TransferFailurePresentation.DIRECTORY_INVALID
        else -> TransferFailurePresentation.PASSTHROUGH_MESSAGE
    }
}
