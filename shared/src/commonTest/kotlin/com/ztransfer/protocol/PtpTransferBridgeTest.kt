package com.ztransfer.protocol

import com.ztransfer.test.hexBytes
import com.ztransfer.viewmodel.suffixedTransferFileName
import com.ztransfer.viewmodel.transferDestinationFolderName
import com.ztransfer.viewmodel.transferPartFileName
import kotlin.test.*

class PtpTransferBridgeTest {
    @Test
    fun startDataPreservesLegacyAnd64BitLengths() {
        assertNull(PtpTransferBridge.decodeStart(hexBytes("010203")))
        assertEquals(0L, PtpTransferBridge.decodeStart(hexBytes("FFFFFFFF"))?.declaredBytes)
        val legacy = requireNotNull(PtpTransferBridge.decodeStart(hexBytes("FFFFFFFFFFFFFFFF")))
        assertEquals(-1, legacy.transactionId)
        assertEquals(0xFFFFFFFFL, legacy.declaredBytes)
        assertEquals(0x140000000L, PtpTransferBridge.decodeStart(hexBytes("010000000000004001000000"))?.declaredBytes)
        assertEquals(-1L, PtpTransferBridge.decodeStart(hexBytes("01000000FFFFFFFFFFFFFFFF"))?.declaredBytes)
    }

    @Test
    fun partialOffsetAndCountMatchNikonFiveParameterContract() {
        assertContentEquals(intArrayOf(-1, 0x3FFFFFFD, 1, 3, 0), PtpTransferBridge.partialParameters(-1, 0x13FFFFFFDL, 3))
        assertNull(PtpTransferBridge.partialParameters(7, -1, 1))
        assertNull(PtpTransferBridge.partialParameters(7, 0, 0))
        assertNull(PtpTransferBridge.partialParameters(7, 0, Int.MAX_VALUE.toLong() + 1))
        assertEquals(0x140000000L, PtpTransferBridge.objectSize(hexBytes("0000004001000000")))
        assertEquals(0L, PtpTransferBridge.objectSize(hexBytes("FFFFFFFFFFFFFFFF")))
        assertEquals(0L, PtpTransferBridge.objectSize(hexBytes("010203")))
    }

    @Test
    fun nativeDownloadDecisionsAreExactlyExistingSharedPolicy() {
        for (support in -1..1) for (size in listOf(0L, 3L, PtpConstants.SIZE_UNKNOWN, 1024L * 1024 * 1024)) {
            for (resume in listOf(0L, 4L * 1024 * 1024)) for (fast in listOf(false, true)) for (forced in listOf(false, true)) {
                assertEquals(shouldUsePartialObjectDownload(
                    when (support) { 0 -> false; 1 -> true; else -> null }, size, resume,
                    preferHighThroughput = fast, forcePartial = forced,
                ), PtpTransferBridge.usePartial(support, size, resume, fast, forced))
                assertEquals(downloadChunkSize(size, preferHighThroughput = fast), PtpTransferBridge.chunkSize(size, fast))
            }
        }
        assertTrue(PtpTransferBridge.resumeUnavailable(1, false))
        assertFalse(PtpTransferBridge.resumeUnavailable(0, false))
    }

    @Test
    fun fallbackRequiresFirstUnsupportedEmptyFreshChunk() {
        assertEquals(PtpTransferBridge.ACCEPT, PtpTransferBridge.partialAction(PtpConstants.RESPONSE_OK, true, 3, 0))
        assertEquals(PtpTransferBridge.FALLBACK, PtpTransferBridge.partialAction(PtpConstants.OPERATION_NOT_SUPPORTED, true, 0, 0))
        assertEquals(PtpTransferBridge.FAIL, PtpTransferBridge.partialAction(PtpConstants.OPERATION_NOT_SUPPORTED, true, 1, 0))
        assertEquals(PtpTransferBridge.FAIL, PtpTransferBridge.partialAction(PtpConstants.OPERATION_NOT_SUPPORTED, false, 0, 0))
        assertEquals(PtpTransferBridge.FAIL, PtpTransferBridge.partialAction(PtpConstants.OPERATION_NOT_SUPPORTED, true, 0, 1))
        assertFalse(PtpTransferBridge.chunkComplete(3, 4))
        assertFalse(PtpTransferBridge.chunkProgress(0))
        assertFalse(PtpTransferBridge.partialComplete(3, 4))
        assertTrue(PtpTransferBridge.fullComplete(3, PtpConstants.SIZE_UNKNOWN))
        assertFalse(PtpTransferBridge.fullComplete(3, 4))
    }

    @Test
    fun nativeStorageNamesAndSpeedDelegateToExistingRules() {
        assertEquals(transferDestinationFolderName("20260905T123456", true, 20260101), PtpTransferBridge.destinationFolder("20260905T123456", true, 20260101))
        assertEquals(transferPartFileName("照片.NEF", 3, null), PtpTransferBridge.partName("照片.NEF", 3, null))
        assertEquals(suffixedTransferFileName("DSC_0001.NEF", 2), PtpTransferBridge.copyName("DSC_0001.NEF", 2))
        assertEquals(endToEndBytesPerSecond(1024, 500), PtpTransferBridge.speed(1024, 500))
        assertEquals(resolvedTransferSize(PtpConstants.SIZE_UNKNOWN, 0x140000000L), PtpTransferBridge.resolvedSize(PtpConstants.SIZE_UNKNOWN, 0x140000000L))
    }
}
