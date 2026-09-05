package com.ztransfer.preview

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif
import kotlin.test.*

class NativePreviewExifCacheTest {
    private val file = CameraFileInfo(7, 100, "A.JPG", "20260905T120000", false)
    private val exif = PhotoExif("f/4", "1/250", "ISO64", "85mm")
    @Test fun unattemptedAndNegativeCacheAreDistinct() {
        val cache = NativePreviewExifCache()
        assertNull(cache.cached(file))
        cache.remember(file, null)
        assertNull(assertNotNull(cache.cached(file)).value)
        cache.remember(file, exif)
        assertSame(exif, assertNotNull(cache.cached(file)).value)
    }
    @Test fun reconnectHandleAndProtectionChangesKeepOriginalStableKey() {
        val cache = NativePreviewExifCache(); cache.remember(file, exif)
        assertSame(exif, cache.cached(file.copy(handle = -123, isProtected = true))?.value)
        assertNull(cache.cached(file.copy(fileName = "B.JPG")))
        assertNull(cache.cached(file.copy(size = 101)))
        assertNull(cache.cached(file.copy(captureDate = null)))
    }
    @Test fun sharedCacheIsNotOwnedByIndividualReadersAndIndependentWorkspacesDoNotShareIt() {
        val owner = NativePreviewExifCache()
        val oldPage = owner; oldPage.remember(file, exif)
        val newPage = owner
        assertSame(exif, newPage.cached(file.copy(handle = 9))?.value)
        assertNull(NativePreviewExifCache().cached(file))
        newPage.remember(file, null)
        assertNull(assertNotNull(oldPage.cached(file)).value)
    }
    @Test fun headerContractKeepsOriginalExtensionsAndLimits() {
        for (ext in listOf("jpg", "JPEG")) assertEquals(128 * 1024, NativePreviewExifPolicy.headerBytes(file.copy(fileName = "A.$ext")))
        for (ext in listOf("NEF", "nrw", "TIF", "tiff")) assertEquals(2048 * 1024, NativePreviewExifPolicy.headerBytes(file.copy(fileName = "A.$ext")))
        for (name in listOf("A.MOV", "A.MP4", "A.HEIC", "A.PNG", "A", "A.JPG.tmp"))
            assertEquals(0, NativePreviewExifPolicy.headerBytes(file.copy(fileName = name)))
    }
}
