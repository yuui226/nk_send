package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class FhdResponseDispositionTest {
    @Test
    fun `only successful response with payload is success`() {
        assertEquals(
            FhdResponseDisposition.SUCCESS,
            classifyFhdResponse(PtpConstants.RESPONSE_OK, hasPayload = true),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(PtpConstants.RESPONSE_OK, hasPayload = false),
        )
    }

    @Test
    fun `only explicit operation not supported is permanent`() {
        assertEquals(
            FhdResponseDisposition.UNSUPPORTED,
            classifyFhdResponse(PtpConstants.OPERATION_NOT_SUPPORTED, hasPayload = false),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(PtpConstants.DEVICE_BUSY, hasPayload = false),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(PtpConstants.INVALID_OBJECT_HANDLE, hasPayload = false),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(0xA801, hasPayload = false),
        )
    }

    @Test
    fun `capability changes only on definitive evidence`() {
        assertEquals(
            true,
            updateFhdSupport(null, FhdResponseDisposition.SUCCESS),
        )
        assertEquals(
            null,
            updateFhdSupport(null, FhdResponseDisposition.TRANSIENT_FAILURE),
        )
        assertEquals(
            true,
            updateFhdSupport(true, FhdResponseDisposition.TRANSIENT_FAILURE),
        )
        assertEquals(
            false,
            updateFhdSupport(false, FhdResponseDisposition.TRANSIENT_FAILURE),
        )
        assertEquals(
            false,
            updateFhdSupport(null, FhdResponseDisposition.UNSUPPORTED),
        )
        assertEquals(
            true,
            updateFhdSupport(true, FhdResponseDisposition.UNSUPPORTED),
        )
    }
}
