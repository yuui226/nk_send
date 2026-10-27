package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.ui.MotionDurationScale
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil

class QueueRemovalMotionTest {
    @Test
    fun onlyEligibleVisibleRowsStaggerInTheirScreenOrder() {
        val delays = queueRemovalDelays(
            visibleItems = listOf(3L to 160, 8L to 40, 1L to -20, 2L to 80),
            targetIds = setOf(1L, 2L, 3L, 100L),
            stagger = true,
        )
        assertEquals(listOf(1L, 2L, 3L), delays.keys.toList())
        assertEquals(listOf(0, 20, 40), delays.values.toList())
    }

    @Test
    fun longQueuesNeverCreateDelaysForOffscreenRowsOrExceedTheCap() {
        val delays = queueRemovalDelays(
            visibleItems = (1L..7L).map { it to it.toInt() * 60 },
            targetIds = (1L..10000L).toSet(),
            stagger = true,
        )
        assertEquals(7, delays.size)
        assertEquals(listOf(0, 20, 40, 60, 80, 80, 80), delays.values.toList())
        assertEquals(400L, queueRemovalCleanupDelay(delays))
    }

    @Test
    fun singleRemovalAndEmptyViewportDoNotWaitForAStagger() {
        val single = queueRemovalDelays(listOf(5L to 200), setOf(5L), stagger = false)
        assertEquals(mapOf(5L to 0), single)
        assertEquals(320L, queueRemovalCleanupDelay(single))
        val offscreen = queueRemovalDelays(listOf(4L to 0), setOf(5L), stagger = true)
        assertTrue(offscreen.isEmpty())
        assertEquals(0L, queueRemovalCleanupDelay(offscreen))
    }

    @Test
    fun drawingFadesBeforeTheLayoutCollapsesAndFinishesBeforeHeightReachesZero() {
        assertEquals(1f, queueRemovalOpacity(1f), .0001f)
        assertEquals(1f, queueRemovalHeight(1f), .0001f)
        assertTrue(queueRemovalOpacity(.9f) < 1f)
        assertEquals(1f, queueRemovalHeight(.9f), .0001f)
        assertEquals(0f, queueRemovalOpacity(.36f), .0001f)
        assertTrue(queueRemovalHeight(.36f) > 0f)
        assertEquals(0f, queueRemovalOpacity(0f), .0001f)
        assertEquals(0f, queueRemovalHeight(0f), .0001f)
    }

    @Test
    fun removalNeverExpandsOrFlickersBackDuringItsTimeline() {
        var previousOpacity = 1f
        var previousHeight = 1f
        for (step in 0..100) {
            val progress = 1f - step / 100f
            val opacity = queueRemovalOpacity(progress)
            val height = queueRemovalHeight(progress)
            assertTrue(opacity in 0f..1f && height in 0f..1f)
            assertTrue(opacity <= previousOpacity && height <= previousHeight)
            previousOpacity = opacity
            previousHeight = height
        }
    }

    @Test
    fun cleanupNeverPrecedesRowsAtAnySystemAnimationScale() = runBlocking {
        val delays = mapOf(1L to 0, 2L to 20, 3L to 80)
        for (scale in listOf(0f, .5f, 1f, 2f, 10f)) {
            val clock = BroadcastFrameClock()
            val durationScale = object : MotionDurationScale {
                override val scaleFactor = scale
            }
            withContext(clock + durationScale) {
                val values = delays.values.map { Animatable(1f) to it }
                val rows = values.map { (value, stagger) ->
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        value.animateTo(0f, queueRemovalAnimationSpec(stagger))
                    }
                }
                val cleanup = launch(start = CoroutineStart.UNDISPATCHED) {
                    awaitQueueRemovalCleanup(delays)
                    assertTrue("Cleanup preceded a row at ${scale}x", rows.all { it.isCompleted })
                }
                clock.sendFrame(0L)
                yield()
                if (scale > 0f) {
                    // Wall time can pass while the UI has no frame. A fixed timer must not
                    // remove still-visible rows, including when system animations are slower.
                    delay(queueRemovalCleanupDelay(delays) + 40L)
                    assertFalse("Cleanup ignored the paused frame clock at ${scale}x", cleanup.isCompleted)
                }
                val lastFrameMs = ceil((QUEUE_REMOVAL_DURATION_MS + 80) * scale).toInt() + 32
                for (frameMs in 16..lastFrameMs step 16) {
                    clock.sendFrame(frameMs * 1_000_000L)
                    yield()
                }
                withTimeout(1_000) {
                    rows.joinAll()
                    cleanup.join()
                }
                values.forEach { (value, _) -> assertEquals(0f, value.value, .0001f) }
                assertFalse("Finished animations retained a frame waiter", clock.hasAwaiters)
            }
        }
    }

    @Test
    fun cancellingCleanupReleasesItsFrameWaiterAndRunsCallerFinally() = runBlocking {
        val clock = BroadcastFrameClock()
        var finishedNormally = false
        var callerCleanedUp = false
        val cleanup = launch(clock, start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitQueueRemovalCleanup(mapOf(1L to 0))
                finishedNormally = true
            } finally {
                callerCleanedUp = true
            }
        }
        assertTrue(clock.hasAwaiters)
        cleanup.cancelAndJoin()
        assertTrue(cleanup.isCancelled)
        assertTrue(callerCleanedUp)
        assertFalse(finishedNormally)
        assertFalse(clock.hasAwaiters)
    }

    @Test
    fun emptyViewportCleanupNeedsNoAnimationFrame() = runBlocking {
        withTimeout(1_000) { awaitQueueRemovalCleanup(emptyMap()) }
    }
}
