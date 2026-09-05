package com.ztransfer.protocol

import kotlin.test.*

class NativePreviewPolicyTest {
    @Test fun nativeCameraIdentityUsesOriginalSerialAndTransportPrecedence() {
        val policy = NativePreviewPolicy()
        val info = LabDeviceInfo(" Nikon ", " Z8 ", "", " SN-1 ", 0, 0, "", emptySet(), emptySet(), emptySet())
        assertEquals("Nikon\u0000Z8\u0000SN-1", policy.cameraKey(info, "guid", "session"))
        assertEquals("Nikon\u0000Z8\u0000guid", policy.cameraKey(info.copy(serial = "0000"), " guid ", "session"))
        assertEquals("\u0000\u0000guid", policy.cameraKey(null, "guid", "session"))
    }

    @Test fun unknownCamerasAreConnectionScopedRatherThanSharingPersistentEntries() {
        val policy = NativePreviewPolicy()
        for (placeholder in listOf(null, "", "unknown", "00-00")) {
            assertEquals("\u0000\u0000session:one", policy.cameraKey(null, placeholder, "one"))
            assertNotEquals(policy.cameraKey(null, placeholder, "one"), policy.cameraKey(null, placeholder, "two"))
        }
    }

    @Test fun nativeCameraExpiryCallsSameStrictNinetyDayBoundary() {
        val policy = NativePreviewPolicy()
        val start = 1_700_000_000_000L
        val duration = com.ztransfer.catalog.THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS
        assertFalse(policy.cameraCacheExpired(start, start + duration))
        assertTrue(policy.cameraCacheExpired(start, start + duration + 1))
        assertFalse(policy.cameraCacheExpired(start, start - 1))
    }

    @Test fun nativeLatchExactlyMatchesSharedResponsePolicy() {
        val codes = listOf(PtpConstants.RESPONSE_OK, PtpConstants.DEVICE_BUSY,
            PtpConstants.OPERATION_NOT_SUPPORTED, PtpConstants.INVALID_OBJECT_HANDLE)
        for (first in codes) for (second in codes) for (payload in listOf(false, true)) {
            val policy = NativePreviewPolicy()
            var expected: Boolean? = null
            for (code in listOf(first, second)) {
                val disposition = classifyFhdResponse(code, payload)
                expected = updateFhdSupport(expected, disposition)
                assertEquals(disposition == FhdResponseDisposition.SUCCESS, policy.record(code, payload))
                assertEquals(expected == false, policy.disabled)
            }
        }
    }
}
