package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.ExportedOriginalIndex
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
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
    fun `latest task index keeps the newest task for each handle`() {
        val older = TransferTask(file(handle = 3, name = "DSC_0003.JPG"))
        val other = TransferTask(file(handle = 4, name = "DSC_0004.JPG"))
        val newer = older.copy(taskId = older.taskId + 100, status = TransferStatus.COMPLETED)
        val tasks = listOf(older, other, newer)

        val index = buildLatestTaskIndexByHandle(tasks)

        assertEquals(newer, tasks[index.getValue(3)])
        assertEquals(other, tasks[index.getValue(4)])
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
