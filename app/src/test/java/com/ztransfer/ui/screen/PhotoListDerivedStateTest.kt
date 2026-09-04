package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.ExportedOriginalIndex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoListDerivedStateTest {
    @Test
    fun `exported handles are not materialized while filter is disabled`() {
        val file = file(handle = 7, name = "DSC_0007.JPG", size = 123L)
        val index = ExportedOriginalIndex().apply { add(file.fileName, file.size) }

        assertTrue(
            exportedHandlesForUntransferredFilter(
                files = listOf(file),
                index = index,
                organizeTransfersByDate = false,
                enabled = false,
            ).isEmpty()
        )
        assertEquals(
            setOf(file.handle),
            exportedHandlesForUntransferredFilter(
                files = listOf(file),
                index = index,
                organizeTransfersByDate = false,
                enabled = true,
            )
        )
    }

    @Test
    fun `photo and burst collection use distinct lazy content types`() {
        val file = file(handle = 1, name = "DSC_0001.JPG")

        assertEquals("photo", ThumbnailGridItem.Photo(file).reuseContentType)
        assertEquals(
            "burst_collection",
            ThumbnailGridItem.BurstCollection("burst", listOf(file)).reuseContentType,
        )
    }

    private fun file(
        handle: Int,
        name: String,
        size: Long = 100L,
    ) = CameraFileInfo(
        handle = handle,
        fileName = name,
        size = size,
        captureDate = "20260813T120000",
    )
}
