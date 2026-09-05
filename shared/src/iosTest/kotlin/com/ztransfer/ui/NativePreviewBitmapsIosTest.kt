package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import com.ztransfer.ui.screen.LocalOriginalPreviewRoute
import com.ztransfer.viewmodel.PhotoExif
import kotlin.test.*

/** Real Skia decoding and shared grid-cache identity; Mac-only, not a Windows pass. */
class NativePreviewBitmapsIosTest {
    private val file = CameraFileInfo(1, 12, "A.JPG", null, false)
    // Valid lossless RGBA PNG containing opaque red then opaque green (not just an IHDR stub).
    private fun png() = byteArrayOf(-119,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,1,8,6,0,0,0,-12,34,127,-118,
        0,0,0,14,73,68,65,84,120,-100,99,-8,-49,-64,-16,31,4,1,16,-8,3,-3,78,-107,-63,111,0,0,0,0,73,69,78,68,-82,66,96,-126)

    private inner class Platform : NativeFilesPagePlatform, NativeQueuePagePlatform, NativePreviewReadPlatform {
        var data: ByteArray? = png()
        val remotes = mutableListOf<Boolean>()
        var fhdReads = 0; var localReads = 0; var rawReads = 0; var ended = 0
        var exifReads = 0; var localExifReads = 0
        var priorityDepth = 0
        val ordered = mutableListOf<String>()
        override fun beginPreviewPriority(sessionId: Long, requestId: Long, completion: NativePreviewPriorityCompletion) {
            priorityDepth++; ordered += "priority"; completion.complete(true)
        }
        override fun endPreviewPriority(sessionId: Long, requestId: Long) { priorityDepth--; ordered += "release" }
        override fun readExif(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativePreviewExifCompletion) {
            exifReads++; ordered += "exif"; completion.complete(PhotoExif("f/4", null, null, null))
        }
        override fun readLocalExif(sessionId: Long, requestId: Long, file: CameraFileInfo, source: String, completion: NativePreviewExifCompletion) {
            localExifReads++; completion.complete(PhotoExif("f/8", null, null, null))
        }
        override fun readBrowsePreferences() = NativeBrowsePreferences.defaults()
        override fun saveBrowsePreferences(value: NativeBrowsePreferences) = true
        override fun currentDayKey() = 20260905
        override fun refresh() {}
        override fun enqueue(handles: IntArray, scanSequence: Long, completion: NativeFilesEnqueueCompletion) { completion.complete(0) }
        override fun thumbnail(file: CameraFileInfo, allowRemote: Boolean, completion: NativeFilesThumbnailCompletion) {
            remotes += allowRemote; completion.complete(data, false)
        }
        override fun cancelRequests() {}
        override fun showConnectionHelp() {}
        override fun completedSpeed(value: Float) = ""
        override fun fixed(value: Double, fractionDigits: Int) = ""
        override fun execute(command: NativeQueueCommand, taskId: Long, excludedTaskIds: LongArray, completion: NativeQueueActionCompletion) {}
        override fun thumbnail(file: CameraFileInfo, completion: NativeQueueThumbnailCompletion) {}
        override fun beginPreviewReads(sessionId: Long) {}
        override fun cancelPreviewRead(sessionId: Long, requestId: Long) {}
        override fun endPreviewReads(sessionId: Long) { ended++ }
        override fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) {
            fhdReads++; ordered += "fhd"; completion.complete(ownedFhdPreviewPng(png()))
        }
        override fun readLocalBitmap(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
            localReads++; completion.complete(ownedLocalPreviewPng(png()))
        }
        override fun readLocalRaw(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
            rawReads++; completion.complete(ownedLocalPreviewPng(png()))
        }
    }
    private fun model(p: Platform): NativeFilesPageModel {
        val q = NativeQueuePageModel("test", p).also { it.setConnected(true) }
        return NativeFilesPageModel("test", q, p).also { m ->
            val snapshot = NativeFilesPageSnapshot("test", true, false)
            snapshot.addFile(file.handle, file.size, file.fileName, null, false, intArrayOf())
            assertTrue(m.finishScan(m.beginScan(), snapshot))
        }
    }
    private fun reads(p: Platform) = NativePreviewReadSession(1, p, { it == file }, Dispatchers.Unconfined,
        isFrozenLocalSource = { f, source -> f == file && source == "frozen" })

    @Test fun sourceFactoryRequiresExistingReadBridgeAndEndsOnlyItsOwnLifetime() {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        assertNull(NativePreviewSessionSource.open(m, grid, listOf(file)))
        assertEquals(0, p.ended); assertTrue(m.queue.connected.value)
        assertTrue(m.attachPreviewReads(p))
        val source = assertNotNull(NativePreviewSessionSource.open(m, grid, listOf(file)))
        assertNull(source.localSource(file))
        source.close(); assertEquals(1, p.ended); assertTrue(m.queue.connected.value)
        m.close(); assertEquals(1, p.ended); grid.close()
    }

    @Test fun completePlatformSourceBorrowsCacheAndBracketsActualImageAndExifReads() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val cached = assertNotNull(grid.thumbnail(file, true))
        val source = NativePreviewSessionSource(reads(p), grid, m.queue.connected, listOf(file), emptyMap())
        source.setFhdActive(true)
        assertSame(cached, source.cached(file.handle)); assertSame(cached, source.thumbnail(file, false))
        val result = source.withInteractivePreviewPriority {
            assertEquals(1, p.priorityDepth)
            assertEquals(2, assertNotNull(source.loadFhdPreview(file)).width)
            assertEquals("f/4", source.loadExif(file)?.aperture)
            assertEquals(1, p.priorityDepth)
            42
        }
        assertEquals(42, result); assertEquals(listOf("priority", "fhd", "exif", "release"), p.ordered)
        assertEquals(0, p.priorityDepth)
        source.setFhdActive(false); source.close()
        assertEquals(1, p.ended); assertSame(cached, grid.cached(file)); assertTrue(m.queue.connected.value)
        assertNull(source.loadFhdPreview(file)); assertNull(source.loadExif(file)); assertNull(source.cached(file.handle))
        grid.close(); m.close()
    }

    @Test fun completeSourceKeepsLocalIdentityFrozenAndServesLocalImageAndExifOffline() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val locations = mutableMapOf(file to "frozen")
        val source = NativePreviewSessionSource(reads(p), grid, m.queue.connected, listOf(file), locations)
        locations[file] = "new"; m.queue.setConnected(false)
        assertEquals("frozen", source.localSource(file))
        assertNull(source.localSource(file.copy(size = 999)))
        assertEquals(2, assertNotNull(source.decodeLocal("frozen", LocalOriginalPreviewRoute.DIRECT_BITMAP)).width)
        assertEquals("f/8", source.loadLocalExif(file, "frozen")?.aperture)
        assertNull(source.decodeLocal("new", LocalOriginalPreviewRoute.DIRECT_BITMAP))
        assertNull(source.loadLocalExif(file.copy(size = 999), "frozen"))
        assertNull(source.loadLocalExif(file, "new"))
        assertEquals(1, p.localReads); assertEquals(1, p.localExifReads); assertEquals(0, p.fhdReads)
        assertTrue(p.ordered.isEmpty())
        source.close(); assertNull(source.localSource(file)); grid.close(); m.close()
    }

    @Test fun completeSourceUsesRawReaderButNeverDecodesTiffLocally() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val raw = file.copy(handle = 2, fileName = "A.NEF")
        val tiff = file.copy(handle = 3, fileName = "A.TIFF")
        val sources = mapOf(raw to "raw", tiff to "tiff")
        val reads = NativePreviewReadSession(1, p, { true }, Dispatchers.Unconfined,
            isFrozenLocalSource = { f, locator -> sources[f] == locator })
        val source = NativePreviewSessionSource(reads, grid, m.queue.connected, listOf(raw, tiff), sources)
        assertEquals(2, assertNotNull(source.decodeLocal("raw", source.localRoute(raw.extension))).width)
        assertNull(source.decodeLocal("raw", LocalOriginalPreviewRoute.DIRECT_BITMAP))
        assertNull(source.decodeLocal("tiff", source.localRoute(tiff.extension)))
        assertNull(source.decodeLocal("tiff", LocalOriginalPreviewRoute.DIRECT_BITMAP))
        assertEquals(1, p.rawReads); assertEquals(0, p.localReads); assertEquals(0, p.fhdReads)
        source.close(); grid.close(); m.close()
    }

    @Test fun completeSourceHistogramUsesItsActualPixelsAndMonotonicUptime() {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val source = NativePreviewSessionSource(reads(p), grid, m.queue.connected, listOf(file), emptyMap())
        val bitmap = assertNotNull(decodeNativePreviewBitmap(png()))
        val histogram = source.histogram(bitmap)
        val expected = FloatArray(256).also { it[53] = 1f; it[182] = 1f }
        assertContentEquals(expected, histogram.bins)
        val first = source.uptimeMillis(); assertTrue(first >= 0); assertTrue(source.uptimeMillis() >= first)
        assertTrue(p.ordered.isEmpty()); assertTrue(p.remotes.isEmpty())
        source.close(); grid.close(); m.close()
    }

    @Test fun realDecodeKeepsPixelsAliveAfterTemporarySkiaImageIsClosed() {
        val bitmap = assertNotNull(decodeNativePreviewBitmap(png(), 2, 1))
        val pixels = IntArray(2); bitmap.readPixels(pixels)
        assertContentEquals(intArrayOf(0xffff0000.toInt(), 0xff00ff00.toInt()), pixels)
    }

    @Test fun badEncodingAndUnexpectedDimensionsAreNotPublishedAsBitmaps() {
        assertNull(decodeNativePreviewBitmap(byteArrayOf(1, 2, 3)))
        assertNull(decodeNativePreviewBitmap(png(), 1, 2))
        assertNull(decodeNativePreviewBitmap(png(), maxEdge = 1))
    }

    @Test fun previewBorrowsExactGridBitmapAndClosingItNeverClearsParentCache() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val bitmap = assertNotNull(grid.thumbnail(file, true))
        val preview = grid.preview(reads(p), listOf(file))
        assertSame(bitmap, preview.cached(file.handle))
        assertSame(bitmap, preview.thumbnail(file, false)); assertEquals(listOf(true), p.remotes)
        preview.close(); preview.close()
        assertNull(preview.cached(file.handle)); assertSame(bitmap, grid.cached(file))
        assertEquals(1, p.ended); assertTrue(m.queue.connected.value)
        grid.close(); m.close()
    }

    @Test fun localThumbnailMissIsNotNegativeCachedAndLaterRemoteMaySucceed() = runBlocking {
        val p = Platform().also { it.data = null }; val m = model(p); val grid = NativeGridImages(m)
        val preview = grid.preview(reads(p), listOf(file))
        assertNull(preview.thumbnail(file, false))
        p.data = png(); assertNotNull(preview.thumbnail(file, true))
        assertEquals(listOf(false, true), p.remotes)
        preview.close(); grid.close(); m.close()
    }

    @Test fun frozenIdentityRejectsAnotherFileWithSameHandle() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val preview = grid.preview(reads(p), listOf(file))
        assertNull(preview.thumbnail(file.copy(size = 999), true))
        assertNull(preview.fhd(file.copy(fileName = "OTHER.JPG")))
        assertTrue(p.remotes.isEmpty()); assertEquals(0, p.fhdReads)
        preview.close(); grid.close(); m.close()
    }

    @Test fun rawUsesItsOwnReaderThenRealBitmapDecodeAndFrozenIdentity() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val preview = grid.preview(reads(p), listOf(file))
        assertEquals(2, assertNotNull(preview.localRaw(file, "frozen")).width)
        assertNull(preview.localRaw(file.copy(size = 13), "frozen"))
        assertNull(preview.localRaw(file, "wrong"))
        assertEquals(1, p.rawReads); assertEquals(0, p.localReads); assertEquals(0, p.fhdReads)
        assertNull(grid.cached(file)); preview.close()
        assertNull(preview.localRaw(file, "frozen")); assertEquals(1, p.rawReads)
        grid.close(); m.close()
    }

    @Test fun fhdAndLocalReallyDecodeWithoutCreatingAnotherThumbnailCache() = runBlocking {
        val p = Platform(); val m = model(p); val grid = NativeGridImages(m)
        val preview = grid.preview(reads(p), listOf(file))
        assertEquals(2, assertNotNull(preview.fhd(file)).width)
        assertEquals(1, assertNotNull(preview.local(file, "frozen")).height)
        assertNull(grid.cached(file)); assertEquals(1, p.fhdReads); assertEquals(1, p.localReads)
        preview.close(); assertNull(preview.fhd(file)); assertEquals(1, p.fhdReads)
        assertNotNull(grid.thumbnail(file, true))
        grid.close(); assertNull(grid.cached(file)); m.close()
    }
}
