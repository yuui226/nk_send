package com.ztransfer.viewmodel

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkOpacity
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.PhotoFrameWatermarkSize
import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TransferStateTest {
    private fun file(handle: Int) = NikonCamera.FileInfo(
        handle = handle,
        size = 100L,
        fileName = "DSC_$handle.JPG",
        captureDate = null,
    )

    @Test
    fun frameGenerationRemainsPartOfPendingWork() {
        val state = TransferState(
            tasks = listOf(
                TransferTask(file(1), status = TransferStatus.WAITING),
                TransferTask(
                    file(2),
                    status = TransferStatus.TRANSFERING,
                    progress = 0.4f,
                ),
                TransferTask(
                    file(3),
                    status = TransferStatus.COMPLETED,
                    progress = 1f,
                    isGeneratingFrame = true,
                ),
            ),
        )

        assertEquals(3, state.remainingCount)
        assertEquals(0.4f, state.currentFileProgress)
    }

    @Test
    fun frameGenerationKeepsCompletedSourceAtFullProgress() {
        val state = TransferState(
            tasks = listOf(
                TransferTask(
                    file(1),
                    status = TransferStatus.COMPLETED,
                    progress = 1f,
                    isGeneratingFrame = true,
                ),
            ),
        )

        assertEquals(1, state.remainingCount)
        assertEquals(1f, state.currentFileProgress)
    }

    @Test
    fun framesAreGeneratedOnlyForJpegPhotos() {
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".jpg"))
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".JPEG"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".mov"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".mp4"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".nef"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = false, extension = ".jpg"))
    }

    @Test
    fun freeEditionAlwaysUsesTheLockedDefaultWatermark() {
        val customized = PhotoFrameWatermark(
            enabled = false,
            text = "My camera",
            font = PhotoFrameWatermarkFont.BOLD,
            size = PhotoFrameWatermarkSize.LARGE,
            position = PhotoFrameWatermarkPosition.RIGHT,
            color = PhotoFrameWatermarkColor.GOLD,
            opacity = PhotoFrameWatermarkOpacity.STRONG,
            effect = PhotoFrameWatermarkEffect.OUTLINE,
        )

        val free = effectivePhotoFrameWatermark(false, customized)
        val pro = effectivePhotoFrameWatermark(true, customized)

        assertEquals(PhotoFrameWatermark(), free)
        assertEquals(PhotoFrameWatermarkOpacity.STANDARD, free.opacity)
        assertEquals(PhotoFrameWatermarkEffect.AUTO, free.effect)
        assertEquals(customized, pro)
        assertEquals(PhotoFrameWatermarkOpacity.STRONG, pro.opacity)
        assertEquals(PhotoFrameWatermarkEffect.OUTLINE, pro.effect)
    }

    @Test
    fun transferStateIncludesWatermarkOpacityAndEffect() {
        val state = TransferState(
            photoFrameWatermarkOpacity = PhotoFrameWatermarkOpacity.SUBTLE,
            photoFrameWatermarkEffect = PhotoFrameWatermarkEffect.SHADOW,
        )

        assertEquals(PhotoFrameWatermarkOpacity.SUBTLE, state.photoFrameWatermark.opacity)
        assertEquals(PhotoFrameWatermarkEffect.SHADOW, state.photoFrameWatermark.effect)
    }

    @Test
    fun imageWatermarkKeepsItsPrivateHashAndUsesOnlyPhotoPositions() {
        val imageHash = "a".repeat(64)
        val preference = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = imageHash,
            position = PhotoFrameWatermarkPosition.LEFT,
        )

        val effective = effectivePhotoFrameWatermark(true, preference)

        assertEquals(PhotoFrameWatermarkContent.IMAGE, effective.content)
        assertEquals(imageHash, effective.imageHash)
        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT, effective.position)
    }

    @Test
    fun invalidImageWatermarkFallsBackToTextWithoutChangingItsTextPosition() {
        val preference = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = "not-a-hash",
            position = PhotoFrameWatermarkPosition.LEFT,
        )

        val effective = effectivePhotoFrameWatermark(true, preference)

        assertEquals(PhotoFrameWatermarkContent.TEXT, effective.content)
        assertEquals(null, effective.imageHash)
        assertEquals(PhotoFrameWatermarkPosition.LEFT, effective.position)
    }

    @Test
    fun queueTaskSnapshotsFrameSettingsAtClickTime() {
        val jpeg = file(1)
        val mist = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
        ).single()
        val cinema = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.CINEMA,
            photoFrameWatermark = PhotoFrameWatermark(enabled = false),
        ).single()

        assertEquals(PhotoFramePreset.MIST, mist.framePreset)
        assertEquals(PhotoFramePreset.CINEMA, cinema.framePreset)
        assertEquals(true, mist.frameWatermarkRequested.enabled)
        assertEquals(false, cinema.frameWatermarkRequested.enabled)
        assertNotEquals(mist.taskId, cinema.taskId)
    }

    @Test
    fun repeatedClickAlwaysCreatesAnIndependentTask() {
        val jpeg = file(1)
        val first = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
        ).single()
        val repeated = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
        ).single()

        assertEquals(PhotoFramePreset.MIST, first.framePreset)
        assertEquals(PhotoFramePreset.MIST, repeated.framePreset)
        assertNotEquals(first.taskId, repeated.taskId)
    }

    @Test
    fun oneBatchStillContainsEachCameraFileOnlyOnce() {
        val jpeg = file(1)
        val tasks = createQueueTasks(
            files = listOf(jpeg, jpeg),
            photoFrameEnabled = false,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
        )

        assertEquals(1, tasks.size)
        assertEquals(null, tasks.single().framePreset)
    }

    @Test
    fun thumbnailColumnsUseOnlyTheSupportedTwoToFourRange() {
        assertEquals(2, normalizeThumbnailColumns(1))
        assertEquals(2, normalizeThumbnailColumns(2))
        assertEquals(3, normalizeThumbnailColumns(3))
        assertEquals(4, normalizeThumbnailColumns(4))
        assertEquals(4, normalizeThumbnailColumns(9))
    }

}
