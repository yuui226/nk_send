package com.ztransfer.protocol

import kotlin.test.*

class NativePreviewPolicyTest {
    @Test fun nativeImageAdmissionRejectsOverflowWithoutChangingOrdinaryCameraResolution() {
        val policy = NativePreviewPolicy()
        assertTrue(policy.originalPixelsAllowed(8256, 5504)) // 45 MP Nikon originals, full resolution.
        assertTrue(policy.originalPixelsAllowed(12288, 8192))
        assertFalse(policy.originalPixelsAllowed(12289, 8192))
        assertFalse(policy.originalPixelsAllowed(Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(policy.originalPixelsAllowed(-1, 2))
        assertTrue(policy.thumbnailPixelsAllowed(8192, 4096))
        assertFalse(policy.thumbnailPixelsAllowed(8193, 4096))
    }

    @Test fun stationCameraPreviewKeepsPrivateFhdProbeAndRequiresAdvertisedLargeThumb() {
        val policy = NativeStaPreviewPolicy()
        assertTrue(policy.shouldRequest(PtpConstants.NK_GET_FHD_PICTURE, false))
        assertFalse(policy.shouldRequest(PtpConstants.NK_GET_LARGE_THUMB, false))
        assertTrue(policy.shouldRequest(PtpConstants.NK_GET_LARGE_THUMB, true))
    }
    @Test fun stationAccessDeniedDisablesOnlyThatOperationWhileBusyRemainsRetryable() {
        val policy = NativeStaPreviewPolicy()
        policy.record(PtpConstants.NK_GET_FHD_PICTURE, PtpConstants.DEVICE_BUSY, false)
        assertTrue(policy.shouldRequest(PtpConstants.NK_GET_FHD_PICTURE, false))
        policy.record(PtpConstants.NK_GET_FHD_PICTURE, PtpConstants.RESPONSE_OK, true)
        policy.record(PtpConstants.NK_GET_FHD_PICTURE, 0x200F, false)
        assertFalse(policy.shouldRequest(PtpConstants.NK_GET_FHD_PICTURE, true))
        assertTrue(policy.shouldRequest(PtpConstants.NK_GET_LARGE_THUMB, true))
    }
    @Test fun rawFhdCandidateOrderMatchesSmallestPlausibleThenDimensionFallback() {
        val policy = NativeStaPreviewPolicy()
        val small = com.ztransfer.preview.NefPreviewReference(10, 1000)
        val fhd = com.ztransfer.preview.NefPreviewReference(10000, 512 * 1024)
        val full = com.ztransfer.preview.NefPreviewReference(600000, 2 * 1024 * 1024)
        assertEquals(listOf(fhd, full), policy.rawCandidates(listOf(full, small, fhd, full)))
        assertEquals(listOf(small), policy.rawCandidates(listOf(small)))
        assertFalse(policy.rawPreviewAdequate(1599, 1080)); assertTrue(policy.rawPreviewAdequate(1080, 1600))
    }
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
