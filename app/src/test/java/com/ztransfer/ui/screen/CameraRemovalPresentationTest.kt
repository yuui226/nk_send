package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraRemovalPresentationTest {
    private fun file(handle: Int, day: String = "20260827") = CameraFileInfo(
        handle = handle,
        size = 1_000L,
        fileName = "DSC_${handle.toString().padStart(4, '0')}.JPG",
        captureDate = "${day}T120000",
    )

    @Test
    fun deletingTheOnlyPhotoRemovesItsWholeDateGroup() {
        val removedDay = file(1, day = "20260826")
        val survivingDay = file(2, day = "20260827")

        assertEquals(2, groupFilesByDate(listOf(survivingDay, removedDay)).size)
        val remainingGroups = groupFilesByDate(listOf(survivingDay))

        assertEquals(listOf("20260827"), remainingGroups.map { it.date })
        assertEquals(listOf(survivingDay), remainingGroups.single().files)
    }
}
