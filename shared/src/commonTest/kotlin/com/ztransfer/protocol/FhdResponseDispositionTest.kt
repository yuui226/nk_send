package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class FhdResponseDispositionTest {
    @Test
    fun onlySuccessfulResponseWithPayloadIsSuccess() {
        assertEquals(
            FhdResponseDisposition.SUCCESS,
            classifyFhdResponse(PtpConstants.RESPONSE_OK, hasPayload = true),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(PtpConstants.RESPONSE_OK, hasPayload = false),
        )
        assertEquals(
            FhdResponseDisposition.TRANSIENT_FAILURE,
            classifyFhdResponse(0xA801, hasPayload = true),
        )
    }

    @Test
    fun onlyExplicitOperationNotSupportedIsPermanent() {
        assertEquals(
            FhdResponseDisposition.UNSUPPORTED,
            classifyFhdResponse(PtpConstants.OPERATION_NOT_SUPPORTED, hasPayload = true),
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
    fun capabilityChangesOnlyOnDefinitiveEvidence() {
        assertEquals(true, updateFhdSupport(null, FhdResponseDisposition.SUCCESS))
        assertEquals(null, updateFhdSupport(null, FhdResponseDisposition.TRANSIENT_FAILURE))
        assertEquals(true, updateFhdSupport(true, FhdResponseDisposition.TRANSIENT_FAILURE))
        assertEquals(false, updateFhdSupport(false, FhdResponseDisposition.TRANSIENT_FAILURE))
        assertEquals(false, updateFhdSupport(null, FhdResponseDisposition.UNSUPPORTED))
        assertEquals(true, updateFhdSupport(true, FhdResponseDisposition.UNSUPPORTED))
    }
}
