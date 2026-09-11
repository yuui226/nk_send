package com.ztransfer.viewmodel

import java.time.LocalDate
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.protocol.CameraFileInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NewMediaTransferPolicyTest {
    @Test
    fun `dated folder uses capture day and stable fallback`() {
        val fallback = LocalDate.of(2026, 3, 21)

        assertEquals("ZT2026-08-17", transferDateFolderName("20260817T142530", fallback))
        assertEquals("ZT2026-03-21", transferDateFolderName(null, fallback))
        assertEquals("ZT2026-03-21", transferDateFolderName("20260231T120000", fallback))
        assertEquals("ZT0000-02-29", transferDateFolderName("00000229T120000", fallback))
    }

    @Test
    fun `queue task snapshots dated folder setting when it is added`() {
        val file = CameraFileInfo(7, 1L, "DSC_0007.JPG", "20260817T142530")
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

}
