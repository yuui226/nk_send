package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
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
    fun onlyAnAlreadyTransferredJpegBecomesAFrameOnlyTask() {
        val jpeg = file(1)
        val video = NikonCamera.FileInfo(
            handle = 2,
            size = 100L,
            fileName = "DSC_2.MP4",
            captureDate = null,
        )
        val existing = mapOf(jpeg.fileName to setOf(jpeg.size), video.fileName to setOf(video.size))

        assertEquals(
            TransferTaskMode.FRAME_ONLY,
            transferTaskModeFor(
                jpeg,
                photoFrameEnabled = true,
                existingExportFiles = existing,
            ),
        )
        assertEquals(
            TransferTaskMode.DOWNLOAD,
            transferTaskModeFor(
                jpeg,
                photoFrameEnabled = false,
                existingExportFiles = existing,
            ),
        )
        assertEquals(
            TransferTaskMode.DOWNLOAD,
            transferTaskModeFor(
                jpeg,
                photoFrameEnabled = true,
                existingExportFiles = emptyMap(),
            ),
        )
        assertEquals(
            TransferTaskMode.DOWNLOAD,
            transferTaskModeFor(
                video,
                photoFrameEnabled = true,
                existingExportFiles = existing,
            ),
        )
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
