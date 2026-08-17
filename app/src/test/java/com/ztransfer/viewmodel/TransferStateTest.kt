package com.ztransfer.viewmodel

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
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
    @Test
    fun frameGenerationTimingUsesUserVisibleMonotonicInterval() {
        val started = TransferTask(file(1)).startFrameGeneration(nowElapsedMs = 1_000L)

        assertEquals(true, started.isGeneratingFrame)
        assertEquals(1_000L, started.frameGenerationStartedAtElapsedMs)
        assertEquals(null, started.frameGenerationElapsedMs)

        val finished = started.finishFrameGeneration(nowElapsedMs = 26_250L)

        assertEquals(false, finished.isGeneratingFrame)
        assertEquals(null, finished.frameGenerationStartedAtElapsedMs)
        assertEquals(25_250L, finished.frameGenerationElapsedMs)
    }

    @Test
    fun finishingInactiveFrameGenerationDoesNotOverwriteItsRecordedDuration() {
        val task = TransferTask(file(1), frameGenerationElapsedMs = 2_500L)

        assertEquals(task, task.finishFrameGeneration(nowElapsedMs = 10_000L))
    }

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
    fun taskStructureUpdatesIncrementOnlyTheStructureRevision() {
        val original = TransferTask(file(1))
        val added = TransferTask(file(2))
        val state = TransferState(
            tasks = listOf(original),
            taskStructureRevision = 7L,
            isTransferring = true,
        )

        val updated = state.withTaskStructure(state.tasks + added)

        assertEquals(listOf(original, added), updated.tasks)
        assertEquals(8L, updated.taskStructureRevision)
        assertEquals(true, updated.isTransferring)
    }

    @Test
    fun statusOnlyTaskReplacementDoesNotChangeTheStructureRevision() {
        val task = TransferTask(file(1))
        val state = TransferState(tasks = listOf(task), taskStructureRevision = 7L)

        val updated = state.copy(
            tasks = listOf(task.copy(status = TransferStatus.TRANSFERING))
        )

        assertEquals(7L, updated.taskStructureRevision)
        assertEquals(TransferStatus.TRANSFERING, updated.tasks.single().status)
    }

    @Test
    fun queueSpeedSurvivesZeroSamplesBetweenFiles() {
        assertEquals(12L * 1024L * 1024L, retainLastValidTransferSpeed(0L, 12L * 1024L * 1024L))
        assertEquals(12L * 1024L * 1024L, retainLastValidTransferSpeed(12L * 1024L * 1024L, 0L))
        assertEquals(9L * 1024L * 1024L, retainLastValidTransferSpeed(12L * 1024L * 1024L, 9L * 1024L * 1024L))
    }

    @Test
    fun activeProgressIsMergedOnlyIntoItsMatchingTaskSnapshot() {
        val activeTask = TransferTask(file(1), status = TransferStatus.TRANSFERING)
        val waitingTask = TransferTask(file(2), status = TransferStatus.WAITING)
        val progress = ActiveTransferProgress(
            taskId = activeTask.taskId,
            fraction = 0.4f,
            downloaded = 40L,
            bytesPerSecond = 12L,
            retainedBytesPerSecond = 15L,
        )

        val merged = activeTask.withActiveProgress(progress)

        assertEquals(0.4f, merged.progress)
        assertEquals(40L, merged.downloaded)
        assertEquals(12L, merged.speed)
        assertEquals(0f, activeTask.progress)
        assertEquals(waitingTask, waitingTask.withActiveProgress(progress))
    }

    @Test
    fun pendingQueuePreservesOrderAndWithdrawsWithoutScanningHistory() {
        val first = TransferTask(file(1))
        val second = TransferTask(file(2))
        val third = TransferTask(file(3))
        val queue = PendingTransferQueue()
        queue.addAll(listOf(first, second, third))

        queue.withdraw(listOf(second.taskId))

        assertEquals(first, queue.takeFirst())
        assertEquals(third, queue.takeFirst())
        assertEquals(null, queue.takeFirst())
    }

    @Test
    fun claimedPendingTaskCanStillBeWithdrawnDuringPreflight() {
        val task = TransferTask(file(1))
        val queue = PendingTransferQueue()
        queue.addAll(listOf(task))

        assertEquals(task, queue.takeFirst())
        queue.withdraw(listOf(task.taskId))

        assertEquals(true, queue.consumeWithdrawal(task.taskId))
        assertEquals(false, queue.consumeWithdrawal(task.taskId))
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
        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER, effective.position)
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

        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER, pro.position)
        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER, free.position)
    }

    @Test
    fun persistedPreferenceKeepsPositionHiddenByCurrentConstraints() {
        val preference = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = "a".repeat(64),
            position = PhotoFrameWatermarkPosition.LEFT,
            opacityPercent = 140,
        )

        val normalized = normalizedPhotoFrameWatermarkPreference(
            preference = preference,
            borderEnabled = false,
        )

        assertEquals(PhotoFrameWatermarkContent.IMAGE, normalized.content)
        assertEquals(PhotoFrameWatermarkPosition.LEFT, normalized.position)
        assertEquals(100, normalized.opacityPercent)
        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            effectivePhotoFrameWatermark(
                isPro = true,
                preference = normalized,
                borderEnabled = false,
            ).position,
        )
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
        val mistMetadata = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showModel = false,
        )
        val cinemaMetadata = defaultPhotoFrameMetadataSettings(PhotoFramePreset.CINEMA).copy(
            showDate = true,
            datePattern = "yyyy.MM.dd",
        )
        val mist = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(enabled = true),
            photoFrameMetadataSettings = mistMetadata,
        ).single()
        val cinema = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.CINEMA,
            photoFrameWatermark = PhotoFrameWatermark(enabled = false),
            photoFrameMetadataSettings = cinemaMetadata,
        ).single()

        assertEquals(PhotoFramePreset.MIST, mist.framePreset)
        assertEquals(PhotoFramePreset.CINEMA, cinema.framePreset)
        assertEquals(true, mist.frameWatermarkRequested.enabled)
        assertEquals(false, cinema.frameWatermarkRequested.enabled)
        assertEquals(mistMetadata, mist.frameMetadataSettings)
        assertEquals(cinemaMetadata, cinema.frameMetadataSettings)
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
