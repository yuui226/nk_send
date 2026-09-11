package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TransferDownloadPolicyTest {
    @Test
    fun transferConstantsKeepExistingByteValuesAndResumeAlignment() {
        assertEquals(4L * 1024 * 1024, TRANSFER_RESUME_CHUNK_SIZE)
        assertEquals(128L * 1024 * 1024, TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD)
        assertEquals(64L * 1024 * 1024, TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE)
        assertEquals(512L * 1024 * 1024, TRANSFER_LARGE_FILE_THRESHOLD)
        assertEquals(32L * 1024 * 1024, TRANSFER_LARGE_FILE_CHUNK_SIZE)
        assertEquals(0L, TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE % TRANSFER_RESUME_CHUNK_SIZE)
        assertEquals(0L, TRANSFER_LARGE_FILE_CHUNK_SIZE % TRANSFER_RESUME_CHUNK_SIZE)
    }

    @Test
    fun onlyPositiveNonSentinelSizesAreKnown() {
        assertFalse(isKnownTransferSize(-1L))
        assertFalse(isKnownTransferSize(0L))
        assertFalse(isKnownTransferSize(PtpConstants.SIZE_UNKNOWN))
        assertTrue(isKnownTransferSize(1L))
        assertTrue(isKnownTransferSize(Long.MAX_VALUE))
    }

    @Test
    fun queriedSizeReplacesOnlyAnUnknownDeclarationWithAPositiveResult() {
        val overFourGiB = 4_300_000_000L
        assertFalse(shouldQueryTransferSize(123L))
        assertEquals(123L, resolvedTransferSize(123L, overFourGiB))
        assertTrue(shouldQueryTransferSize(PtpConstants.SIZE_UNKNOWN))
        assertEquals(overFourGiB, resolvedTransferSize(PtpConstants.SIZE_UNKNOWN, overFourGiB))
        assertEquals(456L, resolvedTransferSize(0L, 456L))
        assertEquals(456L, resolvedTransferSize(-1L, 456L))
        assertEquals(PtpConstants.SIZE_UNKNOWN, resolvedTransferSize(PtpConstants.SIZE_UNKNOWN, null))
        assertEquals(PtpConstants.SIZE_UNKNOWN, resolvedTransferSize(PtpConstants.SIZE_UNKNOWN, 0L))
    }

    @Test
    fun wifiKnownSizesPreferPartialObjectUnlessCameraRejectedIt() {
        assertTrue(shouldUsePartialObjectDownload(null, 1L))
        assertTrue(shouldUsePartialObjectDownload(true, 48L * 1024 * 1024))
        assertFalse(shouldUsePartialObjectDownload(false, 48L * 1024 * 1024))
        assertFalse(shouldUsePartialObjectDownload(null, PtpConstants.SIZE_UNKNOWN))
        assertFalse(shouldUsePartialObjectDownload(null, 0L))
        assertFalse(
            shouldUsePartialObjectDownload(
                partialObjectSupported = false,
                effectiveSize = 48L * 1024 * 1024,
                forcePartial = true,
            ),
        )
    }

    @Test
    fun highThroughputUsesFullObjectOnlyForOrdinaryFreshFilesAtOrBelowThreshold() {
        val ordinary = 26L * 1024 * 1024
        assertFalse(shouldUsePartialObjectDownload(null, ordinary, isUsbConnection = true))
        assertFalse(
            shouldUsePartialObjectDownload(
                null,
                TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD,
                isUsbConnection = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                null,
                TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD + 1L,
                isUsbConnection = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                true,
                ordinary,
                resumeOffset = TRANSFER_RESUME_CHUNK_SIZE,
                isUsbConnection = true,
            ),
        )
        assertFalse(
            shouldUsePartialObjectDownload(
                null,
                ordinary,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                true,
                ordinary,
                resumeOffset = TRANSFER_RESUME_CHUNK_SIZE,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                true,
                TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD + 1L,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                true,
                ordinary,
                preferHighThroughput = true,
                forcePartial = true,
            ),
        )
        assertFalse(
            shouldUsePartialObjectDownload(
                partialObjectSupported = null,
                effectiveSize = PtpConstants.SIZE_UNKNOWN,
                forcePartial = true,
            ),
        )
    }

    @Test
    fun chunkSelectionKeepsExactThresholdAndTransportRules() {
        assertEquals(
            TRANSFER_RESUME_CHUNK_SIZE,
            downloadChunkSize(TRANSFER_LARGE_FILE_THRESHOLD),
        )
        assertEquals(
            TRANSFER_LARGE_FILE_CHUNK_SIZE,
            downloadChunkSize(TRANSFER_LARGE_FILE_THRESHOLD + 1L),
        )
        assertEquals(
            TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(26L * 1024 * 1024, isUsbConnection = true),
        )
        assertEquals(
            TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(1L * 1024 * 1024 * 1024, isUsbConnection = true),
        )
        assertEquals(
            TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(26L * 1024 * 1024, preferHighThroughput = true),
        )
        assertEquals(
            TRANSFER_RESUME_CHUNK_SIZE,
            downloadChunkSize(26L * 1024 * 1024, isUsbConnection = false),
        )
    }

    @Test
    fun exactKnownPartIsFinalizedWithoutAnotherDownload() {
        assertEquals(
            ExistingPartPlan(ExistingPartAction.FINALIZE_COMPLETE_PART),
            planExistingPart(
                objectSize = 12L * 1024 * 1024,
                partSize = 12L * 1024 * 1024,
            ),
        )
    }

    @Test
    fun resumablePartRoundsDownToTheLastCompleteCheckpoint() {
        assertEquals(
            ExistingPartPlan(
                ExistingPartAction.RESUME_FROM_PART,
                resumeOffset = 8L * 1024 * 1024,
            ),
            planExistingPart(
                objectSize = 20L * 1024 * 1024,
                partSize = 11L * 1024 * 1024,
            ),
        )
        assertEquals(
            ExistingPartPlan(
                ExistingPartAction.RESUME_FROM_PART,
                resumeOffset = TRANSFER_RESUME_CHUNK_SIZE,
            ),
            planExistingPart(
                objectSize = PtpConstants.SIZE_UNKNOWN,
                partSize = TRANSFER_RESUME_CHUNK_SIZE + 17L,
            ),
        )
    }

    @Test
    fun unsafeOrTooSmallPartIsDiscarded() {
        val discard = ExistingPartPlan(ExistingPartAction.DISCARD_PART)
        val objectSize = 20L * 1024 * 1024
        assertEquals(discard, planExistingPart(objectSize, TRANSFER_RESUME_CHUNK_SIZE - 1L))
        assertEquals(discard, planExistingPart(objectSize, objectSize + 1L))
        assertEquals(discard, planExistingPart(0L, 0L))
    }

    @Test
    fun unknownOrNonPositiveObjectSizeCanResumeButNeverFinalize() {
        val sentinelPart = planExistingPart(
            objectSize = PtpConstants.SIZE_UNKNOWN,
            partSize = PtpConstants.SIZE_UNKNOWN,
        )
        assertEquals(ExistingPartAction.RESUME_FROM_PART, sentinelPart.action)
        assertEquals(
            (PtpConstants.SIZE_UNKNOWN / TRANSFER_RESUME_CHUNK_SIZE) *
                TRANSFER_RESUME_CHUNK_SIZE,
            sentinelPart.resumeOffset,
        )
        assertEquals(
            ExistingPartAction.RESUME_FROM_PART,
            planExistingPart(0L, TRANSFER_RESUME_CHUNK_SIZE).action,
        )
        assertEquals(
            ExistingPartAction.RESUME_FROM_PART,
            planExistingPart(-1L, TRANSFER_RESUME_CHUNK_SIZE).action,
        )
    }

    @Test
    fun resumedStreamIsRejectedWhenPartialObjectCannotBeUsed() {
        assertFalse(isResumeUnavailable(0L, false))
        assertFalse(isResumeUnavailable(0L, true))
        assertTrue(isResumeUnavailable(TRANSFER_RESUME_CHUNK_SIZE, false))
        assertFalse(isResumeUnavailable(TRANSFER_RESUME_CHUNK_SIZE, true))
    }

    @Test
    fun onlyAZeroByteFreshFirstUnsupportedResponseFallsBackToFullObject() {
        val unsupported = PtpConstants.OPERATION_NOT_SUPPORTED
        assertEquals(
            PartialObjectResponseAction.FALLBACK_TO_FULL_OBJECT,
            classifyPartialObjectResponse(unsupported, true, 0L, 0L),
        )
        assertEquals(
            PartialObjectResponseAction.FAIL,
            classifyPartialObjectResponse(unsupported, false, 0L, 0L),
        )
        assertEquals(
            PartialObjectResponseAction.FAIL,
            classifyPartialObjectResponse(unsupported, true, 1L, 0L),
        )
        assertEquals(
            PartialObjectResponseAction.FAIL,
            classifyPartialObjectResponse(
                unsupported,
                true,
                0L,
                TRANSFER_RESUME_CHUNK_SIZE,
            ),
        )
        assertEquals(
            PartialObjectResponseAction.FAIL,
            classifyPartialObjectResponse(PtpConstants.DEVICE_BUSY, true, 0L, 0L),
        )
        assertEquals(
            PartialObjectResponseAction.ACCEPT,
            classifyPartialObjectResponse(PtpConstants.RESPONSE_OK, true, 0L, 0L),
        )
    }

    @Test
    fun partialAndFullLengthRulesPreserveShortReadAndUnknownBehavior() {
        assertTrue(isPartialChunkLengthComplete(100L, 100L))
        assertFalse(isPartialChunkLengthComplete(99L, 100L))
        assertTrue(isPartialChunkLengthComplete(99L, 0L))
        assertFalse(hasPartialChunkProgress(0L))
        assertTrue(hasPartialChunkProgress(1L))
        assertTrue(isPartialDownloadComplete(1_000L, 1_000L))
        assertFalse(isPartialDownloadComplete(999L, 1_000L))

        assertTrue(isFullObjectLengthComplete(1_000L, 1_000L))
        assertFalse(isFullObjectLengthComplete(999L, 1_000L))
        assertTrue(isFullObjectLengthComplete(999L, 0L))
        assertTrue(isFullObjectLengthComplete(999L, -1L))
        assertTrue(isFullObjectLengthComplete(999L, PtpConstants.SIZE_UNKNOWN))
    }

    @Test
    fun onlyResumeUnavailableFailureDeletesThePartBeforeRetry() {
        assertEquals(
            FailedPartAction.DELETE_BEFORE_FRESH_RETRY,
            failedPartAction(resumeUnavailable = true),
        )
        assertEquals(
            FailedPartAction.KEEP_FOR_RETRY,
            failedPartAction(resumeUnavailable = false),
        )
    }

    @Test
    fun failurePresentationKeepsPlatformAndMessagePrecedence() {
        assertEquals(
            TransferFailurePresentation.GENERIC,
            classifyTransferFailurePresentation(null, true, true),
        )
        assertEquals(
            TransferFailurePresentation.CONNECTION_LOST,
            classifyTransferFailurePresentation("disk full", true, false),
        )
        listOf(
            "Connection Abort",
            "CONNECTION RESET",
            "Broken Pipe",
            "socket closed",
            "ECONNREFUSED",
            "ETIMEDOUT",
            "Network Is Unreachable",
        ).forEach { message ->
            assertEquals(
                TransferFailurePresentation.CONNECTION_LOST,
                classifyTransferFailurePresentation(message, false, false),
                message,
            )
        }
        assertEquals(
            TransferFailurePresentation.CONNECTION_LOST,
            classifyTransferFailurePresentation("socket", false, true),
        )
        assertEquals(
            TransferFailurePresentation.DIRECTORY_INVALID,
            classifyTransferFailurePresentation("missing", false, true),
        )
        assertEquals(
            TransferFailurePresentation.PASSTHROUGH_MESSAGE,
            classifyTransferFailurePresentation("disk full", false, false),
        )
        assertEquals(
            TransferFailurePresentation.PASSTHROUGH_MESSAGE,
            classifyTransferFailurePresentation("", false, false),
        )
    }

    @Test
    fun speedMatchesTheEndToEndDuration() {
        assertEquals(
            2_478_452L,
            endToEndBytesPerSecond(
                transferredBytes = 26L * 1024L * 1024L,
                elapsedMs = 11_000L,
            ),
        )
        assertEquals(4L * 1024L * 1024L, endToEndBytesPerSecond(8L * 1024L * 1024L, 2_000L))
        assertEquals(0L, endToEndBytesPerSecond(0L, 1_000L))
        assertEquals(0L, endToEndBytesPerSecond(1_024L, 0L))
    }

    @Test
    fun resumedTransferCountsOnlyBytesReadByTheCurrentAttempt() {
        assertEquals(
            6L * 1024L * 1024L,
            transferredBytesThisAttempt(26L * 1024L * 1024L, 20L * 1024L * 1024L),
        )
        assertEquals(0L, transferredBytesThisAttempt(downloaded = 4L, resumeOffset = 8L))
    }
}
