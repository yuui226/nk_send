package com.ztransfer.viewmodel

import com.ztransfer.frame.PhotoFramePreset
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
    fun freeUsersAlwaysKeepBrandingWhileProUsersFollowPreference() {
        assertEquals(true, photoFrameBrandingVisible(isPro = false, preferenceEnabled = false))
        assertEquals(true, photoFrameBrandingVisible(isPro = false, preferenceEnabled = true))
        assertEquals(false, photoFrameBrandingVisible(isPro = true, preferenceEnabled = false))
        assertEquals(true, photoFrameBrandingVisible(isPro = true, preferenceEnabled = true))
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
    fun queueTaskSnapshotsFrameSettingsAtClickTime() {
        val jpeg = file(1)
        val mist = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameBrandingEnabled = true,
        ).single()
        val cinema = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.CINEMA,
            photoFrameBrandingEnabled = false,
        ).single()

        assertEquals(PhotoFramePreset.MIST, mist.framePreset)
        assertEquals(PhotoFramePreset.CINEMA, cinema.framePreset)
        assertEquals(true, mist.frameBrandingRequested)
        assertEquals(false, cinema.frameBrandingRequested)
        assertNotEquals(mist.taskId, cinema.taskId)
    }

    @Test
    fun repeatedClickAlwaysCreatesAnIndependentTask() {
        val jpeg = file(1)
        val first = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameBrandingEnabled = true,
        ).single()
        val repeated = createQueueTasks(
            files = listOf(jpeg),
            photoFrameEnabled = true,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameBrandingEnabled = true,
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
            photoFrameBrandingEnabled = true,
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
