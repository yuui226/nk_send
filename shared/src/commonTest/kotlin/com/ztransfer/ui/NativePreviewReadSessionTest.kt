package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.*
import kotlin.test.*

class NativePreviewReadSessionTest {
    private val file = CameraFileInfo(1, 123, "A.JPG", null, false)
    private class Platform : NativePreviewReadPlatform {
        val started = mutableListOf<Long>()
        val ended = mutableListOf<Long>()
        val cancelled = mutableListOf<Pair<Long, Long>>()
        val reads = linkedMapOf<Long, NativeFhdPreviewCompletion>()
        var immediate: NativeFhdPreviewImage? = null
        override fun beginPreviewReads(sessionId: Long) { started += sessionId }
        override fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) {
            reads[requestId] = completion
            immediate?.let { completion.complete(it); completion.complete(null) }
        }
        override fun cancelPreviewRead(sessionId: Long, requestId: Long) { cancelled += sessionId to requestId }
        override fun endPreviewReads(sessionId: Long) { ended += sessionId }
    }
    private class Pending<T>(block: suspend () -> T) {
        var result: Result<T>? = null
        val job = CoroutineScope(Dispatchers.Unconfined).launch(start = CoroutineStart.UNDISPATCHED) {
            result = runCatching { block() }
        }
    }
    private fun session(p: Platform, current: (CameraFileInfo) -> Boolean = { it == file }, timeout: Long = 30_000L) =
        NativePreviewReadSession(7, p, current, Dispatchers.Unconfined, timeout)
    private fun png(width: Int = 10, height: Int = 5): ByteArray {
        val bytes = ByteArray(33)
        intArrayOf(137, 80, 78, 71, 13, 10, 26, 10).forEachIndexed { i, value -> bytes[i] = value.toByte() }
        bytes[11] = 13
        "IHDR".forEachIndexed { i, char -> bytes[12 + i] = char.code.toByte() }
        for ((offset, value) in listOf(16 to width, 20 to height)) {
            for (i in 0..3) bytes[offset+i] = (value ushr (24 - 8*i)).toByte()
        }
        return bytes
    }

    @Test fun synchronousAndDuplicateRepliesAreSafeAndDoNotCancelSuccess() {
        val p = Platform().also { it.immediate = ownedFhdPreviewPng(png()) }
        val session = session(p)
        val read = Pending { session.fhd(file) }
        assertSame(p.immediate, read.result!!.getOrThrow())
        assertTrue(p.cancelled.isEmpty()); assertTrue(read.job.isCompleted)
        session.close(); session.close()
        assertEquals(listOf(7L), p.started); assertEquals(listOf(7L), p.ended)
    }

    @Test fun cancellingOneReadKeepsTheSessionUsableAndNeverAcceptsItsLateReply() {
        val p = Platform(); val session = session(p)
        val first = Pending { session.fhd(file) }; first.job.cancel()
        assertTrue(first.result!!.exceptionOrNull() is CancellationException)
        assertEquals(listOf(7L to 1L), p.cancelled); assertTrue(p.ended.isEmpty())
        val second = Pending { session.fhd(file) }
        p.reads[1]!!.complete(ownedFhdPreviewPng(png()))
        assertNull(second.result)
        p.reads[2]!!.complete(null)
        assertNull(second.result!!.getOrThrow())
        session.close()
    }

    @Test fun closeCancelsAllWaitersOnceAndRejectsLateOrNewReads() {
        val p = Platform(); val session = session(p)
        val a = Pending { session.fhd(file) }; val b = Pending { session.fhd(file) }
        session.close(); session.close()
        assertTrue(a.result!!.isFailure); assertTrue(b.result!!.isFailure)
        p.reads.values.forEach { it.complete(ownedFhdPreviewPng(png())) }
        assertTrue(a.result!!.isFailure); assertTrue(b.result!!.isFailure)
        assertNull(Pending { session.fhd(file) }.result!!.getOrThrow())
        assertEquals(listOf(7L), p.ended); assertEquals(2, p.reads.size)
    }

    @Test fun catalogIdentityIsCheckedBeforeIssuingAndAgainBeforePublishing() {
        val p = Platform(); var valid = false
        val session = session(p, { valid })
        assertNull(Pending { session.fhd(file) }.result!!.getOrThrow()); assertTrue(p.reads.isEmpty())
        valid = true
        val result = Pending { session.fhd(file) }; valid = false
        p.reads[1]!!.complete(ownedFhdPreviewPng(png()))
        assertNull(result.result!!.getOrThrow())
        session.close()
    }

    @Test fun pendingReadCountIsBoundedAndCloseReleasesAll() {
        val p = Platform(); val session = session(p)
        val reads = List(32) { Pending { session.fhd(file) } }
        assertNull(Pending { session.fhd(file) }.result!!.getOrThrow())
        assertEquals(32, p.reads.size)
        session.close()
        assertTrue(reads.all { it.result?.isFailure == true })
    }

    @Test fun deadlineCancellationCannotLeaveAnUnreleasedRequest() {
        val p = Platform(); val session = session(p, timeout = 0L)
        val read = Pending { session.fhd(file) }
        assertTrue(read.result!!.exceptionOrNull() is TimeoutCancellationException)
        assertTrue(p.reads.isEmpty()); assertEquals(listOf(7L to 1L), p.cancelled)
        session.close()
    }

    @Test fun fhdHeaderHasOriginal1920EdgeAndCannotWrapUnsignedDimensions() {
        val image = assertNotNull(ownedFhdPreviewPng(png(1920, 1080)))
        assertEquals(1920, image.width); assertEquals(1080, image.height)
        for ((w, h) in listOf(1921 to 1, 1 to 1921, 0 to 1, -1 to 1, Int.MIN_VALUE to 1)) {
            assertNull(ownedFhdPreviewPng(png(w, h)))
        }
    }

    @Test fun malformedAndOverBudgetPngIsRejectedBeforeBitmapAllocation() {
        assertNull(ownedFhdPreviewPng(png().copyOf(32)))
        assertNull(ownedFhdPreviewPng(png().also { it[12] = 0 }))
        assertNull(ownedFhdPreviewPng(png().copyOf(SINGLE_PHOTO_MAX_BYTES + 1)))
    }
}
