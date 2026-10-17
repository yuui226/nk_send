package com.ztransfer.ui.screen

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectsPreviewTransitionTest {
    private data class Canvas(val rotation: Int = 0, val border: String? = null)
    private data class Frame(val image: Int, val canvas: Canvas = Canvas(), val comparison: Boolean = false)

    private fun plan(current: Frame?, next: Frame?, requested: Canvas) =
        planPhotoEffectsPreviewTransition(current, next, requested, Frame::canvas) { a, b ->
            a.image == b.image
        }

    @Test(timeout = 5_000)
    fun exifUpdatesDuringFirstFadeFinishTheVisibleFrameAndKeepOnlyTheLatestPendingFrame() = runBlocking {
        val frames = Channel<Frame>(Channel.UNLIMITED)
        val firstFadeStarted = CompletableDeferred<Unit>()
        val completeFirstFade = CompletableDeferred<Unit>()
        val started = mutableListOf<Int>()
        val completed = mutableListOf<Int>()
        val collector = launch(start = CoroutineStart.UNDISPATCHED) {
            frames.receiveAsFlow().collectPhotoEffectsPreviewTransitions { frame ->
                started += frame.image
                if (frame.image == 1) {
                    firstFadeStarted.complete(Unit)
                    completeFirstFade.await()
                }
                completed += frame.image
            }
        }
        frames.send(Frame(1))
        firstFadeStarted.await()
        frames.send(Frame(2))
        frames.send(Frame(3))
        // Let the producer merge pending EXIF/FHD results while the first fade is suspended.
        yield()
        assertEquals(listOf(1), started)
        assertTrue(completed.isEmpty())
        completeFirstFade.complete(Unit)
        frames.close()
        collector.join()
        assertEquals(listOf(1, 3), started)
        assertEquals(listOf(1, 3), completed)
    }

    @Test
    fun anOutdatedFirstFrameIsNotAcceptedBeforeTheRequestedDirectionIsReady() {
        val requested = Canvas(rotation = 1)
        val stale = plan(null, Frame(1), requested)
        assertEquals(PhotoEffectsPreviewChange.KEEP, stale.change)
        assertNull(stale.frame)

        val ready = Frame(2, requested)
        val accepted = plan(stale.frame, ready, requested)
        assertEquals(PhotoEffectsPreviewChange.INITIAL, accepted.change)
        assertEquals(ready, accepted.frame)
    }

    @Test
    fun rotationReversalRejectsAnOutdatedFrameAndRestoresTheOriginalCanvas() {
        val original = Frame(1)
        val rotated = Canvas(rotation = 1)
        assertFalse(photoEffectsPreviewCanvasVisible(original.canvas, rotated, failed = false))

        val obsoleteResult = plan(original, Frame(2, rotated), original.canvas)
        assertEquals(PhotoEffectsPreviewChange.KEEP, obsoleteResult.change)
        assertEquals(original, obsoleteResult.frame)
        assertTrue(photoEffectsPreviewCanvasVisible(original.canvas, original.canvas, failed = false))
    }

    @Test
    fun borderChangesReplaceTheCanvasWhileARevertedBorderResultIsIgnored() {
        val original = Frame(1)
        val bordered = Frame(2, Canvas(border = "plate"))
        assertEquals(PhotoEffectsPreviewChange.REPLACE_CANVAS, plan(original, bordered, bordered.canvas).change)

        val reverted = plan(original, bordered, original.canvas)
        assertEquals(PhotoEffectsPreviewChange.KEEP, reverted.change)
        assertEquals(original, reverted.frame)
    }

    @Test
    fun aFailedCanvasReplacementRestoresTheExistingFrameUntilTheNextRequest() {
        val original = Frame(1)
        val requested = Canvas(rotation = 1, border = "plate")
        assertEquals(PhotoEffectsPreviewChange.KEEP, plan(original, original, requested).change)
        assertFalse(photoEffectsPreviewCanvasVisible(original.canvas, requested, failed = false))
        assertTrue(photoEffectsPreviewCanvasVisible(original.canvas, requested, failed = true))
        assertFalse(photoEffectsPreviewCanvasVisible(original.canvas, requested, failed = false))

        val recovered = Frame(2, requested)
        assertEquals(PhotoEffectsPreviewChange.REPLACE_CANVAS, plan(original, recovered, requested).change)
        assertTrue(photoEffectsPreviewCanvasVisible(recovered.canvas, requested, failed = false))
    }

    @Test
    fun comparisonUpdatesDoNotReplayTheFadeButNewEffectFramesDo() {
        val original = Frame(1)
        assertEquals(PhotoEffectsPreviewChange.INITIAL, plan(null, original, original.canvas).change)
        assertEquals(
            PhotoEffectsPreviewChange.UPDATE,
            plan(original, original.copy(comparison = true), original.canvas).change,
        )
        assertEquals(PhotoEffectsPreviewChange.CROSSFADE, plan(original, Frame(2), original.canvas).change)
    }
}
