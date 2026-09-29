package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class VideoTransferPolicyTest {
    @Test fun onlyVideoFormatsCanResume() {
        listOf("a.MOV", "a.mp4", "a.NEV", "a.avi").forEach { assertTrue(supportsVideoResume(it)) }
        listOf("a.JPG", "a.JPEG", "a.NEF", "a.NRW", "a.HEIF", "a.PNG", "a.TIF", "a").forEach {
            assertFalse(supportsVideoResume(it))
        }
    }

    @Test fun photosNeverUseMultipleRequestsRegardlessOfPageOrTransport() {
        for (usb in listOf(false, true)) for (throughput in listOf(false, true)) {
            val size = 120L * 1024 * 1024
            assertFalse(shouldUsePartialObjectDownload(true, size,
                isUsbConnection = usb, preferHighThroughput = throughput, videoTransfer = false))
            assertTrue(shouldUsePartialObjectDownload(true, size,
                isUsbConnection = usb, preferHighThroughput = throughput, forcePartial = true,
                videoTransfer = false))
            assertEquals(size, downloadChunkSize(size, usb, throughput, videoTransfer = false))
        }
    }

    @Test fun videosRetainTheExistingChunkBudget() {
        val size = 120L * 1024 * 1024
        assertEquals(NikonCamera.CHUNK_SIZE, downloadChunkSize(size, videoTransfer = true))
        assertEquals(NikonCamera.HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(size, isUsbConnection = true, videoTransfer = true))
    }
}
