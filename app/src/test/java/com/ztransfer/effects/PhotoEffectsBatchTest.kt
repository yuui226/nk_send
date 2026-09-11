package com.ztransfer.effects

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectsBatchTest {
    @Test fun processesEveryPhotoWithAtMostTwoInFlightAndMonotonicProgress() = runBlocking {
        withTimeout(5_000) {
            val active = AtomicInteger()
            val peak = AtomicInteger()
            val counts = mutableListOf<PhotoEffectsBatchProgress>()
            val seen = mutableListOf<Int>()
            val result = generatePhotoEffectsBatch((1..75).toList(), counts::add) { photo ->
                val concurrent = active.incrementAndGet()
                peak.updateAndGet { maxOf(it, concurrent) }
                delay(if (photo % 2 == 0) 1 else 3)
                seen += photo
                active.decrementAndGet()
                true
            }
            assertEquals(2, peak.get())
            assertEquals((1..75).toList(), seen.sorted())
            assertEquals((0..75).toList(), counts.map { it.completed })
            assertTrue(counts.all { it.total == 75 })
            assertEquals(PhotoEffectsBatchProgress(75, 75, 75), result)
        }
    }

    @Test fun failuresAreCountedAndDoNotStopOtherPhotos() = runBlocking {
        val result = generatePhotoEffectsBatch((1..5).toList(), {}) {
            when (it) {
                2 -> error("Unreadable input")
                4 -> false
                else -> true
            }
        }
        assertEquals(PhotoEffectsBatchProgress(5, 5, 3), result)
        assertEquals(2, result.failed)
    }

    @Test fun emptyAndSingleSelectionsHaveAccurateTotals() = runBlocking {
        assertEquals(PhotoEffectsBatchProgress(0), generatePhotoEffectsBatch(emptyList<Int>(), {}) { error("No work") })
        assertEquals(PhotoEffectsBatchProgress(1, 1, 1), generatePhotoEffectsBatch(listOf(1), {}) { true })
    }

    @Test fun lifecycleCancellationDoesNotCountUnfinishedPhotosAsFailures() = runBlocking {
        withTimeout(5_000) {
            val started = CompletableDeferred<Unit>()
            val counts = mutableListOf<PhotoEffectsBatchProgress>()
            val job = async {
                generatePhotoEffectsBatch(listOf(1, 2, 3), counts::add) {
                    started.complete(Unit)
                    awaitCancellation()
                }
            }
            started.await()
            job.cancelAndJoin()
            assertTrue(job.isCancelled)
            assertEquals(listOf(PhotoEffectsBatchProgress(3)), counts)
        }
    }

    @Test fun workerCancellationIsPropagatedInsteadOfReportedAsCompletion() = runBlocking {
        var cancelled = false
        try {
            generatePhotoEffectsBatch(listOf(1, 2), {}) { throw CancellationException("disposed") }
        } catch (_: CancellationException) {
            cancelled = true
        }
        assertTrue(cancelled)
    }
}
