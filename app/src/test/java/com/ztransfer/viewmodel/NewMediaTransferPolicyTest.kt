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
    fun `handle delta returns only objects added to the connection baseline`() {
        assertEquals(
            setOf(12),
            addedHandlesOrNull(
                knownHandles = setOf(10, 11),
                currentHandles = setOf(10, 11, 12),
            ),
        )
        assertEquals(
            emptySet<Int>(),
            addedHandlesOrNull(
                knownHandles = setOf(10, 11),
                currentHandles = setOf(10, 11),
            ),
        )
    }

    @Test
    fun `empty card baseline accepts additions but disappearing handles force reset`() {
        assertEquals(
            setOf(1),
            addedHandlesOrNull(
                knownHandles = emptySet(),
                currentHandles = setOf(1),
            ),
        )
        assertNull(
            addedHandlesOrNull(
                knownHandles = setOf(10, 11),
                currentHandles = setOf(10, 12),
            ),
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
