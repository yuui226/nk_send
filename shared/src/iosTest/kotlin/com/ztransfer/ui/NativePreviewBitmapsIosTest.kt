package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
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
        var fhdReads = 0; var localReads = 0; var ended = 0
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
            fhdReads++; completion.complete(ownedFhdPreviewPng(png()))
        }
        override fun readLocalBitmap(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
            localReads++; completion.complete(ownedLocalPreviewPng(png()))
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
