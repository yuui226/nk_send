package com.ztransfer.viewmodel

import java.time.LocalDate
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NewMediaTransferPolicyTest {
    @Test
    fun `catalog reconciliation switches a deleted backup primary to its surviving alias`() {
        val card1 = NikonCamera.FileInfo(
            handle = 10,
            size = 42L,
            fileName = "DSC_0010.JPG",
            captureDate = "20260827T120000",
            storageIds = setOf(0x00010001),
        )
        val card2 = card1.copy(handle = 20, storageIds = setOf(0x00020001))
        val published = mergeStorageMembership(card1, card2)

        assertEquals(
            listOf(card2),
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = setOf(20),
                indexedFilesByHandle = mapOf(20 to card2),
            ),
        )
        assertEquals(
            listOf(card1),
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = setOf(10),
                indexedFilesByHandle = mapOf(10 to card1),
            ),
        )
        assertTrue(
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = emptySet(),
                indexedFilesByHandle = emptyMap(),
            ).isEmpty(),
        )
    }

    @Test
    fun `dated folder uses capture day and stable fallback`() {
        val fallback = LocalDate.of(2026, 3, 21)

        assertEquals("ZT2026-08-17", transferDateFolderName("20260817T142530", fallback))
        assertEquals("ZT2026-03-21", transferDateFolderName(null, fallback))
        assertEquals("ZT2026-03-21", transferDateFolderName("20260231T120000", fallback))
    }

    @Test
    fun `queue task snapshots dated folder setting when it is added`() {
        val file = NikonCamera.FileInfo(7, 1L, "DSC_0007.JPG", "20260817T142530")
        fun task(organized: Boolean) = createQueueTasks(
            files = listOf(file),
            photoFrameEnabled = false,
            photoFramePreset = PhotoFramePreset.MIST,
            photoFrameWatermark = PhotoFrameWatermark(),
            organizeTransfersByDate = organized,
            queuedDate = LocalDate.of(2026, 3, 21),
        ).single()

        assertEquals("ZT2026-08-17", task(organized = true).destinationFolderName)
        assertNull(task(organized = false).destinationFolderName)
    }

    @Test
    fun `automatic transfer accepts known photos and videos but not unknown objects`() {
        fun file(name: String) = NikonCamera.FileInfo(1, 1L, name, null)

        assertTrue(isAutoTransferMedia(file("DSC_0001.JPG")))
        assertTrue(isAutoTransferMedia(file("DSC_0002.NEF")))
        assertTrue(isAutoTransferMedia(file("DSC_0003.MOV")))
        assertTrue(isAutoTransferMedia(file("DSC_0004.AVI")))
        assertFalse(isAutoTransferMedia(file("OBJECT.BIN")))
    }
}
