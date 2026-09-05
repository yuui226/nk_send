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
        val locals = linkedMapOf<Long, NativeLocalPreviewCompletion>()
        val raws = linkedMapOf<Long, NativeLocalPreviewCompletion>()
        val exifs = linkedMapOf<Long, NativePreviewExifCompletion>()
        val remoteExifs = linkedMapOf<Long, NativePreviewExifCompletion>()
        val priorities = linkedMapOf<Long, NativePreviewPriorityCompletion>()
        val releasedPriorities = mutableListOf<Pair<Long, Long>>()
        override fun beginPreviewPriority(sessionId: Long, requestId: Long, completion: NativePreviewPriorityCompletion) {
            priorities[requestId] = completion
        }
        override fun endPreviewPriority(sessionId: Long, requestId: Long) { releasedPriorities += sessionId to requestId }
        override fun readExif(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativePreviewExifCompletion) {
            remoteExifs[requestId] = completion
        }
        override fun readLocalExif(sessionId: Long, requestId: Long, file: CameraFileInfo, source: String, completion: NativePreviewExifCompletion) {
            exifs[requestId] = completion
        }
        override fun readLocalRaw(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
            raws[requestId] = completion
        }
        override fun readLocalBitmap(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
            locals[requestId] = completion
        }
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

    @Test fun onePriorityWindowCoversBothCurrentPageReadsAndReturnsTheirResult() {
        val p = Platform(); val s = session(p)
        val task = Pending { s.withInteractivePriority { s.fhd(file); s.exif(file); 42 } }
        assertTrue(p.reads.isEmpty()); assertTrue(p.remoteExifs.isEmpty())
        p.priorities[1]!!.complete(true)
        assertEquals(setOf(2L), p.reads.keys); assertTrue(p.releasedPriorities.isEmpty())
        p.reads[2]!!.complete(null)
        assertEquals(setOf(3L), p.remoteExifs.keys); assertTrue(p.releasedPriorities.isEmpty())
        p.remoteExifs[3]!!.complete(null)
        assertEquals(42, task.result!!.getOrThrow())
        assertEquals(listOf(7L to 1L), p.releasedPriorities)
        p.priorities[1]!!.complete(true); assertEquals(1, p.releasedPriorities.size)
        s.close()
    }

    @Test fun deniedOrExpiredPriorityNeverRunsAnUnprioritizedBlockAndReleasesLateLease() {
        for (expire in listOf(false, true)) {
            val p = Platform(); val clock = ManualDeadline()
            val s = NativePreviewReadSession(7, p, { true }, clock)
            var entered = false
            val task = Pending { s.withInteractivePriority { entered = true } }
            if (expire) clock.expire() else p.priorities[1]!!.complete(false)
            assertTrue(task.result!!.exceptionOrNull() is CancellationException); assertFalse(entered)
            p.priorities[1]!!.complete(true); assertFalse(entered)
            assertEquals(listOf(7L to 1L), p.releasedPriorities)
            assertEquals(if (expire) listOf(7L to 1L) else emptyList(), p.cancelled)
            s.close()
        }
    }

    @Test fun priorityReleaseRunsForFailureAndCancellationDuringItsFhdRead() {
        for (cancel in listOf(false, true)) {
            val p = Platform(); val s = session(p)
            val failure = IllegalStateException("fixture")
            val task = Pending { s.withInteractivePriority { if (cancel) s.fhd(file) else throw failure } }
            p.priorities[1]!!.complete(true)
            if (cancel) task.job.cancel()
            if (cancel) assertTrue(task.result!!.exceptionOrNull() is CancellationException)
            else {
                // JVM coroutine stack recovery can copy the exception and retain its cause.
                val actual = assertIs<IllegalStateException>(task.result!!.exceptionOrNull())
                assertEquals(failure.message, actual.message)
                assertSame(failure, generateSequence<Throwable>(actual) { it.cause }.last())
            }
            assertEquals(listOf(7L to 1L), p.releasedPriorities)
            assertEquals(if (cancel) listOf(7L to 2L) else emptyList(), p.cancelled)
            assertTrue(p.ended.isEmpty()); s.close()
        }
    }

    @Test fun closingWhilePriorityRegistrationIsPendingRejectsLateGrantAndNewWindows() {
        val p = Platform(); val s = session(p); var entered = false
        val first = Pending { s.withInteractivePriority { entered = true } }
        s.close(); p.priorities[1]!!.complete(true)
        assertFalse(entered); assertTrue(first.result!!.isFailure)
        assertEquals(listOf(7L), p.ended); assertEquals(listOf(7L to 1L), p.releasedPriorities)
        assertTrue(Pending { s.withInteractivePriority { entered = true } }.result!!.isFailure)
        assertFalse(entered); assertEquals(1, p.priorities.size)
    }

    @Test fun remoteExifCanQueryOfflineCacheButRejectsUnknownOrChangedFiles() {
        val p = Platform(); var known = true
        val s = NativePreviewReadSession(7, p, { false }, Dispatchers.Unconfined,
            isKnownExifFile = { known && it == file })
        val cached = com.ztransfer.viewmodel.PhotoExif("f/4", null, null, null)
        assertNull(Pending { s.exif(file.copy(size = 99)) }.result!!.getOrThrow())
        assertTrue(p.remoteExifs.isEmpty())
        val first = Pending { s.exif(file) }; p.remoteExifs[1]!!.complete(cached)
        assertSame(cached, first.result!!.getOrThrow()); assertTrue(p.reads.isEmpty())
        val late = Pending { s.exif(file) }; known = false
        p.remoteExifs[2]!!.complete(cached); assertNull(late.result!!.getOrThrow())
        s.close()
    }

    @Test fun remoteAndLocalExifShareImageSlotsAndCancelDoesNotCompleteAnotherRequest() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { true }, Dispatchers.Unconfined, isFrozenLocalSource = { _, _ -> true })
        val first = Pending { s.exif(file) }; first.job.cancel()
        val jobs = List(32) { i -> Pending { if (i % 2 == 0) s.exif(file) else s.localExif(file, "owned") } }
        assertNull(Pending { s.fhd(file) }.result!!.getOrThrow())
        assertTrue(p.remoteExifs.keys.intersect(p.exifs.keys).isEmpty())
        p.remoteExifs[1]!!.complete(com.ztransfer.viewmodel.PhotoExif("late", null, null, null))
        assertTrue(first.result!!.isFailure); assertTrue(jobs.all { it.result == null })
        s.close(); assertTrue(jobs.all { it.result!!.isFailure })
        assertEquals(listOf(7L), p.ended)
    }

    @Test fun remoteExifDeadlineReleasesSlotAndLateReplyCannotPublish() {
        val p = Platform(); val clock = ManualDeadline()
        val s = NativePreviewReadSession(7, p, { true }, clock)
        val first = Pending { s.exif(file) }; clock.expire()
        assertNull(first.result!!.getOrThrow()); assertFalse(first.job.isCancelled)
        assertEquals(listOf(7L to 1L), p.cancelled)
        val next = Pending { s.exif(file) }
        p.remoteExifs[1]!!.complete(com.ztransfer.viewmodel.PhotoExif("late", null, null, null))
        assertNull(next.result)
        p.remoteExifs[2]!!.complete(null); assertNull(next.result!!.getOrThrow())
        s.close()
    }

    @Test fun localExifUsesFrozenSourceOfflineAndCannotTriggerImageOrCameraRead() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { false }, Dispatchers.Unconfined, isFrozenLocalSource = { f, source -> f == file && source == "owned" })
        assertNull(Pending { s.localExif(file, "other") }.result!!.getOrThrow())
        val result = Pending { s.localExif(file, "owned") }
        val exif = com.ztransfer.viewmodel.PhotoExif("f/4", "1/250", "ISO64", null)
        p.exifs[1]!!.complete(exif); p.exifs[1]!!.complete(null)
        assertSame(exif, result.result!!.getOrThrow())
        assertTrue(p.reads.isEmpty()); assertTrue(p.locals.isEmpty()); assertTrue(p.raws.isEmpty())
        s.close()
    }

    @Test fun localExifSharesSlotsAndClosedSessionRejectsLateMetadata() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { true }, Dispatchers.Unconfined, isFrozenLocalSource = { _, _ -> true })
        val results = List(32) { Pending { s.localExif(file, "owned") } }
        assertNull(Pending { s.localRaw(file, "owned") }.result!!.getOrThrow())
        assertNull(Pending { s.fhd(file) }.result!!.getOrThrow())
        s.close(); p.exifs.values.forEach { it.complete(com.ztransfer.viewmodel.PhotoExif(null, null, "ISO64", null)) }
        assertTrue(results.all { it.result!!.isFailure }); assertEquals(32, p.cancelled.size)
    }

    @Test fun localExifDeadlineIsFallbackMissNotPageCancellation() {
        val p = Platform(); val clock = ManualDeadline()
        val s = NativePreviewReadSession(7, p, { false }, clock, 30_000, { _, _ -> true })
        val result = Pending { s.localExif(file, "owned") }
        assertEquals(1, p.exifs.size); clock.expire()
        assertNull(result.result!!.getOrThrow()); assertFalse(result.job.isCancelled)
        assertEquals(listOf(7L to 1L), p.cancelled); s.close()
    }

    @Test fun rawReadsUseFrozenOfflineSourceAndNeverOrdinaryDecodeOrFhd() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { false }, Dispatchers.Unconfined,
            isFrozenLocalSource = { f, source -> f == file && source == "owned" })
        assertNull(Pending { s.localRaw(file, "wrong") }.result!!.getOrThrow())
        val result = Pending { s.localRaw(file, "owned") }
        val image = ownedLocalPreviewPng(png(6000, 4000))
        p.raws[1]!!.complete(image)
        assertSame(image, result.result!!.getOrThrow())
        assertTrue(p.locals.isEmpty()); assertTrue(p.reads.isEmpty())
        s.close()
    }

    @Test fun rawAndOtherRequestsShareSlotsAndCancellationRejectsLateRawReply() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { true }, Dispatchers.Unconfined, isFrozenLocalSource = { _, _ -> true })
        val first = Pending { s.localRaw(file, "owned") }; first.job.cancel()
        assertEquals(listOf(7L to 1L), p.cancelled)
        val pending = List(32) { i -> Pending { if (i % 2 == 0) s.localRaw(file, "owned") else s.localBitmap(file, "owned") } }
        assertNull(Pending { s.fhd(file) }.result!!.getOrThrow())
        p.raws[1]!!.complete(ownedLocalPreviewPng(png()))
        assertTrue(first.result!!.isFailure); assertTrue(pending.all { it.result == null })
        s.close(); assertTrue(pending.all { it.result!!.isFailure })
    }

    @Test fun rawDeadlineIsMissAndReleasesItsSlot() {
        val p = Platform(); val clock = ManualDeadline()
        val s = NativePreviewReadSession(7, p, { false }, clock, 30_000, { _, _ -> true })
        val result = Pending { s.localRaw(file, "owned") }
        assertEquals(1, p.raws.size); clock.expire()
        assertNull(result.result!!.getOrThrow()); assertFalse(result.job.isCancelled)
        assertEquals(listOf(7L to 1L), p.cancelled)
        s.close()
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
        assertNull(read.result!!.getOrThrow()); assertFalse(read.job.isCancelled)
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

    @Test fun frozenLocalSourceWorksOfflineButUnfrozenOrWrongFileSourceNeverIssuesIo() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { false }, Dispatchers.Unconfined,
            isFrozenLocalSource = { f, source -> f == file && source == "file:///owned/A.JPG" })
        assertNull(Pending { s.fhd(file) }.result!!.getOrThrow()); assertTrue(p.reads.isEmpty())
        assertNull(Pending { s.localBitmap(file, "file:///other/A.JPG") }.result!!.getOrThrow())
        assertNull(Pending { s.localBitmap(file.copy(handle = 2), "file:///owned/A.JPG") }.result!!.getOrThrow())
        assertTrue(p.locals.isEmpty())
        val result = Pending { s.localBitmap(file, "file:///owned/A.JPG") }
        val image = ownedLocalPreviewPng(png(8000, 6000))
        p.locals[1]!!.complete(image); p.locals[1]!!.complete(null)
        assertSame(image, result.result!!.getOrThrow())
        s.close()
    }

    @OptIn(InternalCoroutinesApi::class)
    private class ManualDeadline : CoroutineDispatcher(), Delay {
        val deadlines = mutableListOf<Runnable>()
        override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) = block.run()
        override fun scheduleResumeAfterDelay(timeMillis: Long, continuation: CancellableContinuation<Unit>) {
            error("This fixture only advances read deadlines, not UI animation delays")
        }
        override fun invokeOnTimeout(timeMillis: Long, block: Runnable, context: kotlin.coroutines.CoroutineContext): DisposableHandle {
            deadlines += block
            return object : DisposableHandle { override fun dispose() { deadlines.remove(block) } }
        }
        fun expire() { deadlines.toList().forEach { it.run() } }
    }

    @Test fun admittedReadDeadlineReleasesPlatformSlotAndReturnsMissSoFallbackCanContinue() {
        for (local in listOf(false, true)) {
            val clock = ManualDeadline(); val p = Platform()
            val s = NativePreviewReadSession(7, p, { true }, clock, 30_000L, { _, _ -> true })
            val result = Pending { if (local) s.localBitmap(file, "frozen") else s.fhd(file) }
            assertNull(result.result); assertEquals(1, p.reads.size + p.locals.size)
            assertEquals(1, clock.deadlines.size)
            clock.expire()
            assertNull(result.result!!.getOrThrow()); assertFalse(result.job.isCancelled)
            assertEquals(listOf(7L to 1L), p.cancelled); assertTrue(clock.deadlines.isEmpty())
            p.reads[1]?.complete(ownedFhdPreviewPng(png()))
            p.locals[1]?.complete(ownedLocalPreviewPng(png()))
            assertNull(result.result!!.getOrThrow())
            val next = Pending { s.fhd(file) }; p.reads[2]!!.complete(null)
            assertNull(next.result!!.getOrThrow()); assertTrue(p.ended.isEmpty())
            s.close()
        }
    }

    @Test fun localAndFhdShareOneRequestIdSpaceAndCombinedPendingLimit() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { true }, Dispatchers.Unconfined, isFrozenLocalSource = { _, _ -> true })
        val jobs = List(32) { i -> Pending { if (i % 2 == 0) s.fhd(file) else s.localBitmap(file, "frozen") } }
        assertNull(Pending { s.localBitmap(file, "frozen") }.result!!.getOrThrow())
        assertEquals(16, p.reads.size); assertEquals(16, p.locals.size)
        assertTrue(p.reads.keys.intersect(p.locals.keys).isEmpty())
        s.close(); assertTrue(jobs.all { it.result?.isFailure == true })
        p.locals.values.forEach { it.complete(ownedLocalPreviewPng(png())) }
        assertTrue(jobs.all { it.result?.isFailure == true })
    }

    @Test fun localCancelNeverCompletesALaterFhdReadAndDoesNotEndParentSession() {
        val p = Platform()
        val s = NativePreviewReadSession(7, p, { true }, Dispatchers.Unconfined, isFrozenLocalSource = { _, _ -> true })
        val first = Pending { s.localBitmap(file, "frozen") }; first.job.cancel()
        val second = Pending { s.fhd(file) }
        p.locals[1]!!.complete(ownedLocalPreviewPng(png()))
        assertTrue(first.result!!.isFailure); assertNull(second.result); assertTrue(p.ended.isEmpty())
        p.reads[2]!!.complete(null); assertNull(second.result!!.getOrThrow())
        s.close()
    }

    @Test fun localPayloadPreservesFullDimensionsAndDoesNotRelaxFhdOrProbeLimits() {
        val bytes = png(8256, 5504)
        val local = assertNotNull(ownedLocalPreviewPng(bytes))
        assertSame(bytes, local.encoded); assertEquals(8256, local.width); assertEquals(5504, local.height)
        assertNull(ownedFhdPreviewPng(bytes)); assertFalse(isBoundedSinglePhotoPng(bytes))
        assertNotNull(ownedLocalPreviewPng(png().copyOf(SINGLE_PHOTO_MAX_BYTES + 1)))
        for (bad in listOf(png().copyOf(32), png(-1, 1), png(1, 0), png().also { it[12] = 0 })) {
            assertNull(ownedLocalPreviewPng(bad))
        }
    }
}
