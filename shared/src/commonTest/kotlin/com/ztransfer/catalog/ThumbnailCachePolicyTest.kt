package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ThumbnailCachePolicyTest {
    @Test
    fun normalKeyMaterialPreservesSeparatorsAndNullDateBehavior() {
        assertEquals(
            "照片 1.JPG\u0000123\u000020260812T120000",
            thumbnailCacheKeyMaterial("照片 1.JPG", 123L, "20260812T120000"),
        )
        assertEquals(
            thumbnailCacheKeyMaterial("照片 1.JPG", 123L, ""),
            thumbnailCacheKeyMaterial("照片 1.JPG", 123L, null),
        )
    }

    @Test
    fun staKeyMaterialTreatsHandleAsUnsigned() {
        assertEquals(
            "sta\u0000689529333\u000012345",
            staThumbnailCacheKeyMaterial(0x291961F5, 12_345L),
        )
        assertEquals(
            "sta\u00004294967295\u000012345",
            staThumbnailCacheKeyMaterial(-1, 12_345L),
        )
    }

    @Test
    fun cacheExpiresOnlyAfterNinetyDayBoundary() {
        val connectedAt = 1_700_000_000_000L

        assertFalse(
            isThumbnailCameraCacheExpired(
                connectedAt,
                connectedAt + THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS,
            ),
        )
        assertTrue(
            isThumbnailCameraCacheExpired(
                connectedAt,
                connectedAt + THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS + 1,
            ),
        )
    }

    @Test
    fun cameraIdentifierRejectsKnownAndAllZeroPlaceholders() {
        listOf(null, "", "  ", "unknown", "NONE", "Null", "n/A", "00-00:00")
            .forEach { value -> assertNull(normalizedCameraIdentifier(value), value) }

        assertEquals("SN-0001", normalizedCameraIdentifier("  SN-0001  "))
        assertEquals("序列一", normalizedCameraIdentifier(" 序列一 "))
    }

    @Test
    fun cameraIdentityPrefersBodySerialThenTransportFallback() {
        assertEquals(
            "Nikon\u0000Z 6III\u0000body-1",
            cameraThumbnailCacheIdentity(" Nikon ", " Z 6III ", " body-1 ", "usb-2"),
        )
        assertEquals(
            "Nikon\u0000Z 6III\u0000usb-2",
            cameraThumbnailCacheIdentity("Nikon", "Z 6III", "00-00", " usb-2 "),
        )
        assertEquals(
            "\u0000\u0000unknown-device",
            cameraThumbnailCacheIdentity(null, null, "unknown", "0000"),
        )
    }

    @Test
    fun directStaNonJpegMissRemainsRetryableAndIsNotBackgroundPrefetched() {
        listOf(".nef", ".mov", "").forEach { extension ->
            assertFalse(shouldRememberThumbnailMiss(true, extension), extension)
            assertFalse(shouldPrefetchThumbnailInBackground(true, extension), extension)
        }
        assertTrue(shouldRememberThumbnailMiss(true, ".jpg"))
        assertTrue(shouldPrefetchThumbnailInBackground(true, ".jpg"))
        assertTrue(shouldRememberThumbnailMiss(false, ".nef"))
        assertTrue(shouldPrefetchThumbnailInBackground(false, ".mov"))
    }
}
