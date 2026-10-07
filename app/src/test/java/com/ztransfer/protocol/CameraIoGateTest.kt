package com.ztransfer.protocol

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CameraIoGateTest {
    @Test
    fun interactiveWaiterRunsBeforeNextTransferSlice() = runBlocking {
        val gate = CameraIoGate()
        val firstSliceEntered = CompletableDeferred<Unit>()
        val releaseFirstSlice = CompletableDeferred<Unit>()
        val interactiveRegistered = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()

        val firstSlice = launch {
            gate.withTransferSlice {
                order += "transfer-1"
                firstSliceEntered.complete(Unit)
                releaseFirstSlice.await()
            }
        }
        firstSliceEntered.await()

        val interactive = launch {
            gate.withInteractivePriority {
                interactiveRegistered.complete(Unit)
                gate.withInteractive { order += "interactive" }
            }
        }
        interactiveRegistered.await()
        val secondSlice = launch {
            gate.withTransferSlice { order += "transfer-2" }
        }

        releaseFirstSlice.complete(Unit)
        joinAll(firstSlice, interactive, secondSlice)

        assertEquals(listOf("transfer-1", "interactive", "transfer-2"), order)
    }

    @Test
    fun priorityReservationKeepsTransferOutBetweenInteractiveCommands() = runBlocking {
        val gate = CameraIoGate()
        val transferQueued = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        lateinit var transfer: kotlinx.coroutines.Job

        gate.withInteractivePriority {
            gate.withInteractive { order += "fhd" }
            transfer = launch {
                transferQueued.complete(Unit)
                gate.withTransferSlice { order += "transfer" }
            }
            transferQueued.await()
            yield()
            gate.withInteractive { order += "exif" }
        }
        transfer.join()

        assertEquals(listOf("fhd", "exif", "transfer"), order)
    }

    @Test
    fun interactivePreemptsPreviewTransferAndRating() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val active = launch {
            gate.withBackgroundThumbnail {
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val rating = launch { gate.withRatingTransaction { order += "rating" } }
        val transfer = launch { gate.withTransferSlice { order += "transfer" } }
        val preview = launch { gate.withPreviewTransaction { order += "preview" } }
        val interactive = launch { gate.withInteractive { order += "interactive" } }
        yield()
        release.complete(Unit)
        joinAll(active, interactive, preview, transfer, rating)
        assertEquals(listOf("interactive", "preview", "transfer", "rating"), order)
    }

    @Test
    fun ratingTransactionRunsBeforeQueuedVisibleThumbnail() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()

        val visible = launch {
            gate.withVisibleThumbnail {
                order += "visible-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        gate.beginRatingPhase()
        val background = async {
            gate.withBackgroundThumbnail { order += "background" }
        }
        val rating = async {
            gate.withRatingTransaction("rating") { order += "rating" }
        }

        release.complete(Unit)
        joinAll(visible, rating)
        gate.endRatingPhase()
        background.await()
        assertEquals(listOf("visible-1", "rating", "background"), order)
    }

    @Test
    fun transferPreemptsQueuedThumbnailsOutsideRatingPhase() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val first = launch {
            gate.withTransferSlice {
                order += "transfer-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val thumbnail = launch { gate.withBackgroundThumbnail { order += "thumbnail" } }
        val second = launch { gate.withTransferSlice { order += "transfer-2" } }
        yield()
        release.complete(Unit)
        joinAll(first, thumbnail, second)
        assertEquals(listOf("transfer-1", "transfer-2", "thumbnail"), order)
    }

    @Test
    fun firstTransferPreemptsBothVisibleAndBackgroundThumbnailBacklog() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val activeThumbnail = launch {
            gate.withBackgroundThumbnail {
                order += "active-thumbnail"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val visible = launch { gate.withVisibleThumbnail { order += "visible-thumbnail" } }
        val background = launch { gate.withBackgroundThumbnail { order += "background-thumbnail" } }
        val firstTransfer = launch { gate.withTransferSlice { order += "first-transfer" } }
        yield()
        release.complete(Unit)
        joinAll(activeThumbnail, visible, background, firstTransfer)
        assertEquals(
            listOf("active-thumbnail", "first-transfer", "visible-thumbnail", "background-thumbnail"),
            order,
        )
    }

    @Test
    fun ratingPhaseLetsTransferWinButPutsRemoteThumbnailsAfterRating() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val first = launch {
            gate.withTransferSlice {
                order += "transfer-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        gate.beginRatingPhase()
        val thumbnail = launch { gate.withBackgroundThumbnail { order += "thumbnail" } }
        val rating = launch { gate.withRatingTransaction { order += "rating" } }
        val second = launch { gate.withTransferSlice { order += "transfer-2" } }
        yield()
        release.complete(Unit)
        joinAll(first, rating, second)
        gate.endRatingPhase()
        thumbnail.join()
        assertEquals(listOf("transfer-1", "transfer-2", "rating", "thumbnail"), order)
    }

    @Test
    fun ratingPhaseLetsPreviewWinButBlocksLowPriorityAdmission() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val first = launch {
            gate.withPreviewTransaction("preview-1") {
                order += "preview-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        gate.beginRatingPhase()
        val background = launch { gate.withBackgroundThumbnail { order += "background" } }
        val secondPreview = launch { gate.withPreviewTransaction("preview-2") { order += "preview-2" } }
        val rating = launch { gate.withRatingTransaction { order += "rating" } }
        release.complete(Unit)
        joinAll(first, secondPreview, rating)
        assertEquals(listOf("preview-1", "preview-2", "rating"), order)
        gate.endRatingPhase()
        background.join()
        assertEquals(listOf("preview-1", "preview-2", "rating", "background"), order)
    }

    @Test
    fun ratingPhaseBlocksIdleCommandsBetweenFilesButRunsThemAfterPhase() = runBlocking {
        val gate = CameraIoGate()
        val order = mutableListOf<String>()
        gate.beginRatingPhase()
        val idle = launch { gate.withIdleCommand(Unit) { order += "idle" } }
        yield()
        assertTrue(order.isEmpty())
        val rating = launch { gate.withRatingTransaction { order += "rating" } }
        rating.join()
        assertEquals(listOf("rating"), order)
        gate.endRatingPhase()
        idle.join()
        assertEquals(listOf("rating", "idle"), order)
    }

    @Test
    fun ratingPhaseKeepsEventPollingBehindRating() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val firstEvent = launch {
            gate.withCameraTransaction(CameraRequestKind.EVENT_POLL, "EVENT_POLL") {
                order += "event-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        gate.beginRatingPhase()
        val event = launch {
            gate.withCameraTransaction(CameraRequestKind.EVENT_POLL, "EVENT_POLL") { order += "event-2" }
        }
        val nextRating = launch { gate.withRatingTransaction { order += "rating" } }
        release.complete(Unit)
        joinAll(firstEvent, nextRating)
        gate.endRatingPhase()
        event.join()
        assertEquals(listOf("event-1", "rating", "event-2"), order)
    }

    @Test
    fun eventPollingKeepsLegacyFifoOutsideRatingPhase() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val first = launch {
            gate.withTransferSlice {
                order += "transfer-1"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val event = launch {
            gate.withCameraTransaction(CameraRequestKind.EVENT_POLL, "EVENT_POLL") { order += "event" }
        }
        val second = launch { gate.withTransferSlice { order += "transfer-2" } }
        yield()
        release.complete(Unit)
        joinAll(first, event, second)
        assertEquals(listOf("transfer-1", "event", "transfer-2"), order)
    }

    @Test
    fun cancelledQueuedTransactionDoesNotBlockNextRequest() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()

        val active = launch {
            gate.withVisibleThumbnail {
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val queued = launch {
            gate.withBackgroundThumbnail { order += "cancelled" }
        }
        yield()
        queued.cancelAndJoin()

        val rating = launch {
            gate.withRatingTransaction { order += "rating" }
        }
        release.complete(Unit)
        joinAll(active, rating)
        assertEquals(listOf("rating"), order)
    }

    @Test
    fun closingSessionCancelsAllQueuedTransactionsButKeepsActiveOne() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()

        val active = launch {
            gate.withVisibleThumbnail {
                order += "active"
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        launch {
            try {
                gate.withBackgroundThumbnail { order += "queued" }
            } catch (_: CancellationException) {
                cancelled.complete(Unit)
            }
        }
        yield()

        gate.beginShutdown()
        cancelled.await()
        release.complete(Unit)
        active.join()

        assertEquals(listOf("active"), order)
        assertEquals(0, gate.snapshot().queued)
    }

    @Test
    fun shutdownRejectsNewRequestsButAllowsCloseTransaction() = runBlocking {
        val gate = CameraIoGate()
        gate.beginShutdown("test shutdown")

        try {
            gate.withBackgroundThumbnail { fail("new request must be rejected after shutdown") }
            fail("new request must be rejected after shutdown")
        } catch (error: CancellationException) {
            assertEquals("test shutdown", error.message)
        }

        var closed = false
        gate.withCameraTransaction(
            CameraRequestKind.INTERACTIVE,
            "CLOSE_SESSION",
            block = { closed = true },
            allowDuringShutdown = true,
        )
        assertTrue(closed)
    }

    @Test
    fun cancellingActiveTransactionReleasesSchedulerForNextRequest() = runBlocking {
        val gate = CameraIoGate()
        val entered = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()

        val active = launch {
            gate.withVisibleThumbnail {
                entered.complete(Unit)
                awaitCancellation()
            }
        }
        entered.await()
        val next = launch {
            gate.withRatingTransaction { order += "rating" }
        }
        yield()

        active.cancelAndJoin()
        next.join()
        assertEquals(listOf("rating"), order)
    }

    @Test
    fun nestedCameraTransactionIsRejected() = runBlocking {
        val gate = CameraIoGate()
        try {
            gate.withCameraTransaction(CameraRequestKind.INTERACTIVE, "outer") {
                gate.withRatingTransaction("inner") { Unit }
            }
            fail("nested camera transactions must be rejected")
        } catch (error: IllegalStateException) {
            assertTrue(error.message.orEmpty().contains("Nested camera transaction"))
        }
    }

    @Test
    fun cancelledPriorityReservationDoesNotBlockTransfers() = runBlocking {
        val registered = CompletableDeferred<Unit>()
        val gate = CameraIoGate()
        val reservation = launch {
            gate.withInteractivePriority {
                registered.complete(Unit)
                awaitCancellation()
            }
        }
        registered.await()
        reservation.cancelAndJoin()

        withTimeout(1_000) {
            gate.withTransferSlice { }
        }
    }

    @Test
    fun idleCommandIsSkippedForWholeDownloadIncludingSliceGaps() = runBlocking {
        val gate = CameraIoGate()
        val betweenSlices = CompletableDeferred<Unit>()
        val finishDownload = CompletableDeferred<Unit>()
        var idleCommandRuns = 0

        val download = launch {
            gate.withDownloadActivity {
                gate.withTransferSlice { }
                betweenSlices.complete(Unit)
                finishDownload.await()
                gate.withTransferSlice { }
            }
        }
        betweenSlices.await()

        val result = gate.withIdleCommand(skippedValue = "skipped") {
            idleCommandRuns++
            "ran"
        }
        assertEquals("skipped", result)
        assertEquals(0, idleCommandRuns)

        finishDownload.complete(Unit)
        download.join()
        assertEquals(
            "ran",
            gate.withIdleCommand(skippedValue = "skipped") {
                idleCommandRuns++
                "ran"
            },
        )
        assertEquals(1, idleCommandRuns)
    }

    @Test
    fun idleCommandRechecksActivityAfterWaitingForMutex() = runBlocking {
        val gate = CameraIoGate()
        val mutexHeld = CompletableDeferred<Unit>()
        val releaseMutex = CompletableDeferred<Unit>()
        val downloadRegistered = CompletableDeferred<Unit>()
        val finishDownload = CompletableDeferred<Unit>()
        var idleCommandRuns = 0

        val holder = launch {
            gate.mutex.withLock {
                mutexHeld.complete(Unit)
                releaseMutex.await()
            }
        }
        mutexHeld.await()
        val idleCommand = launch {
            assertEquals(
                "skipped",
                gate.withIdleCommand(skippedValue = "skipped") {
                    idleCommandRuns++
                    "ran"
                },
            )
        }
        yield()
        val download = launch {
            gate.withDownloadActivity {
                downloadRegistered.complete(Unit)
                finishDownload.await()
            }
        }
        downloadRegistered.await()

        releaseMutex.complete(Unit)
        joinAll(holder, idleCommand)
        assertEquals(0, idleCommandRuns)

        finishDownload.complete(Unit)
        download.join()
    }

    @Test
    fun cancelledDownloadAlwaysRestoresIdleCommands() = runBlocking {
        val gate = CameraIoGate()
        val registered = CompletableDeferred<Unit>()
        val download = launch {
            gate.withDownloadActivity {
                registered.complete(Unit)
                awaitCancellation()
            }
        }
        registered.await()
        download.cancelAndJoin()

        assertTrue(gate.withIdleCommand(skippedValue = false) { true })
    }

    @Test(timeout = 5000)
    fun ratingGapsBlockEveryBackgroundKindButAllowForegroundAndLocalWork() = runBlocking {
        val gate = CameraIoGate()
        val background = listOf(CameraRequestKind.VISIBLE_THUMBNAIL,
            CameraRequestKind.BACKGROUND_THUMBNAIL, CameraRequestKind.IDLE,
            CameraRequestKind.EVENT_POLL)
        val order = mutableListOf<String>()
        gate.beginRatingPhase()
        val waiting = background.map { kind ->
            launch { gate.withCameraTransaction(kind) { order += kind.name } }
        }
        yield()
        assertEquals(4, gate.snapshot().queued)
        repeat(2) {
            // No rating ticket is queued during this local work, but the phase stays active.
            val local = async { "cached thumbnail" }
            assertEquals("cached thumbnail", local.await())
            for (kind in listOf(CameraRequestKind.INTERACTIVE, CameraRequestKind.PREVIEW,
                CameraRequestKind.TRANSFER, CameraRequestKind.RATING)) {
                gate.withCameraTransaction(kind) { order += kind.name }
            }
            assertFalse(order.any { name -> background.any { it.name == name } })
        }
        gate.endRatingPhase()
        waiting.joinAll()
        assertEquals(0, gate.snapshot().queued)
        assertEquals(background.toSet(), order.takeLast(4).map { CameraRequestKind.valueOf(it) }.toSet())
    }

    @Test(timeout = 5000)
    fun cancelledRatingPassReleasesBlockedRequestsInFinally() = runBlocking {
        val gate = CameraIoGate()
        val started = CompletableDeferred<Unit>()
        val scan = launch {
            gate.beginRatingPhase()
            try {
                started.complete(Unit)
                awaitCancellation()
            } finally { gate.endRatingPhase() }
        }
        started.await()
        var ran = false
        val thumbnail = launch { gate.withBackgroundThumbnail { ran = true } }
        yield()
        assertFalse(ran)
        scan.cancelAndJoin()
        thumbnail.join()
        assertTrue(ran)
    }

    @Test(timeout = 5000)
    fun shutdownClearsPhaseBlockedRequestsAndAllowsClose() = runBlocking {
        val gate = CameraIoGate()
        gate.beginRatingPhase()
        val queued = listOf(CameraRequestKind.EVENT_POLL, CameraRequestKind.IDLE,
            CameraRequestKind.BACKGROUND_THUMBNAIL).map { kind ->
            launch { gate.withCameraTransaction(kind) { fail("blocked request ran") } }
        }
        yield()
        gate.beginShutdown()
        queued.joinAll()
        assertTrue(queued.all { it.isCancelled })
        gate.withCameraTransaction(CameraRequestKind.INTERACTIVE, "close", true) { Unit }
        gate.endRatingPhase()
        assertEquals(0, gate.snapshot().queued)
    }

    @Test(timeout = 5000)
    fun monitorEventsRemainAvailableWhileBackgroundEventsWaitForRating() = runBlocking {
        val gate = CameraIoGate()
        gate.beginRatingPhase()
        var backgroundRan = false
        val background = launch {
            gate.withCameraTransaction(eventPollRequestKind(true)) { backgroundRan = true }
        }
        yield()
        assertFalse(backgroundRan)
        var monitorRan = false
        gate.withCameraTransaction(eventPollRequestKind(false)) { monitorRan = true }
        assertTrue(monitorRan)
        assertFalse(backgroundRan)
        gate.endRatingPhase()
        background.join()
        assertTrue(backgroundRan)
    }

    @Test(timeout = 5000)
    fun overlappingRatingLifecyclesCannotReleaseAnotherPassBarrier() = runBlocking {
        val gate = CameraIoGate()
        gate.beginRatingPhase()
        gate.beginRatingPhase()
        var ran = false
        val thumbnail = launch { gate.withBackgroundThumbnail { ran = true } }
        yield()
        gate.endRatingPhase()
        yield()
        assertFalse(ran)
        gate.withRatingTransaction { Unit }
        gate.endRatingPhase()
        thumbnail.join()
        assertTrue(ran)
    }

    @Test
    fun wifiKnownSizesPreferPartialObjectPath() {
        assertEquals(4L * 1024 * 1024, NikonCamera.CHUNK_SIZE)
        assertEquals(0L, (64L * 1024 * 1024) % NikonCamera.CHUNK_SIZE)
        assertTrue(shouldUsePartialObjectDownload(null, 1L))
        assertTrue(shouldUsePartialObjectDownload(true, 48L * 1024 * 1024))
        assertFalse(shouldUsePartialObjectDownload(false, 48L * 1024 * 1024))
        assertFalse(shouldUsePartialObjectDownload(null, PtpConstants.SIZE_UNKNOWN))
        assertFalse(shouldUsePartialObjectDownload(null, 0L))
    }

    @Test
    fun hugeFilesUseLargerChunksWithoutChangingResumeAlignment() {
        assertEquals(
            NikonCamera.CHUNK_SIZE,
            downloadChunkSize(
                effectiveSize = NikonCamera.LARGE_FILE_THRESHOLD,
                isUsbConnection = false,
            ),
        )
        assertEquals(
            NikonCamera.LARGE_FILE_CHUNK_SIZE,
            downloadChunkSize(
                effectiveSize = NikonCamera.LARGE_FILE_THRESHOLD + 1L,
                isUsbConnection = false,
            ),
        )
        assertEquals(
            0L,
            NikonCamera.LARGE_FILE_CHUNK_SIZE % NikonCamera.CHUNK_SIZE,
        )
    }

    @Test
    fun highThroughputModeUsesFullObjectFastPathForOrdinaryNewFiles() {
        assertEquals(128L * 1024L * 1024L, NikonCamera.HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD)
        assertFalse(
            shouldUsePartialObjectDownload(
                partialObjectSupported = null,
                effectiveSize = 26L * 1024L * 1024L,
                isUsbConnection = true,
            ),
        )
        assertFalse(
            shouldUsePartialObjectDownload(
                partialObjectSupported = null,
                effectiveSize = NikonCamera.HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD,
                isUsbConnection = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                partialObjectSupported = null,
                effectiveSize = NikonCamera.HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD + 1L,
                isUsbConnection = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                partialObjectSupported = true,
                effectiveSize = 26L * 1024L * 1024L,
                resumeOffset = NikonCamera.CHUNK_SIZE,
                isUsbConnection = true,
            ),
        )
        assertFalse(
            shouldUsePartialObjectDownload(
                partialObjectSupported = null,
                effectiveSize = 26L * 1024L * 1024L,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                partialObjectSupported = true,
                effectiveSize = 26L * 1024L * 1024L,
                resumeOffset = NikonCamera.CHUNK_SIZE,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                partialObjectSupported = true,
                effectiveSize = NikonCamera.HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD + 1L,
                preferHighThroughput = true,
            ),
        )
        assertTrue(
            shouldUsePartialObjectDownload(
                partialObjectSupported = true,
                effectiveSize = 26L * 1024L * 1024L,
                preferHighThroughput = true,
                forcePartial = true,
            ),
        )
    }

    @Test
    fun highThroughputPartialPathUses64MbSlicesWhileWifiBrowsePolicyIsUnchanged() {
        assertEquals(64L * 1024L * 1024L, NikonCamera.HIGH_THROUGHPUT_CHUNK_SIZE)
        assertEquals(
            NikonCamera.HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(effectiveSize = 26L * 1024L * 1024L, isUsbConnection = true),
        )
        assertEquals(
            NikonCamera.HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(effectiveSize = 1L * 1024L * 1024L * 1024L, isUsbConnection = true),
        )
        assertEquals(
            NikonCamera.HIGH_THROUGHPUT_CHUNK_SIZE,
            downloadChunkSize(
                effectiveSize = 26L * 1024L * 1024L,
                preferHighThroughput = true,
            ),
        )
        assertEquals(
            NikonCamera.CHUNK_SIZE,
            downloadChunkSize(effectiveSize = 26L * 1024L * 1024L, isUsbConnection = false),
        )
    }
}
