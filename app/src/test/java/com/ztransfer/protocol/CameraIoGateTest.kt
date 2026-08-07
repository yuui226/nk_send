package com.ztransfer.protocol

import kotlinx.coroutines.CompletableDeferred
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

    @Test
    fun allKnownSizesPreferExistingPartialObjectPath() {
        assertEquals(2L * 1024 * 1024, NikonCamera.CHUNK_SIZE)
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
            downloadChunkSize(NikonCamera.LARGE_FILE_THRESHOLD),
        )
        assertEquals(
            NikonCamera.LARGE_FILE_CHUNK_SIZE,
            downloadChunkSize(NikonCamera.LARGE_FILE_THRESHOLD + 1L),
        )
        assertEquals(
            0L,
            NikonCamera.LARGE_FILE_CHUNK_SIZE % NikonCamera.CHUNK_SIZE,
        )
    }
}
