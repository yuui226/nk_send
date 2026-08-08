package com.ztransfer.viewmodel

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
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
    fun photoEffectsUseABoundedMultiWorkerPool() {
        assertEquals(2, PHOTO_FRAME_EXPORT_PARALLELISM)
    }

    @Test
    fun connectedPhotoEffectsUseTheNewWatermarkDefaults() {
        val state = TransferState()

        assertEquals(PhotoFrameWatermarkFont.CALLIGRAPHY, state.photoFrameWatermarkFont)
        assertEquals(80, state.photoFrameWatermarkSizePercent)
        assertEquals(
            80,
            restoredPhotoFrameWatermarkSizePercent(
                persisted = null,
                content = PhotoFrameWatermarkContent.TEXT,
            ),
        )
    }

    @Test
    fun queueSpeedSurvivesZeroSamplesBetweenFiles() {
        assertEquals(12L * 1024L * 1024L, retainLastValidTransferSpeed(0L, 12L * 1024L * 1024L))
        assertEquals(12L * 1024L * 1024L, retainLastValidTransferSpeed(12L * 1024L * 1024L, 0L))
        assertEquals(9L * 1024L * 1024L, retainLastValidTransferSpeed(12L * 1024L * 1024L, 9L * 1024L * 1024L))
    }

    @Test
    fun downloadAndGenerationRemainingCountsStayIndependent() {
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

        assertEquals(2, state.downloadRemainingCount)
        assertEquals(1, state.generationRemainingCount)
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

        assertEquals(0, state.downloadRemainingCount)
        assertEquals(1, state.generationRemainingCount)
        assertEquals(1f, state.currentFileProgress)
    }

    @Test
    fun framesAreGeneratedOnlyForSupportedBitmapPhotos() {
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".jpg"))
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".JPEG"))
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".png"))
        assertEquals(true, shouldGeneratePhotoFrame(enabled = true, extension = ".PNG"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".mov"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".mp4"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = true, extension = ".nef"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = false, extension = ".jpg"))
        assertEquals(false, shouldGeneratePhotoFrame(enabled = false, extension = ".png"))
    }

    @Test
    fun freeEditionAlwaysUsesTheLockedDefaultWatermark() {
        val customized = PhotoFrameWatermark(
            enabled = false,
            text = "My camera",
            font = PhotoFrameWatermarkFont.BOLD,
            sizePercent = 300,
            position = PhotoFrameWatermarkPosition.RIGHT,
            color = PhotoFrameWatermarkColor.GOLD,
            opacityPercent = 100,
            effect = PhotoFrameWatermarkEffect.OUTLINE,
        )

        val free = effectivePhotoFrameWatermark(false, customized)
        val pro = effectivePhotoFrameWatermark(true, customized)

        assertEquals(freeEditionPhotoFrameWatermark(), free)
        assertEquals(80, free.sizePercent)
        assertEquals(PhotoFrameWatermarkFont.CALLIGRAPHY, free.font)
        assertEquals(80, free.opacityPercent)
        assertEquals(PhotoFrameWatermarkEffect.AUTO, free.effect)
        assertEquals(customized, pro)
        assertEquals(300, pro.sizePercent)
        assertEquals(100, pro.opacityPercent)
        assertEquals(PhotoFrameWatermarkEffect.OUTLINE, pro.effect)
    }

    @Test
    fun transferStateIncludesWatermarkOpacityAndEffect() {
        val state = TransferState(
            photoFrameWatermarkOpacityPercent = 41,
            photoFrameWatermarkEffect = PhotoFrameWatermarkEffect.SHADOW,
        )

        assertEquals(41, state.photoFrameWatermark.opacityPercent)
        assertEquals(PhotoFrameWatermarkEffect.SHADOW, state.photoFrameWatermark.effect)
    }

    @Test
    fun legacyWatermarkSizeAndOpacityPreferencesMigrateWithoutVisualJumps() {
        assertEquals(9, restoredPhotoFrameWatermarkSizePercent("SMALL", PhotoFrameWatermarkContent.TEXT))
        assertEquals(26, restoredPhotoFrameWatermarkSizePercent("MEDIUM", PhotoFrameWatermarkContent.TEXT))
        assertEquals(1, restoredPhotoFrameWatermarkSizePercent("SMALL", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(20, restoredPhotoFrameWatermarkSizePercent("MEDIUM", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(51, restoredPhotoFrameWatermarkSizePercent("LARGE", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(
            151,
            restoredPhotoFrameWatermarkSizePercent(
                200,
                PhotoFrameWatermarkContent.TEXT,
                usesLegacyScale = true,
            ),
        )
        assertEquals(300, restoredPhotoFrameWatermarkSizePercent(300, PhotoFrameWatermarkContent.TEXT))
        assertEquals(40, restoredPhotoFrameWatermarkOpacityPercent("SUBTLE"))
        assertEquals(72, restoredPhotoFrameWatermarkOpacityPercent("STANDARD"))
        assertEquals(100, restoredPhotoFrameWatermarkOpacityPercent("STRONG"))
    }

    @Test
    fun watermarkPercentagesAreClampedAtTheRenderingBoundary() {
        val effective = effectivePhotoFrameWatermark(
            isPro = true,
            preference = PhotoFrameWatermark(sizePercent = 999, opacityPercent = 0),
        )

        assertEquals(300, effective.sizePercent)
        assertEquals(1, effective.opacityPercent)
        assertEquals(1, restoredPhotoFrameWatermarkSizePercent(-4, PhotoFrameWatermarkContent.TEXT))
        assertEquals(100, restoredPhotoFrameWatermarkOpacityPercent(140))
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
    fun watermarkOnlyModeForcesTextIntoThePhotoSafeAreaForFreeAndPro() {
        val preference = PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.LEFT)

        val pro = effectivePhotoFrameWatermark(true, preference, borderEnabled = false)
        val free = effectivePhotoFrameWatermark(false, preference, borderEnabled = false)

        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT, pro.position)
        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT, free.position)
    }

    @Test
    fun queueTaskSnapshotsWhetherTheBorderIsEnabled() {
        val task = createQueueTasks(
            files = listOf(file(1)),
            photoFrameEnabled = true,
            photoFrameBorderEnabled = false,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
        ).single()

        assertEquals(false, task.frameBorderRequested)
        assertEquals(PhotoFramePreset.MIST, task.framePreset)
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
    fun queueTaskWithoutAnyPhotoEffectDoesNotRequestDerivativeGeneration() {
        val task = createQueueTasks(
            files = listOf(file(1)),
            photoFrameEnabled = false,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = false),
            photoFilter = null,
        ).single()

        assertEquals(null, task.framePreset)
        assertEquals(null, task.photoFilterRequested)
        assertEquals(false, task.isGeneratingFrame)
    }

    @Test
    fun queueTaskSnapshotsFilterAtClickTimeWithoutEnablingAFrame() {
        val filter = PhotoFilterSelection(
            preset = PhotoFilterPreset(
                id = "abcdef0123456789",
                name = "Simple",
                parameters = NcpPhotoFilterParameters(
                    saturationStep = 0,
                    hueStep = 0,
                    toneCurve = IntArray(257) { index -> (index * 0x7fff) / 256 },
                ),
            ),
            intensityPercent = 64,
        )

        val task = createQueueTasks(
            files = listOf(file(1)),
            photoFrameEnabled = false,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = false),
            photoFilter = filter,
        ).single()

        assertEquals(null, task.framePreset)
        assertEquals(filter, task.photoFilterRequested)
        assertEquals(64, task.photoFilterRequested?.normalizedIntensityPercent)
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
