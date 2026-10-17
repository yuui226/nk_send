package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class CameraStorageResponseTest {
    private fun payload(count: Int, vararg ids: Int) =
        ByteBuffer.allocate(4 + ids.size * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(count)
            ids.forEach { putInt(it) }
        }.array()

    @Test
    fun busyAndRejectedResponsesNeverMeanAnEmptyCard() {
        for (response in listOf(PtpConstants.DEVICE_BUSY, Lab.ACCESS_DENIED)) {
            for (data in listOf(null, payload(0))) {
                val result = parseCameraStorageIdsResponse(response, data)
                assertFalse(result.successful)
                assertEquals(response, result.responseCode)
            }
        }
    }

    @Test
    fun onlyACompleteSuccessfulEmptyArrayConfirmsNoStorage() {
        val result = parseCameraStorageIdsResponse(PtpConstants.RESPONSE_OK, payload(0))
        assertTrue(result.successful)
        assertTrue(result.storageIds.isEmpty())
        for (data in listOf(null, byteArrayOf(), ByteArray(3), payload(1))) {
            assertFalse(parseCameraStorageIdsResponse(PtpConstants.RESPONSE_OK, data).successful)
        }
    }

    @Test
    fun damagedCountsCannotEraseTheAlbumOrOverflowThePayloadBounds() {
        for (count in listOf(-1, Int.MAX_VALUE, 2)) {
            val result = parseCameraStorageIdsResponse(PtpConstants.RESPONSE_OK, payload(count, 0x10001))
            assertFalse(result.successful)
            assertNotNull(result.error)
        }
    }

    @Test
    fun parsesBothCardsAndPreservesNoCardSlotIdsForTheExistingFilter() {
        val ids = intArrayOf(0x10001, 0x20000)
        val result = parseCameraStorageIdsResponse(PtpConstants.RESPONSE_OK, payload(ids.size, *ids))
        assertTrue(result.successful)
        assertEquals(ids.toList(), result.storageIds)
    }
}
